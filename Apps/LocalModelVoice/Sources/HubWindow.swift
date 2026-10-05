import AppKit
import SwiftUI

// MARK: - 通用小控件

/// 圆角卡片：浅色/深色模式自动跟随，避免手写颜色在换主题后失效。
private final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        layer?.backgroundColor = HubInkNS.card.cgColor
        layer?.borderColor = HubInkNS.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }
}

private func captionLabel(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = HubInkNS.sub
    label.lineBreakMode = .byTruncatingTail
    return label
}

// MARK: - 设计稿配色（AppKit 侧）

/// 与 `HubPages.HubInk` 同一套色值：设计稿是浅色界面，AppKit 页面别再跟着系统主题飘。
enum HubInkNS {
    static let page = NSColor(srgbRed: 0.961, green: 0.969, blue: 0.984, alpha: 1)
    static let card = NSColor.white
    static let ink = NSColor(srgbRed: 0.090, green: 0.137, blue: 0.247, alpha: 1)
    static let sub = NSColor(srgbRed: 0.400, green: 0.439, blue: 0.522, alpha: 1)
    static let faint = NSColor(srgbRed: 0.545, green: 0.580, blue: 0.659, alpha: 1)
    static let line = NSColor(srgbRed: 0.906, green: 0.918, blue: 0.949, alpha: 1)
    static let accent = NSColor(srgbRed: 0.388, green: 0.463, blue: 1.0, alpha: 1)
    static let accentSoft = NSColor(srgbRed: 0.933, green: 0.945, blue: 1.0, alpha: 1)
    static let accentLine = NSColor(srgbRed: 0.863, green: 0.886, blue: 1.0, alpha: 1)

    // 侧栏（设计稿 left sidebar）令牌：品牌渐变卡 + 圆点导航 + 页脚状态卡。
    static let brandStart = NSColor(srgbRed: 0.424, green: 0.388, blue: 1.0, alpha: 1)   // #6C63FF
    static let brandEnd = NSColor(srgbRed: 0.310, green: 0.549, blue: 1.0, alpha: 1)     // #4F8CFF
    static let brandMark = NSColor(srgbRed: 0.357, green: 0.424, blue: 0.984, alpha: 1)  // #5B6CFB
    static let brandSub = NSColor(srgbRed: 0.910, green: 0.925, blue: 1.0, alpha: 1)     // #E8ECFF
    static let cardSoft = NSColor(srgbRed: 0.969, green: 0.973, blue: 0.988, alpha: 1)   // #F7F8FC
    static let dotIdle = NSColor(srgbRed: 0.659, green: 0.690, blue: 0.769, alpha: 1)    // #A8B0C4
    static let dotOn = NSColor(srgbRed: 0.388, green: 0.463, blue: 1.0, alpha: 1)        // #6376FF
    static let online = NSColor(srgbRed: 0.224, green: 0.788, blue: 0.541, alpha: 1)     // #39C98A

    // 全局提示横幅（失败态）：浅红底 + 描边 + 文字，跟成功态用同一套结构，只换色。
    static let badSoft = NSColor(srgbRed: 0.992, green: 0.929, blue: 0.933, alpha: 1)    // #FDEDEE
    static let badLine = NSColor(srgbRed: 0.969, green: 0.831, blue: 0.843, alpha: 1)    // #F7D4D7
    static let badInk = NSColor(srgbRed: 0.788, green: 0.341, blue: 0.384, alpha: 1)     // #C95762
    static let badDot = NSColor(srgbRed: 0.902, green: 0.298, blue: 0.235, alpha: 1)     // #E64C3C
    static let tintInk = NSColor(srgbRed: 0.231, green: 0.286, blue: 0.800, alpha: 1)    // #3B49CC
}

/// 设计稿卡片：白底、1px 描边、圆角 14。
final class HubLightCard: NSView {
    /// 圆角：卡片默认 14，输入框外壳这类小控件用 10。
    var cornerRadius: CGFloat = 14 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        layer?.backgroundColor = HubInkNS.card.cgColor
        layer?.borderColor = HubInkNS.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }
}

// MARK: - 能看懂的小工具

/// 时间戳：气泡上显示「什么时候问的」。
private let bubbleTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
}()

/// 把一段可能多行的文字压成一行摘要，用于首页的「最近一次」。
private func singleLine(_ text: String, limit: Int) -> String {
    let collapsed = text
        .split(whereSeparator: { $0.isNewline })
        .joined(separator: " · ")
        .trimmingCharacters(in: .whitespaces)
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
}

/// 聊天气泡：角色（你 / 中枢）+ 正文 + 可选「语音朗读文本」。
private final class BubbleView: NSView {

    let body = NSTextField(wrappingLabelWithString: "")
    let spoken = NSTextField(wrappingLabelWithString: "")

    private let role: NSTextField
    private let fillColor: NSColor
    private let strokeColor: NSColor

    init(roleText: String, emphasized: Bool) {
        role = NSTextField(labelWithString: roleText)
        fillColor = emphasized ? HubInkNS.accentSoft : HubInkNS.card
        strokeColor = emphasized ? HubInkNS.accentLine : HubInkNS.line

        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        role.font = .systemFont(ofSize: 11, weight: .semibold)
        role.textColor = emphasized ? HubInkNS.accent : HubInkNS.sub

        body.font = .systemFont(ofSize: 13)
        body.textColor = HubInkNS.ink
        body.isSelectable = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = 620

        // 语音提问时念出来的那份文本：单独一行，和屏幕上看到的回答分开。
        spoken.font = .systemFont(ofSize: 11)
        spoken.textColor = HubInkNS.faint
        spoken.maximumNumberOfLines = 0
        spoken.lineBreakMode = .byWordWrapping
        spoken.preferredMaxLayoutWidth = 620
        spoken.isHidden = true

        let stack = NSStackView(views: [role, body, spoken])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            spoken.widthAnchor.constraint(lessThanOrEqualToConstant: 620)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = strokeColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }
}

/// 竖直生长、且从顶部开始排列的容器：滚动视图里必须用它，否则内容会贴着底部。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 首页

/// 「中枢首页」：打开 App 看到的第一屏，只回答三件事——
/// 1. 这是什么（Mac 上的 AI 中枢，语音只是其中一个入口）；
/// 2. 现在在干什么（待机 / 聆听 / 转写 / 思考 / 播报）；
/// 3. 接下来点哪里（打字提问、开始说话、线路与状态）。
///
/// 面板不含业务逻辑：所有点击都通过闭包交给 `VoiceController`。
final class HomePanelView: NSView {

    /// 首页顶部的状态展示，由 `VoiceController` 从同一个状态机派生。
    struct Presentation {
        var status: String
        var detail: String
        var tint: NSColor
        var busy: Bool
    }

    var onAsk: ((String) -> Void)?
    var onToggleVoice: (() -> Void)?
    var onOpenPage: ((HubWindowController.Page) -> Void)?

    private let title = NSTextField(labelWithString: "AI 中枢")
    private let intro = NSTextField(wrappingLabelWithString: "这是你 Mac 上的 AI 中枢：用说话或打字提问，中枢会自动挑一条线路（本机模型 / 云端）来回答，需要时再用语音念出来。")
    private let dot = NSView()
    private let statusLabel = NSTextField(labelWithString: "待机")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let askField = NSTextField()
    private let askButton = NSButton()
    private let askHint = NSTextField(labelWithString: "打字也可以：输入后按回车发送；「开始说话」只是另一个入口，两个走同一套流程。")
    private let voiceButton = NSButton()
    private let micNote = NSTextField(wrappingLabelWithString: "麦克风默认关闭：只有点「开始说话」（⌘D）才会开麦，说完停约 2 秒自动结束。关窗口只是把窗口收起来，App 不会退出（⌘Q 才退出）。")
    private let lastAsk = NSTextField(wrappingLabelWithString: "")
    private let lastAnswer = NSTextField(wrappingLabelWithString: "")
    private let lastRoute = NSTextField(labelWithString: "上次线路：还没有提问过")

    private var capabilities: [String] = []
    private var lastPresentation: Presentation?

