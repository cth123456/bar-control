import AppKit

@MainActor
func platformIcon(_ clientID: String) -> NSImage? {
    let bundleIDs: [String]
    let appNames: [String]
    let fallbackSymbol: String
    switch clientID {
    case "codex", "codex-color":
        bundleIDs = ["com.openai.codex", "com.openai.chat"]
        appNames = ["ChatGPT", "Codex"]
        fallbackSymbol = "curlybraces.square.fill"
    case "magpie":
        bundleIDs = ["com.yetone.magpie"]
        appNames = ["magpie", "Magpie"]
        fallbackSymbol = "point.3.connected.trianglepath.dotted"
    case "claude", "claude-desktop":
        bundleIDs = ["com.anthropic.claudefordesktop"]
        appNames = ["Claude"]
        fallbackSymbol = "sparkles"
    case "gemini":
        bundleIDs = []
        appNames = ["Gemini"]
        fallbackSymbol = "diamond.fill"
    case "grokbuild":
        bundleIDs = []
        appNames = ["Grok"]
        fallbackSymbol = "xmark.circle.fill"
    case "opencode":
        bundleIDs = []
        appNames = ["OpenCode"]
        fallbackSymbol = "terminal.fill"
    case "zcode":
        bundleIDs = ["dev.zcode.app"]
        appNames = ["ZCode"]
        fallbackSymbol = "chevron.left.forwardslash.chevron.right"
    case "workbuddy", "workbuddy-color":
        bundleIDs = []
        appNames = ["WorkBuddy"]
        fallbackSymbol = "person.2.fill"
    case "openrouter":
        bundleIDs = []
        appNames = ["OpenRouter"]
        fallbackSymbol = "point.3.connected.trianglepath.dotted"
    case "volcengine", "volcengine-color":
        bundleIDs = []
        appNames = ["Volcengine"]
        fallbackSymbol = "cloud.fill"
    case "agentrouter", "wenxin-color":
        bundleIDs = []
        appNames = ["AgentRouter"]
        fallbackSymbol = "arrow.triangle.branch"
    case "teamorouter":
        bundleIDs = []
        appNames = ["TeamoRouter"]
        fallbackSymbol = "circle.grid.3x3.fill"
    default:
        bundleIDs = []
        appNames = []
        fallbackSymbol = "app.fill"
    }
    for bundleID in bundleIDs {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }
    for name in appNames {
        let path = "/Applications/\(name).app"
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
    }
    return NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: clientID)
}

@MainActor
func accountIcon(_ iconID: String?, fallbackClientID: String) -> NSImage? {
    let magpieIconNames = [
        "codex-color", "zcode", "workbuddy-color", "geminicli-color",
        "volcengine-color", "wenxin-color", "openrouter"
    ]
    let fallbackIconID: String?
    switch fallbackClientID {
    case "codex": fallbackIconID = "codex-color"
    case "zcode": fallbackIconID = "zcode"
    case "workbuddy": fallbackIconID = "workbuddy-color"
    case "gemini": fallbackIconID = "geminicli-color"
    case "volcengine": fallbackIconID = "volcengine-color"
    case "agentrouter": fallbackIconID = "wenxin-color"
    case "openrouter": fallbackIconID = "openrouter"
    default: fallbackIconID = nil
    }
    let fallbackIcon = fallbackIconID == iconID ? nil : fallbackIconID

    if let iconID, magpieIconNames.contains(iconID) {
        let ext = iconID == "zcode" ? "png" : "svg"
        if let url = Bundle.module.url(forResource: iconID, withExtension: ext, subdirectory: "MagpieIcons"),
           let image = NSImage(contentsOf: url) {
            return image
        }
    }

    guard let iconID, !iconID.isEmpty else {
        if let fallbackIcon {
            return accountIcon(fallbackIcon, fallbackClientID: fallbackClientID)
        }
        return platformIcon(fallbackClientID)
    }
    if iconID.hasPrefix("file:") {
        let filename = String(iconID.dropFirst("file:".count))
        if !filename.isEmpty, URL(fileURLWithPath: filename).lastPathComponent == filename {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/magpie/icons", isDirectory: true)
                .appendingPathComponent(filename)
            if let image = NSImage(contentsOfFile: path.path) { return image }
        }
        if let fallbackIcon {
            return accountIcon(fallbackIcon, fallbackClientID: fallbackClientID)
        }
        return platformIcon(fallbackClientID)
    }
    if let fallbackIcon {
        return accountIcon(fallbackIcon, fallbackClientID: fallbackClientID)
    }
    return platformIcon(iconID)
}

