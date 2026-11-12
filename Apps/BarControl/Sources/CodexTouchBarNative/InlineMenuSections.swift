import AppKit

/// 将现有菜单动作转为同一菜单中的向下展开行，保留原有 target、action 和勾选视图。
@MainActor
final class InlineMenuSections {
    private struct Row {
        let item: NSMenuItem
        let parents: [String]
    }
    private weak var menu: NSMenu?
    private var rows: [Row] = []
    private var headers: [String: InlineMenuHeader] = [:]
    private(set) var expanded: Set<String>
    var onToggle: ((Set<String>) -> Void)?
    var onBadgeAction: ((MenuSummaryAction) -> Void)?

    init(menu: NSMenu, expanded: Set<String> = []) {
        self.menu = menu
        self.expanded = expanded
    }

    func append(_ item: NSMenuItem, id: String, summary: String = "", badges: [MenuSummaryBadge] = [], parents: [String] = [], opensWindow: (() -> Void)? = nil) {
        guard let menu else { return }
        if let opensWindow {
            let header = InlineMenuHeader(title: item.title, summary: summary, image: item.image,
                                          depth: parents.count)
            header.setFrameSize(NSSize(width: max(340, menu.minimumWidth), height: header.frame.height))
            header.setBadges(badges)
            header.onPress = opensWindow
            header.showsChevron = false
            header.setExpanded(false)
            header.layoutSubtreeIfNeeded()
            headers[id] = header
            item.view = header
            menu.addItem(item)
            rows.append(Row(item: item, parents: parents))
            updateVisibility()
            return
        }
        if let children = item.submenu {
            item.submenu = nil
            let header = InlineMenuHeader(title: item.title, summary: summary, image: item.image,
                                          depth: parents.count)
            header.setFrameSize(NSSize(width: max(340, menu.minimumWidth), height: header.frame.height))
            header.setBadges(badges)
            header.onBadgeAction = { [weak self] action in self?.onBadgeAction?(action) }
            header.onOverflowAction = { [weak self] in self?.setExpanded(true, for: id) }
            header.setExpanded(expanded.contains(id))
            header.layoutSubtreeIfNeeded()
            header.onPress = { [weak self] in self?.toggle(id) }
            headers[id] = header
            item.view = header
            menu.addItem(item)
            rows.append(Row(item: item, parents: parents))
            let childItems = children.items
            children.removeAllItems()
            for (index, child) in childItems.enumerated() {
                append(child, id: "\(id).\(index)", parents: parents + [id])
            }
        } else if !summary.isEmpty || !badges.isEmpty {
            // 纯状态行（无子菜单、无窗口）：仍用摘要头样式，保持和其他模块一致的观感。
            let header = InlineMenuHeader(title: item.title, summary: summary, image: item.image,
                                          depth: parents.count)
            header.setFrameSize(NSSize(width: max(340, menu.minimumWidth), height: header.frame.height))
            header.setBadges(badges)
            header.showsChevron = false
            header.setExpanded(false)
            header.layoutSubtreeIfNeeded()
            headers[id] = header
            item.view = header
            menu.addItem(item)
            rows.append(Row(item: item, parents: parents))
        } else {
            item.indentationLevel = parents.count
            menu.addItem(item)
            rows.append(Row(item: item, parents: parents))
        }
        updateVisibility()
    }

    func updateSummary(_ summary: String, for id: String, badges: [MenuSummaryBadge]? = nil) {
        guard let header = headers[id] else { return }
        let textChangedSize = header.setSummary(summary)
        let badgesChangedSize = badges.map { header.setBadges($0) } ?? false
        if textChangedSize || badgesChangedSize { menu?.update() }
    }

    func setAccessory(_ view: NSView, for id: String) {
        headers[id]?.setAccessory(view)
    }

    func toggle(_ id: String) {
        guard headers[id] != nil else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        applyExpansion(id)
    }

    private func setExpanded(_ value: Bool, for id: String) {
        guard headers[id] != nil else { return }
        if value { expanded.insert(id) } else { expanded.remove(id) }
        applyExpansion(id)
    }

