import AppKit

@MainActor
final class FixedTouchBarContainer: NSView {
    private let fixedWidth: CGFloat

    init(width: CGFloat) {
        fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: 30)
    }
}

@MainActor
final class QuotaView: NSView {
    private var windows: [LimitWindow] = []
    private var platforms: [PlatformUsage] = []
    var onOpenUsage: (() -> Void)?

    init(width: CGFloat = 225) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with limits: RateLimits?, platforms: [PlatformUsage]? = nil) {
        windows = limits?.ordered ?? []
        self.platforms = platforms ?? []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        roundedFill(NSRect(x: 0, y: 0.5, width: bounds.width, height: 29), radius: 7, color: NSColor(white: 0.15, alpha: 1))
        if let usage = platforms.first(where: { $0.todayRequests > 0 || $0.todayCost > 0 || $0.remainingBalance != nil }) {
            drawAPIUsage(usage)
            return
        }
        drawCodexIcon()

        let byLabel = Dictionary(uniqueKeysWithValues: windows.map { ($0.shortLabel, $0) })
        drawRow(byLabel["5h"], fallbackLabel: "5h", top: true)
        drawRow(byLabel["7d"], fallbackLabel: "7d", top: false)
    }

    override func mouseUp(with event: NSEvent) {
        onOpenUsage?()
    }

    private func drawAPIUsage(_ usage: PlatformUsage) {
        let badge = NSRect(x: 3, y: 2, width: 26, height: 26)
        roundedFill(badge, radius: 6, color: platformColor(usage.id))
        drawText(
            platformCode(usage.id),
            in: NSRect(x: 3, y: 8, width: 26, height: 14),
            font: .systemFont(ofSize: 9, weight: .bold),
            color: .white,
            alignment: .center
        )

        let title = usage.provider.isEmpty ? usage.label : "\(usage.label) · \(usage.provider)"
        drawText(
            title,
            in: NSRect(x: 33, y: 15.5, width: 126, height: 13),
            font: .systemFont(ofSize: 9.5, weight: .semibold),
            color: NSColor(white: 0.9, alpha: 1)
        )
        let primaryValue = usage.remainingBalance.map { "余" + money($0, unit: usage.balanceUnit) }
            ?? money(usage.todayCost, unit: usage.balanceUnit)
        drawText(
            primaryValue,
            in: NSRect(x: 158, y: 14.5, width: 63, height: 15),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            color: .white,
            alignment: .right
        )

        let useMonthly = (usage.dailyLimit ?? 0) <= 0 && (usage.monthlyLimit ?? 0) > 0
        let spent = useMonthly ? usage.monthCost : usage.todayCost
        let limit = useMonthly ? usage.monthlyLimit : usage.dailyLimit
        drawText(
            useMonthly ? "月" : "日",
            in: NSRect(x: 33, y: 1.2, width: 16, height: 13),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: NSColor(white: 0.7, alpha: 1)
        )
        let track = NSRect(x: 50, y: 4, width: 69, height: 8)
        roundedFill(track, radius: 4, color: NSColor(white: 0.30, alpha: 1))
        if let limit, limit > 0 {
            let percent = min(100, max(0, spent / limit * 100))
            let fillWidth = max(track.height, track.width * CGFloat(percent / 100))
            roundedFill(
                NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height),
                radius: 4,
                color: barColor(percent)
            )
            drawText(
                String(format: "%.0f%%", percent),
                in: NSRect(x: 122, y: 0.5, width: 36, height: 14),
                font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
                color: percent >= 50 ? barColor(percent) : .white,
                alignment: .right
            )
        } else {
            drawText(
                "\(usage.todayRequests)次",
                in: NSRect(x: 122, y: 0.5, width: 36, height: 14),
                font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                color: NSColor(white: 0.76, alpha: 1),
                alignment: .right
            )
        }
        let secondaryValue = usage.remainingBalance == nil
            ? "月" + money(usage.monthCost, unit: usage.balanceUnit)
            : "今" + money(usage.todayCost, unit: usage.balanceUnit)
        drawText(
            secondaryValue,
            in: NSRect(x: 160, y: 0.5, width: 61, height: 14),
            font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
            color: NSColor(white: 0.72, alpha: 1),
            alignment: .right
        )
    }

    private func platformCode(_ id: String) -> String {
        switch id {
        case "claude": return "CL"
        case "codex": return "CX"
        case "gemini": return "GM"
        case "grokbuild": return "GK"
        case "opencode": return "OC"
        case "hermes": return "HM"
        default: return String(id.prefix(2)).uppercased()
        }
    }

    private func platformColor(_ id: String) -> NSColor {
        switch id {
        case "claude": return NSColor(calibratedRed: 0.79, green: 0.38, blue: 0.22, alpha: 1)
        case "codex": return NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.82, alpha: 1)
        case "gemini": return NSColor(calibratedRed: 0.23, green: 0.63, blue: 0.55, alpha: 1)
        case "grokbuild": return NSColor(calibratedWhite: 0.35, alpha: 1)
        case "opencode": return NSColor(calibratedRed: 0.42, green: 0.55, blue: 0.20, alpha: 1)
        default: return .systemIndigo
        }
    }

    private func money(_ value: Double, unit: String? = nil) -> String {
        let prefix: String
        switch unit?.uppercased() {
        case "CNY", "RMB": prefix = "¥"
        case nil, "", "USD": prefix = "$"
        default: prefix = (unit ?? "") + " "
        }
        return prefix + (value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value))
    }

    private func drawRow(_ window: LimitWindow?, fallbackLabel: String, top: Bool) {
        let label = window?.shortLabel ?? fallbackLabel
        let yText: CGFloat = top ? 15.2 : 0.2
        let yBar: CGFloat = top ? 18.2 : 3.2
        let track = NSRect(x: 52, y: yBar, width: 67, height: 8.5)

        drawText(
            label,
            in: NSRect(x: 32, y: yText + 0.8, width: 19, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            color: NSColor(white: 0.78, alpha: 1)
        )
        roundedFill(track, radius: 4.25, color: NSColor(white: 0.30, alpha: 1))

        guard let raw = window?.usedPercent else {
            drawText(
                "—",
                in: NSRect(x: 122, y: yText, width: 35, height: 15),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                color: NSColor(white: 0.60, alpha: 1),
                alignment: .right
            )
            return
        }

        let used = min(max(raw, 0), 100)
        if used > 0 {
            let fillWidth = max(track.width * CGFloat(used) / 100, track.height)
            roundedFill(
                NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height),
                radius: 4.25,
                color: barColor(used)
            )
        }
        drawText(
            String(format: "%.0f%%", used),
            in: NSRect(x: 121, y: yText, width: 37, height: 15),
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            color: used >= 50 ? barColor(used) : .white,
            alignment: .right
        )
        drawText(
            resetText(window?.resetsAt, clock: label != "7d"),
            in: NSRect(x: 162, y: yText + 0.8, width: 59, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            color: NSColor(white: 0.88, alpha: 1)
        )
    }

    private func drawCodexIcon() {
        let rect = NSRect(x: 3, y: 2, width: 26, height: 26)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.icon(forFile: appURL.path)
                .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        roundedFill(rect, radius: 6, color: NSColor(white: 0.92, alpha: 1))
        drawText(
            ">_",
            in: NSRect(x: 5, y: 7, width: 22, height: 16),
            font: .monospacedSystemFont(ofSize: 10, weight: .semibold),
            color: NSColor(white: 0.20, alpha: 1),
            alignment: .center
        )
    }

    private func barColor(_ used: Double) -> NSColor {
        if used >= 80 { return .systemRed }
        if used >= 50 { return .systemYellow }
        return .systemGreen
    }

    private func resetText(_ epoch: Double?, clock: Bool) -> String {
        guard let epoch else { return "" }
        let remaining = Int(epoch - Date().timeIntervalSince1970)
        guard remaining > 0 else { return "" }
        if clock {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            return "↻" + formatter.string(from: Date(timeIntervalSince1970: epoch))
        }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "↻\(days)d\(hours)h" }
        if hours > 0 { return "↻\(hours)h\(minutes)m" }
        return "↻\(minutes)m"
    }

    private func roundedFill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func drawText(
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
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

@MainActor
private final class SessionButton: NSButton {
    var displayText = "" { didSet { needsDisplay = true } }
    var displayFontSize: CGFloat = 8 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let fill = (cell?.isHighlighted == true) ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.18, alpha: 1)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        NSColor.systemGreen.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 2, width: 9, height: 9)).fill()
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: 6, y: 4, width: 5, height: 5)).fill()

        let font = NSFont.systemFont(ofSize: displayFontSize, weight: .medium)
        let lines = split(displayText, widths: [max(1, bounds.width - 19), max(1, bounds.width - 10)], font: font)
        if let first = lines.first {
            drawText(first, in: NSRect(x: 15, y: 1, width: bounds.width - 19, height: 12), font: font)
        }
        if lines.count > 1 {
            drawText(lines[1], in: NSRect(x: 6, y: 14, width: bounds.width - 10, height: 12), font: font)
        }
    }

    private func split(_ text: String, widths: [CGFloat], font: NSFont) -> [String] {
        let characters = Array(text)
        var start = 0
        var lines: [String] = []
        for width in widths {
            var end = start
            while end < characters.count {
                let candidate = String(characters[start...end])
                if (candidate as NSString).size(withAttributes: [.font: font]).width > width { break }
                end += 1
            }
            if end == start, start < characters.count { end += 1 }
            lines.append(String(characters[start..<min(end, characters.count)]))
            start = end
        }
        if start < characters.count, !lines.isEmpty {
            lines[lines.count - 1] += "…"
        }
        return lines
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
                .paragraphStyle: paragraph
            ]
        )
    }
}