func usageMoney(_ value: Double, unit: String? = nil) -> String {
    let prefix: String
    switch unit?.uppercased() {
    case "CNY", "RMB": prefix = "¥"
    case nil, "", "USD": prefix = "$"
    default: prefix = (unit ?? "") + " "
    }
    let magnitude = abs(value)
    let number = magnitude >= 100 ? String(format: "%.0f", magnitude) : String(format: "%.2f", magnitude)
    return (value < 0 ? "-" : "") + prefix + number
}

private func accountPrimaryText(_ usage: UsageAccount) -> String {
    if let balance = usage.remainingBalance { return "余" + usageMoney(balance, unit: usage.balanceUnit) }
    if let remaining = usage.remainingPercent { return String(format: "余%.0f%%", remaining) }
    if usage.todayCost > 0 { return "今" + usageMoney(usage.todayCost, unit: usage.balanceUnit) }
    if usage.todayRequests > 0 { return "\(usage.todayRequests)次" }
    return "未采样"
}

@MainActor
private func usageText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(
        in: rect,
        withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    )
}

@MainActor
private final class PlatformIconView: NSView {
    let clientID: String

    init(clientID: String) {
        self.clientID = clientID
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 30))
        toolTip = clientID
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSRect(x: 1, y: 2, width: 26, height: 26)
        NSColor(white: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
        platformIcon(clientID)?.draw(
            in: tile.insetBy(dx: 2, dy: 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}

@MainActor
private final class AccountCardButton: NSButton {
    var usage: UsageAccount? { didSet { needsDisplay = true } }
    var isBeingDragged = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let usage else { return }
        if usage.clientID == "magpie" {
            drawMagpieStrip(usage)
            return
        }
        let fill = cell?.isHighlighted == true ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.16, alpha: 1)
        fill.setFill()
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1.5), xRadius: 6, yRadius: 6)
        card.fill()
        if isBeingDragged || usage.isCurrent {
            let stroke = isBeingDragged ? NSColor.systemTeal : NSColor.systemGreen
            stroke.withAlphaComponent(0.88).setStroke()
            card.lineWidth = 1.2
            card.stroke()
        }

        accountIcon(usage.iconID, fallbackClientID: usage.clientID)?.draw(
            in: NSRect(x: 6, y: 2.5, width: 11, height: 11),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        usageText(
            usage.accountLabel,
            in: NSRect(x: 19, y: 1.2, width: bounds.width - 26, height: 13),
            font: .systemFont(ofSize: 8.8, weight: .semibold),
            color: NSColor(white: 0.94, alpha: 1)
        )
        usageText(
            accountPrimaryText(usage),
            in: NSRect(x: 7, y: 15.2, width: 62, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 8.7, weight: .bold),
            color: usage.remainingPercent == nil ? .white : .systemGreen
        )
        let secondary: String
        if let remaining = usage.secondaryRemainingPercent {
            secondary = String(format: "7d %.0f%%", remaining)
        } else if usage.remainingBalance != nil {
            secondary = usage.balanceUnit ?? ""
        } else if usage.isOfficial {
            secondary = "额度"
        } else if usage.monthCost > 0 {
            secondary = "月" + usageMoney(usage.monthCost, unit: usage.balanceUnit)
        } else {
            secondary = usage.providerLabel
        }
        usageText(
            secondary,
            in: NSRect(x: 70, y: 15.2, width: bounds.width - 77, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 7.5, weight: .medium),
            color: NSColor(white: 0.68, alpha: 1),
            alignment: .right
        )
        if usage.isCurrent {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 7, y: bounds.maxY - 7, width: 4, height: 4)).fill()
        }
    }

    private func drawMagpieStrip(_ usage: UsageAccount) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(white: isBeingDragged ? 0.24 : 0.15, alpha: 1).setFill()
        card.fill()
        if isBeingDragged || usage.isCurrent {
            let stroke = isBeingDragged ? NSColor.systemTeal : NSColor.systemGreen
            stroke.withAlphaComponent(0.88).setStroke()
            card.lineWidth = 1.2
            card.stroke()
        }

        accountIcon(usage.iconID, fallbackClientID: usage.clientID)?.draw(
            in: NSRect(x: 3, y: 4, width: 22, height: 22),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        if let remaining = usage.remainingPercent {
            drawMagpieQuotaRow(
                label: magpieQuotaLabel(usage.primaryWindowLabel),
                remaining: remaining,
                resetAt: usage.primaryResetAt,
                y: 15
            )
        } else {
            drawMagpieBalanceRow(usage, y: 15)
        }

        if let remaining = usage.secondaryRemainingPercent {
            drawMagpieQuotaRow(
                label: magpieQuotaLabel(usage.secondaryWindowLabel),
                remaining: remaining,
                resetAt: usage.secondaryResetAt,
                y: 1
            )
        } else if usage.remainingBalance != nil, usage.remainingPercent != nil {
            usageText(
                usageMoney(usage.remainingBalance ?? 0, unit: usage.balanceUnit),
                in: NSRect(x: 28, y: 1, width: bounds.width - 31, height: 12),
                font: .monospacedDigitSystemFont(ofSize: 7.4, weight: .medium),
                color: NSColor(white: 0.76, alpha: 1)
            )
        } else if usage.remainingPercent != nil {
            usageText(
                usage.accountLabel,
                in: NSRect(x: 28, y: 1, width: bounds.width - 31, height: 12),
                font: .systemFont(ofSize: 6.8, weight: .medium),
                color: NSColor(white: 0.72, alpha: 1)
            )
        } else {
            usageText(
                usage.balanceUnit ?? usage.providerLabel,
                in: NSRect(x: 28, y: 1, width: bounds.width - 31, height: 12),
                font: .systemFont(ofSize: 7, weight: .medium),
                color: NSColor(white: 0.72, alpha: 1)
            )
        }
    }

    private func drawMagpieBalanceRow(_ usage: UsageAccount, y: CGFloat) {
        usageText(
            usage.accountLabel,
            in: NSRect(x: 28, y: y, width: 57, height: 12),
            font: .systemFont(ofSize: 7.2, weight: .semibold),
            color: NSColor(white: 0.86, alpha: 1)
        )
        if let balance = usage.remainingBalance {
            usageText(
                usageMoney(balance, unit: usage.balanceUnit),
                in: NSRect(x: 84, y: y, width: bounds.width - 89, height: 12),
                font: .monospacedDigitSystemFont(ofSize: 7.4, weight: .bold),
                color: balance < 0 ? .systemOrange : .white,
                alignment: .right
            )
        } else {
            usageText(
                usage.providerLabel,
                in: NSRect(x: 86, y: y, width: bounds.width - 91, height: 12),
                font: .systemFont(ofSize: 7, weight: .medium),
                color: NSColor(white: 0.72, alpha: 1),
                alignment: .right
            )
        }
    }

    private func drawMagpieQuotaRow(label: String, remaining: Double, resetAt: Double?, y: CGFloat) {
        usageText(
            label,
            in: NSRect(x: 28, y: y, width: 15, height: 12),
            font: .systemFont(ofSize: 7, weight: .semibold),
            color: NSColor(white: 0.82, alpha: 1)
        )
        let track = NSRect(x: 44, y: y + 3.5, width: 37, height: 5)
        let segmentGap: CGFloat = 1
        let segmentWidth = (track.width - segmentGap * 4) / 5
        let filledSegments = Int(ceil(min(100, max(0, remaining)) / 20))
        let fillColor: NSColor = remaining <= 20 ? .systemRed : (remaining <= 45 ? .systemYellow : .systemGreen)
        for index in 0..<5 {
            let segment = NSRect(
                x: track.minX + CGFloat(index) * (segmentWidth + segmentGap),
                y: track.minY,
                width: segmentWidth,
                height: track.height
            )
            (index < filledSegments ? fillColor : NSColor(white: 0.32, alpha: 1)).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 2.5, yRadius: 2.5).fill()
        }
        usageText(
            String(format: "%.0f%%", remaining),
            in: NSRect(x: 82, y: y, width: 22, height: 12),
            font: .monospacedDigitSystemFont(ofSize: 7.1, weight: .bold),
            color: remaining <= 20 ? .systemRed : .white,
            alignment: .right
        )
        let reset = magpieResetText(resetAt, label: label)
        usageText(
            reset,
            in: NSRect(x: 105, y: y, width: bounds.width - 108, height: 12),
            font: .monospacedDigitSystemFont(ofSize: 6.2, weight: .medium),
            color: NSColor(white: 0.72, alpha: 1),
            alignment: .right
        )
    }

    private func magpieResetText(_ timestamp: Double?, label: String) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        let resetDate = Date(timeIntervalSince1970: timestamp)
        let seconds = max(0, Int(timestamp - Date().timeIntervalSince1970))
        if label == "5h" {
            return Self.quotaClockFormatter.string(from: resetDate)
        }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        return days > 0 ? "\(days)d\(hours)h" : "\(max(1, hours))h"
    }

    private func magpieQuotaLabel(_ label: String?) -> String {
        switch label?.lowercased() {
        case "5 hours", "5h": return "5h"
        case "7 days", "7d": return "7d"
        case "30 days", "30d": return "30d"
        default: return "额度"
        }
    }

    private static let quotaClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