    private func applyExpansion(_ id: String) {
        headers[id]?.setExpanded(expanded.contains(id))
        updateVisibility()
        menu?.update()
        onToggle?(expanded)
    }

    private func updateVisibility() {
        for row in rows {
            row.item.isHidden = !row.parents.allSatisfy { expanded.contains($0) }
        }
    }
}

@MainActor
private final class InlineMenuHeader: NSView {
    private let summaryLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let chevron = NSImageView()
    private let button = NSButton()
    private let badgeContainer = HitThroughContainer()
    private let depth: Int
    private var badges: [MenuSummaryBadge] = []
    private var badgeViews: [MenuSummaryBadgeView] = []
    private var hiddenBadgeCount = 0
    private var overflowView: MenuSummaryOverflowView?
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var expanded = false
    private let glassContent = MenuGlassContentView()
    private var accessory: NSView?
    var showsChevron = true {
        didSet { chevron.isHidden = !showsChevron }
    }
    var onPress: (() -> Void)?
    var onBadgeAction: ((MenuSummaryAction) -> Void)?
    var onOverflowAction: (() -> Void)?

    override var isFlipped: Bool { true }

    init(title: String, summary: String, image: NSImage?, depth: Int) {
        self.depth = depth
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 46))
        autoresizingMask = [.width]
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        iconView.image = image
        iconView.contentTintColor = .controlAccentColor
        summaryLabel.stringValue = summary
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.usesSingleLineMode = false
        summaryLabel.lineBreakMode = .byTruncatingTail
        chevron.contentTintColor = .secondaryLabelColor
        addSubview(glassContent)
        for view in [iconView, titleLabel, summaryLabel, chevron] { glassContent.addSubview(view) }
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(pressed)
        button.setAccessibilityLabel(title)
        glassContent.addSubview(button)
        glassContent.addSubview(badgeContainer)
        resizeToContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAccessory(_ view: NSView) {
        accessory?.removeFromSuperview()
        accessory = view
        glassContent.addSubview(view)
        resizeToContent()
    }

    @discardableResult
    func setSummary(_ summary: String) -> Bool {
        guard summaryLabel.stringValue != summary else { return false }
        summaryLabel.stringValue = summary
        updateAccessibilityValue()
        return resizeToContent()
    }

    @discardableResult
    func setBadges(_ next: [MenuSummaryBadge]) -> Bool {
        guard badges != next else { return false }
        badges = next
        badgeViews.forEach { $0.removeFromSuperview() }
        badgeViews = next.map(MenuSummaryBadgeView.init)
        for view in badgeViews {
            view.onPress = { [weak self, weak view] in
                guard let self, let view else { return }
                guard let action = view.badge.action else {
                    self.onPress?()
                    return
                }
                self.onBadgeAction?(action)
            }
            badgeContainer.addSubview(view)
        }
        layoutBadges()
        return resizeToContent()
    }

    @discardableResult
    private func resizeToContent() -> Bool {
        let height: CGFloat
        if accessory != nil {
            height = 38
        } else if expanded {
            height = 32
        } else if !badges.isEmpty {
            height = 38
        } else {
            height = 30
        }
        let changed = frame.height != height
        setFrameSize(NSSize(width: frame.width, height: height))
        summaryLabel.isHidden = accessory != nil || expanded || !badges.isEmpty || summaryLabel.stringValue.isEmpty
        badgeViews.forEach { $0.isHidden = expanded }
        badgeContainer.isHidden = accessory != nil || expanded || badgeViews.isEmpty
        needsLayout = true
        needsDisplay = true
        return changed
    }

    override func layout() {
        super.layout()
        glassContent.frame = bounds
        let inset = CGFloat(12 + depth * 14)
        let titleWidth = titleColumnWidth
        let centerY = (bounds.height - 18) / 2
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.frame = NSRect(x: inset + 30, y: centerY, width: titleWidth, height: 18)
        iconView.frame = NSRect(x: inset + 5, y: (bounds.height - 15) / 2, width: 15, height: 15)
        chevron.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 10) / 2, width: 10, height: 10)
        let leading = rightLeading
        let available = rightAvailableWidth
        summaryLabel.alignment = .right
        summaryLabel.frame = NSRect(x: leading, y: centerY + 1, width: available, height: 16)
        badgeContainer.frame = NSRect(x: leading, y: (bounds.height - MenuSummaryBadgeView.height) / 2,
                                      width: available, height: MenuSummaryBadgeView.height)
        layoutBadges()
        button.frame = bounds
        if let accessory {
            // Independent controls sit above the full-row expansion button.
            accessory.frame.origin = NSPoint(x: bounds.width - accessory.frame.width - 12,
                                             y: (bounds.height - accessory.frame.height) / 2)
            chevron.isHidden = true
            titleLabel.frame.size.width = max(0, accessory.frame.minX - titleLabel.frame.minX - 8)
        }
    }

    private func layoutBadges() {
        guard !badgeViews.isEmpty else { return }
        let gap: CGFloat = 5
        let available = badgeContainer.bounds.width
        let total = badgeViews.reduce(0) { $0 + min($1.preferredWidth, available) + gap } - gap
        let overflowWidth: CGFloat = 34
        let reserve = total > available ? overflowWidth + gap : 0
        var x: CGFloat = available - reserve
        hiddenBadgeCount = 0
        for view in badgeViews {
            let width = min(view.preferredWidth, available)
            if x - width < 0 {
                hiddenBadgeCount += 1
                view.isHidden = true
                continue
            }
            view.isHidden = false
            x -= width
            view.frame = NSRect(x: x, y: 0, width: width, height: MenuSummaryBadgeView.height)
            x -= gap
        }
        overflowView?.removeFromSuperview()
        overflowView = nil
        if hiddenBadgeCount > 0 {
            let more = MenuSummaryOverflowView(count: hiddenBadgeCount)
            more.onPress = { [weak self] in self?.onOverflowAction?() }
            more.frame.origin = NSPoint(x: max(0, available - overflowWidth), y: 0)
            badgeContainer.addSubview(more)
            overflowView = more
        }
    }

    private var titleColumnWidth: CGFloat {
        let inset = CGFloat(12 + depth * 14)
        let measured = ceil((titleLabel.stringValue as NSString)
            .size(withAttributes: [.font: titleLabel.font!]).width) + 4
        let rightNeed: CGFloat = badges.contains(where: \.isSupplier) ? 206 : 150
        let available = bounds.width - inset - 42 - rightNeed
        return min(max(48, measured), max(48, available))
    }

    private var rightLeading: CGFloat {
        CGFloat(12 + depth * 14) + 30 + titleColumnWidth + 10
    }

    private var rightAvailableWidth: CGFloat {
        max(0, bounds.width - 34 - rightLeading)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // 追踪区域重建时先清掉旧悬停，避免移出事件丢失后残留高亮。
        hovered = false
        needsDisplay = true
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    private func invalidateMenuHighlights() {
        // AppKit 管理唯一当前高亮项；即使退出事件丢失，下次进入任意行也会重画旧行。
        for item in enclosingMenuItem?.menu?.items ?? [] {
            item.view?.needsDisplay = true
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        invalidateMenuHighlights()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        invalidateMenuHighlights()
    }

    /// 指针是否真的还在行内。mark 菜单可能吞掉 mouseExited，
    /// 绘制前用窗口坐标复核，保证不会留下陈旧高亮。
    private var pointerInside: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    /// 系统菜单样式：整块背景由 NSMenu 提供，只有悬停行画一个圆角高亮。
    override func draw(_ dirtyRect: NSRect) {
        guard hovered, pointerInside else {
            if hovered { hovered = false }
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlight = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 1),
            xRadius: 8,
            yRadius: 8
        )
        NSColor.labelColor.withAlphaComponent(dark ? 0.14 : 0.07).setFill()
        highlight.fill()
    }

    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                                accessibilityDescription: expanded ? "收起" : "展开")
        resizeToContent()
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        button.setAccessibilityValue("\(expanded ? "已展开" : "已收起")，\(summaryLabel.stringValue)")
    }

    @objc private func pressed() { onPress?() }
}

@MainActor
private final class HitThroughContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }
}

@MainActor
private final class MenuGlassContentView: NSView {
    override var isFlipped: Bool { true }
}