    /// 自检读数：首页必须能一眼看出「这是中枢」并给出两个入口。
    var introText: String { intro.stringValue }
    var hasTypedInput: Bool { askField.isEditable && askButton.title == "发送" }
    var canAskTyped: Bool { askField.isEnabled && askButton.isEnabled }
    var voiceButtonTitle: String { voiceButton.title }
    var capabilityTitles: [String] { capabilities }
    var micNoteText: String { micNote.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        apply(Presentation(
            status: "待机",
            detail: "还没有开始对话：打字问一句，或者点「开始说话」。",
            tint: .secondaryLabelColor,
            busy: false
        ))
        setLastExchange(question: "", answer: "", route: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let presentation = lastPresentation {
            dot.layer?.backgroundColor = presentation.tint.cgColor
        }
    }

    // MARK: 对外接口

    func apply(_ presentation: Presentation) {
        lastPresentation = presentation
        dot.layer?.backgroundColor = presentation.tint.cgColor
        statusLabel.stringValue = presentation.status
        statusDetail.stringValue = presentation.detail.isEmpty ? " " : presentation.detail
        askField.isEnabled = !presentation.busy
        askButton.isEnabled = !presentation.busy
        voiceButton.title = presentation.busy ? "取消本次对话" : "🎙 开始说话"
    }

    func setLastExchange(question: String, answer: String, route: String) {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        lastAsk.stringValue = cleanQuestion.isEmpty
            ? "还没有提问过。打字或说话之后，最近一次问答会显示在这里。"
            : "你：" + singleLine(cleanQuestion, limit: 140)

        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        lastAnswer.stringValue = cleanAnswer.isEmpty ? "" : "中枢：" + singleLine(cleanAnswer, limit: 260)
        lastAnswer.isHidden = cleanAnswer.isEmpty

        let cleanRoute = route.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRoute.stringValue = "上次线路：" + (cleanRoute.isEmpty ? "还没有提问过" : cleanRoute)
    }

    /// 打开窗口时把光标放到输入框，明确告诉用户「这里可以打字」。
    func focusTypedInput() {
        window?.makeFirstResponder(askField)
    }

    // MARK: 构建

    private func build() {
        title.font = .systemFont(ofSize: 22, weight: .bold)

        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 760

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10)
        ])

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.preferredMaxLayoutWidth = 760

        askField.placeholderString = "在这里打字问一句，回车发送"
        askField.font = .systemFont(ofSize: 13)
        askField.target = self
        askField.action = #selector(askTapped)
        askField.translatesAutoresizingMaskIntoConstraints = false

        configure(askButton, title: "发送", action: #selector(askTapped))
        configure(voiceButton, title: "🎙 开始说话", action: #selector(voiceTapped))

        askHint.font = .systemFont(ofSize: 11)
        askHint.textColor = .secondaryLabelColor
        askHint.lineBreakMode = .byTruncatingTail

        micNote.font = .systemFont(ofSize: 11)
        micNote.textColor = .tertiaryLabelColor
        micNote.preferredMaxLayoutWidth = 760

        lastAsk.font = .systemFont(ofSize: 12)
        lastAsk.textColor = .labelColor
        lastAsk.maximumNumberOfLines = 0
        lastAsk.preferredMaxLayoutWidth = 760

        lastAnswer.font = .systemFont(ofSize: 12)
        lastAnswer.textColor = .secondaryLabelColor
        lastAnswer.maximumNumberOfLines = 0
        lastAnswer.preferredMaxLayoutWidth = 760

        lastRoute.font = .systemFont(ofSize: 11)
        lastRoute.textColor = .tertiaryLabelColor

        let headRow = NSStackView(views: [title, intro])
        headRow.orientation = .vertical
        headRow.alignment = .leading
        headRow.spacing = 6

        let statusRow = NSStackView(views: [dot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let statusCard = card([
            statusRow,
            statusDetail,
            micNote
        ])

        let inputRow = NSStackView(views: [askField, askButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        askField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let actionStack = NSStackView(views: [
            sectionLabel("问一句（打字或说话，任选一个）"),
            inputRow,
            askHint,
            voiceButton
        ])
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 8
        let actionCard = CardView()
        pin(actionStack, in: actionCard, insets: 14)
        NSLayoutConstraint.activate([
            inputRow.widthAnchor.constraint(equalTo: actionStack.widthAnchor),
            askHint.widthAnchor.constraint(equalTo: actionStack.widthAnchor)
        ])

        let cardRow = NSStackView(views: [
            capabilityCard(title: "对话（语音 / 打字）",
                           detail: "说话或打字提问；本机转写、自动挑线路，需要时用 Siri 音色念出来。",
                           symbol: "mic",
                           page: .voice,
                           buttonTitle: "进入对话"),
            capabilityCard(title: "Agent 与线路",
                           detail: "本机模型、云端线路、路由策略和可用性。",
                           symbol: "arrow.triangle.branch",
                           page: .router,
                           buttonTitle: "查看线路"),
            capabilityCard(title: "运行状态",
                           detail: "依赖自检、日志、配置文件在哪。",
                           symbol: "stethoscope",
                           page: .status,
                           buttonTitle: "查看状态")
        ])
        cardRow.orientation = .horizontal
        cardRow.distribution = .fillEqually
        cardRow.alignment = .top
        cardRow.spacing = 12

        let lastStack = NSStackView(views: [
            sectionLabel("最近一次"),
            lastAsk,
            lastAnswer,
            lastRoute
        ])
        lastStack.orientation = .vertical
        lastStack.alignment = .leading
        lastStack.spacing = 6
        let lastCard = CardView()
        pin(lastStack, in: lastCard, insets: 14)
        NSLayoutConstraint.activate([
            lastAsk.widthAnchor.constraint(equalTo: lastStack.widthAnchor),
            lastAnswer.widthAnchor.constraint(equalTo: lastStack.widthAnchor)
        ])

        for view in [headRow, statusCard, actionCard, cardRow, lastCard] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22)
            ])
        }
        NSLayoutConstraint.activate([
            intro.widthAnchor.constraint(equalTo: headRow.widthAnchor),
            statusDetail.widthAnchor.constraint(equalTo: statusCard.widthAnchor, constant: -28),
            micNote.widthAnchor.constraint(equalTo: statusCard.widthAnchor, constant: -28),

            headRow.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            statusCard.topAnchor.constraint(equalTo: headRow.bottomAnchor, constant: 14),
            actionCard.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 14),
            cardRow.topAnchor.constraint(equalTo: actionCard.bottomAnchor, constant: 14),
            lastCard.topAnchor.constraint(equalTo: cardRow.bottomAnchor, constant: 14),
            lastCard.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20)
        ])
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 每张卡片：「标题 + 图标」一行、「说明」一行、一个直达按钮。
    private func capabilityCard(title: String,
                                detail: String,
                                symbol: String,
                                page: HubWindowController.Page,
                                buttonTitle: String) -> NSView {
        capabilities.append(title)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)

        let headRow = NSStackView(views: [icon, name])
        headRow.orientation = .horizontal
        headRow.alignment = .centerY
        headRow.spacing = 6

        let caption = NSTextField(wrappingLabelWithString: detail)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 0
        caption.preferredMaxLayoutWidth = 220

        let button = NSButton(title: buttonTitle, target: self, action: #selector(openPage(_:)))
        button.bezelStyle = .rounded
        button.tag = page.rawValue
        button.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headRow, caption, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        let card = CardView()
        pin(stack, in: card, insets: 12)
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        NSLayoutConstraint.activate([
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            button.topAnchor.constraint(greaterThanOrEqualTo: caption.bottomAnchor, constant: 6)
        ])
        return card
    }

    private func card(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let container = CardView()
        pin(stack, in: container, insets: 14)
        return container
    }

    /// 把内容栈四边贴死卡片：卡片高度由内容决定，避免出现「高度 0」的空卡片。
    private func pin(_ view: NSView, in container: NSView, insets: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets)
        ])
    }

    // MARK: 动作

    @objc private func askTapped() {
        let text = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAsk?(text)
    }

    @objc private func voiceTapped() { onToggleVoice?() }

    @objc private func openPage(_ sender: NSButton) {
        guard let page = HubWindowController.Page(rawValue: sender.tag) else { return }
        onOpenPage?(page)
    }
}

// MARK: - 对话页

/// 「对话」页：一条一条的聊天记录 + 输入区。
///
/// 语音和打字汇进同一份记录：先出现「你」的气泡，再出现「中枢」的气泡，
/// 顶部状态带说明现在走到哪一步（待机 → 聆听 → 转写 → 思考 → 播报）。
/// 面板不含业务逻辑，点击一律通过闭包交给 `VoiceController`。
final class ChatPanelView: NSView {

    /// 语音链路的四个阶段，用来在界面顶部告诉用户「现在走到哪一步」。
    enum Stage: Int, CaseIterable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking

