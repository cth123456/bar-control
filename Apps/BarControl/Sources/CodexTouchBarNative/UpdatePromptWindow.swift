import AppKit

/// 发现新版本时的独立弹窗。不复用菜单详情窗口：它是浮层，
/// 不该覆盖用户正在看的设置页，也不需要返回层级。
@MainActor
final class UpdatePromptWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdatePromptWindowController()

    private var panel: NSPanel?
    private var release: SoftwareRelease?
    private weak var primaryButton: NSButton?
    private weak var laterButton: NSButton?
    private weak var skipButton: NSButton?
    private weak var hintLabel: NSTextField?
    private weak var progressBar: NSProgressIndicator?

    var isVisible: Bool { panel?.isVisible == true }

    func show(release: SoftwareRelease, currentVersion: String, build: String) {
        self.release = release
        UpdateChecker.shared.markPrompted(release)

        let size = NSSize(width: 460, height: 490)
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        panel.contentView = makeContent(size: size, release: release,
                                        currentVersion: currentVersion, build: build)
        panel.setContentSize(size)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        AppLog.write("update prompt shown version=\(release.versionText)")
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Bar Control 更新"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // 更新提示必须出现在用户当前所在的空间（含全屏应用之上），
        // 否则后台代理进程的窗口会被丢到另一个桌面。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    private func makeContent(size: NSSize, release: SoftwareRelease,
                             currentVersion: String, build: String) -> NSView {
        let root = WindowPageView(frame: NSRect(origin: .zero, size: size))

        let icon = NSImageView(frame: NSRect(x: 24, y: 40, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(icon)

        let title = NSTextField(labelWithString: "发现新版本 \(release.versionText)")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 90, y: 42, width: 346, height: 26)
        root.addSubview(title)

        let subtitle = NSTextField(labelWithString: "当前 \(currentVersion) (\(build)) · \(releaseSubtitle(release))")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 90, y: 70, width: 346, height: 16)
        root.addSubview(subtitle)

        let card = WindowCard(frame: NSRect(x: 24, y: 108, width: 412, height: 248), tint: nil, emphasized: false)
        root.addSubview(card)

        let notesTitle = NSTextField(labelWithString: release.name.isEmpty ? "更新内容" : release.name)
        notesTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        notesTitle.textColor = .secondaryLabelColor
        notesTitle.lineBreakMode = .byTruncatingTail
        notesTitle.frame = NSRect(x: 14, y: 12, width: 384, height: 16)
        card.addSubview(notesTitle)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 36, width: 388, height: 200))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 388, height: 200))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textColor = .labelColor
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 0, height: 3)
        text.string = release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "这个版本没有填写更新说明。"
            : release.notes
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        card.addSubview(scroll)

        let hint = NSTextField(labelWithString: release.canInstallInApp
            ? "点「立即更新」会自动下载、校验并替换，完成后自动重开。"
            : "下载新版替换旧版即可，模块布局与设置会保留。")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 24, y: 360, width: 412, height: 14)
        root.addSubview(hint)
        hintLabel = hint

        let progress = NSProgressIndicator(frame: NSRect(x: 24, y: 380, width: 412, height: 6))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.isHidden = true
        root.addSubview(progress)
        progressBar = progress

        let skip = NSButton(title: "跳过此版本", target: self, action: #selector(skipVersion))
        skip.isBordered = false
        skip.bezelStyle = .inline
        skip.font = .systemFont(ofSize: 11)
        skip.contentTintColor = .secondaryLabelColor
        skip.frame = NSRect(x: 20, y: 410, width: 100, height: 24)
        root.addSubview(skip)
        skipButton = skip

        let later = NSButton(title: "稍后", target: self, action: #selector(dismissPrompt))
        later.bezelStyle = .rounded
        later.controlSize = .regular
        later.frame = NSRect(x: 240, y: 408, width: 78, height: 30)
        root.addSubview(later)
        laterButton = later

        let download = NSButton(title: release.canInstallInApp ? "立即更新" : "前往下载",
                                target: self, action: #selector(primaryAction))
        download.bezelStyle = .rounded
        download.controlSize = .regular
        download.keyEquivalent = "\r"
        download.frame = NSRect(x: 326, y: 408, width: 110, height: 30)
        root.addSubview(download)
        primaryButton = download
        return root
    }

    private func releaseSubtitle(_ release: SoftwareRelease) -> String {
        guard let date = release.publishedAt else { return "来自 GitHub Releases" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "发布于 \(formatter.string(from: date))"
    }

    @objc private func primaryAction() {
        guard let release else { return }
        guard release.canInstallInApp else {
            openReleasePage()
            return
        }
        startInstall(release)
    }

    private func startInstall(_ release: SoftwareRelease) {
        setInstalling(true)
        hintLabel?.stringValue = "正在准备更新…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await UpdateInstaller.shared.install(release) { message, fraction in
                    self.hintLabel?.stringValue = message
                    self.progressBar?.doubleValue = fraction
                }
                self.hintLabel?.stringValue = "更新完成，正在重新打开 Bar Control…"
                self.progressBar?.doubleValue = 1
                try? await Task.sleep(for: .milliseconds(800))
                NSApp.terminate(nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.hintLabel?.stringValue = message
                self.setInstalling(false)
                self.primaryButton?.title = "前往下载"
                AppLog.write("update install failed: \(message)")
            }
        }
    }

    private func setInstalling(_ installing: Bool) {
        primaryButton?.isEnabled = !installing
        laterButton?.isEnabled = !installing
        skipButton?.isEnabled = !installing
        progressBar?.isHidden = !installing
    }

    @objc private func openReleasePage() {
        guard let release else { return }
        NSWorkspace.shared.open(release.pageURL)
        close()
    }

    @objc private func skipVersion() {
        if let release { UpdateChecker.shared.skip(release) }
        close()
    }

    @objc private func dismissPrompt() {
        close()
    }
}