@MainActor
final class AIActivityMarkView: NSView {
    var activeCount = 0 {
        didSet {
            refreshState()
        }
    }
    var taskState = "idle" {
        didSet {
            refreshState()
        }
    }
    private var phase: CGFloat = 0
    private var animationTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 4, dy: 3)
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let radius = min(circle.width, circle.height) / 2
        guard activeCount > 0 else {
            if taskState == "completed" {
                drawStatusBadge("✓", color: .systemBlue)
            } else if taskState == "aborted" {
                drawStatusBadge("×", color: .systemRed)
            }
            return
        }
        NSColor(white: 1, alpha: 0.26).setStroke()
        let track = NSBezierPath(ovalIn: circle)
        track.lineWidth = 1.2
        track.stroke()

        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: phase,
            endAngle: phase + 230,
            clockwise: false
        )
        ring.lineWidth = 1.6
        ring.lineCapStyle = .round
        NSColor.systemTeal.setStroke()
        ring.stroke()

        let count = activeCount > 9 ? "9+" : "\(activeCount)"
        drawStatusBadge(count, color: .systemTeal)
    }

    private func drawStatusBadge(_ text: String, color: NSColor) {
        let badge = NSRect(x: bounds.maxX - 10, y: 2, width: 9, height: 9)
        color.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: text.count > 1 ? 4.1 : 5.2, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(
                x: badge.midX - textSize.width / 2,
                y: badge.midY - textSize.height / 2,
                width: textSize.width + 1,
                height: textSize.height + 1
            ),
            withAttributes: attributes
        )
    }

    private func refreshState() {
        let active = activeCount > 0
        isHidden = !active && taskState == "idle"
        setAccessibilityLabel(active ? "\(activeCount) 个 AI coding 任务运行中" : "AI coding \(taskState)")
        updateAnimation()
        needsDisplay = true
    }

    private func updateAnimation() {
        guard window != nil, activeCount > 0, !isHidden else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phase = (self.phase + 30).truncatingRemainder(dividingBy: 360)
                self.needsDisplay = true
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor
final class QuotaInteractionView: NSView {
    var onTap: ((NSPoint) -> Void)?
    var onDragStart: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint, NSPoint, NSPoint) -> Void)?
    var onDragEnd: ((NSPoint, NSPoint) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var previousPoint: NSPoint?
    private var didDrag = false
    private var trackedTouch: NSTouch?
    var isInteracting: Bool { startPoint != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = .direct
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard trackedTouch == nil else { return }
        beginInteraction(at: convert(event.locationInWindow, from: nil))
    }

    func beginInteraction(at point: NSPoint) {
        startPoint = point
        previousPoint = point
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard trackedTouch == nil else { return }
        moveInteraction(to: convert(event.locationInWindow, from: nil))
    }

    func moveInteraction(to point: NSPoint) {
        guard let startPoint else { return }
        if !didDrag, hypot(point.x - startPoint.x, point.y - startPoint.y) >= 6 {
            didDrag = true
            onDragStart?(startPoint)
        }
        if didDrag, let previousPoint {
            onDrag?(startPoint, previousPoint, point)
        }
        previousPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        guard trackedTouch == nil else { return }
        endInteraction(at: convert(event.locationInWindow, from: nil))
    }

    func endInteraction(at point: NSPoint) {
        if let startPoint {
            if didDrag {
                onDragEnd?(startPoint, point)
            } else {
                onTap?(point)
            }
        }
        startPoint = nil
        previousPoint = nil
        didDrag = false
    }

    override func touchesBegan(with event: NSEvent) {
        guard !isInteracting,
              let touch = event.touches(matching: .began, in: self).first(where: { $0.type == .direct }) else { return }
        trackedTouch = touch
        beginInteraction(at: touch.location(in: self))
    }

    override func touchesMoved(with event: NSEvent) {
        guard let touch = matchingTouch(in: event, phase: .moved) else { return }
        moveInteraction(to: touch.location(in: self))
    }

    override func touchesEnded(with event: NSEvent) {
        guard let touch = matchingTouch(in: event, phase: .ended) else { return }
        endInteraction(at: touch.location(in: self))
        trackedTouch = nil
    }

    override func touchesCancelled(with event: NSEvent) {
        guard matchingTouch(in: event, phase: .cancelled) != nil else { return }
        cancelInteraction()
    }

    func cancelInteraction() {
        onCancel?()
        trackedTouch = nil
        startPoint = nil
        previousPoint = nil
        didDrag = false
    }

    private func matchingTouch(in event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let trackedTouch else { return nil }
        return event.touches(matching: phase, in: self).first {
            $0.identity.isEqual(trackedTouch.identity)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        onScroll?(delta)
    }
}

@MainActor
final class QuotaView: NSView {
    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let interactionView = QuotaInteractionView()
    private var accountKeys: [String] = []
    private enum DragMode {
        case scroll
        case reorder(AccountCardButton)
    }
    private var dragMode: DragMode?
    var onOpenUsage: ((String) -> Void)?

    init(width: CGFloat = 455) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentView
        addSubview(scrollView)
        interactionView.frame = bounds
        interactionView.autoresizingMask = [.width, .height]
        interactionView.toolTip = "点按打开账户详情；拖动供应商图标调整顺序，拖动卡片区域横向浏览"
        interactionView.onTap = { [weak self] point in self?.openAccount(at: point) }
        interactionView.onDragStart = { [weak self] point in self?.beginDrag(at: point) }
        interactionView.onDrag = { [weak self] start, previous, current in
            self?.continueDrag(start: start, previous: previous, current: current)
        }
        interactionView.onDragEnd = { [weak self] start, end in self?.endDrag(start: start, end: end) }
        interactionView.onScroll = { [weak self] delta in self?.scrollHorizontally(by: delta) }
        interactionView.onCancel = { [weak self] in
            if case .reorder(let card)? = self?.dragMode { card.isBeingDragged = false }
            self?.dragMode = nil
        }
        addSubview(interactionView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var viewport = bounds
        if let window, window.frame.width >= 200 {
            let originX = convert(bounds.origin, to: nil).x
            viewport.size.width = max(0, min(bounds.width, window.frame.width - originX - 8))
        }
        scrollView.frame = viewport
        interactionView.frame = viewport
        scrollHorizontally(by: 0)
    }

    func update(
        with limits: RateLimits?,
        platforms: [PlatformUsage]? = nil,
        accounts: [UsageAccount]? = nil
    ) {
        // A refresh must not replace a card while a finger is dragging it.
        guard !interactionView.isInteracting else { return }
        let rawVisible = accounts?.isEmpty == false ? accounts! : legacyAccounts(limits: limits, platforms: platforms ?? [])
        contentView.subviews.forEach { $0.removeFromSuperview() }
        accountKeys = []
        // 用户设置：软件勾选展示与否；供应商默认只展示当前在用的，
        // 其余通过菜单勾选补充（覆盖表），当前使用的账号始终排最前。
        let platformOverrides = UserDefaults.standard.dictionary(forKey: "aiCodingPlatformOverrides.v1") as? [String: Bool] ?? [:]
        let providerOverrides = UserDefaults.standard.dictionary(forKey: "aiCodingProviderOverrides.v1") as? [String: Bool] ?? [:]
        let savedMagpieOrder = UserDefaults.standard.stringArray(forKey: "aiCodingMagpieAccountOrder.v1") ?? []
        var magpieOrderIndex: [String: Int] = [:]
        for (index, key) in savedMagpieOrder.enumerated() where magpieOrderIndex[key] == nil {
            magpieOrderIndex[key] = index
        }
        let hasDefaultByClient = Dictionary(grouping: rawVisible, by: \.clientID)
            .mapValues { $0.contains { $0.showByDefault ?? $0.isCurrent } }
        var candidates = rawVisible.filter { account in
            let platformShown = platformOverrides[account.clientID] ?? hasDefaultByClient[account.clientID] ?? false
            guard platformShown else { return false }
            return providerOverrides[account.key] ?? account.showByDefault ?? account.isCurrent
        }
        let allGrouped = Dictionary(grouping: candidates, by: \.clientID)
        var display: [UsageAccount] = []
        var seenClients: [String] = []
        for usage in candidates where !seenClients.contains(usage.clientID) { seenClients.append(usage.clientID) }
        for clientID in seenClients {
            var group = allGrouped[clientID] ?? []
            if clientID == "magpie", !magpieOrderIndex.isEmpty {
                group = group.enumerated().sorted { left, right in
                    let leftRank = magpieOrderIndex[left.element.key] ?? Int.max
                    let rightRank = magpieOrderIndex[right.element.key] ?? Int.max
                    return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
                }.map(\.element)
            }
            display.append(contentsOf: group)
        }
        candidates = display
        let visible = candidates
        let grouped = Dictionary(grouping: visible, by: \.clientID)
        var clientOrder: [String] = []
        for usage in visible where !clientOrder.contains(usage.clientID) { clientOrder.append(usage.clientID) }

        let itemGap: CGFloat = 3
        let groupGap: CGFloat = 6
        var x: CGFloat = 0
        for clientID in clientOrder {
            guard let accounts = grouped[clientID], !accounts.isEmpty else { continue }
            if clientID != "magpie" {
                let icon = PlatformIconView(clientID: clientID)
                icon.toolTip = accounts[0].clientLabel
                icon.frame.origin = NSPoint(x: x, y: 0)
                contentView.addSubview(icon)
                x += 30
            }
            let cardWidth: CGFloat = clientID == "magpie" ? 132 : 126

            for usage in accounts {
                let button = AccountCardButton(title: "", target: self, action: #selector(openAccount(_:)))
                button.tag = accountKeys.count
                accountKeys.append(usage.key)
                button.isBordered = false
                button.usage = usage
                button.toolTip = "\(usage.clientLabel) · \(usage.accountLabel) · \(usage.providerLabel)"
                button.frame = NSRect(x: x, y: 0, width: cardWidth, height: 30)
                contentView.addSubview(button)
                x += cardWidth + itemGap
            }
            x += groupGap - itemGap
        }
        contentView.frame = NSRect(x: 0, y: 0, width: max(bounds.width, max(0, x - groupGap)), height: 30)
        let maxOffset = max(0, contentView.frame.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(scrollView.contentView.bounds.origin.x, maxOffset), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func accountButton(at point: NSPoint) -> AccountCardButton? {
        let documentPoint = NSPoint(
            x: point.x + scrollView.contentView.bounds.origin.x,
            y: point.y + scrollView.contentView.bounds.origin.y
        )
        return contentView.subviews
            .compactMap { $0 as? AccountCardButton }
            .first { $0.frame.contains(documentPoint) }
    }

    private func openAccount(at point: NSPoint) {
        guard let button = accountButton(at: point), let key = button.usage?.key else { return }
        onOpenUsage?(key)
    }

    private func beginDrag(at point: NSPoint) {
        guard let button = accountButton(at: point), let usage = button.usage else {
            dragMode = .scroll
            return
        }
        let documentX = point.x + scrollView.contentView.bounds.origin.x
        let iconHit = documentX - button.frame.minX <= 27
        if usage.clientID == "magpie", iconHit {
            button.isBeingDragged = true
            dragMode = .reorder(button)
        } else {
            dragMode = .scroll
        }
    }

    private func continueDrag(start: NSPoint, previous: NSPoint, current: NSPoint) {
        if dragMode == nil { beginDrag(at: start) }
        guard case .scroll? = dragMode else { return }
        scrollHorizontally(by: previous.x - current.x)
    }

    private func scrollHorizontally(by delta: CGFloat) {
        let maximumOffset = max(0, contentView.frame.width - scrollView.contentView.bounds.width)
        guard maximumOffset > 0 else { return }
        let offset = min(
            max(0, scrollView.contentView.bounds.origin.x + delta),
            maximumOffset
        )
        scrollView.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func endDrag(start: NSPoint, end: NSPoint) {
        defer { dragMode = nil }
        guard case .reorder(let source)? = dragMode else { return }
        defer { source.isBeingDragged = false }
        guard let target = accountButton(at: end), target !== source else { return }
        reorderMagpieCards(from: source, to: target)
    }

    private func reorderMagpieCards(from source: AccountCardButton, to target: AccountCardButton) {
        var cards = contentView.subviews
            .compactMap { $0 as? AccountCardButton }
            .filter { $0.usage?.clientID == "magpie" }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let sourceIndex = cards.firstIndex(where: { $0 === source }),
              let targetIndex = cards.firstIndex(where: { $0 === target }) else { return }

        let slots = cards.map(\.tag)
        let positions = cards.map(\.frame.minX)
        let moving = cards.remove(at: sourceIndex)
        cards.insert(moving, at: targetIndex)
        for (index, button) in cards.enumerated() {
            var frame = button.frame
            frame.origin.x = positions[index]
            button.frame = frame
            let slot = slots[index]
            button.tag = slot
            if accountKeys.indices.contains(slot), let key = button.usage?.key {
                accountKeys[slot] = key
            }
        }
        UserDefaults.standard.set(cards.compactMap { $0.usage?.key }, forKey: "aiCodingMagpieAccountOrder.v1")
    }

    @objc private func openAccount(_ sender: NSButton) {
        guard accountKeys.indices.contains(sender.tag) else { return }
        onOpenUsage?(accountKeys[sender.tag])
    }

    private func legacyAccounts(limits: RateLimits?, platforms: [PlatformUsage]) -> [UsageAccount] {
        let converted = platforms.map { usage in
            UsageAccount(
                key: "legacy:\(usage.id):\(usage.provider)", clientID: usage.id, clientLabel: usage.label,
                accountLabel: usage.provider, providerLabel: usage.provider,
                isCurrent: true, showByDefault: nil, iconID: nil, isOfficial: false,
                metricKind: usage.remainingBalance == nil ? "cost" : "balance",
                remainingBalance: usage.remainingBalance, balanceUnit: usage.balanceUnit,
                remainingPercent: nil, secondaryRemainingPercent: nil,
                todayCost: usage.todayCost, monthCost: usage.monthCost,
                todayRequests: usage.todayRequests, todayTokens: usage.todayTokens,
                cacheHitPercent: nil, successPercent: nil, modelLabel: "", metricsScope: usage.label,
                chartTitle: "7日费用", chartUnit: usage.balanceUnit ?? "USD", latestAt: usage.latestAt, history: []
            )
        }
        if !converted.isEmpty { return converted }
        let windows = limits?.ordered ?? []
        return [UsageAccount(
            key: "legacy:codex:current", clientID: "codex", clientLabel: "Codex",
            accountLabel: "当前账户", providerLabel: "OpenAI Official",
            isCurrent: true, showByDefault: nil, iconID: nil, isOfficial: true,
            metricKind: "subscription", remainingBalance: nil, balanceUnit: nil,
            remainingPercent: windows.first?.remainingPercent,
            secondaryRemainingPercent: windows.dropFirst().first?.remainingPercent,
            todayCost: 0, monthCost: 0, todayRequests: 0, todayTokens: 0,
            cacheHitPercent: nil, successPercent: nil, modelLabel: "", metricsScope: "Codex 会话",
            chartTitle: "额度趋势", chartUnit: "percent", latestAt: Date().timeIntervalSince1970, history: []
        )]
    }
}

@MainActor
final class UsageDetailStripView: NSView {
    var usage: UsageAccount? { didSet { needsDisplay = true } }

    init(width: CGFloat = 683) { super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let usage else { return }
        drawHeader(usage)
        drawChart(usage)
        drawStats(usage)
    }

    private func drawHeader(_ usage: UsageAccount) {
        let rect = NSRect(x: 0, y: 1, width: 164, height: 28)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let iconRect = NSRect(x: 3, y: 3, width: 24, height: 24)
        accountIcon(usage.iconID, fallbackClientID: usage.clientID)?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        usageText(usage.accountLabel, in: NSRect(x: 31, y: 15.2, width: 129, height: 13), font: .systemFont(ofSize: 9, weight: .semibold), color: .white)
        usageText(usage.providerLabel, in: NSRect(x: 31, y: 1.2, width: 79, height: 13), font: .systemFont(ofSize: 7.5, weight: .medium), color: NSColor(white: 0.66, alpha: 1))
        let metric = usage.secondaryRemainingPercent.map { String(format: "%.0f/%.0f%%", usage.remainingPercent ?? 0, $0) } ?? accountPrimaryText(usage)
        usageText(metric, in: NSRect(x: 103, y: 0.8, width: 57, height: 14), font: .monospacedDigitSystemFont(ofSize: 8.2, weight: .bold), color: .systemGreen, alignment: .right)
    }

    private func drawChart(_ usage: UsageAccount) {
        let chart = NSRect(x: 169, y: 1, width: 330, height: 28)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: chart, xRadius: 6, yRadius: 6).fill()
        let plot = chart.insetBy(dx: 7, dy: 4)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let mid = NSBezierPath()
        mid.move(to: NSPoint(x: plot.minX, y: plot.midY))
        mid.line(to: NSPoint(x: plot.maxX, y: plot.midY))
        mid.lineWidth = 0.7
        mid.stroke()

        let points = usage.history.sorted { $0.timestamp < $1.timestamp }
        let primary = points.map(\.primary)
        let secondary = points.compactMap(\.secondary)
        let allValues = primary + secondary
        guard points.count >= 2, let minimum = allValues.min(), let maximum = allValues.max(), maximum - minimum > 0.000_001 else {
            if let value = primary.last {
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: plot.midX - 1.8, y: plot.midY - 1.8, width: 3.6, height: 3.6)).fill()
                usageText("\(usage.chartTitle) · 等待变化（\(formatChartValue(value, unit: usage.chartUnit))）", in: NSRect(x: chart.minX + 8, y: 8, width: chart.width - 16, height: 14), font: .systemFont(ofSize: 8, weight: .medium), color: NSColor(white: 0.58, alpha: 1), alignment: .center)
            } else {
                usageText("\(usage.chartTitle) · 等待采样", in: NSRect(x: chart.minX + 8, y: 8, width: chart.width - 16, height: 14), font: .systemFont(ofSize: 8, weight: .medium), color: NSColor(white: 0.52, alpha: 1), alignment: .center)
            }
            return
        }
        let padding = max((maximum - minimum) * 0.12, 0.000_001)
        drawSeries(primary, in: plot, minimum: minimum - padding, maximum: maximum + padding, color: .systemGreen)
        if secondary.count == points.count {
            drawSeries(secondary, in: plot, minimum: minimum - padding, maximum: maximum + padding, color: .systemBlue)
        }
    }

    private func drawSeries(_ values: [Double], in rect: NSRect, minimum: Double, maximum: Double, color: NSColor) {
        guard values.count >= 2, maximum > minimum else { return }
        let path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.minY + rect.height * CGFloat((value - minimum) / (maximum - minimum))
            if index == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        color.setStroke()
        path.lineWidth = 1.35
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func formatChartValue(_ value: Double, unit: String) -> String {
        switch unit {
        case "percent": return String(format: "%.0f%%", value)
        case "tokens": return value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) : String(format: "%.0f", value)
        default: return usageMoney(value, unit: unit)
        }
    }

    private func drawStats(_ usage: UsageAccount) {
        let rect = NSRect(x: 504, y: 1, width: bounds.maxX - 504, height: 28)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let cache = usage.cacheHitPercent.map { String(format: "缓存命中 %.0f%%", $0) } ?? "缓存命中 —"
        let success = usage.successPercent.map { String(format: " · 成功 %.0f%%", $0) } ?? ""
        usageText(cache + success, in: NSRect(x: rect.minX + 7, y: 15, width: rect.width - 14, height: 12), font: .monospacedDigitSystemFont(ofSize: 8.2, weight: .semibold), color: .white)
        let model = usage.modelLabel.isEmpty ? usage.metricsScope : usage.modelLabel
        let activity = usage.todayRequests > 0 ? " · 今\(usage.todayRequests)次" : ""
        usageText(model + activity, in: NSRect(x: rect.minX + 7, y: 1.5, width: rect.width - 14, height: 12), font: .systemFont(ofSize: 7.5, weight: .medium), color: NSColor(white: 0.66, alpha: 1))
    }
}
