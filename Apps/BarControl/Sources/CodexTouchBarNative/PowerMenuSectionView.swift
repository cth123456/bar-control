import AppKit

/// The power area is a top-level menu item, not a submenu header.
/// AppKit routes clicks on submenu rows into submenu tracking, which made
/// controls embedded in the header unreachable; a plain item view receives
/// clicks normally, like the application-yield row.
@MainActor
final class PowerMenuSectionView: NSView {
    let titleLabel = NSTextField(labelWithString: "整机功率")
    let iconView = NSImageView()
    let controls = PowerMenuControlsView()
    let panel: NSView
    var onEcoTap: (() -> Void)?
    /// +5 / -5 from the inline arrows.
    var onLimitStep: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    init(width: CGFloat, panel: NSView) {
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40 + panel.frame.height))
        autoresizingMask = [.width]
        iconView.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .controlAccentColor
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        for view in [iconView, titleLabel, controls, panel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("整机功率")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var ecoRect: NSRect {
        NSRect(x: controls.frame.minX, y: controls.frame.minY,
               width: controls.ecoButton.frame.width, height: controls.frame.height)
    }

    private var limitRect: NSRect {
        NSRect(x: controls.frame.minX + 68, y: controls.frame.minY,
               width: controls.frame.width - 68, height: controls.frame.height)
    }

    private func limitStep(at point: NSPoint) -> Int? {
        let local = NSPoint(x: point.x - controls.frame.minX, y: point.y - controls.frame.minY)
        if controls.limitDown.frame.contains(local) { return -5 }
        if controls.limitUp.frame.contains(local) { return 5 }
        return nil
    }

    /// Menu item views are the reliable click target inside NSMenu; child
    /// buttons are not always reached, so dispatch from the row itself.
    private var powerPanel: PowerFlowPanelView? { panel as? PowerFlowPanelView }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let powerPanel,
           powerPanel.containsPolicyControl(at: convert(point, to: powerPanel)) {
            return self
        }
        if ecoRect.contains(point) || limitRect.contains(point) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let powerPanel,
           powerPanel.handlePolicyClick(at: convert(point, to: powerPanel)) {
            return
        }
        if ecoRect.contains(point) {
            onEcoTap?()
            return
        }
        if limitRect.contains(point), let step = limitStep(at: point) {
            onLimitStep?(step)
            return
        }
        super.mouseDown(with: event)
    }

    func layout(width: CGFloat) {
        let target = NSSize(width: width, height: 40 + panel.frame.height)
        if frame.size != target { setFrameSize(target) }
        layoutRow(width: width)
    }

    override func layout() {
        super.layout()
        layoutRow(width: bounds.width)
    }

    private func layoutRow(width: CGFloat) {
        let inset: CGFloat = 17
        iconView.frame = NSRect(x: inset, y: 12, width: 15, height: 15)
        let titleText = titleLabel.stringValue as NSString
        let measured = ceil(titleText.size(withAttributes: [.font: titleLabel.font!]).width) + 2
        let controlWidth = controls.preferredWidth
        let rightInset: CGFloat = 12
        let controlX = max(inset + 25 + measured + 12, width - controlWidth - rightInset)
        titleLabel.frame = NSRect(x: inset + 25, y: 10,
                                  width: max(0, controlX - inset - 25 - 10), height: 18)
        controls.frame = NSRect(x: controlX, y: 6, width: min(controlWidth, width - controlX - rightInset), height: 28)
        controls.layoutSubtreeIfNeeded()
        panel.frame = NSRect(x: 0, y: 40, width: width, height: panel.frame.height)
    }
}