        var title: String {
            switch self {
            case .idle: return "待机"
            case .listening: return "聆听"
            case .transcribing: return "转写"
            case .thinking: return "思考"
            case .speaking: return "播报"
            }
        }
    }

    struct Presentation {
        var headline: String
        var hint: String
        var stage: Stage = .idle
        var primaryTitle: String
        var primaryEnabled = true
        var tint: NSColor
        var showsMeter = false
        var showsCancel = false
    }

    var onPrimary: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSendText: ((String) -> Void)?
    var onCopyAnswer: (() -> Void)?
    var onReplayAnswer: (() -> Void)?
    var onRevealSupportDirectory: (() -> Void)?

    private let pageTitle = NSTextField(labelWithString: "语音助手")
    private let intro = NSTextField(wrappingLabelWithString: "在同一个助手中说话或打字：左边一条是「你」，右边一条是「中枢」，回答默认念出来。")
    private let dot = NSView()
    private let headline = NSTextField(labelWithString: "待机")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let meter = NSLevelIndicator()
    private let primaryButton = NSButton()
    private let cancelButton = NSButton()
    private let inputField = NSTextField()
    private let sendButton = NSButton()
    private let copyButton = NSButton()
    private let replayButton = NSButton()
    private let footer = NSTextField(labelWithString: "")
    private let transcriptScroll = NSScrollView()
    private let transcriptStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "还没有对话。先在下面输入框问一句试试，比如「帮我看看今天该先做什么」。")
    private var assistantBubble: BubbleView?
    private var speakers: [String] = []
    private var stepLabels: [Stage: NSTextField] = [:]
    private var lastPresentation: Presentation?

    /// 自检用：这个页面到底是「只会语音」还是「AI 中枢」，靠下面几个读数判断。
    var introText: String { intro.stringValue }
    var hasTypedInput: Bool { inputField.isEditable && sendButton.title == "发送" }
    var canSendTypedInput: Bool { inputField.isEnabled && sendButton.isEnabled }
    var sectionTitles: [String] { speakers }
    var bubbleCount: Int { transcriptStack.arrangedSubviews.count - (emptyLabel.isHidden ? 0 : 1) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = HubInkNS.page.cgColor
        build()
        apply(Presentation(
            headline: "待机",
            hint: "点「开始说话」或直接在下面打字：停顿约 2 秒自动结束，转写只在本机做。",
            primaryTitle: "开始说话",
            tint: .secondaryLabelColor
        ))
        setTranscript("")
        setAnswer("")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let presentation = lastPresentation {
            apply(presentation)
        }
    }

    // MARK: 对外接口

    func apply(_ presentation: Presentation) {
        lastPresentation = presentation
        dot.layer?.backgroundColor = presentation.tint.cgColor
        headline.stringValue = presentation.headline
        hint.stringValue = presentation.hint

        for (stage, label) in stepLabels {
            let active = stage == presentation.stage
            let done = presentation.stage != .idle && stage.rawValue < presentation.stage.rawValue
            label.textColor = active ? .labelColor : (done ? .secondaryLabelColor : .tertiaryLabelColor)
            label.font = .systemFont(ofSize: 11, weight: active ? .bold : .regular)
        }

        primaryButton.title = presentation.primaryTitle
        primaryButton.isEnabled = presentation.primaryEnabled
        cancelButton.isHidden = !presentation.showsCancel
        meter.isHidden = !presentation.showsMeter
    }

    func setLevel(_ value: Double) {
        meter.doubleValue = max(0, min(1, value))
    }

    /// 新的一轮提问：追加一条「你」的气泡，并准备接收新的回答。
    func setTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        emptyLabel.isHidden = true
        appendBubble(role: "你", text: trimmed, emphasized: true)
        speakers.append("你")
        assistantBubble = nil
    }

    /// 回答边流式生成边刷新同一条「中枢」气泡。
    func setAnswer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            assistantBubble?.isHidden = true
            return
        }
        let bubble: BubbleView
        if let existing = assistantBubble {
            bubble = existing
        } else {
            bubble = appendBubble(role: "中枢", text: trimmed, emphasized: false)
            speakers.append("中枢")
            assistantBubble = bubble
        }
        bubble.isHidden = false
        bubble.body.stringValue = trimmed
        bubble.spoken.isHidden = true
        scrollTranscriptToBottom()
    }

    /// 语音提问时真正念出来的文本：挂在同一条气泡下面，方便比对。
    func setSpokenText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bubble = assistantBubble else { return }
        bubble.spoken.stringValue = trimmed.isEmpty ? "" : "🔊 语音朗读：" + singleLine(trimmed, limit: 240)
        bubble.spoken.isHidden = trimmed.isEmpty
        scrollTranscriptToBottom()
    }

    func setFooter(_ text: String) {
        footer.stringValue = text
    }

    func setReplayEnabled(_ enabled: Bool) {
        replayButton.isEnabled = enabled
        copyButton.isEnabled = enabled
    }

    func setSendEnabled(_ enabled: Bool) {
        inputField.isEnabled = enabled
        sendButton.isEnabled = enabled
    }

    /// 只有中枢确实受理了这条提问才清空输入框，避免文字白丢。
    func clearTypedInput() {
        inputField.stringValue = ""
    }

    func focusTypedInput() {
        window?.makeFirstResponder(inputField)
    }

    // MARK: 构建

    private func build() {
        pageTitle.font = .systemFont(ofSize: 26, weight: .bold)
        pageTitle.textColor = HubInkNS.ink

        intro.font = .systemFont(ofSize: 13)
        intro.textColor = HubInkNS.sub
        intro.maximumNumberOfLines = 0
        intro.preferredMaxLayoutWidth = 900

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10)
        ])

        headline.font = .systemFont(ofSize: 18, weight: .bold)
        headline.textColor = HubInkNS.ink
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = HubInkNS.sub
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 900

        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0
        meter.maxValue = 1
        meter.isHidden = true
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.widthAnchor.constraint(equalToConstant: 160).isActive = true

        primaryButton.title = "开始说话"
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.bezelColor = HubInkNS.accent
        primaryButton.contentTintColor = .white
        primaryButton.keyEquivalent = "d"
        primaryButton.keyEquivalentModifierMask = .command
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "取消"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = HubInkNS.faint
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.preferredMaxLayoutWidth = 420

        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.addArrangedSubview(emptyLabel)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(transcriptStack)
        transcriptScroll.documentView = document
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        inputField.placeholderString = "在这里打字提问，回车发送"
        inputField.font = .systemFont(ofSize: 14)
        inputField.textColor = HubInkNS.ink
        inputField.drawsBackground = false
        inputField.isBezeled = false
        inputField.focusRingType = .none
        inputField.target = self
        inputField.action = #selector(sendTapped)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        sendButton.title = "发送"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .large
        sendButton.bezelColor = HubInkNS.accent
        sendButton.contentTintColor = .white
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.widthAnchor.constraint(equalToConstant: 88).isActive = true

        copyButton.title = "复制回答"
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.bezelStyle = .inline
        copyButton.isEnabled = false

        replayButton.title = "重新播报"
        replayButton.target = self
        replayButton.action = #selector(replayTapped)
        replayButton.bezelStyle = .inline
        replayButton.isEnabled = false

        let revealButton = NSButton(
            title: "打开配置目录",
            target: self,
            action: #selector(revealTapped)
        )
        revealButton.bezelStyle = .inline

        for button in [copyButton, replayButton, revealButton] {
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.contentTintColor = HubInkNS.accent
        }

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = HubInkNS.faint
        footer.lineBreakMode = .byTruncatingTail

        let headRow = NSStackView(views: [dot, headline])
        headRow.orientation = .horizontal
        headRow.alignment = .centerY
        headRow.spacing = 8

        let actionRow = NSStackView(views: [primaryButton, cancelButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let statusStack = NSStackView(views: [headRow, hint, meter, actionRow, stepRow()])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 10

        let statusCard = HubLightCard()
        pin(statusStack, in: statusCard, insets: 20)
        NSLayoutConstraint.activate([
            hint.widthAnchor.constraint(equalTo: statusStack.widthAnchor)
        ])

        // 对话记录卡：左上标题区，右上是三个次操作（设计稿没有它们，但它们是真实功能，放在记录旁边最顺手）。
        let transcriptTitle = NSTextField(labelWithString: "对话记录")
        transcriptTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        transcriptTitle.textColor = HubInkNS.ink
        let transcriptSub = NSTextField(labelWithString: "语音和打字汇进同一条记录，回答也会念出来；离开页面不会丢。")
        transcriptSub.font = .systemFont(ofSize: 11)
        transcriptSub.textColor = HubInkNS.faint
        let transcriptTitles = NSStackView(views: [transcriptTitle, transcriptSub])
        transcriptTitles.orientation = .vertical
        transcriptTitles.alignment = .leading
        transcriptTitles.spacing = 2

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let transcriptHeader = NSStackView(
            views: [transcriptTitles, headerSpacer, copyButton, replayButton, revealButton]
        )
        transcriptHeader.orientation = .horizontal
        transcriptHeader.alignment = .centerY
        transcriptHeader.spacing = 8
        transcriptHeader.translatesAutoresizingMaskIntoConstraints = false

        let transcriptCard = HubLightCard()
        transcriptCard.addSubview(transcriptHeader)
        transcriptCard.addSubview(transcriptScroll)
        NSLayoutConstraint.activate([
            transcriptHeader.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor, constant: 18),
            transcriptHeader.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor, constant: -18),
            transcriptHeader.topAnchor.constraint(equalTo: transcriptCard.topAnchor, constant: 16),

            transcriptScroll.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor, constant: 16),
            transcriptScroll.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor, constant: -16),
            transcriptScroll.topAnchor.constraint(equalTo: transcriptHeader.bottomAnchor, constant: 10),
            transcriptScroll.bottomAnchor.constraint(equalTo: transcriptCard.bottomAnchor, constant: -16),

            document.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: transcriptScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),

            transcriptStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            transcriptStack.topAnchor.constraint(equalTo: document.topAnchor),
            transcriptStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])

        // 输入卡：设计稿的输入框是白底 + 浅描边，单独做个外壳保证任何主题下都是这个观感。
        let fieldShell = HubLightCard()
        fieldShell.cornerRadius = 10
        fieldShell.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        fieldShell.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        pin(inputField, in: fieldShell, insets: 11)

        // 一行输入框 + 发送按钮；线路回显挪到卡片下面单独一行。
        let inputRow = NSStackView(views: [fieldShell, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10

        let inputCard = HubLightCard()
        pin(inputRow, in: inputCard, insets: 16)

        // 页头：设计稿的 26/13 标题区。
        let header = NSStackView(views: [pageTitle, intro])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        for view in [header, statusCard, transcriptCard, inputCard, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40)
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            statusCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            transcriptCard.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 14),
            transcriptCard.bottomAnchor.constraint(equalTo: inputCard.topAnchor, constant: -14),
            inputCard.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            // 对话记录自身滚动，不能随着大窗口把空白区域无限拉高。
            transcriptCard.heightAnchor.constraint(equalToConstant: 320)
        ])
    }

    private func stepRow() -> NSView {
        var views: [NSView] = []
        for stage in Stage.allCases {
            let label = NSTextField(labelWithString: stage.title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = HubInkNS.faint
            stepLabels[stage] = label
            views.append(label)
            if stage != Stage.allCases.last {
                let arrow = NSTextField(labelWithString: "›")
                arrow.font = .systemFont(ofSize: 11)
                arrow.textColor = HubInkNS.faint
                views.append(arrow)
            }
        }
        if let ready = stepLabels[.idle] {
            ready.textColor = HubInkNS.ink
            ready.font = .systemFont(ofSize: 11, weight: .bold)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    /// 追加一条气泡；用户的气泡靠右，中枢的气泡靠左。
    @discardableResult
    private func appendBubble(role: String, text: String, emphasized: Bool) -> BubbleView {
        let bubble = BubbleView(roleText: role + " · " + bubbleTimeFormatter.string(from: Date()),
                                emphasized: emphasized)
        bubble.body.stringValue = text

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        // 设计稿：说话的人在左，中枢在右。
        let row = NSStackView(views: emphasized ? [bubble, spacer] : [spacer, bubble])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true

        scrollTranscriptToBottom()
        return bubble
    }

    private func scrollTranscriptToBottom() {
        layoutSubtreeIfNeeded()
        guard let document = transcriptScroll.documentView else { return }
        let visible = transcriptScroll.contentView.bounds.height
        let y = max(0, document.frame.height - visible)
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    /// 把内容栈四边贴死卡片：卡片高度由内容决定，避免出现「高度 0」的空卡片。
    private func pin(_ view: NSView, in container: NSView, insets: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets)
        ])
    }

    // MARK: 动作

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func cancelTapped() { onCancel?() }

    @objc private func sendTapped() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText?(text)
    }

    @objc private func copyTapped() {
        onCopyAnswer?()
    }

    @objc private func replayTapped() { onReplayAnswer?() }
    @objc private func revealTapped() { onRevealSupportDirectory?() }
}


