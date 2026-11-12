import AppKit

/// Shared visual system for Bar Control's standalone windows.
@MainActor
enum WindowDesign {
    static let pageInset: CGFloat = 24
    static let cardRadius: CGFloat = 12
    static let accent = NSColor.controlAccentColor

    /// 方案 D：顶部统计头里的一个数字 + 标签。
    static func heroMetric(value: String, caption: String, color: NSColor) -> NSView {
        let container = NSView()
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = color
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(valueLabel)
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 9.5)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.alignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(captionLabel)
        NSLayoutConstraint.activate([
            valueLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor),
            captionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            captionLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1),
            captionLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// 方案 D：行内的发光状态点。
    static func statusDot(color: NSColor, glowing: Bool) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = 4.5
        if glowing {
            view.layer?.shadowColor = color.cgColor
            view.layer?.shadowOpacity = 0.55
            view.layer?.shadowRadius = 4
            view.layer?.shadowOffset = .zero
        }
        return view
    }

    static func background(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor(calibratedWhite: 0.957, alpha: 1)
    }

    static func applyBackground(to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = background(for: view.effectiveAppearance).cgColor
    }

    static func cardBackground(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.17, alpha: 1)
            : NSColor.white
    }

    static func cardBorder(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1)
            : NSColor.black.withAlphaComponent(0.075)
    }

    static func card(
        frame: NSRect,
        tint: NSColor? = nil,
        emphasized: Bool = false
    ) -> WindowCard {
        WindowCard(frame: frame, tint: tint, emphasized: emphasized)
    }

    static func header(
        title: String,
        subtitle: String,
        symbol: String,
        accent: NSColor
    ) -> NSView {
        let container = NSView()
        let symbolView = NSImageView()
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        symbolView.contentTintColor = accent
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(symbolView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            symbolView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            symbolView.widthAnchor.constraint(equalToConstant: 30),
            symbolView.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func statusPill(text: String, color: NSColor, width: CGFloat? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        let size = label.intrinsicContentSize
        let width = width ?? (size.width + 16)
        let pill = PillBackgroundView(color: color)
        pill.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        label.frame = NSRect(x: 6, y: 2, width: width - 12, height: 15)
        pill.addSubview(label)
        return pill
    }

    static func actionButton(
        _ title: String,
        target: AnyObject?,
        action: Selector,
        emphasis: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.keyEquivalent = emphasis ? "\r" : ""
        return button
    }

    /// Section heading used to preserve the menu's former grouping inside a
    /// details window. A count is optional so "常驻任务" and "定时任务"
    /// remain distinguishable at a glance.
    static func section(
        title: String,
        count: Int? = nil,
        symbol: String,
        accent: NSColor
    ) -> NSView {
        let container = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        var trailing = container.trailingAnchor
        if let count {
            let countLabel = NSTextField(labelWithString: "\(count)")
            countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            countLabel.textColor = .tertiaryLabelColor
            countLabel.alignment = .right
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(countLabel)
            NSLayoutConstraint.activate([
                countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            trailing = countLabel.leadingAnchor
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -8),
            container.heightAnchor.constraint(equalToConstant: 22),
        ])
        return container
    }

    /// Summary metric placed in the window header. Keeps the page useful at a
    /// glance without adding another row of cards.
    static func metric(text: String, value: String, color: NSColor) -> NSView {
        let container = NSView()
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        valueLabel.textColor = color
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(valueLabel)
        let caption = NSTextField(labelWithString: text)
        caption.font = .systemFont(ofSize: 10.5)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(caption)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor),
            caption.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 5),
            caption.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }
}

@MainActor
final class WindowCard: NSView {
    private let tint: NSColor?
    private let emphasized: Bool

    init(frame: NSRect, tint: NSColor?, emphasized: Bool) {
        self.tint = tint
        self.emphasized = emphasized
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = WindowDesign.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = tint ?? WindowDesign.accent
        if let tint {
            layer?.backgroundColor = tint.withAlphaComponent(dark ? 0.19 : 0.11).cgColor
            layer?.borderColor = tint.withAlphaComponent(dark ? 0.36 : 0.24).cgColor
        } else {
            layer?.backgroundColor = WindowDesign.cardBackground(for: effectiveAppearance).cgColor
            layer?.borderColor = WindowDesign.cardBorder(for: effectiveAppearance).cgColor
        }
        if emphasized && tint == nil {
            layer?.borderColor = base.withAlphaComponent(dark ? 0.3 : 0.2).cgColor
        }
    }
}

/// Root page view that keeps its explicit background in sync with the
/// window appearance (including when system light/dark mode changes).
@MainActor
final class WindowPageView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        WindowDesign.applyBackground(to: self)
    }

    override func updateLayer() {
        WindowDesign.applyBackground(to: self)
    }
}

