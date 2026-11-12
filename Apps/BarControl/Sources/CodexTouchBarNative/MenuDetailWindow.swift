import AppKit

/// Independent details window opened from a menu summary row. The menu row
/// stays a compact status line; actions and dense content live here.
@MainActor
final class MenuDetailWindowController: NSObject, NSWindowDelegate {
    static let shared = MenuDetailWindowController()

    private var window: NSWindow?
    private var onRefresh: (@MainActor (NSView) -> Void)?

    private struct Page {
        let id: String
        let title: String
        let subtitle: String
        var size: NSSize
        let accessory: NSView?
        let fullBleed: Bool
        let build: @MainActor () -> NSView
    }

    private var current: Page?
    private var history: [Page] = []
    private(set) var pageSize = NSSize(width: 900, height: 640)

    /// 当前页面 id；关于页和设置页共用一个窗口，刷新前要靠它区分。
    var currentPageID: String? { current?.id }
    var isVisible: Bool { window?.isVisible == true }

    /// 根页面：清空层级栈。
    func show(id: String, title: String, subtitle: String,
              size: NSSize, accessory: NSView? = nil, fullBleed: Bool = false,
              build: @escaping @MainActor () -> NSView) {
        history.removeAll()
        render(Page(id: id, title: title, subtitle: subtitle, size: size, accessory: accessory,
                    fullBleed: fullBleed, build: build))
    }

    /// 二级页面：在同一个窗口里压栈，左上角出现返回按钮。
    func push(id: String, title: String, subtitle: String,
              size: NSSize, accessory: NSView? = nil, fullBleed: Bool = false,
              build: @escaping @MainActor () -> NSView) {
        if let current { history.append(current) }
        render(Page(id: id, title: title, subtitle: subtitle, size: size, accessory: accessory,
                    fullBleed: fullBleed, build: build))
    }

