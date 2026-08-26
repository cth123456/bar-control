import AppKit

@MainActor
private func platformIcon(_ clientID: String) -> NSImage? {
    let bundleIDs: [String]
    let appNames: [String]
    let fallbackSymbol: String
    switch clientID {
    case "codex":
        bundleIDs = ["com.openai.codex", "com.openai.chat"]
        appNames = ["ChatGPT", "Codex"]
        fallbackSymbol = "curlybraces.square.fill"
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

private func usageMoney(_ value: Double, unit: String? = nil) -> String {
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

    override func draw(_ dirtyRect: NSRect) {
        guard let usage else { return }
        let fill = cell?.isHighlighted == true ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.16, alpha: 1)
        fill.setFill()
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1.5), xRadius: 6, yRadius: 6)
        card.fill()
        if usage.isCurrent {
            NSColor.systemGreen.withAlphaComponent(0.88).setStroke()
            card.lineWidth = 1.2
            card.stroke()
        }

        usageText(
            usage.accountLabel,
            in: NSRect(x: 7, y: 1.2, width: bounds.width - 14, height: 13),
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
}

@MainActor
final class QuotaView: NSView {
    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private var accountKeys: [String] = []
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        with limits: RateLimits?,
        platforms: [PlatformUsage]? = nil,
        accounts: [UsageAccount]? = nil
    ) {
        let visible = accounts?.isEmpty == false ? accounts! : legacyAccounts(limits: limits, platforms: platforms ?? [])
        contentView.subviews.forEach { $0.removeFromSuperview() }
        accountKeys = []
        let grouped = Dictionary(grouping: visible, by: \.clientID)
        var clientOrder: [String] = []
        for usage in visible where !clientOrder.contains(usage.clientID) { clientOrder.append(usage.clientID) }

        let cardWidth: CGFloat = 126
        let itemGap: CGFloat = 3
        let groupGap: CGFloat = 6
        var x: CGFloat = 0
        for clientID in clientOrder {
            guard let accounts = grouped[clientID], !accounts.isEmpty else { continue }
            let icon = PlatformIconView(clientID: clientID)
            icon.toolTip = accounts[0].clientLabel
            icon.frame.origin = NSPoint(x: x, y: 0)
            contentView.addSubview(icon)
            x += 30

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
    }

    @objc private func openAccount(_ sender: NSButton) {
        guard accountKeys.indices.contains(sender.tag) else { return }
        onOpenUsage?(accountKeys[sender.tag])
    }

    private func legacyAccounts(limits: RateLimits?, platforms: [PlatformUsage]) -> [UsageAccount] {
        let converted = platforms.map { usage in
            UsageAccount(
                key: "legacy:\(usage.id):\(usage.provider)", clientID: usage.id, clientLabel: usage.label,
                accountLabel: usage.provider, providerLabel: usage.provider, isCurrent: true, isOfficial: false,
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
            accountLabel: "当前账户", providerLabel: "OpenAI Official", isCurrent: true, isOfficial: true,
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
        platformIcon(usage.clientID)?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
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