// MARK: - 运行状态页

enum CheckLevel {
    case ok
    case warn
    case fail

    var symbol: String {
        switch self {
        case .ok: return "✅"
        case .warn: return "⚠️"
        case .fail: return "❌"
        }
    }
}

struct EnvironmentCheck {
    let name: String
    let level: CheckLevel
    let detail: String
}

/// 「运行状态」页：把语音链路依赖和最近日志摊开，排障时不用猜。
final class StatusPanelView: NSView {

    var onRefresh: (() -> Void)?
    var onRevealSupportDirectory: (() -> Void)?
    var onOpenMicrophoneSettings: (() -> Void)?

    private let checksStack = NSStackView()
    private let summaryLabel = captionLabel("尚未自检", size: 12, weight: .semibold)
    private let logView = NSTextView()
    private let logPathLabel = captionLabel("", size: 11)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        wantsLayer = true
        layer?.backgroundColor = HubInkNS.page.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setChecks(_ checks: [EnvironmentCheck]) {
        for view in checksStack.arrangedSubviews {
            checksStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        checksStack.addArrangedSubview(row("状态", level: .ok, detail: "共 \(checks.count) 项检查"))
        for check in checks {
            checksStack.addArrangedSubview(row(check.name, level: check.level, detail: check.detail))
        }
        let failed = checks.filter { $0.level == .fail }.count
        let warned = checks.filter { $0.level == .warn }.count
        if failed > 0 {
            summaryLabel.stringValue = "\(failed) 项不可用，语音链路可能失败"
            summaryLabel.textColor = .systemRed
        } else if warned > 0 {
            summaryLabel.stringValue = "\(warned) 项需要注意，其余可用"
            summaryLabel.textColor = .systemOrange
        } else {
            summaryLabel.stringValue = "全部可用"
            summaryLabel.textColor = .systemGreen
        }
    }

    func setLogPath(_ path: String) {
        logPathLabel.stringValue = path
    }

    func setLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logView.string = trimmed.isEmpty ? "（还没有运行日志）" : trimmed
        logView.textColor = trimmed.isEmpty ? .tertiaryLabelColor : .labelColor
        logView.scrollToEndOfDocument(nil)
    }

