import AppKit

/// Only runs after an explicit click; no privileged changes during refresh/tests.
enum LowPowerModeCommand {
    static func script(enabled: Bool) -> String {
        "do shell script \"/usr/bin/pmset -a lowpowermode \(enabled ? 1 : 0)\" with administrator privileges"
    }

    static func apply(enabled: Bool) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script(enabled: enabled)]
            let error = Pipe()
            process.standardError = error
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return error.localizedDescription }
            let data = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(data: data, encoding: .utf8) ?? "系统未能切换低电量模式"
            return message.contains("-128") ? "已取消省电模式切换" : message
        }.value
    }
}

@MainActor
final class PowerMenuControlsView: NSView {
    let ecoButton = NSButton()
    let limitDown = NSButton()
    let limitUp = NSButton()
    private let limitLabel = NSTextField(labelWithString: "")
    let limitIcon = NSImageView()
    private var maximum = 100
    var onEco: (() -> Void)?
    /// +5 / -5 from the inline arrows.
    var onStep: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        ecoButton.title = "省电"
        ecoButton.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)
        ecoButton.imagePosition = .imageLeading
        ecoButton.isBordered = false
        ecoButton.font = .systemFont(ofSize: 11, weight: .semibold)
        ecoButton.wantsLayer = true
        ecoButton.layer?.cornerRadius = 13
        ecoButton.target = self
        ecoButton.action = #selector(toggleEco)
        ecoButton.setAccessibilityLabel("系统低电量模式")
        addSubview(ecoButton)

        limitLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        limitLabel.alignment = .right
        addSubview(limitLabel)
        // 强制模板模式：否则符号图可能按多色调色板渲染，tint 的黑白会被盖掉。
        let limitSymbol = NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        limitSymbol?.isTemplate = true
        limitIcon.image = limitSymbol
        limitIcon.contentTintColor = .labelColor
        addSubview(limitIcon)
        for (button, name, delta) in [(limitDown, "chevron.left", -5), (limitUp, "chevron.right", 5)] {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            button.isBordered = false
            button.title = ""
            button.tag = delta
            button.target = self
            button.action = #selector(step(_:))
            addSubview(button)
        }
        limitDown.setAccessibilityLabel("降低充电上限")
        limitUp.setAccessibilityLabel("提高充电上限")
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredWidth: CGFloat { 68 + Self.limitWidth(for: maximum) }

    static func limitWidth(for percent: Int) -> CGFloat {
        let text = "上限 ?percent?" as NSString
        _ = text
        let label = "上限 \(percent)%" as NSString
        let width = label.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width
        return ceil(width) + 12 * 2 + 16 * 2 + 4 + 20
    }

    override func layout() {
        super.layout()
        ecoButton.frame = NSRect(x: 0, y: 1, width: 62, height: 26)
        let limitX: CGFloat = 68
        let width = bounds.width - limitX
        let capsule = NSRect(x: limitX, y: 1, width: width, height: 26)
        limitIcon.frame = NSRect(x: capsule.minX + 10, y: 6.5, width: 14, height: 13)
        // Arrows sit together at the right edge, like a stepper.
        limitUp.frame = NSRect(x: capsule.maxX - 20, y: 1, width: 18, height: 26)
        limitDown.frame = NSRect(x: limitUp.frame.minX - 15, y: 1, width: 16, height: 26)
        limitLabel.frame = NSRect(x: limitIcon.frame.maxX + 2, y: 6,
                                  width: limitDown.frame.minX - limitIcon.frame.maxX - 4, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSRect(x: 68, y: 1, width: bounds.width - 68, height: 26)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 13, yRadius: 13).fill()
    }

    func update(lowPower: Bool, busy: Bool, maximum: Int, effective: Int?, supported: Bool) {
        self.maximum = maximum
        let color: NSColor = lowPower ? .systemGreen : .secondaryLabelColor
        ecoButton.contentTintColor = color
        ecoButton.layer?.backgroundColor = color.withAlphaComponent(lowPower ? 0.12 : 0.07).cgColor
        ecoButton.title = busy ? "切换中" : "省电"
        ecoButton.isEnabled = !busy
        limitLabel.stringValue = "上限 \(maximum)%"
        limitLabel.textColor = supported ? .labelColor : .tertiaryLabelColor
        limitDown.isEnabled = supported && maximum > 80
        limitUp.isEnabled = supported && maximum < 100
        limitDown.contentTintColor = limitDown.isEnabled ? .labelColor : .tertiaryLabelColor
        limitUp.contentTintColor = limitUp.isEnabled ? .labelColor : .tertiaryLabelColor
        limitIcon.contentTintColor = supported ? .labelColor : .tertiaryLabelColor
        toolTip = supported
            ? "最大充电电量 \(maximum)%；当前策略生效上限 \(effective.map(String.init) ?? "未知")%"
            : "本机不支持系统充电上限"
        needsLayout = true
        needsDisplay = true
    }

    @objc private func toggleEco() { onEco?() }
    @objc private func step(_ sender: NSButton) { onStep?(sender.tag) }
}