@MainActor
private final class PillBackgroundView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Flat, explicitly drawn action row. Unlike NSButton.layer colors, this
/// redraws when the window switches between light and dark appearance.
@MainActor
/// 行内文字/图标不接收点击，事件要落到整行上（否则点在标题文字上没反应）。
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 带滑块的开关，和 macOS 控制中心的开关同构：轨道颜色渐变 + 滑块位移 + 轻微回弹。
final class WindowToggleSwitch: NSView {
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private(set) var isOn = false
    private let trackSize = NSSize(width: 34, height: 20)

    init() {
        super.init(frame: NSRect(origin: .zero, size: trackSize))
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(knobLayer)
        trackLayer.frame = CGRect(origin: .zero, size: trackSize)
        trackLayer.cornerRadius = trackSize.height / 2
        knobLayer.cornerRadius = 8
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.18
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { trackSize }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        apply(animated: animated)
    }

    private var knobOriginX: CGFloat { isOn ? trackSize.width - 18 : 2 }

    private func apply(animated: Bool) {
        let trackColor = (isOn
            ? NSColor.controlAccentColor
            : NSColor.systemGray.withAlphaComponent(0.45)).cgColor
        let knobCenter = CGPoint(x: knobOriginX + 8, y: trackSize.height / 2)
        if animated {
            let color = CABasicAnimation(keyPath: "backgroundColor")
            color.fromValue = trackLayer.backgroundColor
            color.toValue = trackColor
            color.duration = 0.16
            trackLayer.add(color, forKey: "stateColor")
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = knobLayer.position.x
            move.toValue = knobCenter.x
            move.duration = 0.2
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 1.4, 0.6, 1.0)
            knobLayer.add(move, forKey: "stateMove")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.backgroundColor = trackColor
        knobLayer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        knobLayer.position = knobCenter
        CATransaction.commit()
    }
}

final class WindowActionRow: NSView {
    private let title: String
    private let subtitle: String
    private let symbol: String
    private let action: Selector
    weak var target: AnyObject?
    private let titleLabel = PassthroughLabel(labelWithString: "")
    private let subtitleLabel = PassthroughLabel(labelWithString: "")
    private let iconView = PassthroughImageView()
    private let chevronView = PassthroughImageView()
    private let valueLabel = PassthroughLabel(labelWithString: "")
    private let toggleView = WindowToggleSwitch()
    private var symbolOff: String?

    init(frame: NSRect, title: String, subtitle: String, symbol: String,
         value: String? = nil, toggle: Bool = false, symbolOff: String? = nil,
         image: NSImage? = nil,
         target: AnyObject?, action: Selector) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.target = target
        self.action = action
        super.init(frame: frame)
        wantsLayer = true
        self.symbolOff = symbolOff
        for subview in [titleLabel, subtitleLabel, iconView, chevronView, valueLabel, toggleView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        iconView.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // 真实 App 图标自带颜色；SF Symbol 才需要跟随强调色。
        iconView.contentTintColor = image == nil ? .controlAccentColor : nil
        chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevronView.contentTintColor = .tertiaryLabelColor
        valueLabel.stringValue = value ?? ""
        valueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.isHidden = value == nil || toggle
        chevronView.isHidden = value != nil || toggle
        toggleView.isHidden = !toggle
        iconView.wantsLayer = true
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 50),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 96),
            toggleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 14),
            chevronView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    /// 开关行：滑块动画 + 图标切换到“填充版”，并轻微弹一下。
    func setSwitchState(on: Bool, animated: Bool) {
        toggleView.setOn(on, animated: animated)
        guard let symbolOff else { return }
        let name = on ? symbol : symbolOff
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard animated, let iconLayer = iconView.layer else { return }
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.84
        pop.toValue = 1.0
        pop.duration = 0.2
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(pop, forKey: "iconState")
    }

    /// 动作行（显示/收起）：文字淡入 + 图标轻弹。
    func setValueText(_ text: String, symbol: String?, animated: Bool) {
        valueLabel.stringValue = text
        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        guard animated else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.16
        valueLabel.layer?.add(fade, forKey: "valueFade")
        if let iconLayer = iconView.layer {
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.84
            pop.toValue = 1.0
            pop.duration = 0.18
            iconLayer.add(pop, forKey: "iconPop")
        }
    }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = WindowDesign.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        // 设置行不维护悬停选中状态，滚动/切页时不会遗留高亮。
        layer?.backgroundColor = WindowDesign.cardBackground(for: effectiveAppearance).cgColor
        layer?.borderColor = WindowDesign.cardBorder(for: effectiveAppearance).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        _ = target?.perform(action, with: self)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