    private func build() {
        let title = NSTextField(labelWithString: "运行环境自检")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let intro = captionLabel("逐项检查语音链路依赖；缺哪一项、要装什么，都写在下面。")

        let refresh = NSButton(title: "重新自检", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .rounded
        let reveal = NSButton(title: "打开配置目录", target: self, action: #selector(revealTapped))
        reveal.bezelStyle = .rounded
        let microphone = NSButton(title: "麦克风设置", target: self, action: #selector(microphoneSettingsTapped))
        microphone.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [refresh, reveal, microphone, summaryLabel])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        checksStack.orientation = .vertical
        checksStack.alignment = .leading
        checksStack.spacing = 6
        checksStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        checksStack.translatesAutoresizingMaskIntoConstraints = false

        let checksCard = CardView()
        checksCard.addSubview(checksStack)
        NSLayoutConstraint.activate([
            checksStack.leadingAnchor.constraint(equalTo: checksCard.leadingAnchor),
            checksStack.trailingAnchor.constraint(equalTo: checksCard.trailingAnchor),
            checksStack.topAnchor.constraint(equalTo: checksCard.topAnchor),
            checksStack.bottomAnchor.constraint(equalTo: checksCard.bottomAnchor),
        ])

        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = true
        logScroll.backgroundColor = HubInkNS.card
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = true
        logView.backgroundColor = HubInkNS.card
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.frame = NSRect(x: 0, y: 0, width: 720, height: 200)

        let logTitle = captionLabel("最近运行日志（本机记录，含每次交互的阶段与用时）", size: 12, weight: .semibold)

        let root = NSStackView(views: [title, intro, buttonRow, checksCard, logTitle, logPathLabel, logScroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            checksCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            logScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        for view in [title, intro, buttonRow, checksCard, logTitle, logPathLabel] {
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        logScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
    }

    private func row(_ name: String, level: CheckLevel, detail: String) -> NSView {
        let icon = NSTextField(labelWithString: level.symbol)
        icon.font = .systemFont(ofSize: 12)
        icon.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let nameLabel = captionLabel(name, size: 12, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.widthAnchor.constraint(equalToConstant: 176).isActive = true
        let detailLabel = captionLabel(detail, size: 12)
        detailLabel.textColor = .labelColor
        detailLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [icon, nameLabel, detailLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    @objc private func refreshTapped() { onRefresh?() }
    @objc private func revealTapped() { onRevealSupportDirectory?() }
    @objc private func microphoneSettingsTapped() { onOpenMicrophoneSettings?() }
}

// MARK: - 中枢主窗口

/// AI 中枢主窗口：常驻，左侧栏在「语音助手 / Agent 与线路 / 运行状态」之间切换。
///
/// 关闭窗口只隐藏（`windowShouldClose` 返回 false），应用继续在状态栏和 Dock 里
/// 存活 —— 这正是之前"关掉录音软件整个 App 就没了"的修复点。
final class HubWindowController: NSWindowController, NSWindowDelegate,
                                  NSTableViewDataSource, NSTableViewDelegate {

    enum Page: Int, CaseIterable {
        case home
        case voice
        case router
        case agents
        case jev
        case status
        case routerDetail

        /// 侧栏顺序；「供应商详情」是二级页，不占侧栏位置。
        static let sidebarOrder: [Page] = [.home, .voice, .router, .agents, .jev, .status]

        var title: String {
            switch self {
            case .home: return "总览"
            case .voice: return "语音助手"
            case .router: return "本地路由"
            case .agents: return "Agent 管理"
            case .jev: return "Jev 档位"
            case .status: return "设置与状态"
            case .routerDetail: return "供应商详情"
            }
        }

        var subtitle: String {
            switch self {
            case .home: return "现状、入口与能力"
            case .voice: return "说话或打字提问"
            case .router: return "供应商、模型与健康检查"
            case .agents: return "检测客户端配置并接入"
            case .jev: return "四档映射到具体模型"
            case .status: return "权限、自检与日志"
            case .routerDetail: return "维护这条连接的模型目录"
            }
        }

        var symbol: String {
            switch self {
            case .home: return "square.grid.2x2"
            case .voice: return "bubble.left.and.bubble.right"
            case .router: return "network"
            case .agents: return "person.2"
            case .jev: return "slider.horizontal.3"
            case .status: return "gearshape"
            case .routerDetail: return "link"
            }
        }
    }

    /// 首页：默认打开的那一页，负责解释「这是什么」并给出两个入口（打字 / 说话）。
    let homePanel = HomePanelView()
    /// 对话页：真正的聊天记录 + 输入区，语音和打字都走这里。
    let chatPanel = ChatPanelView()
    let statusPanel = StatusPanelView()

    /// 切页时回调，`VoiceController` 用它按需刷新运行状态页。
    var onPageChange: ((Page) -> Void)?

    private(set) var currentPage: Page = .home

    /// 自检用：这一页是否已经真的建出来（侧栏有条目但点进去空白就是没建）。
    func isPageBuilt(_ page: Page) -> Bool { pageViews[page] != nil }

    // MARK: 自检入口（横幅是私有视图，自检只能透过窗口这一层问它）
    //
    // 这些钩子只读状态、不改界面，形状跟 `isPageBuilt` 一致：测的是「界面真的这样画了吗」，
    // 而不是「某个私有字段等于某个值」。

    /// 自检用：全局提示当前显示的文字与高度。高度 0 = 已收起，内容列顶部不留空带。
    func noticeBannerState() -> (text: String, height: CGFloat) {
        (noticeBanner.textForTesting, noticeBanner.frame.height)
    }

    /// 自检用：当前页顶边离内容列顶边多远。横幅展开时它必须 ≥ 横幅高度（页面被推下去，不是被盖住）。
    func currentPageTopInset() -> CGFloat? {
        guard let page = currentPageView, page.superview === contentContainer else { return nil }
        return contentContainer.bounds.maxY - page.frame.maxY
    }

    /// 自检用：走一遍跟数据层完全相同的路径展出一条提示。
    func showNotice(text: String?, ok: Bool) {
        noticeBanner.show(text: text, ok: ok)
    }

    /// 自检用：数据层是不是把「说什么」接到了这条横幅上（没接就等于提示无处可去）。
    var isNoticeWired: Bool { hubModel.onNotice != nil }

    /// 自检用：策略写入前是否有确认钩子（没有钩子＝会不经同意就改别人的配置文件）。
    var hasGatewayConfirmWired: Bool { hubModel.presentGatewayConfirm != nil }

    /// 设计稿各页共用的数据层：router.json / health.json / stats.json + Agent 扫描。
    let hubModel = HubModel()
    /// 「总览」页的状态桥：语音状态和最近一次对话由 VoiceController 推进来。
    let homeBridge = HubHomeBridge()

    private let sidebarTable = NSTableView()
    private let contentContainer = NSView()
    /// 当前可见的页视图（自检要量它离内容列顶边多远，判断横幅有没有把页面盖住）。
    private weak var currentPageView: NSView?
    /// 内容列顶部的全局提示横幅（成功/失败共用一条）。
    private let noticeBanner = HubNoticeBanner()
    private let routerController: RouterManagerWindowController
    private var pageViews: [Page: NSView] = [:]
    private var syncingSidebarSelection = false
    /// 侧栏当前高亮行（「供应商详情」沿用「本地路由」那一行）。
    private var selectedSidebarRow = 0
    private var sidebarWidthConstraint: NSLayoutConstraint?
    // 与当前 Codex 主窗口（1146×793）保持同一默认比例；用户后续手动调整的尺寸
    // 仍由 autosave 保留，不会被 present() 覆盖。
    private static let defaultSize = NSSize(width: 1146, height: 793)
    /// 最小尺寸只保证「侧栏 224 + 一列可读内容」还在；各页在窄宽度会自动堆叠。
    /// 不要把设计稿宽度当成最小值，否则用户几乎没有可拖动的范围。
    private static let minimumSize = NSSize(width: 760, height: 500)
    // 当前用户实际使用的窄侧栏宽度；品牌卡和选中胶囊会按这个宽度收缩。
    private static let defaultSidebarWidth: CGFloat = 182
    private static let sidebarWidthRange: ClosedRange<CGFloat> = 180...360
    private static let sidebarWidthDefaultsKey = "AIHubSidebarWidth"
    private static let sidebarWidthVersionKey = "AIHubSidebarWidthVersion"
    private static let currentSidebarWidthVersion = 2

    private static var preferredSidebarWidth: CGFloat {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: sidebarWidthVersionKey) != currentSidebarWidthVersion {
            defaults.removeObject(forKey: sidebarWidthDefaultsKey)
            defaults.set(currentSidebarWidthVersion, forKey: sidebarWidthVersionKey)
        }
        let stored = defaults.double(forKey: sidebarWidthDefaultsKey)
        return sidebarWidthRange.contains(stored) ? stored : defaultSidebarWidth
    }
    /// 记住用户手动调过的窗口尺寸，下次打开沿用它。
    private static let frameAutosaveName = "AIHubWindowFrame"

    private static var savedFrameSize: NSSize? {
        guard let raw = UserDefaults.standard.string(forKey: "NSWindow Frame \(frameAutosaveName)"),
              !raw.isEmpty else { return nil }
        let rect = NSRectFromString(raw)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect.size
    }

    /// 自动保存 frame 的版本号。布局/设计稿换代时 +1，旧版本存下来的尺寸直接作废。
    private static let frameAutosaveVersionKey = "AIHubWindowFrameVersion"
    private static let currentFrameAutosaveVersion = 5

    /// 丢掉过期的 `NSWindow Frame AIHubWindowFrame`。
    ///
    /// 用户实测：窗口打开是 1224×771，设计稿要的 1355×900（屏可见区收窄）根本没生效。
    /// 根因是 `setFrameAutosaveName` 会恢复老会话保存的 frame；版本不一致时必须丢弃。
    /// 这里按版本号判定：版本对不上（含老版本没写版本号的情况）就删掉那份 frame，
    /// 让窗口回到设计稿尺寸；版本一致才当作「用户自己拖过」沿用。
    static func discardStaleSavedFrameIfNeeded() {
        let defaults = UserDefaults.standard
        let frameKey = "NSWindow Frame \(frameAutosaveName)"
        let storedVersion = defaults.object(forKey: frameAutosaveVersionKey) as? Int
        guard storedVersion != currentFrameAutosaveVersion else { return }
        if let stale = defaults.string(forKey: frameKey) {
            NSLog("AIHub: 丢弃过期窗口 frame「%@」(版本 %@ → %d)", stale, storedVersion.map(String.init) ?? "无", currentFrameAutosaveVersion)
            defaults.removeObject(forKey: frameKey)
        }
        defaults.set(currentFrameAutosaveVersion, forKey: frameAutosaveVersionKey)
    }

    init() {
        // Read the last frame before creating the window. This makes a fresh
        // app launch start at the user's current size instead of briefly using
        // the design canvas and then being resized by AppKit/autosave.
        HubWindowController.discardStaleSavedFrameIfNeeded()
        let launchSize = HubWindowController.savedFrameSize ?? HubWindowController.defaultSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: launchSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AI助手 · 中枢"
        window.subtitle = "语音助手 · Agent 线路 · 运行状态"
        // 设计稿固定为浅色；不让系统深色外观把 AppKit 标题/按钮渲染成白字落在浅底上。
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        // 最小尺寸随窗口一起放小，用户才能真正拖动缩放。
        window.contentMinSize = HubWindowController.minimumSize
        window.minSize = NSSize(
            width: HubWindowController.minimumSize.width,
            height: HubWindowController.minimumSize.height + 32
        )
        // 初始尺寸：沿用当前 frame；首次启动才按设计稿尺寸，并按可见区收窄。
        //（showWindow 会收缩窗口），那时用的是同一个 applyDesignedFrame。
        let visible = (NSScreen.main ?? window.screen)?.visibleFrame
            ?? NSRect(origin: .zero, size: launchSize)
        let chrome = max(window.frame.height - window.contentLayoutRect.height, 0)
        let initial = NSSize(
            width: min(launchSize.width, visible.width),
            height: min(launchSize.height + chrome, visible.height)
        )
        window.setFrame(
            NSRect(
                x: visible.minX,
                y: max(visible.minY, visible.maxY - initial.height),
                width: initial.width,
                height: initial.height
            ),
            display: false
        )
        window.setFrameAutosaveName(HubWindowController.frameAutosaveName)

        routerController = RouterManagerWindowController()
        super.init(window: window)
        window.delegate = self

        buildUI()

        // 页内跳转由中枢窗口自己管：设计稿里的「供应商详情」是「本地路由」的二级页。
        hubModel.onOpenPage = { [weak self] page in self?.select(page) }
        hubModel.presentLegacyRouterPanel = { [weak self] in self?.routerController.showWindow(nil) }
        hubModel.ensureGatewayRunning = { [weak self] in self?.routerController.startGatewayIfNeeded() }
        // 数据层只负责「说什么」，横幅由窗口画：全 App 唯一一份提示，不跟着页面重复。
        hubModel.onNotice = { [weak self] text, ok in
            self?.noticeBanner.show(text: text, ok: ok)
        }
        // 改别人的配置文件之前必须让人看清「动哪些文件、改成什么样」，所以确认框留在窗口这一层。
        hubModel.presentGatewayConfirm = { [weak self] prompt in
            self?.confirmGatewayWrite(prompt) ?? false
        }
        hubModel.presentAgentModelConfirm = { [weak self] prompt in
            self?.confirmAgentModelWrite(prompt) ?? false
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 「Agent 线路策略 → 统一网关」写入前的确认框。
    ///
    /// 正文可能很长（每个客户端一条差异），所以放进可滚动的只读文本域，而不是
    /// `informativeText` —— 那里放长文本会被弹窗裁掉，用户看不到自己将要同意什么。
    private func confirmGatewayWrite(_ prompt: HubStrategySync.WritePrompt) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.messageText
        alert.informativeText = "下面是即将写入的内容；确认后脚本会先备份原文件，再改动这些客户端。"
        // 默认键 = 「写入」，Esc = 「取消」：危险的按钮不该是顺手敲回车就中的那个。
        alert.addButton(withTitle: "写入")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let detail = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        detail.string = prompt.informativeText
        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = false
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        scroll.documentView = detail
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 「添加模型」与「统一网关」共用滚动确认框，避免长 diff 被系统弹窗裁掉。
    private func confirmAgentModelWrite(_ prompt: HubStrategySync.AgentModelWritePrompt) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.messageText
        alert.informativeText = "确认后会先备份客户端配置，再同步它自己的 Agent 线路；取消不会改任何文件。"
        alert.addButton(withTitle: "备份并写入")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let detail = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        detail.string = prompt.informativeText
        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = false
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        scroll.documentView = detail
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: 构建

    private func buildUI() {
        // 用窗口当前的 contentLayoutRect，而不是写死设计画布 1440×900。
        // `window.contentView = container` 会按新内容视图的 frame 反过来调整窗口尺寸：
        // 写死 1440×900 会把 init 里刚算好的、已经收窄到可见区的窗口重新撑大，
        // 系统再把窗口夹回屏幕内时宽度就停在最小宽（实测 1180），
        // 「总览」页 1060pt 的按钮区因此落到窗口外面点不到。
        let layout = window?.contentLayoutRect.size ?? HubWindowController.defaultSize
        let container = NSView(frame: NSRect(origin: .zero, size: layout))

        // 设计稿侧栏是纯白底 + 右侧 1px 分隔线：毛玻璃材质在浅色设计里会显脏。
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.white.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let brandCard = HubBrandCard()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.style = .plain
        sidebarTable.selectionHighlightStyle = .regular
        // 设计稿行距 58：48 高的胶囊 + 10pt 空隙。AppKit 只在行视图内部留空隙，
        // 所以整行按 58 建，胶囊画在行顶的 48 内（见 HubSidebarRow / SidebarCell）。
        sidebarTable.rowHeight = 58
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 0)
        sidebarTable.allowsEmptySelection = false
        sidebarTable.backgroundColor = .white
        sidebarTable.gridStyleMask = []
        sidebarTable.focusRingType = .none
        sidebarTable.dataSource = self
        sidebarTable.delegate = self

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(brandCard)
        sidebar.addSubview(sidebarScroll)

        // 侧栏页脚：设计稿是一张 176×74 的浅灰状态卡（绿点 + 系统在线 + 说明）。
        let footnote = HubSidebarFooter()
        sidebar.addSubview(footnote)

        let divider = HubSidebarResizeHandle()
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = HubInkNS.page.cgColor
        // A page must never paint over the sidebar while its document view is
        // remeasuring during a resize.  The scroll views still own scrolling;
        // this boundary only clips transient intrinsic-width overshoot.
        contentContainer.layer?.masksToBounds = true
        // 横幅在内容列内部：它出现时页面被推下去，收起时高度归零、页面重新占满。
        contentContainer.addSubview(noticeBanner)
        container.addSubview(sidebar)
        container.addSubview(divider)
        container.addSubview(contentContainer)

        let sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: Self.preferredSidebarWidth)
        self.sidebarWidthConstraint = sidebarWidthConstraint
        divider.onDrag = { [weak self] delta in
            guard let self, let constraint = self.sidebarWidthConstraint else { return }
            let width = min(max(constraint.constant + delta, Self.sidebarWidthRange.lowerBound),
                            Self.sidebarWidthRange.upperBound)
            constraint.constant = width
            UserDefaults.standard.set(width, forKey: Self.sidebarWidthDefaultsKey)
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebarWidthConstraint,

            // 设计稿：卡片左上角 (24,24)，176×56。
            brandCard.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            brandCard.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 24),
            brandCard.widthAnchor.constraint(equalToConstant: 158),
            brandCard.heightAnchor.constraint(equalToConstant: 56),

            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            // 首行距卡片底 36（设计稿 row1 顶边 116 = 80 + 36）。
            sidebarScroll.topAnchor.constraint(equalTo: brandCard.bottomAnchor, constant: 36),
            sidebarScroll.bottomAnchor.constraint(equalTo: footnote.topAnchor, constant: -12),

            footnote.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            footnote.widthAnchor.constraint(equalToConstant: 158),
            footnote.heightAnchor.constraint(equalToConstant: 74),
            footnote.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -36),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 8),

            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The window uses `.fullSizeContentView`; on this window the custom
            // container's safeAreaGuide is zero even though the titlebar overlays
            // the first ~64pt. Keep the content column explicitly below it.
            contentContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 64),
            contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            noticeBanner.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 40),
            noticeBanner.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -40),
            noticeBanner.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 16),
        ])

