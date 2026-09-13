import AppKit

// MARK: - Small building blocks

/// Rounded card surface used by the interface detail page.
@MainActor
private final class InterfaceCardView: NSView {
    let contentStack = NSStackView()
    private let emphasized: Bool
    private let tint: NSColor?

    init(emphasized: Bool = false, tint: NSColor? = nil) {
        self.emphasized = emphasized
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 5
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let tint {
            layer?.backgroundColor = tint.withAlphaComponent(isDark ? 0.22 : 0.14).cgColor
            layer?.borderColor = tint.withAlphaComponent(isDark ? 0.45 : 0.35).cgColor
        } else if emphasized {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        }
    }
}

/// PDO / spec chip.
@MainActor
private final class InterfaceChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let highlighted: Bool

    init(text: String, highlighted: Bool) {
        self.highlighted = highlighted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: highlighted ? .semibold : .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if highlighted {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(isDark ? 0.32 : 0.18).cgColor
            label.textColor = isDark ? .white : .controlAccentColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06).cgColor
            label.textColor = .secondaryLabelColor
        }
    }
}

// MARK: - Content view

/// Builds the complete "接口与线缆详情" content. Kept free of window logic so
/// the headless probe can render it straight to PNG.
@MainActor
enum InterfaceDetailContent {
    static let contentWidth: CGFloat = 500

    static func makeView(specs: InterfaceSpecs, metrics: SystemMetrics) -> NSView {
        let container = FlippedContainerView()
        container.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if let charger = specs.charger {
            add(makeChargerCard(charger))
        } else {
            add(makeEmptyChargerCard())
        }

        for port in specs.ports where port.hasCable || port.deviceVendorID != nil {
            add(makePortCard(port, metrics: metrics))
        }

        add(makeVerdictCard(
            PowerDiagnosis.verdict(specs: specs, metrics: metrics)
        ))

        let footer = label(
            "数据来自本机 IORegistry，无需管理员权限 · 速率与供电按 USB-PD 规范保守显示",
            font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor
        )
        add(footer)

        return container
    }

    // MARK: Charger

    private static func makeChargerCard(_ charger: ChargerSpecs) -> NSView {
        let card = InterfaceCardView(emphasized: true)
        let portText = charger.portNumber.map { "USB-C 端口 \($0)" } ?? "USB-C"
        card.contentStack.addArrangedSubview(label(
            "充电器输入 · \(portText)",
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .systemBlue
        ))
        card.contentStack.addArrangedSubview(label(
            charger.name ?? "未知充电器",
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: .labelColor
        ))

        var identity: [String] = []
        if let brand = charger.brandLabel { identity.append(brand) }
        if let model = charger.model { identity.append("型号 \(model)") }
        if let serial = charger.serial { identity.append("序列号 \(serial)") }
        if !identity.isEmpty {
            card.contentStack.addArrangedSubview(label(
                identity.joined(separator: " · "),
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor
            ))
        }

        var tech: [String] = []
        if let firmware = charger.firmware { tech.append("固件 \(firmware)") }
        if let hardware = charger.hardware { tech.append("硬件 \(hardware)") }
        if let watts = charger.ratedWatts { tech.append(String(format: "铭牌 %.0f W", watts)) }
        if !tech.isEmpty {
            card.contentStack.addArrangedSubview(label(
                tech.joined(separator: " · "),
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor
            ))
        }

        if !charger.options.isEmpty {
            card.contentStack.addArrangedSubview(spacer(4))
            card.contentStack.addArrangedSubview(label(
                "PD 档位（当前协商高亮）",
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .secondaryLabelColor
            ))
            let chipRow = NSStackView()
            chipRow.orientation = .horizontal
            chipRow.spacing = 6
            let negotiated = charger.negotiated
            for option in charger.options {
                let isCurrent = negotiated.map {
                    abs($0.volts - option.volts) < 0.01 && abs($0.amps - option.amps) < 0.01
                } ?? false
                chipRow.addArrangedSubview(InterfaceChipView(text: option.label, highlighted: isCurrent))
            }
            card.contentStack.addArrangedSubview(chipRow)
        }

        if let volts = charger.liveVolts, let amps = charger.liveAmps, let watts = charger.liveWatts {
            card.contentStack.addArrangedSubview(spacer(4))
            card.contentStack.addArrangedSubview(label(
                String(format: "当前实测 %.2f V / %.2f A / %.1f W", volts, amps, watts),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                color: .secondaryLabelColor
            ))
        }
        return card
    }

    private static func makeEmptyChargerCard() -> NSView {
        let card = InterfaceCardView()
        card.contentStack.addArrangedSubview(label(
            "充电器",
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .secondaryLabelColor
        ))
        card.contentStack.addArrangedSubview(label(
            "未检测到充电器输入，当前由电池供电。",
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        ))
        return card
    }

    // MARK: Ports