/// Clipboard and keyboard lock share one 30pt row, styled like the other
/// menu rows: icon + semibold title on the left, a tinted status pill on the right.
@MainActor
final class ClipboardKeyboardMenuRow: NSView {
    let clipboardButton = NSButton()
    let keyboardButton = NSButton()
    private var clipboardCount = 0
    private var keyboard = KeyboardLockPolicy.presentation(locked: false)
    var onClipboard: (() -> Void)?
    var onKeyboard: (() -> Void)?
    override var isFlipped: Bool { true }

    init(width: CGFloat, clipboard: Bool, keyboard: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        autoresizingMask = [.width]
        for button in [clipboardButton, keyboardButton] {
            button.isBordered = false
            button.title = ""
            button.isTransparent = true
            button.target = self
            addSubview(button)
        }
        clipboardButton.isHidden = !clipboard
        keyboardButton.isHidden = !keyboard
        clipboardButton.action = #selector(openClipboard)
        keyboardButton.action = #selector(toggleKeyboard)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let both = !clipboardButton.isHidden && !keyboardButton.isHidden
        let width = both ? bounds.width / 2 : bounds.width
        clipboardButton.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        keyboardButton.frame = NSRect(x: both ? width : 0, y: 0, width: width, height: bounds.height)
        needsDisplay = true
    }

    func update(count: Int, keyboard: KeyboardLockPresentation) {
        clipboardCount = count
        self.keyboard = keyboard
        setAccessibilityLabel("剪贴板 \(count) 条，键盘锁 \(keyboard.title)")
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clipboardButton.frame.contains(point) { openClipboard(); return }
        if keyboardButton.frame.contains(point) { toggleKeyboard(); return }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let half = bounds.width / 2
        let both = !clipboardButton.isHidden && !keyboardButton.isHidden
        func drawHalf(x: CGFloat, width: CGFloat, icon: String, title: String,
                      value: String, tint: NSColor) {
            if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
                let colored = NSImage(size: image.size)
                colored.lockFocus()
                image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.controlAccentColor.setFill()
                NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
                colored.unlockFocus()
                colored.draw(in: NSRect(x: x + 17, y: 7.5, width: 15, height: 15))
            }
            (title as NSString).draw(at: NSPoint(x: x + 39, y: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor])
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: tint]
            let textWidth = (value as NSString).size(withAttributes: attrs).width
            let pillWidth = textWidth + 14
            let pill = NSRect(x: x + width - pillWidth - 14, y: 6, width: pillWidth, height: 18)
            tint.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            (value as NSString).draw(at: NSPoint(x: pill.minX + 7, y: 8), withAttributes: attrs)
        }
        if !clipboardButton.isHidden {
            drawHalf(x: 0, width: both ? half : bounds.width,
                     icon: "doc.on.clipboard", title: "剪贴板",
                     value: "\(clipboardCount) 条",
                     tint: NSColor.secondaryLabelColor)
        }
        if !keyboardButton.isHidden {
            let tint: NSColor = keyboard.permissionMissing ? .systemOrange
                : keyboard.locked ? .systemPurple : .systemGreen
            drawHalf(x: both ? half : 0, width: both ? half : bounds.width,
                     icon: keyboard.symbol, title: "键盘锁",
                     value: keyboard.permissionMissing ? "待授权" : keyboard.locked ? "已锁定" : "已解锁",
                     tint: tint)
        }
        if both {
            NSColor.separatorColor.setFill()
            NSRect(x: half.rounded(), y: 6, width: 1, height: 18).fill()
        }
    }

    @objc private func openClipboard() { onClipboard?() }
    @objc private func toggleKeyboard() { onKeyboard?() }
}