        window?.contentView = container
        // `setContentView` 之后再次明确保留原生可缩放能力。某些 macOS
        // 版本在 fullSizeContentView + autosave 恢复时会重算 style mask；
        // 这里是最终边界，确保绿色缩放按钮和拖拽边框都可用。
        if let window {
            window.styleMask.insert(.resizable)
            window.contentMinSize = HubWindowController.minimumSize
            window.minSize = NSSize(width: HubWindowController.minimumSize.width,
                                    height: HubWindowController.minimumSize.height + 32)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
        select(.home)
    }

    /// 页面按需构建：路由面板很重（三张表 + 落盘读取），首次切到该页才建。
    private func installPage(_ page: Page, view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            // 挂在横幅下沿：横幅收起时是 0 高，页面就跟以前一样贴顶。
            view.topAnchor.constraint(equalTo: noticeBanner.bottomAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        pageViews[page] = view
        view.isHidden = (page != currentPage)
        if page == currentPage { currentPageView = view }
    }

    private func ensurePageBuilt(_ page: Page) {
        switch page {
        case .home:
            if pageViews[page] == nil {
                installPage(page, view: hosted(HubOverviewPage(bridge: homeBridge, model: hubModel), for: page))
            }
        case .voice:
            if pageViews[page] == nil { installPage(page, view: HostedPanelScrollView(panel: chatPanel)) }
        case .status:
            if pageViews[page] == nil { installPage(page, view: statusPanel) }
        case .router:
            if pageViews[page] == nil {
                installPage(page, view: hosted(HubRouterPage(model: hubModel), for: page))
            }
        case .routerDetail:
            if pageViews[page] == nil {
                installPage(page, view: hosted(HubConnectionDetailPage(model: hubModel), for: page))
            }
        case .agents:
            if pageViews[page] == nil {
                installPage(page, view: hosted(HubAgentsPage(model: hubModel), for: page))
            }
        case .jev:
            if pageViews[page] == nil {
                installPage(page, view: hosted(HubJevPage(model: hubModel), for: page))
            }
        }
        pageViews[page]?.isHidden = (page != currentPage)
    }

    /// 包一层 SwiftUI 宿主，并把内容区宽度回传给数据层。
    private func hosted<Content: View>(_ root: Content, for page: Page) -> HostedSwiftUIPage {
        let container = HostedSwiftUIPage(root: root)
        container.onViewportWidth = { [weak self] width in
            guard let self else { return }
            // 页面贴在 contentContainer 上，宽度已经不含侧栏，直接用即可。
            let usable = max(width, 1)
            if abs(self.hubModel.viewportWidth - usable) > 1 {
                self.hubModel.viewportWidth = usable
            }
        }
        return container
    }

    /// SwiftUI 页面：正文自己撑高，外面套一层滚动容器，窗口变宽时跟着重排。
    private final class HostedSwiftUIPage: NSScrollView {
        private let host: NSHostingView<AnyView>
        private var pendingScrollToTop = false
        /// 内容区真实宽度回传给页面，让页面自己决定列数。
        var onViewportWidth: ((CGFloat) -> Void)?

        init<Content: View>(root: Content) {
            host = NSHostingView(rootView: AnyView(root))
            super.init(frame: .zero)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(HubInk.page).cgColor
            hasVerticalScroller = true
            // 页面已改成自适应宽度，正常不会再需要横向滚动；
            // 这里保留它只作兜底，避免极端情况下右侧被静默裁掉、按钮点不到。
            hasHorizontalScroller = false
            horizontalScrollElasticity = .none
            autohidesScrollers = true
            drawsBackground = true
            backgroundColor = NSColor(HubInk.page)
            borderType = .noBorder
            contentView.drawsBackground = true
            contentView.backgroundColor = NSColor(HubInk.page)
            documentView = host
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layout() {
            super.layout()
            let viewportWidth = max(contentView.bounds.width, 1)
            // 把真实可用宽度回传给页面：页面据此决定两列并排还是上下堆叠。
            onViewportWidth?(viewportWidth)
            // 先按视口宽排一次，再问内容需要多高。
            if host.frame.size.width != viewportWidth {
                host.frame.size.width = viewportWidth
            }
            let fitting = host.fittingSize
            // 宽度一律锁在视口宽。不能取 max(viewport, fitting.width)：
            // fittingSize 是按「文字不换行的理想宽度」算的，页面上长长的 baseURL
            // （即使写了 lineLimit(1)）也会让文档视图撑到 1031pt，
            // 于是内容比窗口宽、右边被横向滚动裁掉 —— 用户看到的就是「UI 重叠 / 点不到」。
            // 页面本身已经做成了自适应（窄了就堆叠），所以锁宽度不会挤压内容。
            let width = viewportWidth
            let height = max(fitting.height, contentView.bounds.height)
            if host.frame.size != NSSize(width: width, height: height) {
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
            if pendingScrollToTop {
                applyScrollToTop()
                pendingScrollToTop = false
            }
        }

        func scrollToTop() {
            pendingScrollToTop = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            applyScrollToTop()
            // SwiftUI can trigger one more host layout after the page becomes
            // visible; repeat once after that layout so the old expanded-page
            // offset cannot hide the new page header.
            DispatchQueue.main.async { [weak self] in
                self?.applyScrollToTop()
            }
        }

        private func applyScrollToTop() {
            contentView.setBoundsOrigin(.zero)
            reflectScrolledClipView(contentView)
        }
    }

    /// 路由面板是"自己撑满宽度 + 内容决定高度"的视图，放进滚动容器里最稳。
    private final class HostedPanelScrollView: NSScrollView {
        private let panel: NSView

        init(panel: NSView) {
            self.panel = panel
            super.init(frame: .zero)
            hasVerticalScroller = true
            hasHorizontalScroller = false
            drawsBackground = true
            backgroundColor = HubInkNS.page
            borderType = .noBorder
            contentView.drawsBackground = true
            contentView.backgroundColor = HubInkNS.page
            panel.wantsLayer = true
            panel.layer?.backgroundColor = HubInkNS.page.cgColor
            documentView = panel
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layout() {
            super.layout()
            let fitting = panel.fittingSize
            // A document view without an explicit width is otherwise sized to
            // the intrinsic width of its tables, leaving the right half of a
            // wide native window blank. Use the viewport width as the floor.
            let viewportWidth = contentView.bounds.width
            let width = max(viewportWidth, contentSize.width, fitting.width)
            let height = max(contentSize.height, fitting.height)
            if panel.frame.size != NSSize(width: width, height: height) {
                panel.frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
        }
    }

    // MARK: 对外接口

    func select(_ page: Page) {
        ensurePageBuilt(page)
        currentPage = page
        currentPageView = pageViews[page]
        for (candidate, view) in pageViews {
            view.isHidden = (candidate != page)
        }
        // 二级页（供应商详情）在侧栏里沿用「本地路由」这一行的高亮。
        let highlighted = page == .routerDetail ? Page.router : page
        if let row = Page.sidebarOrder.firstIndex(of: highlighted) {
            if sidebarTable.selectedRow != row {
                syncingSidebarSelection = true
                sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                syncingSidebarSelection = false
            }
            selectedSidebarRow = row
            refreshSidebarRows()
        }
        // 每次切页都回到页面顶部。否则上一次在展开台账/供应商后留下的滚动位置
        // 会带到下一次打开，表现为标题被裁掉、展开后找不到收起按钮。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let scroll = self.pageViews[page] as? HostedSwiftUIPage else { return }
            scroll.scrollToTop()
            DispatchQueue.main.async {
                scroll.scrollToTop()
            }
        }
        onPageChange?(page)
    }

    /// 表里已经建出来的行跟着选中状态换色（选中是加粗深色 + 蓝点）。
    private func refreshSidebarRows() {
        for row in 0..<Page.sidebarOrder.count {
            guard let cell = sidebarTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell else { continue }
            cell.setSelected(row == selectedSidebarRow)
        }
    }

    func present(_ page: Page = .home) {
        select(page)
        // showWindow 可能按内容视图的 intrinsic height 改一次 frame；先记住用户
        // 当前真正使用的尺寸，showWindow 后再把同一个尺寸夹回可见区，避免每次
        // 从菜单/状态栏打开都被重置成 1440×900。
        let preferredSize = window?.frame.size
        showWindow(nil)
        applyDesignedFrame(preferredSize: preferredSize)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 按用户当前尺寸摆回可见区；首次创建时 init 已经用设计稿尺寸初始化。
    /// 只有尺寸越过屏幕边界才收窄，不再每次打开都覆盖用户手动调整的比例。
    private func applyDesignedFrame(preferredSize: NSSize? = nil) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let chrome = max(window.frame.height - window.contentLayoutRect.height, 0)
        let requested = preferredSize ?? window.frame.size
        let size = NSSize(
            width: min(max(requested.width, HubWindowController.minimumSize.width), visible.width),
            height: min(max(requested.height, HubWindowController.minimumSize.height + chrome), visible.height)
        )
        window.setFrame(
            NSRect(
                x: visible.minX,
                y: max(visible.minY, visible.maxY - size.height),
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    /// 退出前收尾：路由页里可能起过「总路由网关」子进程。
    func shutdown() {
        routerController.shutdownGateway()
    }

    /// 关窗口不是退出：藏起来，App 继续待机。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: 侧栏数据源 / 代理

    func numberOfRows(in tableView: NSTableView) -> Int {
        Page.sidebarOrder.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard Page.sidebarOrder.indices.contains(row) else { return nil }
        let page = Page.sidebarOrder[row]
        let identifier = NSUserInterfaceItemIdentifier("page-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarCell)
            ?? SidebarCell(identifier: identifier)
        cell.apply(page, selected: row == selectedSidebarRow)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HubSidebarRow()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSidebarSelection, Page.sidebarOrder.indices.contains(sidebarTable.selectedRow) else { return }
        let page = Page.sidebarOrder[sidebarTable.selectedRow]
        guard page != currentPage else { return }
        select(page)
    }
}

/// 侧栏与内容区之间的可拖拽分隔条。
private final class HubSidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        HubInkNS.line.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// 侧栏顶部的品牌卡：176×56 紫蓝渐变圆角卡，白圆里一个蓝色加号。
private final class HubBrandCard: NSView {

    private let gradient = CAGradientLayer()
    private let badge = NSView()
    private let mark = HubPlusMark()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 176, height: 56))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        // 设计稿渐变 135°：左上 #6C63FF → 右下 #4F8CFF。CALayer 的 y 轴向上，所以起点是 (0,1)。
        gradient.colors = [HubInkNS.brandStart.cgColor, HubInkNS.brandEnd.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)

        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.white.cgColor
        badge.layer?.cornerRadius = 15
        badge.translatesAutoresizingMaskIntoConstraints = false

        mark.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "AI助手")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "本地 AI 中枢")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = HubInkNS.brandSub
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(mark)
        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),

            mark.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 15),
            mark.heightAnchor.constraint(equalToConstant: 15),

            // 设计稿基线：标题 y=50、副标题 y=67（卡片顶边 24）。
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            title.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 26),
            subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            subtitle.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 43),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

/// 品牌卡里的加号（12px 臂长、3px 圆头描边）。
private final class HubPlusMark: NSView {

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 6
        HubInkNS.brandMark.setStroke()
        for isVertical in [true, false] {
            let path = NSBezierPath()
            if isVertical {
                path.move(to: NSPoint(x: center.x, y: center.y - arm))
                path.line(to: NSPoint(x: center.x, y: center.y + arm))
            } else {
                path.move(to: NSPoint(x: center.x - arm, y: center.y))
                path.line(to: NSPoint(x: center.x + arm, y: center.y))
            }
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}

/// 全局提示横幅：整个 App 只有这一份「刚才发生了什么」。
///
/// 每个页面各画一份提示，同一句话就会在界面上出现两次（数据层推一次、页面自己拼一次），
/// 所以数据层的通知只投到这里。横幅挂在内容列顶部，出现时把页面往下推（走容器布局），
/// 而不是浮在页面上盖住底下的按钮。
private final class HubNoticeBanner: NSView {