    /// 调试用：等价于点击左上角返回。
    func debugGoBack() { goBack() }

    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        render(previous)
    }

    private var resizeRebuildScheduled = false

    private func render(_ page: Page) {
        current = page
        pageSize = page.size
        let content = makePage(page, showsBack: !history.isEmpty, body: page.build())
        content.frame = NSRect(origin: .zero, size: page.size)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        onRefresh = { [weak self] body in
            guard let self, let current = self.current else { return }
            let next = self.makePage(current, showsBack: !self.history.isEmpty, body: body)
            next.frame = NSRect(origin: .zero, size: current.size)
            self.window?.contentView = next
        }
        let window = window ?? {
            let next = NSWindow(
                contentRect: NSRect(origin: .zero, size: page.size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            next.isReleasedWhenClosed = false
            next.delegate = self
            self.window = next
            return next
        }()
        let wasVisible = window.isVisible
        window.title = page.title
        if page.fullBleed {
            // 全幅页面：内容延伸到标题栏下方，侧栏与交通灯同区（同系统设置）。
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // 全幅二级页（如“关于”）仍保留返回按钮，允许比设置根页更窄。
            window.minSize = NSSize(width: history.isEmpty ? 720 : 520, height: 480)
            window.maxSize = NSSize(width: 1400, height: 1200)
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.minSize = NSSize(width: min(page.size.width, 480), height: min(page.size.height, 300))
            window.maxSize = NSSize(width: 1200, height: 1600)
        }
        window.isMovableByWindowBackground = true
        window.setContentSize(page.size)
        window.contentView = content
        window.appearance = nil
        window.displayIfNeeded()
        // 层级切换时保持窗口位置，只有首次出现才居中。
        if !wasVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口缩放时按新尺寸重排页面（两栏布局需要重新计算列宽）。
    func windowDidResize(_ notification: Notification) {
        guard let window, var page = current, page.fullBleed else { return }
        let size = window.contentView?.bounds.size ?? page.size
        guard abs(size.width - page.size.width) > 0.5 || abs(size.height - page.size.height) > 0.5 else { return }
        page.size = size
        pageSize = size
        current = page
        guard !resizeRebuildScheduled else { return }
        resizeRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeRebuildScheduled = false
            guard let page = self.current else { return }
            self.onRefresh?(page.build())
        }
    }

    /// 调试用：模拟用户拖拽改变窗口尺寸。
    func debugResize(to size: NSSize) {
        guard let window else { return }
        var frame = window.frame
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        window.setFrame(frame, display: true)
    }

    func updateIfVisible(build: @MainActor () -> NSView) {
        guard let window, window.isVisible else { return }
        onRefresh?(build())
    }

    func attach(body: NSView) {
        onRefresh?(body)
    }

    private func makePage(_ page: Page, showsBack: Bool, body: NSView) -> NSView {
        let title = page.title
        let subtitle = page.subtitle
        let size = page.size
        let accessory = page.accessory
        let root = visualBackground(size: size)

        // 全幅根页（设置）自己画两栏；全幅二级页仍要标题栏下方的标题与返回按钮。
        let topInset: CGFloat = page.fullBleed ? 40 : WindowDesign.pageInset
        let secondaryFullBleed = page.fullBleed && showsBack

        if page.fullBleed && !showsBack {
            // 全幅页面不套 NSScrollView：内容高度固定，滚动视图首次布局时
            // 自动调整 insets 会让顶部占位跳一次。
            body.identifier = NSUserInterfaceItemIdentifier("detail-body")
            body.translatesAutoresizingMaskIntoConstraints = true
            var frame = NSRect(origin: .zero, size: size)
            frame.size.height = max(size.height, body.frame.height)
            body.frame = frame
            body.autoresizingMask = []
            root.addSubview(body)
            return root
        }

        let symbol: String
        switch title {
        case "服务": symbol = "server.rack"
        case "Touch Bar 设置": symbol = "slider.horizontal.3"
        case "让位应用": symbol = "rectangle.on.rectangle.slash"
        case "关于 Bar Control": symbol = "info.circle"
        default: symbol = "bolt.fill"
        }
        let accent: NSColor
        switch title {
        case "服务": accent = .systemGreen
        case "Touch Bar 设置", "让位应用", "关于 Bar Control": accent = .systemPurple
        default: accent = .systemOrange
        }
        let header = WindowDesign.header(title: title, subtitle: subtitle, symbol: symbol, accent: accent)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(accessory)
        }
        let scrollView = DetailScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier("detail-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = body
        body.identifier = NSUserInterfaceItemIdentifier("detail-body")
        body.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(scrollView)

        var constraints: [NSLayoutConstraint] = [
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: topInset),
            header.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: WindowDesign.pageInset + (showsBack ? 32 : 0)
            ),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -WindowDesign.pageInset),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            scrollView.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: secondaryFullBleed ? topInset + 60 : 96
            ),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: WindowDesign.pageInset),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -WindowDesign.pageInset),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        if let accessory {
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -WindowDesign.pageInset),
                accessory.firstBaselineAnchor.constraint(equalTo: root.topAnchor, constant: 52),
                accessory.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 16),
            ]
        }
        if showsBack {
            let back = NSButton(
                image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "返回上一级")
                    ?? NSImage(),
                target: self,
                action: #selector(goBack)
            )
            back.isBordered = false
            back.contentTintColor = .labelColor
            back.toolTip = "返回上一级"
            back.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(back)
            constraints += [
                back.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: WindowDesign.pageInset - 4),
                back.topAnchor.constraint(equalTo: root.topAnchor, constant: topInset + 10),
                back.widthAnchor.constraint(equalToConstant: 28),
                back.heightAnchor.constraint(equalToConstant: 28),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        body.autoresizingMask = []
        return root
    }

    private func visualBackground(size: NSSize) -> NSView {
        let root = WindowPageView(frame: NSRect(origin: .zero, size: size))
        root.appearance = nil
        root.wantsLayer = true
        root.layer?.backgroundColor = WindowDesign.background(for: root.effectiveAppearance).cgColor
        return root
    }

    /// Rebuild the page after an appearance change so every dynamic color is
    /// resolved against the window's current effective appearance.
    func refreshAppearance() {
        guard let window, let content = window.contentView,
              let body = findBody(in: content),
              let current
        else { return }
        body.removeFromSuperview()
        let page = makePage(current, showsBack: !history.isEmpty, body: body)
        page.appearance = nil
        window.contentView = page
        page.layoutSubtreeIfNeeded()
        page.displayIfNeeded()
    }

    private func findBody(in content: NSView) -> NSView? {
        if let scroll = content.subviews.compactMap({ $0 as? NSScrollView }).first {
            return scroll.documentView
        }
        return content.subviews.first { $0.identifier?.rawValue == "detail-body" }
    }
}

/// 把文档视图宽度精确钉在可视区域宽度；文档自身不参与 autoresizing，
/// 避免 NSScrollView 从 0 宽初始化时把文档宽度翻倍。
@MainActor
final class DetailScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let document = documentView else { return }
        let width = contentView.bounds.width
        guard width > 0, abs(document.frame.width - width) > 0.5 else { return }
        var frame = document.frame
        frame.size.width = width
        document.frame = frame
        document.layoutSubtreeIfNeeded()
    }
}