@MainActor
final class SessionStripView: NSView {
    private var threadIDs: [String?] = []
    var onOpen: ((String) -> Void)?

    init(width: CGFloat = 455) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with threads: [ActiveThread]) {
        subviews.forEach { $0.removeFromSuperview() }
        let visible = Array(threads.prefix(5))
        threadIDs = visible.map(\.id)
        guard !visible.isEmpty else { return }

        let gap: CGFloat = 3
        let cardWidth = floor((bounds.width - gap * CGFloat(visible.count - 1)) / CGFloat(visible.count))
        for (index, thread) in visible.enumerated() {
            let button = SessionButton(title: "", target: self, action: #selector(openThread(_:)))
            button.tag = index
            button.isBordered = false
            button.displayText = thread.title
            button.displayFontSize = visible.count <= 2 ? 8.5 : (visible.count <= 4 ? 8 : 7.5)
            button.toolTip = thread.title
            button.frame = NSRect(
                x: CGFloat(index) * (cardWidth + gap),
                y: 1.5,
                width: cardWidth,
                height: 27
            )
            addSubview(button)
        }
    }

    @objc private func openThread(_ sender: NSButton) {
        guard threadIDs.indices.contains(sender.tag), let id = threadIDs[sender.tag] else { return }
        onOpen?(id)
    }
}