    /// 点「关闭」后回调，让窗口知道自己被收起了。
    var onDismiss: (() -> Void)?

    private let row = NSStackView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let flexibleSpace = NSView()
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    /// 展开时用四条边把行贴满；收起时换成固定 0 高，免得行内边距留下一条空带。
    private var edgeConstraints: [NSLayoutConstraint] = []
    private var collapsedConstraint: NSLayoutConstraint?
    /// 到点自己收起的定时器。新提示进来先取消旧的，不然早到的那个会把新提示收掉。
    private var autoCollapse: Timer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        label.font = .systemFont(ofSize: 12)
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let minimumLabelWidth = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
        minimumLabelWidth.priority = .defaultHigh
        minimumLabelWidth.isActive = true
        // 先给多行文本一个合理的初始换行宽度，避免空字符串初始化时
        // NSTextField 的 intrinsic width 变成极窄列，首条提示被竖排。
        label.preferredMaxLayoutWidth = 480
        // 让文字区域可压缩：横幅宽度由窗口决定，文字自己换行，而不是把横幅顶宽。
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        flexibleSpace.translatesAutoresizingMaskIntoConstraints = false
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        flexibleSpace.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        row.addArrangedSubview(flexibleSpace)
        row.addArrangedSubview(closeButton)
        addSubview(row)