    private static func makePortCard(_ port: PortSpecs, metrics: SystemMetrics) -> NSView {
        let card = InterfaceCardView()
        let roleText = port.isChargerPort ? "充电器端口" : "外接设备"
        card.contentStack.addArrangedSubview(label(
            "\(roleText) · USB-C 端口 \(port.portNumber) · 线缆 e-marker",
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: port.isChargerPort ? .systemBlue : .systemGreen
        ))

        let metricsName = metrics.usbOutputs
            .first { $0.portIndex == port.portNumber }?
            .name
        if let deviceName = port.deviceName ?? metricsName {
            var text = "对端设备：\(deviceName)"
            if let vid = port.deviceVendorID {
                text += String(format: "（VID %d", vid)
                if let pid = port.deviceProductID {
                    text += String(format: " / PID %d", pid)
                }
                text += "）"
            }
            card.contentStack.addArrangedSubview(label(
                text,
                font: .systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor
            ))
        } else if let vid = port.deviceVendorID {
            card.contentStack.addArrangedSubview(label(
                "对端设备：未识别（VID \(vid) / PID \(port.deviceProductID ?? 0)）",
                font: .systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor
            ))
        }

        guard let cable = port.cable else {
            card.contentStack.addArrangedSubview(label(
                "无 e-marker：普通被动线，规格不可知（通常 ≤3 A / 60 W）。",
                font: .systemFont(ofSize: 11),
                color: .secondaryLabelColor
            ))
            return card
        }

        var typeParts: [String] = []
        if let productType = port.cableProductType { typeParts.append(productType) }
        typeParts.append("插头 \(cable.plugLabel)")
        if let revision = port.cableSpecRevision { typeParts.append("规范修订 \(revision)") }
        card.contentStack.addArrangedSubview(label(
            "线缆类型 " + typeParts.joined(separator: " · "),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        ))

        card.contentStack.addArrangedSubview(spacer(2))
        card.contentStack.addArrangedSubview(specRow(
            caption: "速率",
            value: cable.speedLabel,
            note: cable.speedRawNote
        ))
        card.contentStack.addArrangedSubview(specRow(
            caption: "供电",
            value: "\(cable.powerLabel) · \(cable.eprLabel)",
            note: "电流字段 \(cable.currentLabel)"
        ))

        var identity: [String] = []
        identity.append("厂商 \(port.cableVendorID ?? 0) / 产品 \(port.cableProductID ?? 0)")
        if let xid = port.cableCertXID {
            identity.append(xid == 0 ? "无证书 XID" : String(format: "证书 XID 0x%08X", xid))
        } else {
            identity.append("无证书 XID")
        }
        card.contentStack.addArrangedSubview(label(
            identity.joined(separator: " · "),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        ))

        for note in port.notes {
            card.contentStack.addArrangedSubview(label(
                "⚠︎ \(note)",
                font: .systemFont(ofSize: 11, weight: .medium),
                color: .systemOrange
            ))
        }
        return card
    }

    // MARK: Verdict

    private static func makeVerdictCard(_ verdict: PowerVerdict) -> NSView {
        let tint: NSColor
        switch verdict.severity {
        case .ok: tint = .systemGreen
        case .warning: tint = .systemOrange
        case .info: tint = .systemGray
        }
        let card = InterfaceCardView(tint: tint)
        card.contentStack.addArrangedSubview(label(
            verdict.title,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        ))
        let detail = label(
            verdict.detail,
            font: .systemFont(ofSize: 11.5),
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 0
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = contentWidth - 60
        card.contentStack.addArrangedSubview(detail)
        return card
    }

    // MARK: Small helpers

    private static func specRow(caption: String, value: String, note: String) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 1

        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 8
        let captionLabel = label(
            caption,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .tertiaryLabelColor
        )
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        head.addArrangedSubview(captionLabel)
        head.addArrangedSubview(label(
            value,
            font: .systemFont(ofSize: 12.5, weight: .semibold),
            color: .labelColor
        ))
        row.addArrangedSubview(head)

        let noteLabel = label(
            note,
            font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor
        )
        noteLabel.maximumNumberOfLines = 0
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.preferredMaxLayoutWidth = contentWidth - 60
        row.addArrangedSubview(noteLabel)
        return row
    }

    private static func label(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

/// Top-down coordinate container so the scroll content starts at the top.
@MainActor
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Window

@MainActor
final class InterfaceDetailWindowController: NSObject, NSWindowDelegate {
    static let shared = InterfaceDetailWindowController()

    private var window: NSWindow?

    func show(specs: InterfaceSpecs, metrics: SystemMetrics) {
        let content = makeScrollableContent(specs: specs, metrics: metrics)
        if let window {
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 524, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "接口与线缆详情"
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = content
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
            newWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rebuilds the page in place while the window is open, so live power
    /// numbers and hot-plugged cables stay current.
    func updateIfVisible(specs: InterfaceSpecs, metrics: SystemMetrics) {
        guard let window, window.isVisible else { return }
        window.contentView = makeScrollableContent(specs: specs, metrics: metrics)
    }

    private func makeScrollableContent(specs: InterfaceSpecs, metrics: SystemMetrics) -> NSView {
        let content = InterfaceDetailContent.makeView(specs: specs, metrics: metrics)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        return scrollView
    }
}
