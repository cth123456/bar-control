import AppKit

struct MenuSummaryBadge: Equatable {
    enum Tone { case blue, green, orange, purple, secondary }
    let title: String
    let value: String
    let symbol: String
    var tone: Tone = .blue
    var progress: Double? = nil
    var iconID: String? = nil
    var clientID: String? = nil
    var action: MenuSummaryAction? = nil

    var isSupplier: Bool { clientID != nil }
}

enum MenuSummaryAction: Equatable {
    case openUsage(String)
    case openAIDetails
    case openClipboard
    case toggleSidecar
    case showSystemDetails
    case openSettings
    case openCustomizer
    case openServiceLogs
    case toggleKeyboardLock
    // 独立窗口入口（点模块标题直接打开详情窗口）
    case openSidecarWindow
    case openClipboardWindow
}

/// 收起状态的一行式状态标签。高度固定，不随文字换行。
@MainActor
final class MenuSummaryBadgeView: NSView {
    static let height: CGFloat = 24
    let badge: MenuSummaryBadge
    let fullText: String
    let preferredWidth: CGFloat
    private let icon: NSImage?
    var onPress: (() -> Void)?

    init(_ badge: MenuSummaryBadge) {
        self.badge = badge
        if let clientID = badge.clientID {
            icon = accountIcon(badge.iconID, fallbackClientID: clientID)
        } else {
            icon = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)
        }
        let value = badge.value
            .replacingOccurrences(of: "● ", with: "")
            .replacingOccurrences(of: " 运行", with: "")
            .replacingOccurrences(of: "跟随系统", with: "跟系统")
            .replacingOccurrences(of: "进行中", with: "记录中")
            .replacingOccurrences(of: "credit", with: "cr")
            .replacingOccurrences(of: "余额未读取", with: "余额未知")
        if badge.isSupplier {
            let name = badge.title
                .replacingOccurrences(of: " Plus", with: "+")
                .replacingOccurrences(of: " Free", with: "")
            let balance: String
            if badge.value.hasPrefix("credits "), let amount = Double(badge.value.dropFirst(8)) {
                balance = amount >= 1_000 ? String(format: "%.1fK", amount / 1_000) : String(format: "%.0f", amount)
            } else {
                balance = value.replacingOccurrences(of: "余 ", with: "")
            }
            fullText = "\(name) \(balance)"
        } else {
            fullText = "\(badge.title) \(value)".trimmingCharacters(in: .whitespaces)
        }
        let font = Self.font
        let measured = ceil((fullText as NSString).size(withAttributes: [.font: font]).width)
        preferredWidth = min(180, measured + (badge.isSupplier ? 28 : 28))
        super.init(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(badge.action == nil ? .staticText : .button)
        setAccessibilityLabel("\(badge.title)，\(badge.value)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func resetCursorRects() {
        guard onPress != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func performPress() {
        onPress?()
    }

    /// 徽章本身是可点区域；支持辅助功能/AX 按下，与鼠标点击走同一条路径。
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    private var accent: NSColor {
        let base: NSColor = switch badge.tone {
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .purple: .systemPurple
        case .secondary: .secondaryLabelColor
        }
        return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? (base.blended(withFraction: 0.28, of: .black) ?? base)
            : base
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 11, yRadius: 11)
        accent.withAlphaComponent(0.09).setFill()
        path.fill()
        let symbol = NSRect(x: 7, y: 6, width: 12, height: 12)
        if let icon {
            if badge.isSupplier {
                icon.draw(in: symbol, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            } else {
                let tinted = icon.withSymbolConfiguration(.init(paletteColors: [accent])) ?? icon
                tinted.draw(in: symbol, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
            }
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textColor: NSColor = badge.tone == .secondary ? .secondaryLabelColor : .labelColor
        (fullText as NSString).draw(
            in: NSRect(x: 23, y: 5, width: max(0, bounds.width - 25), height: 15),
            withAttributes: [
                .font: Self.font,
                .foregroundColor: textColor,
                .paragraphStyle: style
            ]
        )
        if let progress = badge.progress {
            let track = NSRect(x: 7, y: bounds.height - 3, width: bounds.width - 14, height: 1.5)
            accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            let fill = NSRect(x: track.minX, y: track.minY,
                              width: track.width * min(1, max(0, progress)), height: 1.5)
            accent.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
        }
    }
}

@MainActor
final class MenuSummaryOverflowView: NSView {
    private let count: Int
    var onPress: (() -> Void)?
    init(count: Int) {
        self.count = count
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: MenuSummaryBadgeView.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("还有 \(count) 项，展开查看")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 11, yRadius: 11).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("+" + String(count)).draw(
            in: NSRect(x: 0, y: 4.5, width: bounds.width, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        )
    }
}