        edgeConstraints = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(edgeConstraints)
        show(text: nil, ok: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 自检用：当前挂在横幅上的文字（空串＝已收起）。
    var textForTesting: String { isHidden ? "" : label.stringValue }

    /// 展出/收起一条提示。`text` 为空就整条收起（高度归零，页面重新占满）。
    ///
    /// 展开的横幅跟数据层里那条 `notice` 活得一样长（`hubNoticeLifetime`），到点自己收起：
    /// 常驻横幅会把每页顶部都顶下去一截，那正是「遮住其他内容」。
    func show(text: String?, ok: Bool) {
        autoCollapse?.invalidate()
        autoCollapse = nil
        guard let text, !text.isEmpty else {
            setExpanded(false)
            return
        }
        label.stringValue = text
        label.textColor = ok ? HubInkNS.tintInk : HubInkNS.badInk
        dot.layer?.backgroundColor = (ok ? HubInkNS.online : HubInkNS.badDot).cgColor
        layer?.backgroundColor = (ok ? HubInkNS.accentSoft : HubInkNS.badSoft).cgColor
        layer?.borderColor = (ok ? HubInkNS.accentLine : HubInkNS.badLine).cgColor
        closeButton.attributedTitle = NSAttributedString(
            string: "关闭",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ok ? HubInkNS.accent : HubInkNS.badInk,
            ]
        )
        // 文字被截断时，鼠标停着也能看全。
        toolTip = text
        setExpanded(true)

        let timer = Timer(timeInterval: hubNoticeLifetime, repeats: false) { [weak self] _ in
            self?.autoCollapse = nil
            self?.setExpanded(false)
        }
        autoCollapse = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setExpanded(_ expanded: Bool) {
        isHidden = !expanded
        row.isHidden = !expanded
        if expanded {
            collapsedConstraint?.isActive = false
            collapsedConstraint = nil
            NSLayoutConstraint.activate(edgeConstraints)
        } else {
            NSLayoutConstraint.deactivate(edgeConstraints)
            let zero = heightAnchor.constraint(equalToConstant: 0)
            zero.isActive = true
            collapsedConstraint = zero
        }
    }

    override func layout() {
        super.layout()
        // NSTextField 在栈里换行要靠这个宽度提示，否则会按「整句不换行」算高度。
        label.preferredMaxLayoutWidth = label.frame.width
    }

    @objc private func dismiss() {
        autoCollapse?.invalidate()
        autoCollapse = nil
        setExpanded(false)
        onDismiss?()
    }
}

/// 侧栏页脚状态卡：绿点 + 「系统在线」+ 一句话说明。
private final class HubSidebarFooter: NSView {

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 176, height: 74))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = HubInkNS.cardSoft.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = HubInkNS.line.cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = HubInkNS.online.cgColor
        dot.layer?.cornerRadius = 7
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "系统在线")
        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = HubInkNS.ink
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "关闭窗口不会退出 App")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = HubInkNS.faint
        hint.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(title)
        addSubview(hint)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            dot.centerYAnchor.constraint(equalTo: topAnchor, constant: 27),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42),
            title.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 31),

            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 55),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// 侧栏一行：16px 圆点 + 14px 标题（设计稿没有图标和副标题）。
private final class SidebarCell: NSTableCellView {

    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        textField = title

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 8
        dot.translatesAutoresizingMaskIntoConstraints = false

        title.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(title)
        NSLayoutConstraint.activate([
            // 设计稿：圆点圆心 x=48，标题 x=64，行基线 = 行顶 + 29。
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 35),
            // 圆点圆心 = 胶囊顶 + 24（胶囊 48 高，正好是垂直居中）。
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            dot.widthAnchor.constraint(equalToConstant: 16),
            dot.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64),
            title.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 29),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ page: HubWindowController.Page, selected: Bool) {
        title.stringValue = page.title
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        title.font = .systemFont(ofSize: 14, weight: selected ? .bold : .regular)
        title.textColor = selected ? HubInkNS.ink : HubInkNS.sub
        dot.layer?.backgroundColor = (selected ? HubInkNS.dotOn : HubInkNS.dotIdle).cgColor
    }
}

/// 选中行底：18px 缩进、188×48、圆角 12 的淡紫底（设计稿 selection pill）。
private final class HubSidebarRow: NSTableRowView {

    override func drawBackground(in dirtyRect: NSRect) {
        // 交给列表的白色底，避免行视图再刷一层。
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // 设计稿 selection pill：x=18、188×48、圆角 12，顶边与行顶对齐；
        // 行内剩下的 10pt 就是设计里的行间距。
        let pillWidth = min(188, max(140, bounds.width - 36))
        let pill = NSRect(x: 18, y: 0, width: pillWidth, height: min(48, bounds.height))
        HubInkNS.accentSoft.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
    }
}
