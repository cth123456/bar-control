import AppKit
import Foundation

@MainActor
final class RemoteControlWindowController: NSWindowController, NSWindowDelegate {
    private unowned let manager: RemoteControlManager
    private let statusLabel = NSTextField(labelWithString: "")
    private let cloudLabel = NSTextField(labelWithString: "")
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let workingDirectoryField = NSTextField(string: RemoteControlConstants.defaultWorkingDirectory)
    private let logView = NSTextView()
    private let promptView = NSTextView()
    private let approvalBar = NSStackView()
    private let approvalLabel = NSTextField(labelWithString: "")
    private var approvalEvent: RemoteEvent?
    private var answeredApprovalEventIDs: Set<UUID> = []
    private var lastRenderedSequence: Int64 = -1
    private var providerIDs: [String] = []

    init(manager: RemoteControlManager) {
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bar Control · 远程 Codex"
        window.minSize = NSSize(width: 620, height: 480)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func refresh() {
        statusLabel.stringValue = manager.statusText
        cloudLabel.stringValue = manager.cloudStatusText
        refreshProviders()
        refreshApprovals()
        renderNewEvents()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "远程控制 Codex")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString: "语音或文字 → 本地 Qwen 分类 → Codex；所有可见事件逐段记录")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3
        root.addArrangedSubview(heading)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        cloudLabel.font = .systemFont(ofSize: 12)
        cloudLabel.textColor = .secondaryLabelColor
        let stateRow = NSStackView(views: [statusLabel, separatorDot(), cloudLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 7
        root.addArrangedSubview(stateRow)

        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
        providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let switchButton = NSButton(title: "切换并验证", target: self, action: #selector(switchProvider))
        switchButton.bezelStyle = .rounded
        let providerRow = NSStackView(views: [
            label("Codex 供应商"), providerPopup, switchButton,
            label("工作目录"), workingDirectoryField
        ])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY
        providerRow.spacing = 8
        workingDirectoryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        workingDirectoryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        root.addArrangedSubview(providerRow)
        providerRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true

        approvalBar.orientation = .horizontal
        approvalBar.alignment = .centerY
        approvalBar.spacing = 8
        approvalBar.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        approvalBar.wantsLayer = true
        approvalBar.layer?.cornerRadius = 8
        approvalBar.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.13).cgColor
        approvalLabel.lineBreakMode = .byTruncatingTail
        let approve = NSButton(title: "批准一次", target: self, action: #selector(approveRequest))
        let decline = NSButton(title: "拒绝", target: self, action: #selector(declineRequest))
        approvalBar.addArrangedSubview(approvalLabel)
        approvalBar.addArrangedSubview(approve)
        approvalBar.addArrangedSubview(decline)
        approvalLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(approvalBar)
        approvalBar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        approvalBar.isHidden = true

        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.drawsBackground = true
        logScroll.backgroundColor = NSColor.textBackgroundColor
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textContainerInset = NSSize(width: 10, height: 10)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logScroll.documentView = logView
        root.addArrangedSubview(logScroll)
        logScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        logScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptView.font = .systemFont(ofSize: 13)
        promptView.textContainerInset = NSSize(width: 8, height: 8)
        promptView.string = ""
        promptScroll.documentView = promptView
        promptScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let sendButton = NSButton(title: "发送", target: self, action: #selector(sendPrompt))
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded
        let stopButton = NSButton(title: "停止", target: self, action: #selector(stopTurn))
        stopButton.bezelStyle = .rounded
        let clearButton = NSButton(title: "清除本机记录", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded
        let buttonColumn = NSStackView(views: [sendButton, stopButton, clearButton])
        buttonColumn.orientation = .vertical
        buttonColumn.alignment = .leading
        buttonColumn.spacing = 7
        let composer = NSStackView(views: [promptScroll, buttonColumn])
        composer.orientation = .horizontal
        composer.alignment = .top
        composer.spacing = 10
        root.addArrangedSubview(composer)
        composer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        promptScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        promptScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        NSLayoutConstraint.activate([
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            logScroll.bottomAnchor.constraint(lessThanOrEqualTo: composer.topAnchor, constant: -10)
        ])
    }

    private func refreshProviders() {
        let ids = manager.providers.map(\.id)
        guard ids != providerIDs else { return }
        providerIDs = ids
        providerPopup.removeAllItems()
        for provider in manager.providers {
            providerPopup.addItem(withTitle: (provider.isCurrent ? "✓ " : "") + provider.name)
        }
        if let currentIndex = manager.providers.firstIndex(where: \.isCurrent) {
            providerPopup.selectItem(at: currentIndex)
        }
    }

    private func refreshApprovals() {
        approvalEvent = manager.events.last(where: {
            $0.kind == .approvalRequired && !answeredApprovalEventIDs.contains($0.id)
        })
        guard let approvalEvent else {
            approvalBar.isHidden = true
            return
        }
        approvalLabel.stringValue = approvalEvent.text.isEmpty ? "Codex 请求批准" : approvalEvent.text
        approvalBar.isHidden = false
    }

    private func renderNewEvents() {
        let events = manager.events
        if events.isEmpty {
            if lastRenderedSequence != -1 { logView.string = "" }
            lastRenderedSequence = -1
            return
        }
        if lastRenderedSequence > (events.last?.sequence ?? -1) {
            logView.string = ""
            lastRenderedSequence = -1
        }
        let newEvents = events.filter { $0.sequence > lastRenderedSequence }
        guard !newEvents.isEmpty else { return }
        let storage = logView.textStorage ?? NSTextStorage()
        for event in newEvents {
            storage.append(Self.attributedLine(for: event))
            lastRenderedSequence = max(lastRenderedSequence, event.sequence)
        }
        logView.scrollToEndOfDocument(nil)
    }

    private static func attributedLine(for event: RemoteEvent) -> NSAttributedString {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let time = formatter.string(from: event.createdAt)
        let title = event.title.isEmpty ? event.kind.rawValue : event.title
        let prefix = "[\(event.sequence) · \(time)] \(title)\n"
        let body = event.text.isEmpty ? "" : event.text + "\n"
        let result = NSMutableAttributedString(
            string: prefix,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: color(for: event.kind)
            ]
        )
        result.append(NSAttributedString(
            string: body + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        return result
    }

    private static func color(for kind: RemoteEventKind) -> NSColor {
        switch kind {
        case .error, .turnFailed: return .systemRed
        case .approvalRequired, .warning: return .systemOrange
        case .turnCompleted, .providerChanged: return .systemGreen
        case .modelChanged: return .systemBlue
        case .agentMessageDelta: return .systemBlue
        case .localIntent: return .systemPurple
        case .commandOutputDelta: return .systemTeal
        default: return .secondaryLabelColor
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        return field
    }

    private func separatorDot() -> NSTextField {
        let field = NSTextField(labelWithString: "•")
        field.textColor = .tertiaryLabelColor
        return field
    }

    @objc private func sendPrompt() {
        let text = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        promptView.string = ""
        let cwd = workingDirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.submit(text: text, cwd: cwd.isEmpty ? nil : cwd)
    }

    @objc private func stopTurn() {
        manager.stopCurrentTurn()
    }

    @objc private func clearHistory() {
        manager.clearHistory()
    }

    @objc private func providerSelectionChanged() {
        // Selection alone never switches an account. The separate button is the explicit action.
    }

    @objc private func switchProvider() {
        let index = providerPopup.indexOfSelectedItem
        guard providerIDs.indices.contains(index) else { return }
        manager.switchProvider(id: providerIDs[index])
    }

    @objc private func approveRequest() {
        guard let event = approvalEvent else { return }
        answeredApprovalEventIDs.insert(event.id)
        manager.answerApproval(event: event, accepted: true)
        refreshApprovals()
    }

    @objc private func declineRequest() {
        guard let event = approvalEvent else { return }
        answeredApprovalEventIDs.insert(event.id)
        manager.answerApproval(event: event, accepted: false)
        refreshApprovals()
    }
}