@MainActor
final class ApplicationYieldMenuRow: NSView {
    private let title = NSTextField(labelWithString: "是否在此应用让位")
    private let name = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    private let icon = NSImageView()
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        autoresizingMask = [.width]
        // 让位开关属于辅助设置，视觉上比主模块更弱：小字号、次级颜色。
        title.font = .systemFont(ofSize: 11, weight: .regular)
        title.textColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 10)
        name.textColor = .tertiaryLabelColor
        name.alignment = .right
        name.lineBreakMode = .byTruncatingTail
        icon.image = NSImage(systemSymbolName: "rectangle.on.rectangle.slash", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        for view in [icon, title, name, toggle] { addSubview(view) }
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.controlSize = .small
        toggle.setAccessibilityLabel("是否在此应用让位")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 19, y: 6, width: 13, height: 13)
        title.frame = NSRect(x: 40, y: 5, width: 150, height: 16)
        toggle.frame = NSRect(x: bounds.width - 46, y: 4, width: 32, height: 18)
        name.frame = NSRect(x: 205, y: 5, width: max(0, bounds.width - 259), height: 16)
    }
    func update(name: String?, enabled: Bool) {
        self.name.stringValue = name ?? "不适用"
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = name != nil
    }
    @objc private func changed() { onChange?() }
}

/// Standalone selection panel. A nested NSMenu opened while the status menu is
/// tracking is ignored by AppKit, so the picker is an NSPopover after the menu closes.
@MainActor
final class ChargeLimitPopover: NSObject {
    static let shared = ChargeLimitPopover()
    private var popover: NSPopover?
    private var onSelect: ((Int) -> Void)?

    func show(relativeTo rect: NSRect, of view: NSView, current: Int, onSelect: @escaping (Int) -> Void) {
        close()
        self.onSelect = onSelect
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for percent in [80, 85, 90, 95, 100] {
            let button = NSButton(title: "\(percent)%", target: self, action: #selector(select(_:)))
            button.tag = percent
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12.5, weight: percent == current ? .semibold : .regular)
            button.image = percent == current
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                : nil
            button.imagePosition = .imageLeading
            button.frame = NSRect(x: 0, y: 0, width: 92, height: 24)
            stack.addArrangedSubview(button)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 112, height: 5 * 26 + 16)
        let host = NSViewController()
        host.view = stack
        popover.contentViewController = host
        popover.contentSize = stack.frame.size
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
    }

    @objc private func select(_ sender: NSButton) {
        onSelect?(sender.tag)
        close()
    }
}

/// Plain command row (no submenu): same metrics as the other menu rows,
/// so "退出 Bar Control" no longer falls back to the default menu look.
@MainActor
final class MenuCommandRow: NSView {
    private let iconName: String
    private let title: String
    var onPress: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    init(width: CGFloat, title: String, symbol: String) {
        self.title = title
        self.iconName = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        hovered = false
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let colored = NSImage(size: image.size)
            colored.lockFocus()
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.controlAccentColor.setFill()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
            colored.unlockFocus()
            colored.draw(in: NSRect(x: 17, y: 7.5, width: 15, height: 15))
        }
        (title as NSString).draw(at: NSPoint(x: 39, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor])
    }
}

/// 定时 / 常驻两半，右侧数字气泡用颜色表示状态，和剪贴板那行同构。
@MainActor
final class ServiceCountsMenuRow: NSView {
    private var scheduledRunning = 0, scheduledTotal = 0
    private var residentRunning = 0, residentTotal = 0
    private var unknown = true
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("服务")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(scheduledRunning: Int, scheduledTotal: Int, residentRunning: Int, residentTotal: Int, unknown: Bool) {
        self.scheduledRunning = scheduledRunning; self.scheduledTotal = scheduledTotal
        self.residentRunning = residentRunning; self.residentTotal = residentTotal
        self.unknown = unknown
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onPress?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let half = bounds.width / 2
        func halfRow(x: CGFloat, width: CGFloat, icon: String, title: String, running: Int, total: Int) {
            if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
                let tinted = NSImage(size: image.size); tinted.lockFocus()
                image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.controlAccentColor.setFill(); NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
                tinted.unlockFocus()
                tinted.draw(in: NSRect(x: x + 17, y: 7.5, width: 15, height: 15))
            }
            (title as NSString).draw(at: NSPoint(x: x + 39, y: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor])
            let text = unknown ? "读取中" : "\(running)/\(total)"
            let tone: NSColor = unknown ? .secondaryLabelColor : (running > 0 ? .systemGreen : .secondaryLabelColor)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: tone]
            let w = (text as NSString).size(withAttributes: attrs).width + 14
            let pill = NSRect(x: x + width - w - 14, y: 6, width: w, height: 18)
            tone.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            (text as NSString).draw(at: NSPoint(x: pill.minX + 7, y: 8), withAttributes: attrs)
        }
        halfRow(x: 0, width: half, icon: "clock", title: "定时服务", running: scheduledRunning, total: scheduledTotal)
        NSColor.separatorColor.setFill(); NSRect(x: half.rounded(), y: 6, width: 1, height: 18).fill()
        halfRow(x: half, width: half, icon: "server.rack", title: "常驻服务", running: residentRunning, total: residentTotal)
    }
}
