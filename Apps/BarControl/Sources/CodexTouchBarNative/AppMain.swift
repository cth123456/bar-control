import AppKit
import Darwin
import ImageIO
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

private struct SidecarStatus: Equatable {
    let state: String
    let message: String
    let detail: String

    static let idle = SidecarStatus(state: "idle", message: "随航 ⇄ 通用控制", detail: "")

    /// 连接结果至少完整展示的时长；低于这个时间切回双向默认态会显得像闪一下。
    static let minimumResultDisplay: TimeInterval = 4.5

    static func load(from url: URL) -> SidecarStatus {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .idle }
        let parts = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2, ["idle", "connecting", "success", "failure"].contains(parts[0]) else {
            return .idle
        }
        // success/failure 只代表一次操作的短暂结果。任何残留都不能让模块永久停在
        // 绿色/红色页；超过 20 秒视为过期，回到随航默认的双向状态。
        if ["success", "failure"].contains(parts[0]),
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 20 {
            return .idle
        }
        return SidecarStatus(
            state: parts[0],
            message: parts[1].isEmpty ? "随航 ⇄ 通用控制" : parts[1],
            detail: parts.count >= 3 ? parts[2] : ""
        )
    }
}

/// 模块 item 的固定尺寸透明容器。系统按 item 视图的 intrinsicContentSize 决定 item
/// 尺寸并会改写直接子视图，所以按钮必须包在容器里、容器报告精确的「宽×30」。
@MainActor
/// 侧栏只为当前选中分类绘制底色，不缓存鼠标悬停状态。
final class SidebarItemButton: NSButton {
    var isSelected = false { didSet { updateBackground() } }
    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = 8
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// 侧栏图标/文字只负责显示，点击事件继续落到整行按钮上。
private final class SidebarPassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SidebarPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 侧栏右侧的拖拽把手：拖动改变宽度。
final class SidebarDragHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var currentWidth: CGFloat = 200

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // 拖动期间只移动把手（预览），松手后再重排内容，避免拖拽被重建打断。
        let next = min(320, max(160, currentWidth + event.deltaX))
        guard abs(next - currentWidth) > 0.5 else { return }
        currentWidth = next
        frame.origin.x = next - 2
        onDrag?(next)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }
}

private final class ModuleItemView: NSView {
    private var size: NSSize

    init(width: CGFloat) {
        size = NSSize(width: width, height: 30)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { size }

    override func contentHuggingPriority(for orientation: NSLayoutConstraint.Orientation) -> NSLayoutConstraint.Priority {
        .required
    }

    override func contentCompressionResistancePriority(for orientation: NSLayoutConstraint.Orientation) -> NSLayoutConstraint.Priority {
        .required
    }

    func setWidth(_ width: CGFloat) {
        guard abs(size.width - width) > 0.5 else { return }
        size.width = width
        frame.size.width = width
        invalidateIntrinsicContentSize()
    }
}

private final class PaddedPillButtonCell: NSButtonCell {
    private let leadingOffset: CGFloat = 8

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        offset(super.imageRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        offset(super.titleRect(forBounds: rect))
    }

    private func offset(_ rect: NSRect) -> NSRect {
        guard !title.isEmpty || attributedTitle.length > 0 else { return rect }
        return rect.offsetBy(dx: leadingOffset, dy: 0)
    }
}

/// 预览格子：宽度小于 52pt 时只画图标，避免“功耗”在窄格子里折成两行。
@MainActor
private final class CompactSlotButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard rect.width >= 52 else { return .zero }
        return super.titleRect(forBounds: rect)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard rect.width >= 52 else {
            return NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
        }
        return super.imageRect(forBounds: rect)
    }
}

enum MainComponent: String, CaseIterable {
    case sidecar
    case aiCoding
    case systemMonitor
    case clipboard
    case keyboardLock

    static let defaultsKey = "mainComponentOrder.v1"
    static let visibilityPrefix = "mainComponentVisible.v1."
    static let widthPrefix = "mainComponentWidth.v1."
    static let slotsKey = "mainComponentSlots.v1"
    static let slotCount = 6
    /// 空槽位在实体 Touch Bar 上留白的固定宽度。
    static let emptySlotWidth: CGFloat = 48

    // MARK: - 软件可用性（与具体软件解耦：没装对应软件就不显示该模块）

    /// 模块对应的软件是否可用。未安装对应软件的模块在 Touch Bar/自定义面板中不出现，
    /// 装好软件后重新打开即出现。systemMonitor 为纯系统动画，不依赖任何软件。
    var isSoftwareAvailable: Bool {
        let manager = FileManager.default
        switch self {
        case .systemMonitor:
            return true
        case .clipboard:
            return true
        case .keyboardLock:
            return true
        case .sidecar:
            return manager.fileExists(atPath: "/Applications/随航管家.app")
        case .aiCoding:
            // 只有真实存在账户或中转配置时才显示；空目录不算数据。
            if manager.fileExists(atPath: "/Applications/magpie.app") { return true }
            if manager.fileExists(atPath: "/Applications/ChatGPT.app") { return true }
            let paths = [
                "/.codex/auth.json",
                "/.cc-switch/cc-switch.db",
                "/.zcode/v2/config.json",
                "/.claude/.credentials.json",
                "/.config/github-copilot/hosts.json",
            ]
            return paths.contains { manager.fileExists(atPath: NSHomeDirectory() + $0) }
        }
    }

    var title: String {
        switch self {
        case .sidecar: return "随航与通用控制"
        case .aiCoding: return "AI coding"
        case .systemMonitor: return "功率动画"
        case .clipboard: return "剪贴板"
        case .keyboardLock: return "键盘锁"
        }
    }

    var symbol: String {
        switch self {
        case .sidecar: return "ipad.and.iphone"
        case .aiCoding: return "curlybraces.square.fill"
        case .systemMonitor: return "hare.fill"
        case .clipboard: return "doc.on.clipboard"
        case .keyboardLock: return "lock.fill"
        }
    }

    /// 预览格子使用的短名称。
    var shortTitle: String {
        switch self {
        case .sidecar: return "随航"
        case .aiCoding: return "AI"
        case .systemMonitor: return "功耗"
        case .clipboard: return "剪贴板"
        case .keyboardLock: return "键盘"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .sidecar: return 146
        case .aiCoding: return 104
        case .systemMonitor: return 48
        case .clipboard: return 112
        case .keyboardLock: return 44
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .sidecar: return 72...300
        case .aiCoding: return 72...180
        case .systemMonitor: return 36...72
        case .clipboard: return 72...220
        case .keyboardLock: return 36...64
        }
    }

    /// 功率动画是逐帧绘制，键盘锁的图标与文字跟随锁定状态；两者都不参与图标/文字自定义。
    var supportsIconAndTextCustomization: Bool {
        self != .systemMonitor && self != .keyboardLock
    }

    static func loadOrder() -> [MainComponent] {
        guard let values = UserDefaults.standard.stringArray(forKey: defaultsKey) else { return allCases }
        var order: [MainComponent] = []
        for value in values {
            guard let component = MainComponent(rawValue: value), !order.contains(component) else { continue }
            order.append(component)
        }
        for component in allCases where !order.contains(component) {
            order.append(component)
        }
        return order
    }

    static func saveOrder(_ order: [MainComponent]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: defaultsKey)
    }

    /// 读取槽位布局（长度固定 slotCount）。槽位是 Touch Bar 排布的权威来源：
    /// 某模块出现在某槽位 = 显示在那里；模块不在任何槽位 = 不显示。
    /// 首次运行读不到 slots 时，用旧 order + visibility 迁移出初始槽位。
    static func loadSlots() -> [MainComponent?] {
        if let stored = UserDefaults.standard.stringArray(forKey: slotsKey) {
            // Once a layout has been saved, it is authoritative. Never insert
            // modules or reorder slots automatically on launch.
            return decodeStoredSlots(stored)
        }
        let legacyOrder = loadOrder()
        let legacyVisibility = loadVisibility()
        var slots = Array<MainComponent?>(repeating: nil, count: slotCount)
        var cursor = 0
        for component in legacyOrder where legacyVisibility[component] ?? true {
            guard cursor < slotCount else { break }
            slots[cursor] = component
            cursor += 1
        }
        saveSlots(slots)
        return slots
    }

    /// Decodes a stored six-slot layout without migrations. Unknown values
    /// become empty slots; empty slots are intentional and keep their position.
    static func decodeStoredSlots(_ stored: [String]) -> [MainComponent?] {
        var slots = Array<MainComponent?>(repeating: nil, count: slotCount)
        for (index, value) in stored.enumerated() where index < slotCount {
            slots[index] = MainComponent(rawValue: value)
        }
        return slots
    }

    /// Resolves a persisted layout without mutating it. A configuration with
    /// any known module is authoritative even when that module is currently
    /// unavailable; only an entirely empty/unknown layout gets a display-only
    /// fallback. The caller decides whether that fallback is saved.
    static func resolveSavedSlots(_ stored: [String]) -> (slots: [MainComponent?], fallback: Bool) {
        let decoded = decodeStoredSlots(stored)
        if decoded.contains(where: { $0 != nil }) {
            return (decoded, false)
        }
        var fallback = Array<MainComponent?>(allCases.filter { $0.isSoftwareAvailable })
        while fallback.count < slotCount { fallback.append(nil) }
        return (fallback, true)
    }

    static func saveSlots(_ slots: [MainComponent?]) {
        let values = slots.map { $0?.rawValue ?? "" }
        UserDefaults.standard.set(values, forKey: slotsKey)
    }

    /// 把「各槽位基础宽」按「空槽吃剩余」规则分配到指定总宽，返回各槽位实际像素宽。
    /// 实体 Touch Bar 布局与预览条格子都复用它，保证两者宽度分布永远一致。
    /// - baseWidths：各槽位基础宽（模块用配置/动态宽，空槽位用 emptySlotWidth）。
    /// - emptyFlags：标记哪个槽位是空槽位。
    /// - gap：槽位间间距。
    /// - total：目标总宽（实体=Touch Bar 实际可用宽，预览=预览条可用宽）。
    /// - 返回：各槽位实际像素宽，Σ结果 + gap*(n-1) 恰为 total（有剩余时），铺满。
    static func distribute(
        baseWidths: [CGFloat],
        emptyFlags: [Bool],
        gap: CGFloat,
        within total: CGFloat
    ) -> [CGFloat] {
        guard baseWidths.count == emptyFlags.count, !baseWidths.isEmpty else { return baseWidths }
        let baseTotal = baseWidths.reduce(0, +) + gap * CGFloat(baseWidths.count - 1)
        let surplus = max(0, total - baseTotal)
        let emptyCount = emptyFlags.filter { $0 }.count
        let nonEmptyCount = baseWidths.count - emptyCount

        var widths = baseWidths.enumerated().map { index, width in
            if emptyFlags[index] {
                return emptyCount > 0 ? width + surplus / CGFloat(emptyCount) : width
            } else {
                return emptyCount == 0 && nonEmptyCount > 0 ? width + surplus / CGFloat(nonEmptyCount) : width
            }
        }

        // 把剩余空间补给最后一个槽位，使它的右缘精确对齐 total（最右贴齐）。
        // 否则当最右槽位是内容模块、且中间空槽位吃走全部剩余时，它会停在左侧留白，视觉在中间。
        let rowWidth = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        if rowWidth < total, let last = widths.indices.last {
            widths[last] += total - rowWidth
        }
        return widths
    }

    /// 该模块是否显示在「展开菜单」里（默认显示）。
    var isVisibleInMenu: Bool {
        let key = Self.visibilityPrefix + rawValue
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setVisibleInMenu(_ visible: Bool, for component: MainComponent) {
        UserDefaults.standard.set(visible, forKey: visibilityPrefix + component.rawValue)
    }

    static func loadVisibility() -> [MainComponent: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { component in
            let key = visibilityPrefix + component.rawValue
            let value = UserDefaults.standard.object(forKey: key) == nil
                ? true
                : UserDefaults.standard.bool(forKey: key)
            return (component, value)
        })
    }

    static func loadWidths() -> [MainComponent: CGFloat] {
        Dictionary(uniqueKeysWithValues: allCases.map { component in
            let key = widthPrefix + component.rawValue
            let stored = UserDefaults.standard.object(forKey: key) == nil
                ? component.defaultWidth
                : CGFloat(UserDefaults.standard.double(forKey: key))
            if component == .systemMonitor, stored > component.widthRange.upperBound {
                return (component, component.defaultWidth)
            }
            return (component, min(component.widthRange.upperBound, max(component.widthRange.lowerBound, stored)))
        })
    }
}

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate, NSMenuDelegate, NSWindowDelegate {
    private enum Item {
        static let mainContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.mainContainer.v7")
        static let sidecar = NSTouchBarItem.Identifier("CodexTouchBarNative.sidecar.v1")
        static let aiCoding = NSTouchBarItem.Identifier("CodexTouchBarNative.aiCoding.v1")
        static let systemMonitor = NSTouchBarItem.Identifier("CodexTouchBarNative.systemMonitor.v1")
        static let detailContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.detailContainer.v7")
        static let usageContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.usageContainer.v2")
        static let systemContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.systemContainer.v1")
        static let clipboardContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.clipboardContainer.v1")
        static let controlStrip = NSTouchBarItem.Identifier("CodexTouchBarNative.controlStrip.v2")
        static let keyboardLockStripBase = "CodexTouchBarNative.keyboardLockStrip"

        /// 空槽占位 item（带槽位下标，保证每个空槽一个独立 id，避免系统按 id 复用冲突）。
        static func emptySlot(_ index: Int) -> NSTouchBarItem.Identifier {
            NSTouchBarItem.Identifier("CodexTouchBarNative.emptySlot.\(index)")
        }

        /// 弹性占位 item：插在最后一个模块前，把最后模块的胶囊推到实体条最右侧。
        static let flexSpacer = NSTouchBarItem.Identifier("CodexTouchBarNative.flexSpacer.v1")
    }

    private enum DefaultsKey {
        static let showPillBorders = "showPillBorders.v1"
        static let keepTouchBarMaximumBrightness = "keepTouchBarMaximumBrightness.v1"
        static let persistentModules = "persistentModules.v1"
    }

    private var touchBar = NSTouchBar()
    private let statusClient = CodexStatusClient()
    private let remoteControl = RemoteControlManager()
    private let clipboardHistory = ClipboardHistoryStore.shared
    private lazy var touchBarPower = TouchBarPower()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var duoMenuIcon: DuoMenuIcon?
    private var controlStripItem: NSTouchBarItem?
    private var controlStripIdentifier = NSTouchBarItem.Identifier(
        "CodexTouchBarNative.keyboardLockStrip.v1"
    )
    private var controlStripGeneration = 1
    /// 主层/详情层各 item 的缓存：NSTouchBar delegate 要求同一 identifier 返回稳定实例，
    /// 绝不能每次 makeItem 都新建（否则模态/Control Strip 上下文会错乱、模块消失）。
    private var touchBarItems: [String: NSTouchBarItem] = [:]
    private weak var aiCodingButton: NSButton?
    private weak var aiActivityMark: AIActivityMarkView?
    private weak var sidecarButton: NSButton?
    private weak var systemMonitorButton: PowerRunnerButton?
    private var inlineMenuSections: InlineMenuSections?
    private var expandedMenuSections: Set<String> = [MainComponent.systemMonitor.rawValue]
    private var mainMenuIsOpen = false
    private var menuPreviewWindow: NSWindow?
    private weak var backButton: NSButton?
    /// 自定义面板：模块图标与文字默认收起，点标题展开一层。
    private weak var clipboardButton: NSButton?
    private weak var keyboardLockButton: NSButton?
    private var keyboardLockAnimationTimer: Timer?
    private var keyboardLockAnimationFrames: [String] = []
    private var keyboardLockAnimationFrame = 0
    private var keyboardLockAnimating = false
    private var lastKeyboardLockState: Bool?
    private weak var quotaView: QuotaView?
    private weak var usageDetailView: UsageDetailStripView?
    private weak var systemDetailView: SystemDetailStripView?
    private weak var powerFlowView: PowerFlowPanelView?
    private weak var servicesWindowMenuItem: NSMenuItem?
    private weak var settingsWindowMenuItem: NSMenuItem?
    private weak var clipboardHistoryView: ClipboardHistoryStripView?
    private weak var brightnessMenuItem: NSMenuItem?
    private var componentSlots = MainComponent.loadSlots()
    /// 当前实际生效的槽位布局：过滤掉「对应软件未安装」的模块（与具体软件解耦）。
    /// 布局、菜单栏分组、预览都用这一层，避免出现点了无响应的模块。
    private var effectiveSlots: [MainComponent?] {
        componentSlots.map { slot in
            guard let component = slot, component.isSoftwareAvailable else { return nil }
            return component
        }
    }
    private var componentOrder: [MainComponent] { effectiveSlots.compactMap { $0 } }
    private var componentWidths = MainComponent.loadWidths()
    private var showPillBorders = UserDefaults.standard.bool(forKey: DefaultsKey.showPillBorders)
    private var keepTouchBarMaximumBrightness: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.keepTouchBarMaximumBrightness) != nil else { return true }
        return defaults.bool(forKey: DefaultsKey.keepTouchBarMaximumBrightness)
    }()
    /// 最近一次确认的 Touch Bar 操作时间；自动亮度用它判断是否空闲。
    private var lastTouchBarInteractionAt = Date.distantPast
    /// 自动亮度：使用 Mac 或触控栏时为 0 档，真正空闲后回落到 1 档。
    private let touchBarActiveDimmingStep = TouchBarPower.maximumBrightnessStep
    private let touchBarIdleDimmingStep = TouchBarPower.maximumBrightnessStep + 1
    private let touchBarIdleDelay: TimeInterval = 15
    private var appliedDimmingStep: Int?
    private var lastBrightnessReassertionAt = Date.distantPast
    private var lastActualBrightnessTarget: Double?
    private var lastActualBrightnessLog = ""
    private var touchBarInputMonitor: Any?
    /// 连续通过实体截图确认“中间内容区为空”的次数。
    private var invisibleTouchBarChecks = 0
    /// 上一次实体 Touch Bar 可见性探测时间（自愈里限频）。
    private var lastInvisibleProbeAt = Date.distantPast
    /// 常驻模式：把模块栏以无关闭钮的系统模态长驻在触控栏中间区域（正常状态可见）。
    private var persistentModules: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.persistentModules) != nil else { return true }
        return defaults.bool(forKey: DefaultsKey.persistentModules)
    }()
    /// 我们把主层模态呈上去了吗（用于 fn 模式修复与设置窗口里的“显示/收起”状态）。
    private var mainBarShown = false
    /// 用户主动收起过模块栏：之后的自愈、唤醒、应用切换都不再自动弹回。
    private var userHiddenMainBar = false
    /// 用户在本应用里主动点固定栏图标：本次停留期间不因为让位规则再收起。
    private var manualYieldBypass = false
    /// 已经因为让位收起：用于区分“让位收起”和“用户收起”，恢复时只恢复前者。
    private var yieldDismissed = false
    /// 前台应用的焦点当前落在文本输入框里（用于让出输入建议区域）。
    private var textFocusEditing = false
    /// 后台探测输入焦点时避免重叠。
    private var yieldProbeInFlight = false
    private var lastYieldProbeAt = Date.distantPast
    private var yieldTimer: Timer?
    private var frontmostObserver: NSObjectProtocol?
    /// 最近一次前台切换时间：自动识别只在刚切过来的应用上生效，
    /// 避免把随机的 DFR 抽风记到某个无关应用头上。
    private var frontmostChangedAt = Date.distantPast
    private weak var yieldMenuItem: NSMenuItem?
    private weak var applicationYieldRow: ApplicationYieldMenuRow?
    private weak var compactModuleRow: ClipboardKeyboardMenuRow?
    private weak var powerMenuControls: PowerMenuControlsView?
    private var isChangingLowPowerMode = false
    /// 最近一次更新检查结果；设置页与菜单摘要都读它。
    private var lastUpdateResult: UpdateCheckResult?
    private var isCheckingForUpdates = false
    private var updateCheckTimer: Timer?
    private weak var copyVersionRow: WindowActionRow?
    /// 设置窗口里的行引用：点击后原地更新开关/文字，避免整页重建打断动画。
    private var settingsRows: [String: WindowActionRow] = [:]
    private var settingsCategoryIndex = 0
    private var settingsSidebarWidth: CGFloat = 200
    /// 设置右栏：分类列表，或原地进入组件编辑器（不新开窗口）。
    private enum SettingsPane { case category, customizer }
    private var settingsPane: SettingsPane = .category
    /// 默认展开硬件与让位列表，避免每个入口都要多点一次。
    private var settingsInlineExpanded: Set<String> = ["interface", "yieldApps"]
    private weak var balancedLowerSlider: NSSlider?
    private weak var balancedLowerLabel: NSTextField?
    private weak var balancedUpperSlider: NSSlider?
    private weak var balancedUpperLabel: NSTextField?
    private var menuModuleRows: [MainComponent: WindowActionRow] = [:]
    /// 实测的 item 起始偏移（随关闭钮显隐而变化），持久化——呈现时即用正确值，
    /// 避免 0.8s 后空槽宽度重算导致模块二次位移（重新唤出时的"卡一下才到位"）。
    private var measuredLeadingOffset: CGFloat? {
        get { UserDefaults.standard.object(forKey: "measuredLeadingOffset.v1") as? CGFloat }
        set { UserDefaults.standard.set(newValue, forKey: "measuredLeadingOffset.v1") }
    }
    private weak var persistentMenuItem: NSMenuItem?
    private var powerRunnerStyle = PowerRunnerStyle.load()
    private var orderPanel: NSPanel?
    private weak var orderStack: NSStackView?
    private weak var stylePicker: NSPopUpButton?
    private weak var slotPreviewStack: NSStackView?
    private var slotPreviewButtons: [NSButton] = []
    private weak var aiDisplayMenu: NSMenu?
    private var aiDisplayMenuKey = ""
    private var aiDisplayMenuOpen = false
    private var pendingAIQuotaRefresh = false
    private weak var customStack: NSStackView?

    static let moduleIconPrefix = "moduleIcon.v1."
    static let moduleLabelPrefix = "moduleLabel.v1."
    static let moduleTextModePrefix = "moduleTextMode.v1."
    /// 自定义面板可选的 SF Symbols 图标清单。
    static let symbolChoices = [
        "waveform.circle.fill", "mic.circle.fill", "brain.head.profile", "sparkles",
        "cpu", "memorychip", "gauge.circle.fill", "bolt.circle.fill", "power", "fan.fill",
        "ipad.and.iphone", "laptopcomputer.and.iphone", "display",
        "curlybraces.square.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill",
        "gearshape.fill", "ellipsis.circle.fill", "heart.fill", "star.fill", "moon.fill", "wifi"
    ]

    private func storedIcon(for component: MainComponent) -> String {
        UserDefaults.standard.string(forKey: Self.moduleIconPrefix + component.rawValue) ?? ""
    }

    private func storedLabel(for component: MainComponent) -> String {
        UserDefaults.standard.string(forKey: Self.moduleLabelPrefix + component.rawValue) ?? ""
    }

    /// 文字显示模式：默认名称 / 无（纯图标）/ 自定义文字。
    private enum ModuleTextMode: String {
        case defaultName = "default"
        case none = "none"
        case custom = "custom"
    }

    private func storedTextMode(for component: MainComponent) -> ModuleTextMode {
        if let raw = UserDefaults.standard.string(forKey: Self.moduleTextModePrefix + component.rawValue),
           let mode = ModuleTextMode(rawValue: raw) {
            return mode
        }
        // 旧数据迁移：之前存过非空自定义文字的按自定义处理，否则按默认。
        if !(UserDefaults.standard.string(forKey: Self.moduleLabelPrefix + component.rawValue) ?? "").isEmpty {
            return .custom
        }
        return .defaultName
    }

    /// 生效标题：nil = 用模块内置默认行为；"" = 纯图标；非空 = 自定义文字。
    private func effectiveTitle(for component: MainComponent) -> String? {
        switch storedTextMode(for: component) {
        case .defaultName: return nil
        case .none: return ""
        case .custom: return storedLabel(for: component)
        }
    }

    /// 模态 Touch Bar 布局实测常量（coords 日志，本机 756pt 条）：
    /// items 从 x=64 起（系统关闭钮区），item 间距 8，右缘留 8。
    static let modalLeadingOffset: CGFloat = 64
    static let modalItemGap: CGFloat = 8
    static let modalRightMargin: CGFloat = 8
    static let fallbackModalWidth: CGFloat = 756
    /// 空槽占位容器（按槽位下标索引），用于把剩余空间平摊给空槽。
    /// 主层单容器（present 时只挂载这一个 item，避免 6 个独立 item 逐个出现的卡顿）。
    private var mainContainerView: ModuleItemView?
    /// 空槽占位 view（按槽位下标），在主层容器内手动布局。
    private var mainEmptySlotViews: [Int: NSView] = [:]

    private var snapshot = CodexSnapshot.loading
    private var selectedUsageAccountKey: String?
    private var refreshTimer: Timer?
    private var sidecarTimer: Timer?
    private var sidecarPollTick = 0
    /// 随航按下后的本地旋转计时器（不等状态文件回读）。
    private var sidecarSpinTimer: Timer?
    private var metricsTimer: Timer?
    private var powerPolicyRefreshTask: Task<Void, Never>?
    private var brightnessTimer: Timer?
    /// 常驻 DFR 自愈计时器：定期检测模块栏是否还在显示，消失则重新呈现。
    private var dfrWatchdogTimer: Timer?
    /// 原生 F1–F12 模式检测/恢复计时器。
    private var touchBarModeRepairTimer: Timer?
    /// 最近一次自愈时间，避免连续触发。
    private var lastSelfHealAt = Date.distantPast
    /// 深度恢复（重新注册 Control Strip 托盘项）节流时间。
    private var lastDeepRecoveryAt = Date.distantPast
    /// 连续检测到「零宽退化窗口」的次数；持续退化升级为深度恢复。
    private var degenerateWindowChecks = 0
    /// 屏幕/系统唤醒观察 token（block 观察需显式移除）。
    private var wakeObserverTokens: [NSObjectProtocol] = []
    /// 锁屏状态：锁屏期间系统接管触控栏（我们的模态被挂起、窗口塌缩为 0 宽），
    /// 此时不做自愈（present 会被系统忽略）；解锁后统一重新呈现。
    private var isScreenLocked = false
    /// 锁屏/解锁分布式通知 token。
    private var lockObserverTokens: [NSObjectProtocol] = []
    private let universalControlWatchdog = UniversalControlWatchdog()
    private var isRefreshing = false
    private var isMetricsRefreshing = false
    private var metricsFetchStartedAt: Date?
    private var lastPanelMetricsAt: Date?
    private var didCreateVisibleItem = false
    private var lastLoggedStatus = ""
    private var lastLoggedMetrics = ""
    private var sidecarStatus = SidecarStatus.idle
    /// 连续读不到随航设备的次数：建连瞬间列表会短暂为空，不能立刻判成断开。
    private var sidecarFrame = 0
    private var sidecarTransientShownAt: Date?
    private var systemMetrics = SystemMetrics.unavailable
    /// Charger and cable specifications, refreshed on the same 1 s cadence
    /// but changing far less often (only on plug/unplug).
    private var interfaceSpecs = InterfaceSpecs.empty
    private var interfaceSpecsReadAt = Date.distantPast
    private var interfaceSpecsPowerState: Bool?
    private var smokeRetainedView: NSView?
    private var smokeRetainedWindow: NSWindow?
    /// 主层布局日志去重：布局在多个计时器里调用，只在原点/宽度变化时记录。
    private var lastLayoutLogKey = ""
    private let sidecarStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SidecarPilot/touchbar-state.tsv")

    override init() {
        super.init()
        configureTouchBar()
        configureMenuBar()
    }

    func start() {
        // 后台预热跑猫等所有动画帧图，避免主线程首次读盘拖慢呈现。
        PowerRunnerButton.warmFramesInBackground()
        // 启动时可能已处于锁屏状态（收不到锁定瞬间的通知），主动检测一次。
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            isScreenLocked = locked
        }
        AppLog.reset()
        AppLog.write("start bundle=\(Bundle.main.bundlePath)")
        AppLog.write("menu items=\(statusItem.menu?.items.map(\.title) ?? [])")
        // 每次启动换新 identifier：DFR 会跨进程记住某个 id 的
        // “注册成功但不绘制”状态，复用旧 id 会直接复现空白图标。
        rotateControlStripIdentifier()
        installControlStripItem()
        TouchBarYieldPolicy.purgeOwnHelpers()
        ControlStrip.fixCloseBoxPolicy(shows: true)
        ensureRescueEntryPoints()
        ensureUsableSlots()
        KeyboardLockController.shared.onChange = { [weak self] in
            guard let self else { return }
            self.refreshKeyboardLockButton()
            self.updateMenuSummary(for: .keyboardLock)
        }
        KeyboardLockController.shared.start()
        placeKeyboardLockInEmptySlotOnce()
        clipboardHistory.onChange = { [weak self] in
            guard let self else { return }
            self.clipboardHistoryView?.update(entries: self.clipboardHistory.entries)
        }
        clipboardHistory.start()
        // 远程控制台已并入 phonecodex Mac app，BarControl 不再启动。
        if let switchIndex = CommandLine.arguments.firstIndex(of: "--switch-provider"),
           switchIndex + 1 < CommandLine.arguments.count {
            remoteControl.switchProvider(id: CommandLine.arguments[switchIndex + 1])
        }
        refresh()
        let refreshTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.refreshTimer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
        refreshSidecarStatus()
        sidecarTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sidecarPollTick += 1
                // 连接中每 2 秒轮询，其余状态每 6 秒读一次。
                if self.sidecarStatus.state == "connecting" || self.sidecarPollTick % 3 == 0 {
                    self.refreshSidecarStatus()
                }
            }
        }
        refreshSystemMetrics()
        let metricsTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 菜单关闭时把 IORegistry/IOReport 采样降到约 10 秒一次；
                // 展开菜单会立即触发一次并恢复 2 秒节奏。
                if !self.mainMenuIsOpen,
                   Date().timeIntervalSince(self.lastPanelMetricsAt ?? .distantPast) < 10 {
                    return
                }
                self.refreshSystemMetrics()
            }
        }
        self.metricsTimer = metricsTimer
        RunLoop.main.add(metricsTimer, forMode: .common)
        let brightnessTimer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maintainTouchBarBrightness() }
        }
        self.brightnessTimer = brightnessTimer
        RunLoop.main.add(brightnessTimer, forMode: .common)
        touchBarInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.directTouch, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .gesture]
        ) { [weak self] event in
            guard let self else { return event }
            let ownTouchBarWindow = event.window.map { window in
                self.touchBarItems.values.contains {
                    ($0 as? NSCustomTouchBarItem)?.view.window === window
                }
            } ?? false
            if event.type == .directTouch || ownTouchBarWindow {
                self.noteTouchBarInteraction()
            }
            return event
        }
        // The Control Strip registration is asynchronous. Presenting in the
        // same run-loop turn is silently ignored on recent macOS versions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard TouchBarPresentationPolicy.shouldAutoExpand(
                persistent: self.persistentModules,
                yieldingToApp: self.shouldYieldTouchBar,
                systemOwnsTouchBar: self.systemOwnsTouchBar
            ) else {
                AppLog.write("launch present skipped: bar owned by system or another app")
                return
            }
            self.autoShowMain()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, !self.didCreateVisibleItem,
                  TouchBarPresentationPolicy.shouldPresentAtLaunch(persistent: self.persistentModules) else { return }
            AppLog.write("no delegate item request after first present; retrying")
            self.autoShowMain()
        }
        // 若上次退出前 Touch Bar 停在原生 F1–F12 模式，启动后切回 App 控制条。
        // 用户按 Fn 也可能进入该模式；这里只恢复我们自己的呈现，不改其他 App。
        let modeRepair = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repairNativeTouchBarModeIfNeeded() }
        }
        RunLoop.main.add(modeRepair, forMode: .common)
        self.touchBarModeRepairTimer = modeRepair
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.repairNativeTouchBarModeIfNeeded()
        }
        // 常驻自愈：每 2 秒检查模块栏是否仍在显示，消失则重新呈现。
        let dfrTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dfrSelfHealIfNeeded() }
        }
        self.dfrWatchdogTimer = dfrTimer
        RunLoop.main.add(dfrTimer, forMode: .common)
        // 屏幕唤醒 / 会话激活后，系统常会撤掉我们的 DFR 模态，主动补一次。
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let screensWake = workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // 唤醒后系统会恢复各家 App 的控制条；不再抢着 present 自己的模块栏，
                // 否则会盖掉别的应用（Safari/Bilibili 等）的触控栏内容。
                // 用户想看模块栏时点固定区图标或菜单里的入口即可。
                AppLog.write("screens did wake: restoring if persistent")
                if TouchBarPresentationPolicy.shouldAutoExpand(
                    persistent: self?.persistentModules == true,
                    yieldingToApp: self?.shouldYieldTouchBar == true,
                    systemOwnsTouchBar: self?.systemOwnsTouchBar == true
                ), Date() >= (self?.mainBarHiddenUntil ?? .distantPast) {
                    self?.autoShowMain()
                }
            }
        }
        let systemWake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                AppLog.write("system did wake: restoring if persistent")
                if TouchBarPresentationPolicy.shouldAutoExpand(
                    persistent: self?.persistentModules == true,
                    yieldingToApp: self?.shouldYieldTouchBar == true,
                    systemOwnsTouchBar: self?.systemOwnsTouchBar == true
                ), Date() >= (self?.mainBarHiddenUntil ?? .distantPast) {
                    self?.autoShowMain()
                }
            }
        }
        wakeObserverTokens = [screensWake, systemWake]
        // 锁屏/解锁监听：锁屏时系统接管触控栏，解锁后需要重新呈现才能交还。
        let distributed = DistributedNotificationCenter.default()
        let lockedToken = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                AppLog.write("screen locked: suspending DFR self-heal")
            }
        }
        let unlockedToken = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                AppLog.write("screen unlocked: restoring if persistent")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    self.ensureKeyboardLockStripAlive()
                    if TouchBarPresentationPolicy.shouldRestoreAfterWake(
                        persistent: self.persistentModules,
                        userHidden: self.userHiddenMainBar
                    ) {
                        self.autoShowMain()
                    }
                }
            }
        }
        lockObserverTokens = [lockedToken, unlockedToken]
        // 让位检测：切应用立即判定；输入焦点变化用 0.8 秒轮询（读取辅助功能，
        // 只读不写）。轮询在后台线程做，避免某个 App 的 AX 响应拖住主线程。
        frontmostObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.frontmostChangedAt = Date()
                self.manualYieldBypass = false
                self.detailYieldBypassUntil = .distantPast
                self.textFocusEditing = false
                self.evaluateTouchBarYield()
            }
        }
        let yieldTicker = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateTouchBarYield() }
        }
        self.yieldTimer = yieldTicker
        RunLoop.main.add(yieldTicker, forMode: .common)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        clipboardHistory.stop()
        clipboardHistory.onChange = nil
        sidecarTimer?.invalidate()
        sidecarTimer = nil
        sidecarSpinTimer?.invalidate()
        sidecarSpinTimer = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        powerPolicyRefreshTask?.cancel()
        powerPolicyRefreshTask = nil
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        yieldTimer?.invalidate()
        yieldTimer = nil
        if let touchBarInputMonitor { NSEvent.removeMonitor(touchBarInputMonitor) }
        touchBarInputMonitor = nil
        dfrWatchdogTimer?.invalidate()
        dfrWatchdogTimer = nil
        touchBarModeRepairTimer?.invalidate()
        touchBarModeRepairTimer = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        wakeObserverTokens.forEach { workspaceCenter.removeObserver($0) }
        wakeObserverTokens = []
        if let frontmostObserver { workspaceCenter.removeObserver(frontmostObserver) }
        frontmostObserver = nil
        let distributed = DistributedNotificationCenter.default()
        lockObserverTokens.forEach { distributed.removeObserver($0) }
        lockObserverTokens = []
        systemMonitorButton?.stopAnimating()
        powerFlowView?.stopAnimating()
        universalControlWatchdog.stop()
        if let controlStripItem {
            ControlStrip.remove(controlStripItem)
        }
        controlStripItem = nil
    }

    func runRemoteProtocolSmokeTest() {
        Task {
            let passed = await remoteControl.runProtocolSmokeTest()
            AppLog.write("remote protocol smoke test passed=\(passed)")
            stop()
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    func runAppServerRestartSmokeTest() {
        Task {
            let passed = await remoteControl.runAppServerRestartSmokeTest()
            AppLog.write("app-server restart smoke test passed=\(passed)")
            stop()
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    func runProviderContinuityProbe(providerName: String, threadID: String) {
        Task {
            let passed = await remoteControl.runProviderContinuityProbe(
                providerName: providerName,
                threadID: threadID
            )
            AppLog.write(
                "provider continuity probe provider=\(providerName) thread=\(threadID) passed=\(passed)"
            )
            stop()
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// 单进程核对设置窗口开关前后的真实 Touch Bar 坐标，不改写用户配置。
    func runSettingsPositionProbe() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.showMain()
            try? await Task.sleep(for: .seconds(1))
            @MainActor func positions(_ stage: String) -> [String: CGFloat] {
                self.updateMainModuleWidths()
                let buttons: [(String, NSButton?)] = [
                    ("sidecar", self.sidecarButton), ("ai", self.aiCodingButton),
                    ("clipboard", self.clipboardButton), ("system", self.systemMonitorButton)
                ]
                var result: [String: CGFloat] = [:]
                for (name, button) in buttons {
                    guard let button, !button.isHidden,
                          button.window != nil else { continue }
                    result[name] = button.convert(.zero, to: nil).x
                }
                AppLog.write("settings position probe \(stage) x=\(result)")
                return result
            }
            let baseline = positions("before")
            var passed = !baseline.isEmpty
            for cycle in 1...2 {
                self.showComponentOrder()
                try? await Task.sleep(for: cycle == 1 ? .seconds(2) : .seconds(1))
                let opened = positions("open-\(cycle)")
                // 第一次打开面板时系统挂载模态可能短暂把主窗口塌缩到 0 宽，
                // 探针本身不应把这个瞬态当成位置回归；再等 2 秒核对一次。
                if opened.isEmpty {
                    try? await Task.sleep(for: .seconds(2))
                    let retried = positions("open-retry-\(cycle)")
                    if !retried.isEmpty {
                        passed = passed && Set(retried.keys) == Set(baseline.keys)
                            && baseline.allSatisfy { abs((retried[$0.key] ?? -1_000) - $0.value) < 1 }
                    }
                }
                passed = passed && Set(opened.keys) == Set(baseline.keys)
                    && baseline.allSatisfy { abs((opened[$0.key] ?? -1_000) - $0.value) < 1 }
                self.orderPanel?.performClose(nil)
                try? await Task.sleep(for: .seconds(1))
                let closed = positions("closed-\(cycle)")
                passed = passed && Set(closed.keys) == Set(baseline.keys)
                    && baseline.allSatisfy { abs((closed[$0.key] ?? -1_000) - $0.value) < 1 }
            }
            AppLog.write("settings position probe passed=\(passed)")
        }
    }

    func runSmokeTest() {
        AppLog.write("smoke test scheduled")
        // 先等实体 Touch Bar 完成一次真实挂载，再开始断言。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let visible = self.captureAndCheckRealTouchBar(stage: "smoke-initial")
            assert(visible, "primary Touch Bar layer must render visible content")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.renderPreview(self.makeMainContainer(), name: "main")
            let decodedOutputs = SystemMetricsReader.decodePowerOutputs(
                raw: [[
                    "PortIndex": 1,
                    "Watts": 10_700,
                    "AdapterVoltage": 5_100,
                    "Current": 2_100
                ]],
                usbDevices: [USBDeviceDescriptor(name: "iPad Pro", locationID: 0x0010_0000)]
            )
            assert(decodedOutputs.count == 1)
            assert(decodedOutputs.first?.name == "iPad Pro")
            assert(abs((decodedOutputs.first?.watts ?? 0) - 10.7) < 0.001)
            assert(SystemMetricsReader.gpuUsagePercent([
                "Device Utilization %": 0,
                "Renderer Utilization %": 42,
                "Tiler Utilization %": 17
            ]) == 42)
            let liveMetrics = self.systemMetrics
            self.systemMetrics = .preview
            self.updateSystemMonitor()
            let runnerPreview = self.makeMainContainer()
            let runner = self.systemMonitorButton
            let runnerWindow = NSWindow(
                contentRect: runnerPreview.bounds,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            runnerWindow.contentView = runnerPreview
            self.smokeRetainedWindow = runnerWindow
            let savedRunnerStyle = self.powerRunnerStyle
            let testRunnerStyle: PowerRunnerStyle = savedRunnerStyle == .slime ? .cat : .slime
            self.setPowerRunnerStyle(testRunnerStyle)
            assert(self.powerRunnerStyle == testRunnerStyle)
            assert(self.systemMonitorButton?.style == testRunnerStyle)
            self.setPowerRunnerStyle(savedRunnerStyle)
            for style in PowerRunnerStyle.allCases {
                runner?.setStyle(style)
                assert(runner?.frameCount == style.frameCount)
                self.renderPreview(runnerPreview, name: "main-power-runner-\(style.rawValue)")
            }
            runner?.setStyle(self.powerRunnerStyle)
            assert(PowerRunnerButton.framesPerSecond(for: 80) > PowerRunnerButton.framesPerSecond(for: 5))
            assert(PowerRunnerButton.framesPerSecond(for: 500) == 14)
            runner?.watts = 42
            runner?.startAnimating()
            assert(runner?.isAnimating == true)
            self.renderPreview(runnerPreview, name: "main-power-runner")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { [weak self, runnerPreview, runner] in
                assert(runner?.isAnimating == true)
                assert((runner?.animationFrame ?? 0) > 0)
                self?.renderPreview(runnerPreview, name: "main-power-runner-moving")
                runner?.stopAnimating()
                self?.smokeRetainedWindow = nil
            }
            let systemDetails = self.makeSystemContainer()
            self.renderPreview(systemDetails, name: "system-detail")
            runner?.performClick(nil)
            assert(self.touchBar.defaultItemIdentifiers == self.systemIdentifiers)
            assert(self.touchBar.principalItemIdentifier == nil)
            self.showMain()
            assert(self.touchBar.defaultItemIdentifiers == self.mainIdentifiers)
            assert(self.touchBar.principalItemIdentifier == nil)
            let flowPreview = FrostedPowerFlowView()
            flowPreview.metrics = .preview
            assert(FrostedPowerFlowView.flowDuration(for: 80) > 0)
            assert(FrostedPowerFlowView.flowDuration(for: 0) == 0)
            assert(FrostedPowerFlowView.ribbonWidth(for: 80) > FrostedPowerFlowView.ribbonWidth(for: 5))
            assert(FrostedPowerFlowView.ribbonWidth(for: 0) == 0)
            assert(
                FrostedPowerFlowView.ribbonStartWidth(for: 61.2, startsNarrow: false)
                    == FrostedPowerFlowView.ribbonWidth(for: 61.2)
            )
            assert(
                FrostedPowerFlowView.ribbonStartWidth(for: 10.7, startsNarrow: true)
                    < FrostedPowerFlowView.ribbonStartWidth(for: 10.7, startsNarrow: false)
            )
            assert(
                FrostedPowerFlowView.mainCardHeight(for: 61.2)
                    > FrostedPowerFlowView.mainCardHeight(for: 0.2)
            )
            let outputStarts = FrostedPowerFlowView.outputBranchStartWidths(
                for: [10.7, 3.83, 9.15]
            )
            let outputEnds = FrostedPowerFlowView.outputBranchEndWidths(
                for: [10.7, 3.83, 9.15]
            )
            assert(outputStarts.count == 3 && outputEnds.count == 3)
            assert(outputStarts[0] > outputStarts[2] && outputStarts[2] > outputStarts[1])
            assert(outputEnds[0] > outputEnds[2] && outputEnds[2] > outputEnds[1])
            assert(abs(outputStarts.reduce(0, +) - 116) < 0.01)
            assert(abs(outputEnds.reduce(0, +) - 116) < 0.01)
            assert((outputStarts.min() ?? 0) >= 31.99)
            assert((outputEnds.min() ?? 0) >= 31.99)
            let soloOutputStart = FrostedPowerFlowView.outputBranchStartWidths(for: [10.7])
            let pairedOutputStarts = FrostedPowerFlowView.outputBranchStartWidths(for: [10.7, 9.15])
            assert(abs(soloOutputStart[0] - 116) < 0.01)
            assert(abs(pairedOutputStarts.reduce(0, +) - 116) < 0.01)
            assert(pairedOutputStarts[0] > pairedOutputStarts[1])
            let dynamicCards = FrostedPowerFlowView.endpointCardHeights(
                for: [58.6, 3.90, 26.7]
            )
            assert(dynamicCards[0] > dynamicCards[2] && dynamicCards[2] > dynamicCards[1])
            assert((dynamicCards.min() ?? 0) >= 95.99)
            let equalizedDynamic = FrostedPowerFlowView.equalizedOutputWidths(
                preferredHeights: dynamicCards,
                watts: [58.6, 3.90, 26.7],
                maximumTotalHeight: 360
            )
            assert(abs(equalizedDynamic.reduce(0, +) - 360) < 0.01)
            assert((equalizedDynamic.min() ?? 0) >= 95.99)
            let singlePreferred = FrostedPowerFlowView.preferredOutputCardHeights(
                for: [10.7]
            )
            assert(singlePreferred == [132])
            assert(
                FrostedPowerFlowView.requiredSystemCardHeight(for: [10.7]) == 164
            )
            assert(FrostedPowerFlowView.endpointIconSize(forCardHeight: 96) == 64)
            assert(FrostedPowerFlowView.endpointIconSize(forCardHeight: 132) >= 64)
            assert(FrostedPowerFlowView.secondLevelIconSize(forCardHeight: 96) == 72)
            assert(FrostedPowerFlowView.secondLevelIconSize(forCardHeight: 360) == 80)
            assert(FrostedPowerFlowView.endpointCaption(for: "CPU") == "CPU")
            assert(FrostedPowerFlowView.endpointCaption(for: "GPU") == "GPU")
            assert(FrostedPowerFlowView.endpointCaption(for: "USB-C 显示器") == "显示器")
            assert(FrostedPowerFlowView.endpointCaption(for: "USB-C 设备") == "外接设备")
            let normalInputCards = FrostedPowerFlowView.linkedCardHeights(
                for: [3.47, 84.0],
                totalHeight: 456,
                minimumHeight: 132
            )
            assert(abs(normalInputCards.reduce(0, +) - 456) < 0.01)
            assert((normalInputCards.min() ?? 0) >= 131.99)
            let compactPreferred = FrostedPowerFlowView.endpointCardHeights(
                for: [10.7, 3.83, 9.15]
            )
            let equalizedCompact = FrostedPowerFlowView.equalizedOutputWidths(
                preferredHeights: compactPreferred,
                watts: [10.7, 3.83, 9.15],
                maximumTotalHeight: 360
            )
            assert(abs(equalizedCompact.reduce(0, +) - 360) < 0.01)
            assert(equalizedCompact[0] > equalizedCompact[2])
            assert(equalizedCompact[2] > equalizedCompact[1])
            assert((equalizedCompact.min() ?? 0) >= 95.99)
            assert(
                FrostedPowerFlowView.requiredSystemCardHeight(
                    for: [10.7, 3.83, 9.15]
                ) >= 343
            )
            let referenceSecondLevel = FrostedPowerFlowView.secondLevelCardHeights(
                batteryWatts: 61.2,
                systemWatts: 23.7,
                minimumSystemHeight: 164
            )
            assert(
                abs(referenceSecondLevel.battery + referenceSecondLevel.system - 456) < 0.01
            )
            let dynamicSecondLevel = FrostedPowerFlowView.secondLevelCardHeights(
                batteryWatts: 3.47,
                systemWatts: 84.0,
                minimumSystemHeight: 360
            )
            assert(dynamicSecondLevel.system > dynamicSecondLevel.battery)
            assert(dynamicSecondLevel.battery >= 95.99)
            assert(dynamicSecondLevel.system >= 359.99)
            assert(
                abs(dynamicSecondLevel.battery + dynamicSecondLevel.system - 456) < 0.01
            )
            let compactLinkedCards = FrostedPowerFlowView.linkedCardHeights(
                for: [3.47, 84.0],
                totalHeight: 394,
                minimumHeight: 72
            )
            assert(compactLinkedCards[0] < compactLinkedCards[1])
            assert(abs(compactLinkedCards.reduce(0, +) - 394) < 0.01)
            assert(FrostedPowerFlowView.showsChargingBranch(for: .preview))
            assert(!FrostedPowerFlowView.showsBatteryBranch(for: .previewBatteryIdle))
            assert(!FrostedPowerFlowView.showsBatteryBranch(for: .previewBatteryDischarging))
            assert(FrostedPowerFlowView.showsBatteryInput(for: .previewBatteryDischarging))
            assert(FrostedPowerFlowView.showsBatteryInput(for: .previewDynamicHierarchy))
            assert(!FrostedPowerFlowView.batteryFlowIsReversed(for: .preview))
            assert(FrostedPowerFlowView.batteryFlowIsReversed(for: .previewBatteryDischarging))
            assert(FrostedPowerFlowView.visibleDeviceCount(for: .preview) == 3)
            assert(FrostedPowerFlowView.displayedDeviceCount(for: .previewInternalBreakdown) == 3)
            assert(
                FrostedPowerFlowView.displayedOutputNames(for: .previewInternalBreakdown)
                    == ["CPU", "GPU", "其他硬件"]
            )
            assert(
                !FrostedPowerFlowView.displayedOutputNames(for: .previewInternalBreakdown)
                    .contains { $0.contains("进程") }
            )
            assert(FrostedPowerFlowView.displayedOutputNames(for: .previewBatteryDischarging) == ["其他硬件"])
            assert(FrostedPowerFlowView.displayedOutputNames(for: .previewWithoutOutputs) == ["其他硬件"])
            assert(abs((SystemMetrics.previewLocalAndExternalBreakdown.localComputerWatts ?? 0) - 17.7) < 0.001)
            assert(abs(SystemMetrics.previewLocalAndExternalBreakdown.externalOutputWatts - 15.0) < 0.001)
            assert(abs(SystemMetrics.previewLocalAndExternalBreakdown.batterySupplyWatts - 20.1) < 0.001)
            assert(SystemMetrics.previewLocalAndExternalBreakdown.fanRPMs == [2_160])
            assert(abs((SystemMetrics.previewLocalAndExternalBreakdown.gpuTemperature ?? 0) - 63.9) < 0.001)
            flowPreview.startAnimating()
            assert(flowPreview.isAnimating)
            self.renderPreview(flowPreview, name: "power-flow")
            self.renderPreview(self.makePowerFlowMaterialPreview(metrics: .preview), name: "power-flow-menu-material")
            let liveFlowPreview = FrostedPowerFlowView()
            liveFlowPreview.metrics = liveMetrics
            self.renderPreview(liveFlowPreview, name: "power-flow-live")
            self.renderPreview(
                self.makePowerFlowMaterialPreview(metrics: liveMetrics),
                name: "power-flow-live-menu-material"
            )
            let noOutputFlowPreview = FrostedPowerFlowView()
            noOutputFlowPreview.metrics = .previewWithoutOutputs
            self.renderPreview(noOutputFlowPreview, name: "power-flow-no-outputs")
            self.renderPreview(
                self.makePowerFlowMaterialPreview(metrics: .previewWithoutOutputs),
                name: "power-flow-no-outputs-menu-material"
            )
            assert(!FrostedPowerFlowView.showsChargingBranch(for: .previewBatteryIdle))
            assert(FrostedPowerFlowView.visibleDeviceCount(for: .previewBatteryIdle) == 3)
            self.renderPreview(
                self.makePowerFlowMaterialPreview(metrics: .previewBatteryIdle),
                name: "power-flow-battery-idle-menu-material"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { [weak self, flowPreview] in
                assert(flowPreview.animationFrame > 0)
                self?.renderPreview(flowPreview, name: "power-flow-moving")
                flowPreview.stopAnimating()
                assert(!flowPreview.isAnimating)
            }
            self.systemMetrics = liveMetrics
            if let menu = self.statusItem.menu {
                self.menuWillOpen(menu)
                assert(self.powerFlowView?.isAnimating == true)
                self.menuDidClose(menu)
                assert(self.powerFlowView?.isAnimating == false)
            }
            let liveSlots = self.componentSlots
            let liveWidths = self.componentWidths
            self.componentSlots = [.sidecar, .aiCoding, .systemMonitor, nil, nil, nil]
            self.renderPreview(self.makeMainContainer(), name: "main-custom-order")
            self.componentSlots = [nil, .systemMonitor, nil, nil, nil, .sidecar]
            self.componentWidths[.systemMonitor] = MainComponent.systemMonitor.widthRange.lowerBound
            self.renderPreview(self.makeMainContainer(), name: "main-empty-slots")
            self.componentSlots = liveSlots
            self.componentWidths = liveWidths
            self.showComponentOrder()
            let defaults = UserDefaults.standard
            let customizable = MainComponent.allCases.filter(\.supportsIconAndTextCustomization)
            let savedModes = customizable.map {
                defaults.object(forKey: Self.moduleTextModePrefix + $0.rawValue)
            }
            for component in customizable {
                defaults.set(ModuleTextMode.none.rawValue, forKey: Self.moduleTextModePrefix + component.rawValue)
            }
            self.refreshModuleAppearance()
            let compactWidths = customizable.map { self.displayedModuleWidth(for: $0) }
            let liveButtonWidths = [self.aiCodingButton?.frame.width, self.clipboardButton?.frame.width]
            self.renderPreview(self.makeMainContainer(), name: "main-icon-only")
            for (component, savedMode) in zip(customizable, savedModes) {
                let key = Self.moduleTextModePrefix + component.rawValue
                if let savedMode {
                    defaults.set(savedMode, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            self.refreshModuleAppearance()
            precondition(compactWidths.allSatisfy { $0 == 44 }, "Icon-only modules must use compact width")
            precondition(liveButtonWidths.allSatisfy { $0 == 44 }, "Live buttons must shrink with their titles")
            AppLog.write("smoke icon-only widths=\(compactWidths), live=\(liveButtonWidths)")
            if let settingsView = self.orderPanel?.contentView {
                self.renderPreview(settingsView, name: "component-order-settings")
            }
            // 深色外观验证：同一面板切到 darkAqua 后应使用深色底与浅色语义文字。
            if let panel = self.orderPanel {
                let saved = panel.appearance
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.contentView = self.makeComponentSettingsContent()
                panel.contentView?.appearance = NSAppearance(named: .darkAqua)
                self.reloadSlotPreview()
                self.reloadOrderRows()
                self.reloadCustomRows()
                panel.contentView?.layoutSubtreeIfNeeded()
                if let settingsView = panel.contentView {
                    self.renderPreview(settingsView, name: "component-order-settings-dark")
                }
                panel.appearance = saved
                panel.contentView = self.makeComponentSettingsContent()
                self.reloadSlotPreview()
                self.reloadOrderRows()
                self.reloadCustomRows()
            }
            self.orderPanel?.orderOut(nil)
            let detailView = self.makeDetailContainer()
            let liveSnapshot = self.snapshot
            let now = Date().timeIntervalSince1970
            let sampleAccounts = [
                UsageAccount(
                    key: "codex:oauth:main", clientID: "codex", clientLabel: "Codex",
                    accountLabel: "主力 Plus", providerLabel: "OpenAI Official",
                    isCurrent: true, showByDefault: nil, iconID: nil, isOfficial: true,
                    metricKind: "subscription", remainingBalance: nil, balanceUnit: nil,
                    remainingPercent: 68, secondaryRemainingPercent: 82,
                    todayCost: 25.3, monthCost: 421.8, todayRequests: 283, todayTokens: 70_000_000,
                    cacheHitPercent: 49, successPercent: 99, modelLabel: "gpt-5.6-sol", metricsScope: "Codex 会话总计",
                    chartTitle: "7日费用", chartUnit: "USD", latestAt: now,
                    history: [22, 53, 21, 95, 47, 61, 118].enumerated().map {
                        UsagePoint(timestamp: now - Double(6 - $0.offset) * 86_400, primary: Double($0.element), secondary: nil)
                    }
                ),
                UsageAccount(
                    key: "codex:provider:kakou", clientID: "codex", clientLabel: "Codex",
                    accountLabel: "卡扣AI", providerLabel: "API",
                    isCurrent: false, showByDefault: nil, iconID: nil, isOfficial: false,
                    metricKind: "balance", remainingBalance: -0.1084, balanceUnit: "USD",
                    remainingPercent: nil, secondaryRemainingPercent: nil,
                    todayCost: 0, monthCost: 0, todayRequests: 0, todayTokens: 0,
                    cacheHitPercent: nil, successPercent: nil, modelLabel: "", metricsScope: "卡扣AI",
                    chartTitle: "余额趋势", chartUnit: "USD", latestAt: now,
                    history: [UsagePoint(timestamp: now, primary: -0.1084, secondary: nil)]
                ),
                UsageAccount(
                    key: "codex:provider:deepseek", clientID: "codex", clientLabel: "Codex",
                    accountLabel: "DeepSeek", providerLabel: "API",
                    isCurrent: false, showByDefault: nil, iconID: nil, isOfficial: false,
                    metricKind: "balance", remainingBalance: 6.21, balanceUnit: "CNY",
                    remainingPercent: nil, secondaryRemainingPercent: nil,
                    todayCost: 0, monthCost: 0, todayRequests: 0, todayTokens: 0,
                    cacheHitPercent: nil, successPercent: nil, modelLabel: "", metricsScope: "DeepSeek",
                    chartTitle: "余额趋势", chartUnit: "CNY", latestAt: now,
                    history: [UsagePoint(timestamp: now, primary: 6.21, secondary: nil)]
                )
            ]
            self.snapshot = CodexSnapshot(
                label: liveSnapshot.label,
                state: liveSnapshot.state,
                activeCount: liveSnapshot.activeCount,
                activeThreads: liveSnapshot.activeThreads,
                limits: liveSnapshot.limits,
                platforms: [
                    PlatformUsage(
                        id: "claude",
                        label: "Claude",
                        provider: "API 示例",
                        todayCost: 7.2,
                        monthCost: 42.8,
                        todayRequests: 86,
                        todayTokens: 120_000,
                        dailyLimit: 10,
                        monthlyLimit: 100,
                        latestAt: Date().timeIntervalSince1970,
                        remainingBalance: 57.2,
                        balanceUnit: "USD"
                    )
                ],
                accounts: sampleAccounts
            )
            self.renderPreview(self.makeDetailContainer(), name: "detail-account-dashboard")
            self.selectedUsageAccountKey = "codex:oauth:main"
            self.renderPreview(self.makeUsageContainer(), name: "usage-detail")
            self.snapshot = CodexSnapshot(
                label: "空闲",
                state: "idle",
                activeCount: 0,
                activeThreads: [],
                limits: liveSnapshot.limits,
                platforms: liveSnapshot.platforms
            )
            self.renderPreview(self.makeDetailContainer(), name: "detail-empty")
            self.snapshot = liveSnapshot
            self.sidecarStatus = .idle
            let compactSidecarWidth = self.sidecarWidth
            self.sidecarStatus = SidecarStatus(state: "connecting", message: "正在检查连接…", detail: "准备")
            assert(self.sidecarWidth >= compactSidecarWidth + 30)
            self.renderSidecarPreview(
                SidecarStatus(state: "connecting", message: "正在连接 iPad", detail: "2/3"),
                name: "sidecar-connecting"
            )
            self.renderSidecarPreview(
                SidecarStatus(state: "success", message: "随航连接成功", detail: "2.1 秒"),
                name: "sidecar-success"
            )
            self.renderSidecarPreview(
                SidecarStatus(state: "failure", message: "随航连接失败", detail: "请重试"),
                name: "sidecar-failure"
            )
            self.renderSidecarPreview(.idle, name: "sidecar-idle")
            self.smokeRetainedView = self.makeMainContainer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            AppLog.write("smoke test: click AI coding")
            self?.aiCodingButton?.performClick(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            AppLog.write("smoke test: click back")
            self?.backButton?.performClick(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
            guard let self else { return }
            // 场景 1：槽位配置被改空或旧配置全部失效，必须自动恢复可用主层。
            let savedSlots = self.componentSlots
            self.componentSlots = Array(repeating: nil, count: MainComponent.slotCount)
            assert(self.componentOrder.isEmpty)
            self.ensureUsableSlots()
            assert(!self.componentOrder.isEmpty, "empty slot config must self-recover")
            self.componentSlots = savedSlots
            // 场景 2：Control Strip 托盘项丢失，必须每 2 秒自愈重新注册。
            if let item = self.controlStripItem {
                ControlStrip.remove(item)
            }
            self.controlStripItem = nil
            self.ensureRescueEntryPoints()
            assert(self.controlStripItem != nil, "control strip item must self-recover")
            // 场景 3：菜单栏菜单被清空，必须能重建。
            self.statusItem.menu = nil
            self.ensureRescueEntryPoints()
            assert(self.statusItem.menu != nil, "menu bar menu must self-recover")
            AppLog.write("smoke rescue checks passed")
            // 自动亮度：操作应落到 0 档，Mac 与触控栏都空闲后回落到 1 档（仅面板点亮时）。
            let brightnessWasEnabled = self.keepTouchBarMaximumBrightness
            let stepBefore = self.touchBarPower.currentDimmingStep()
            let displayOn = self.touchBarPower.displayState == 2
            self.keepTouchBarMaximumBrightness = true
            self.lastTouchBarInteractionAt = Date()
            self.maintainTouchBarBrightness(macIdleOverride: .infinity)
            let activeStep = self.touchBarPower.currentDimmingStep()
            self.lastTouchBarInteractionAt = Date().addingTimeInterval(-(self.touchBarIdleDelay + 1))
            self.maintainTouchBarBrightness(macIdleOverride: .infinity)
            let idleStep = self.touchBarPower.currentDimmingStep()
            if displayOn {
                assert(activeStep == TouchBarPower.maximumBrightnessStep, "active Touch Bar should use brightest step")
                assert(idleStep == TouchBarPower.maximumBrightnessStep + 1, "idle Touch Bar should fall back one step")
            }
            self.keepTouchBarMaximumBrightness = brightnessWasEnabled
            self.lastTouchBarInteractionAt = Date()
            self.maintainTouchBarBrightness()
            AppLog.write(
                "smoke brightness displayOn=\(displayOn) before=\(stepBefore.map(String.init) ?? "nil") active=\(activeStep.map(String.init) ?? "nil") idle=\(idleStep.map(String.init) ?? "nil")"
            )
            // 随航点按的即时反馈：performClick 后同一帧必须已经进入 connecting 旋转帧，
            // 不能等 SidecarPilot 落状态文件、再被 0.25s 轮询读到。
            // 只验证本地首帧反馈路径，不 performClick，避免冒烟测试真的拉起随航进程。
            let sidecarStateBefore = self.sidecarStatus.state
            if sidecarStateBefore != "connecting" {
                self.beginSidecarConnectingLocally()
                let spinTitle = self.sidecarButton?.title ?? ""
                precondition(self.sidecarStatus.state == "connecting", "Sidecar tap must enter connecting immediately")
                precondition(spinTitle.contains("正在连接") || spinTitle.contains("◐") || spinTitle.contains("◓") || spinTitle.contains("◑") || spinTitle.contains("◒"), "Sidecar tap must show spinner immediately, got \(spinTitle)")
                AppLog.write("smoke sidecar immediate feedback title=\(spinTitle)")
                self.sidecarSpinTimer?.invalidate()
                self.sidecarSpinTimer = nil
                self.sidecarStatus = SidecarStatus.load(from: self.sidecarStateURL)
                self.updateSidecarButton(animated: false)
            }
            // 真实可见性：截图实体 Touch Bar，检查关闭钮之后、Control Strip 之前的中间区域
            // 是否有模块像素。视图有 window、有坐标都不等于系统模态真的挂上了内容。
            self.captureAndCheckRealTouchBar(stage: "smoke")
            AppLog.write("smoke test complete")
            NSApp.terminate(nil)
        }
    }

    func runStylePreviews() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 390))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let flow = PowerFlowView()
        flow.metrics = .preview
        container.addSubview(flow)
        for (index, style) in PowerFlowStyle.allCases.enumerated() {
            flow.style = style
            flow.startAnimating()
            renderPreview(container, name: "powerflow-style-\(style.rawValue)")
            AppLog.write("style preview \(index + 1)/\(PowerFlowStyle.allCases.count): \(style.rawValue)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    func runPowerFlowAnimationPreview() {
        // Design-option renders: the same data-driven renderer at two
        // structure scales so the reference can be compared 1:1 before we
        // commit to the final layout.
        for (name, structure) in [
            ("powerflow-option-reference", FrostedPowerFlowView.Structure.reference),
            ("powerflow-option-bold", FrostedPowerFlowView.Structure.bold)
        ] {
            let option = FrostedPowerFlowView()
            option.appearance = NSAppearance(named: .darkAqua)
            option.structure = structure
            option.metrics = .preview
            renderPreview(option, name: name)
        }

        let flow = FrostedPowerFlowView()
        flow.appearance = NSAppearance(named: .darkAqua)
        flow.metrics = .preview
        for previewFrame in 0..<24 {
            flow.setAnimationFrameForPreview(previewFrame * 5)
            renderPreview(
                flow,
                name: String(format: "power-flow-animation-%02d", previewFrame)
            )
        }
        let dynamicFlow = FrostedPowerFlowView()
        dynamicFlow.appearance = NSAppearance(named: .darkAqua)
        dynamicFlow.metrics = .previewDynamicHierarchy
        for previewFrame in 0..<8 {
            dynamicFlow.setAnimationFrameForPreview(previewFrame * 12)
            renderPreview(
                dynamicFlow,
                name: String(format: "power-flow-dynamic-animation-%02d", previewFrame)
            )
        }
        renderPowerFlowAnimationSequence(
            metrics: .previewCompactLowBatteryCharging,
            appearance: NSAppearance(named: .aqua),
            name: "power-flow-compact-low-battery-animation",
            frameCount: 18,
            frameStep: 6
        )
        renderPowerFlowAnimationSequence(
            metrics: .previewDynamicHierarchy,
            appearance: NSAppearance(named: .aqua),
            name: "power-flow-underpowered-hierarchy-animation",
            frameCount: 18,
            frameStep: 6
        )
        renderPowerFlowAnimationSequence(
            metrics: .previewInternalBreakdown,
            appearance: NSAppearance(named: .aqua),
            name: "power-flow-internal-breakdown-animation",
            frameCount: 36,
            frameStep: 3
        )
        for (name, metrics) in [
            ("power-flow-state-charging", SystemMetrics.preview),
            ("power-flow-state-battery-idle", SystemMetrics.previewBatteryIdle),
            ("power-flow-state-battery-discharging", SystemMetrics.previewBatteryDischarging),
            ("power-flow-state-dynamic-hierarchy", SystemMetrics.previewDynamicHierarchy),
            ("power-flow-state-compact-low-battery", SystemMetrics.previewCompactLowBatteryCharging),
            ("power-flow-state-single-device", SystemMetrics.previewSingleOutput),
            ("power-flow-state-internal-breakdown", SystemMetrics.previewInternalBreakdown),
            ("power-flow-state-one-device-missing", SystemMetrics.previewOneDeviceMissing),
            ("power-flow-state-battery-only", SystemMetrics.previewWithoutOutputs)
        ] {
            let statePreview = FrostedPowerFlowView()
            statePreview.appearance = NSAppearance(named: .darkAqua)
            statePreview.metrics = metrics
            renderPreview(statePreview, name: name)
        }
        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua)
        ] {
            let statePreview = FrostedPowerFlowView()
            statePreview.appearance = NSAppearance(named: appearanceName)
            statePreview.metrics = .preview
            renderPreview(statePreview, name: "power-flow-state-charging-\(name)")
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: .preview,
                    appearance: NSAppearance(named: appearanceName)
                ),
                name: "power-flow-menu-material-\(name)"
            )
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: .previewCompactReference,
                    appearance: NSAppearance(named: appearanceName)
                ),
                name: "power-flow-compact-menu-material-\(name)"
            )
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: .previewBatteryIdle,
                    appearance: NSAppearance(named: appearanceName)
                ),
                name: "power-flow-battery-idle-menu-material-\(name)"
            )
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: .previewCompactLowBatteryCharging,
                    appearance: NSAppearance(named: appearanceName)
                ),
                name: "power-flow-compact-low-battery-menu-material-\(name)"
            )
        }
        for (name, metrics) in [
            ("one", SystemMetrics.previewSingleOutput),
            ("two", SystemMetrics.previewOneDeviceMissing),
            ("three", SystemMetrics.preview)
        ] {
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: metrics,
                    appearance: NSAppearance(named: .aqua)
                ),
                name: "power-flow-device-count-\(name)-light"
            )
        }
        renderPreview(
            makePowerFlowMaterialPreview(
                metrics: .previewDynamicHierarchy,
                appearance: NSAppearance(named: .aqua)
            ),
            name: "power-flow-dynamic-hierarchy-light"
        )
        renderPreview(
            makePowerFlowMaterialPreview(
                metrics: .previewDynamicHierarchy,
                appearance: NSAppearance(named: .darkAqua)
            ),
            name: "power-flow-dynamic-hierarchy-dark"
        )
        renderPreview(
            makePowerFlowMaterialPreview(
                metrics: .previewInternalBreakdown,
                appearance: NSAppearance(named: .aqua)
            ),
            name: "power-flow-internal-breakdown-light"
        )
        renderPreview(
            makePowerFlowMaterialPreview(
                metrics: .previewInternalBreakdown,
                appearance: NSAppearance(named: .darkAqua)
            ),
            name: "power-flow-internal-breakdown-dark"
        )
        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua)
        ] {
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: .previewLocalAndExternalBreakdown,
                    appearance: NSAppearance(named: appearanceName)
                ),
                name: "power-flow-local-external-summary-\(name)"
            )
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func runGreenFlowAnimationVariantPreviews() {
        for style in FlowAnimationStyle.allCases {
            renderPowerFlowAnimationSequence(
                metrics: .previewLocalAndExternalBreakdown,
                appearance: NSAppearance(named: .aqua),
                name: "power-flow-green-\(style.rawValue)",
                frameCount: 36,
                frameStep: 3,
                animationStyle: style
            )
            renderPreview(
                makePowerFlowMaterialPreview(
                    metrics: .previewLocalAndExternalBreakdown,
                    appearance: NSAppearance(named: .aqua),
                    animationFrame: 24,
                    animationStyle: style
                ),
                name: "power-flow-green-\(style.rawValue)-still"
            )
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func runLivePowerTelemetryProbe() {
        Task { [weak self] in
            _ = await SystemMetricsReader.fetch()
            try? await Task.sleep(for: .seconds(1.15))
            let metrics = await SystemMetricsReader.fetch()
            guard let self else { return }
            let cpu = metrics.cpuWatts.map { String(format: "%.3f W", $0) } ?? "unavailable"
            let gpu = metrics.gpuWatts.map { String(format: "%.3f W", $0) } ?? "unavailable"
            let fans = metrics.fanRPMs.map { String(format: "%.0f", $0) }.joined(separator: ",")
            let batteryTemperature = metrics.batteryTemperature.map {
                String(format: "%.2f C", $0)
            } ?? "unavailable"
            let gpuTemperature = metrics.gpuTemperature.map {
                String(format: "%.2f C", $0)
            } ?? "unavailable"
            let processes = metrics.processPower.map {
                "\($0.name):\(String(format: "%.4f", $0.billedWatts))W"
            }.joined(separator: ",")
            AppLog.write("power telemetry cpu=\(cpu) gpu=\(gpu) fanRPM=[\(fans)] batteryTemp=\(batteryTemperature) gpuTemp=\(gpuTemperature) billedProcesses=[\(processes)]")
            self.renderPreview(
                self.makePowerFlowMaterialPreview(
                    metrics: metrics,
                    appearance: NSAppearance(named: .aqua)
                ),
                name: "power-flow-live-hardware-breakdown-light"
            )
            NSApp.terminate(nil)
        }
    }

    /// Headless end-to-end check for the panel's charge policy: applies
    /// "优先充电" (full charge), "负载均衡" (80% hold), and — when the
    /// discharge helper is installed — "优先放电" (charger cut), logging the
    /// PowerUI/SMC read-back and the live battery direction at each step.
    func runChargingLimitProbe() {
        Task { [weak self] in
            let controller = ChargingLimitController.shared
            let adapter = AdapterDischargeController.shared
            controller.refreshSnapshot()
            adapter.refresh()
            AppLog.write(
                "charging-limit probe start supported=\(controller.snapshot.isSupported) enabled=\(controller.snapshot.isEnabled) limit=\(controller.snapshot.limitPercent.map(String.init) ?? "nil") helperInstalled=\(adapter.helperInstalled) chieCut=\(adapter.isCut)"
            )
            guard controller.snapshot.isSupported else {
                AppLog.write("charging-limit probe abort: unsupported")
                NSApp.terminate(nil)
                return
            }

            PowerFlowPolicyStore.current = .charging
            let chargingMetrics = await SystemMetricsReader.fetch()
            controller.update(
                policy: .charging,
                metrics: chargingMetrics,
                userInitiated: true
            )
            try? await Task.sleep(for: .seconds(2))
            controller.refreshSnapshot()
            let afterCharging = controller.snapshot.limitPercent.map(String.init) ?? "nil"
            try? await Task.sleep(for: .seconds(10))
            let chargingSample = await SystemMetricsReader.fetch()
            let chargingWatts = chargingSample.batteryWatts.map {
                String(format: "%.2f", $0)
            } ?? "nil"
            AppLog.write(
                "charging-limit probe charging step: systemLimit=\(afterCharging) batteryWatts=\(chargingWatts) percent=\(chargingSample.batteryPercent.map(String.init) ?? "nil")"
            )
            self?.renderPreview(
                self?.makePowerFlowMaterialPreview(
                    metrics: chargingSample,
                    appearance: NSAppearance(named: .aqua)
                ) ?? NSView(),
                name: "power-flow-charging-policy-light"
            )

            PowerFlowPolicyStore.current = .balanced
            controller.update(
                policy: .balanced,
                metrics: chargingSample,
                userInitiated: true
            )
            try? await Task.sleep(for: .seconds(2))
            controller.refreshSnapshot()
            let afterBalanced = controller.snapshot.limitPercent.map(String.init) ?? "nil"
            try? await Task.sleep(for: .seconds(8))
            let balancedSample = await SystemMetricsReader.fetch()
            let balancedWatts = balancedSample.batteryWatts.map {
                String(format: "%.2f", $0)
            } ?? "nil"
            AppLog.write(
                "charging-limit probe balanced step: systemLimit=\(afterBalanced) batteryWatts=\(balancedWatts) percent=\(balancedSample.batteryPercent.map(String.init) ?? "nil")"
            )
            self?.renderPreview(
                self?.makePowerFlowMaterialPreview(
                    metrics: balancedSample,
                    appearance: NSAppearance(named: .darkAqua)
                ) ?? NSView(),
                name: "power-flow-balanced-policy-dark"
            )

            // Optional: exercise the privileged discharge path when the
            // helper has been installed; otherwise report and continue.
            adapter.refresh()
            if adapter.helperInstalled {
                PowerFlowPolicyStore.current = .discharging
                adapter.handlePolicySelection(.discharging)
                try? await Task.sleep(for: .seconds(4))
                adapter.refresh()
                let cutState = adapter.isCut
                let dischargeSample = await SystemMetricsReader.fetch()
                let dischargeWatts = dischargeSample.batteryWatts.map {
                    String(format: "%.2f", $0)
                } ?? "nil"
                AppLog.write(
                    "charging-limit probe discharge step: chieCut=\(cutState) batteryWatts=\(dischargeWatts) percent=\(dischargeSample.batteryPercent.map(String.init) ?? "nil") error=\(adapter.lastError ?? "nil")"
                )
                self?.renderPreview(
                    self?.makePowerFlowMaterialPreview(
                        metrics: dischargeSample,
                        appearance: NSAppearance(named: .darkAqua)
                    ) ?? NSView(),
                    name: "power-flow-discharge-policy-dark"
                )
                PowerFlowPolicyStore.current = .balanced
                adapter.handlePolicySelection(.balanced)
                try? await Task.sleep(for: .seconds(3))
                adapter.refresh()
                AppLog.write(
                    "charging-limit probe discharge restore: chieCut=\(adapter.isCut)"
                )
            } else {
                AppLog.write(
                    "charging-limit probe discharge step skipped: helper not installed"
                )
            }

            // Leave the machine in the standing balanced state.
            controller.update(
                policy: PowerFlowPolicyStore.current,
                metrics: balancedSample,
                userInitiated: true
            )
            AppLog.write(
                "charging-limit probe done finalLimit=\(controller.snapshot.limitPercent.map(String.init) ?? "nil")"
            )
            NSApp.terminate(nil)
        }
    }

    /// Headless entry for the same install path the settings menu uses.
    func runInstallPowerHelperProbe() {
        Task {
            let controller = AdapterDischargeController.shared
            let ok = await controller.installHelper()
            AppLog.write(
                "install-helper probe ok=\(ok) installed=\(controller.helperInstalled) lastError=\(controller.lastError ?? "nil")"
            )
            NSApp.terminate(nil)
        }
    }

    /// 仅用于人工验收真实菜单；不运行其它会改布局或随航连接的 smoke 操作。
    func runMenuInteractionPreview() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Control Bar 菜单交互验收"
        let openButton = NSButton(title: "展开菜单", target: statusItem.button,
                                  action: #selector(NSButton.performClick(_:)))
        openButton.frame = NSRect(x: 140, y: 60, width: 120, height: 32)
        window.contentView?.addSubview(openButton)
        window.center()
        window.makeKeyAndOrderFront(nil)
        menuPreviewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        // 定时触发真实标题按钮，验证菜单跟踪期间的展开与收起。
        for (delay, title) in [(4.0, "剪贴板"), (6.0, "Touch Bar 设置"), (8.0, "整机功率")] {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mainMenuIsOpen,
                          let header = self.statusItem.menu?.items.first(where: { $0.title == title })?.view,
                          let button = header.subviews.compactMap({ $0 as? NSButton }).first else { return }
                    button.performClick(nil)
                    AppLog.write("menu inline preview clicked=\(title) open=\(self.mainMenuIsOpen) expanded=\(self.expandedMenuSections.sorted())")
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        let badgeTimer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mainMenuIsOpen,
                      let header = self.statusItem.menu?.items.first(where: { $0.title == "剪贴板" })?.view,
                      let badge = header.subviews.flatMap({ $0.subviews })
                        .compactMap({ $0 as? MenuSummaryBadgeView }).first else { return }
                AppLog.write("menu summary preview badge=\(badge.fullText) action=\(String(describing: badge.badge.action))")
                badge.performPress()
            }
        }
        RunLoop.main.add(badgeTimer, forMode: .eventTracking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    /// 菜单打开延迟探针：首帧不得同步读取硬件，后台采样应随后更新功率视图。
    func runMenuOpenProbe() {
        let argumentIndex = CommandLine.arguments.firstIndex(of: "--menu-open-probe")
        let delay: Double = {
            guard let argumentIndex,
                  CommandLine.arguments.indices.contains(argumentIndex + 1),
                  let value = Double(CommandLine.arguments[argumentIndex + 1]) else {
                return 3
            }
            return value
        }()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let menu = self.statusItem.menu else { return }
            // Force the cold state: the panel exists but no metrics ever
            // landed in it, which is what an immediate first menu open sees.
            self.lastPanelMetricsAt = nil
            self.systemMetrics = .unavailable
            self.powerFlowView?.metrics = .unavailable
            let coldWatts = self.powerFlowView?.metrics.systemWatts
                .map { String(format: "%.2f", $0) } ?? "nil"
            if let panel = self.powerFlowView {
                self.renderPreview(panel, name: "menu-open-probe-cold")
            }
            let started = CACurrentMediaTime()
            self.menuWillOpen(menu)
            let syncMilliseconds = (CACurrentMediaTime() - started) * 1_000
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                let after = self.powerFlowView?.metrics
                let afterWatts = after?.systemWatts.map { String(format: "%.2f", $0) } ?? "nil"
                AppLog.write(
                    "menu-open-probe coldWatts=\(coldWatts) asyncWatts=\(afterWatts) external=\(after?.externalPower ?? false) syncMs=\(String(format: "%.1f", syncMilliseconds))"
                )
                if let panel = self.powerFlowView {
                    self.renderPreview(panel, name: "menu-open-probe-after")
                }
                self.menuDidClose(menu)
                NSApp.terminate(nil)
            }
        }
    }

    /// Headless renders for the charger/cable rows and the detail page, in
    /// both appearances, using live hardware when available and the bundled
    /// fixture otherwise.
    func runInterfaceSpecsPreviews() {
        let useFixture = CommandLine.arguments.contains("--interface-specs-fixture")
        let liveSpecs = InterfaceSpecsReader.read()
        let specs = (useFixture || !liveSpecs.hasPanelContent) ? .preview : liveSpecs
        let liveMetrics = SystemMetricsReader.read()
        let metrics = (useFixture || !liveMetrics.externalPower)
            ? SystemMetrics.previewUnderpowered
            : liveMetrics
        AppLog.write(
            "interface-specs preview useFixture=\(useFixture) charger=\(specs.charger?.summary ?? "nil") ports=\(specs.ports.count) underpowered=\(PowerDiagnosis.isUnderpowered(metrics))"
        )
        for (name, appearance) in [
            ("interface-panel-light", NSAppearance(named: .aqua)),
            ("interface-panel-dark", NSAppearance(named: .darkAqua)),
        ] {
            let panel = PowerFlowPanelView()
            panel.appearance = appearance
            panel.metrics = metrics
            panel.interfaceSpecs = specs
            renderPreview(panel, name: name)
        }
        for (name, appearance) in [
            ("interface-detail-light", NSAppearance(named: .aqua)),
            ("interface-detail-dark", NSAppearance(named: .darkAqua)),
        ] {
            let view = InterfaceDetailContent.makeView(specs: specs, metrics: metrics)
            view.appearance = appearance
            let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 524, height: 760)))
            container.appearance = appearance
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
            container.layoutSubtreeIfNeeded()
            renderPreview(container, name: name)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// Headless render of the real inline menu headers. This validates the
    /// AppKit view geometry that NSMenu lays out, not a hand-built mock.
    func runInlineMenuPreview() {
        NSApp.setActivationPolicy(.regular)
        let normal = NSMenu()
        let normalSections = InlineMenuSections(menu: normal)
        let expanded = NSMenu()
        let expandedSections = InlineMenuSections(menu: expanded, expanded: ["sidecar"])

        let entries: [(String, String, [MenuSummaryBadge], NSMenu)] = [
            ("整机功率", "bolt.fill", [
                .init(title: "整机", value: "22.5 W", symbol: "bolt.fill", tone: .orange, action: .showSystemDetails),
                .init(title: "内存", value: "67%", symbol: "memorychip", tone: .purple, action: .showSystemDetails)
            ], NSMenu()),
            ("服务", "server.rack", [
                .init(title: "常驻", value: "4/4 运行", symbol: "server.rack", tone: .green, action: .openServiceLogs),
                .init(title: "定时", value: "0/3 运行", symbol: "clock", tone: .secondary, action: .openServiceLogs)
            ], NSMenu()),
            ("随航与通用控制", "ipad.and.iphone", [
                .init(title: "CTHPAD", value: "已连接", symbol: "ipad.landscape", tone: .green, action: .toggleSidecar)
            ], NSMenu()),
            ("AI coding", "curlybraces.square.fill", [
                .init(title: "Codex Plus", value: "余 40%", symbol: "creditcard", progress: 0.4, clientID: "codex", action: .openUsage("codex")),
                .init(title: "Codex Free", value: "余 64%", symbol: "creditcard", progress: 0.64, clientID: "codex"),
                .init(title: "WorkBuddy Free", value: "credits 1414", symbol: "creditcard", clientID: "workbuddy"),
                .init(title: "ZCode", value: "余 100%", symbol: "creditcard", progress: 1, clientID: "zcode")
            ], NSMenu()),
            ("剪贴板", "doc.on.clipboard", [
                .init(title: "", value: "8 条 · 记录中", symbol: "doc.on.clipboard", tone: .green, action: .openClipboard)
            ], NSMenu()),
            ("Touch Bar 设置", "slider.horizontal.3", [
                .init(title: "外观", value: "跟随系统", symbol: "circle.lefthalf.filled", tone: .purple, action: .openSettings),
                .init(title: "Touch Bar", value: "自定义", symbol: "slider.horizontal.3", action: .openSettings)
            ], NSMenu())
        ]

        var heights: [CGFloat] = []
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.0, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.0)
            let submenu = entry.3
            if index == 2 {
                submenu.addItem(NSMenuItem(title: "切换随航", action: nil, keyEquivalent: ""))
                submenu.addItem(NSMenuItem(title: "修复随航黑屏并重新连接", action: nil, keyEquivalent: ""))
                submenu.addItem(NSMenuItem(title: "控制环境修复", action: nil, keyEquivalent: ""))
            } else if index == 1 {
                submenu.addItem(NSMenuItem(title: "常驻任务 4/4", action: nil, keyEquivalent: ""))
                submenu.addItem(NSMenuItem(title: "定时任务 0/3", action: nil, keyEquivalent: ""))
            } else {
                submenu.addItem(NSMenuItem(title: "示例操作", action: nil, keyEquivalent: ""))
            }
            item.submenu = submenu
            normalSections.append(item, id: "item-\(index)", summary: "摘要", badges: entry.2)
            heights.append(item.view?.frame.height ?? 0)
        }
        // 展开态：单独构建，避免与收起态共用 NSMenuItem 造成重复挂载。
        let expandedItem = NSMenuItem(title: "随航与通用控制", action: nil, keyEquivalent: "")
        expandedItem.image = NSImage(systemSymbolName: "ipad.and.iphone", accessibilityDescription: nil)
        let expandedMenu = NSMenu()
        expandedMenu.addItem(NSMenuItem(title: "切换随航", action: nil, keyEquivalent: ""))
        expandedMenu.addItem(NSMenuItem(title: "修复随航黑屏并重新连接", action: nil, keyEquivalent: ""))
        expandedItem.submenu = expandedMenu
        expandedSections.append(expandedItem, id: "sidecar",
                                summary: "已连接 · CTHPAD",
                                badges: [.init(title: "CTHPAD", value: "已连接", symbol: "ipad.landscape", tone: .green)])

        let width: CGFloat = 390
        let padding: CGFloat = 10
        let expandedHeight = expandedItem.view?.frame.height ?? 0
        let height = heights.reduce(16) { $0 + $1 + 6 } + expandedHeight + padding + 28
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        var y: CGFloat = 10
        for item in normal.items.reversed() where item.view != nil {
            guard let view = item.view else { continue }
            view.autoresizingMask = []
            item.view = nil
            canvas.addSubview(view)
            view.frame = NSRect(x: 0, y: y, width: width, height: view.frame.height)
            view.layoutSubtreeIfNeeded()
            y += view.frame.height + 6
        }
        if let expandedView = expandedItem.view {
            expandedView.autoresizingMask = []
            expandedItem.view = nil
            canvas.addSubview(expandedView)
            expandedView.frame = NSRect(x: 0, y: y + 4, width: width, height: expandedView.frame.height)
            expandedView.layoutSubtreeIfNeeded()
            y += expandedView.frame.height + 6
            for child in expandedMenu.items {
                child.view = nil
            }
        }
        AppLog.write("inline menu preview heights=\(heights) collapsedTotal=\(height) expanded=\(expandedHeight)")
        if let rep = renderedBitmap(for: canvas), let data = rep.representation(using: .png, properties: [:]) {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/CodexTouchBarNative-inline-menu-preview.png")
            try? data.write(to: url, options: .atomic)
            AppLog.write("inline menu preview=\(url.path)")
        }
    }

    private func renderPreview(_ view: NSView, name: String) {
        guard let representation = renderedBitmap(for: view) else {
            AppLog.write("preview \(name) failed: bitmap")
            return
        }
        guard let data = representation.representation(using: .png, properties: [:]) else {
            AppLog.write("preview \(name) failed: png")
            return
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexTouchBarNative-\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            AppLog.write("preview \(name)=\(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        } catch {
            AppLog.write("preview \(name) failed: write")
        }
    }

    private func renderedBitmap(for view: NSView) -> NSBitmapImageRep? {
        // NSStackView 等没有固定 frame 的视图，bounds 可能为 0，先给一个兜底布局尺寸。
        if view.bounds.width <= 0 || view.bounds.height <= 0 {
            view.frame = NSRect(x: 0, y: 0, width: 700, height: 30)
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private func renderPowerFlowAnimationSequence(
        metrics: SystemMetrics,
        appearance: NSAppearance?,
        name: String,
        frameCount: Int,
        frameStep: Int,
        animationStyle: FlowAnimationStyle = .auroraPulse
    ) {
        let gifURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexTouchBarNative-\(name).gif")
        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            AppLog.write("preview \(name) failed: gif destination")
            return
        }
        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ] as CFDictionary
        )
        for index in 0..<frameCount {
            let view = makePowerFlowMaterialPreview(
                metrics: metrics,
                appearance: appearance,
                animationFrame: index * frameStep,
                animationStyle: animationStyle
            )
            guard let representation = renderedBitmap(for: view),
                  let image = representation.cgImage else {
                continue
            }
            let frameName = String(format: "%@-%02d", name, index)
            if let data = representation.representation(using: .png, properties: [:]) {
                let frameURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/CodexTouchBarNative-\(frameName).png")
                try? data.write(to: frameURL, options: .atomic)
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: 0.10,
                        kCGImagePropertyGIFUnclampedDelayTime: 0.10
                    ]
                ] as CFDictionary
            )
        }
        if CGImageDestinationFinalize(destination) {
            AppLog.write("preview \(name)=\(gifURL.path) animated gif")
        } else {
            AppLog.write("preview \(name) failed: gif finalize")
        }
    }

    private func renderSidecarPreview(_ status: SidecarStatus, name: String) {
        sidecarStatus = status
        sidecarFrame = 0
        let view = makeMainContainer()
        updateSidecarButton(animated: false)
        renderPreview(view, name: name)
    }

    /// `--render-main` 入口：渲染当前主层预览到 PNG 后退出。
    func runMainRender() {
        AppLog.write("render-main start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.renderPreview(self.makeMainContainer(), name: "main-current")
            AppLog.write("render-main done")
            self.stop()
            exit(EXIT_SUCCESS)
        }
    }

    /// 用系统 `screencapture -b` 截实体 Touch Bar，并核对中间模块区域不是空白。
    /// 这是唯一能区分“视图存在”与“系统模态真的显示内容”的检查。
    @discardableResult
    private func captureAndCheckRealTouchBar(stage: String) -> Bool {
        let path = NSTemporaryDirectory() + "barcontrol-touchbar-\(stage).png"
        try? FileManager.default.removeItem(atPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-b", "-x", path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.write("touch bar capture failed stage=\(stage): \(error.localizedDescription)")
            return false
        }
        guard process.terminationStatus == 0,
              let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            AppLog.write("touch bar capture unavailable stage=\(stage) status=\(process.terminationStatus)")
            return false
        }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 中间内容区：跳过左侧关闭钮（约 80pt）与右侧 Control Strip（约 260pt）。
        let scale = CGFloat(width) / Self.fallbackModalWidth
        let startX = min(width - 1, Int(80 * scale))
        let endX = max(startX + 1, Int(CGFloat(width) - 260 * scale))
        var brightPixels = 0
        for y in 0..<height {
            for x in startX..<endX {
                let offset = (y * width + x) * 4
                let luma = Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                if luma > 90 { brightPixels += 1 }
            }
        }
        let visible = brightPixels > 400
        AppLog.write(
            "touch bar visual stage=\(stage) size=\(width)x\(height) contentBright=\(brightPixels) visible=\(visible)"
        )
        return visible
    }

    /// 区分“系统切到原生 F1–F12”（整条全是有内容的键）和真正的空白故障。
    private func classifyRealTouchBar(stage: String) -> (captured: Bool, hasContent: Bool, nativeKeys: Bool) {
        // 重新安装后 TCC 可能把屏幕录制权限收回，screencapture 会静默输出全黑帧。
        // 没有权限就不做视觉判断，避免把黑帧当成“内容为空”触发无意义重绑。
        guard CGPreflightScreenCaptureAccess() else {
            if !loggedCaptureBlocked {
                loggedCaptureBlocked = true
                AppLog.write("touch bar capture blocked: screen recording permission missing")
            }
            return (false, false, false)
        }
        let path = NSTemporaryDirectory() + "barcontrol-touchbar-\(stage).png"
        try? FileManager.default.removeItem(atPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-b", "-x", path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, false, false)
        }
        guard process.terminationStatus == 0,
              let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (false, false, false)
        }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (false, false, false) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = CGFloat(width) / Self.fallbackModalWidth
        let startX = min(width - 1, Int(80 * scale))
        let endX = max(startX + 1, Int(CGFloat(width) - 260 * scale))
        // 右侧固定区必须能截到亮点。整帧全黑说明 screencapture 没拿到触控栏
        // （无屏幕录制权限、触控栏休眠等），这时不能当成“内容为空”去自愈。
        let stripStartX = max(0, Int(CGFloat(width) - 220 * scale))
        var contentPixels = 0
        var stripPixels = 0
        // 把中间区分成 12 段，按“有像素的段数”判断是 F1–F12 还是半截空白。
        var occupiedSegments = Set<Int>()
        let segmentCount = 12
        let segmentWidth = max(1, (endX - startX) / segmentCount)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                guard luma > 90 else { continue }
                if x >= stripStartX { stripPixels += 1 }
                if x >= startX && x < endX {
                    contentPixels += 1
                    occupiedSegments.insert(min(segmentCount - 1, (x - startX) / segmentWidth))
                }
            }
        }
        guard stripPixels > 30 else {
            AppLog.write(
                "touch bar capture invalid stage=\(stage) size=\(width)x\(height) stripBright=\(stripPixels)"
            )
            return (false, false, false)
        }
        let hasContent = contentPixels > 400
        let nativeKeys = occupiedSegments.count >= 9
        AppLog.write(
            "touch bar visual stage=\(stage) size=\(width)x\(height) contentBright=\(contentPixels) segments=\(occupiedSegments.count) nativeKeys=\(nativeKeys) visible=\(hasContent && !nativeKeys)"
        )
        return (true, hasContent, nativeKeys)
    }

    private func makePowerFlowMaterialPreview(
        metrics: SystemMetrics,
        appearance: NSAppearance? = nil,
        animationFrame: Int? = nil,
        animationStyle: FlowAnimationStyle = .auroraPulse
    ) -> NSView {
        let panel = PowerFlowPanelView()
        panel.appearance = appearance
        panel.metrics = metrics
        panel.setAnimationStyleForPreview(animationStyle)
        if let animationFrame {
            panel.setAnimationFrameForPreview(animationFrame)
        }
        panel.layoutSubtreeIfNeeded()
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.appearance = appearance
        container.wantsLayer = true
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        container.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.11, alpha: 1)
            : NSColor(calibratedWhite: 0.86, alpha: 1)
        ).cgColor
        panel.frame.origin = .zero
        container.addSubview(panel)
        return container
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        didCreateVisibleItem = true
        AppLog.write("make item \(identifier.rawValue)")
        // NSTouchBar delegate 契约：同一 identifier 必须返回稳定实例，绝不能每次新建。
        if let cached = touchBarItems[identifier.rawValue] {
            return cached
        }
        let item: NSTouchBarItem
        switch identifier {
        case Item.mainContainer:
            let modal = NSCustomTouchBarItem(identifier: identifier)
            modal.visibilityPriority = .high
            modal.view = makeMainContainerItem()
            item = modal
        case Item.detailContainer:
            let modal = NSCustomTouchBarItem(identifier: identifier)
            modal.visibilityPriority = .high
            modal.view = makeDetailContainer()
            item = modal
        case Item.usageContainer:
            let modal = NSCustomTouchBarItem(identifier: identifier)
            modal.visibilityPriority = .high
            modal.view = makeUsageContainer()
            item = modal
        case Item.systemContainer:
            let modal = NSCustomTouchBarItem(identifier: identifier)
            modal.visibilityPriority = .high
            modal.view = makeSystemContainer()
            item = modal
        case Item.clipboardContainer:
            let modal = NSCustomTouchBarItem(identifier: identifier)
            modal.visibilityPriority = .high
            modal.view = makeClipboardContainer()
            item = modal
        default:
            return nil
        }
        touchBarItems[identifier.rawValue] = item
        return item
    }

    /// 主层单容器 item：内含 4 个模块按钮 + 各槽位的空槽占位，全部手动布局。
    /// 整个主层作为一个 item 呈现，present 时只挂载一次，模块同时出现、无逐个挂载卡顿。
    private func makeMainContainerItem() -> NSView {
        let container = ModuleItemView(width: Self.fallbackModalWidth)
        container.appearance = NSAppearance(named: .darkAqua)
        mainContainerView = container
        mainEmptySlotViews = [:]

        let sidecar = pillButton(
            title: effectiveTitle(for: .sidecar) ?? "随航 ⇄ 通用控制",
            symbol: storedIcon(for: .sidecar).isEmpty ? "ipad.and.iphone" : storedIcon(for: .sidecar),
            action: #selector(openSidecar),
            background: sidecarColor
        )
        sidecarButton = sidecar
        container.addSubview(sidecar)

        let aiCoding = pillButton(
            title: effectiveTitle(for: .aiCoding) ?? "AI coding",
            symbol: storedIcon(for: .aiCoding).isEmpty ? "curlybraces.square.fill" : storedIcon(for: .aiCoding),
            action: #selector(showDetails),
            background: NSColor(calibratedRed: 48 / 255, green: 66 / 255, blue: 120 / 255, alpha: 1)
        )
        aiCodingButton = aiCoding
        let activityMark = AIActivityMarkView(frame: .zero)
        activityMark.activeCount = snapshot.activeCount
        aiActivityMark = activityMark
        aiCoding.addSubview(activityMark)
        container.addSubview(aiCoding)

        let systemMonitor = PowerRunnerButton(
            target: self,
            action: #selector(showSystemDetails),
            style: powerRunnerStyle
        )
        systemMonitor.onInteraction = { [weak self] in self?.noteTouchBarInteraction() }
        systemMonitor.toolTip = systemMonitorToolTip
        systemMonitorButton = systemMonitor
        container.addSubview(systemMonitor)

        let clipboard = pillButton(
            title: effectiveTitle(for: .clipboard) ?? "剪贴板",
            symbol: storedIcon(for: .clipboard).isEmpty ? "doc.on.clipboard" : storedIcon(for: .clipboard),
            action: #selector(showClipboardHistory),
            background: NSColor(calibratedRed: 47 / 255, green: 76 / 255, blue: 72 / 255, alpha: 1)
        )
        clipboardButton = clipboard
        container.addSubview(clipboard)

        let keyboardLock = pillButton(
            title: "",
            symbol: keyboardLockPresentation.symbol,
            action: #selector(toggleKeyboardLock),
            background: keyboardLockColor
        )
        keyboardLockButton = keyboardLock
        lastKeyboardLockState = keyboardLockPresentation.locked
        container.addSubview(keyboardLock)

        let effective = effectiveSlots
        for index in 0..<MainComponent.slotCount where effective.indices.contains(index) && effective[index] == nil {
            let empty = NSView()
            mainEmptySlotViews[index] = empty
            container.addSubview(empty)
        }

        updateMainModuleWidths()
        return container
    }

    /// 把模块按钮包进一个报告固定尺寸（宽×30）的透明容器，容器作为 item 视图。
    /// 系统按 item 视图的 intrinsicContentSize 定尺寸、并会重设子视图 frame——直接把按钮
    /// 当 item 视图（无论约束还是 frame）都会被系统改成 fitting 高度（19 或 40.5）再被
    /// 30pt 窗口裁切，圆角被切掉后看起来就是方块。0.17 的容器 + intrinsic + 子按钮 frame
    /// 从未被改动，因此正常；这里复刻同一机制。
    private func makeTouchBarItemView(_ button: NSView, width: CGFloat) -> NSView {
        button.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        let wrapper = ModuleItemView(width: width)
        wrapper.appearance = NSAppearance(named: .darkAqua)
        wrapper.addSubview(button)
        return wrapper
    }

    /// 主层预览容器（供冒烟测试 renderPreview 渲染，生产主层用独立 item，不走这里）。
    /// 按 componentSlots 顺序水平排布各模块按钮与空槽占位，仅用于渲染，不污染生产弱引用。
    private func makeMainContainer() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        for slot in componentSlots {
            let view: NSView
            let width: CGFloat
            switch slot {
            case .some(.sidecar):
                view = pillButton(title: effectiveTitle(for: .sidecar) ?? "随航 ⇄ 通用控制", symbol: "ipad.and.iphone", action: #selector(openSidecar), background: sidecarColor)
                width = sidecarWidth
            case .some(.aiCoding):
                view = pillButton(title: effectiveTitle(for: .aiCoding) ?? "AI coding", symbol: "curlybraces.square.fill", action: #selector(showDetails), background: NSColor(calibratedRed: 48 / 255, green: 66 / 255, blue: 120 / 255, alpha: 1))
                width = aiCodingWidth
            case .some(.systemMonitor):
                view = PowerRunnerButton(target: self, action: #selector(showSystemDetails), style: powerRunnerStyle)
                width = configuredWidth(for: .systemMonitor)
            case .some(.clipboard):
                view = pillButton(
                    title: effectiveTitle(for: .clipboard) ?? "剪贴板",
                    symbol: "doc.on.clipboard",
                    action: #selector(showClipboardHistory),
                    background: NSColor(calibratedRed: 47 / 255, green: 76 / 255, blue: 72 / 255, alpha: 1)
                )
                width = displayedModuleWidth(for: .clipboard)
            case .some(.keyboardLock):
                view = pillButton(
                    title: "",
                    symbol: keyboardLockPresentation.symbol,
                    action: #selector(toggleKeyboardLock),
                    background: keyboardLockColor
                )
                width = keyboardLockWidth
            case .none:
                let empty = NSView()
                empty.widthAnchor.constraint(equalToConstant: MainComponent.emptySlotWidth).isActive = true
                empty.heightAnchor.constraint(equalToConstant: 30).isActive = true
                stack.addArrangedSubview(empty)
                continue
            }
            // 预览与生产 item 一致：统一宽度与 30 高，保证渲染比例真实。
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            view.heightAnchor.constraint(equalToConstant: 30).isActive = true
            stack.addArrangedSubview(view)
        }
        return stack
    }

    private func makeSystemContainer() -> NSView {
        // 6 张卡片总宽 457，左侧返回键占 40；容器留 8px 右内边距，
        // 否则最后一张气泡会被黑底裁掉。
        let container = FixedTouchBarContainer(width: 505)
        let back = iconButton(
            symbol: "chevron.backward",
            description: "返回主层",
            action: #selector(showMain)
        )
        back.frame = NSRect(x: 0, y: 0, width: 32, height: 30)
        container.addSubview(back)

        let details = SystemDetailStripView()
        details.frame.origin = NSPoint(x: 40, y: 0)
        details.metrics = systemMetrics
        systemDetailView = details
        container.addSubview(details)
        AppLog.write("system detail frames back=\(back.frame) details=\(details.frame)")
        return container
    }

    private func makeDetailContainer() -> NSView {
        let container = FixedTouchBarContainer(width: 730)

        let back = iconButton(
            symbol: "chevron.backward",
            description: "返回主层",
            action: #selector(showMain)
        )
        back.frame = NSRect(x: 0, y: 0, width: 32, height: 30)
        backButton = back
        container.addSubview(back)

        let quota = QuotaView(width: 669)
        quota.frame.origin = NSPoint(x: 40, y: 0)
        quota.update(with: snapshot.limits, platforms: snapshot.platforms, accounts: snapshot.accounts)
        quota.onOpenUsage = { [weak self] key in
            self?.showUsageDetails(key)
        }
        quotaView = quota
        container.addSubview(quota)

        AppLog.write("detail frames back=\(back.frame) quota=\(quota.frame)")
        return container
    }

    private func makeClipboardContainer() -> NSView {
        let container = FixedTouchBarContainer(width: Self.fallbackModalWidth)
        let back = iconButton(
            symbol: "chevron.backward",
            description: "返回主层",
            action: #selector(showMain)
        )
        back.frame = NSRect(x: 0, y: 0, width: 32, height: 30)
        container.addSubview(back)

        let history = ClipboardHistoryStripView(width: Self.fallbackModalWidth - 47)
        history.frame.origin = NSPoint(x: 40, y: 0)
        history.onCopy = { [weak self] entry in
            _ = self?.clipboardHistory.copy(entry)
        }
        history.onInteraction = { [weak self] in self?.noteTouchBarInteraction() }
        history.update(entries: clipboardHistory.entries)
        clipboardHistoryView = history
        container.addSubview(history)
        return container
    }

    private func makeUsageContainer() -> NSView {        let container = FixedTouchBarContainer(width: 730)
        let back = iconButton(
            symbol: "chevron.backward",
            description: "返回 AI coding 账户",
            action: #selector(showDetails)
        )
        back.frame = NSRect(x: 0, y: 0, width: 32, height: 30)
        container.addSubview(back)

        let details = UsageDetailStripView(width: 683)
        details.frame.origin = NSPoint(x: 40, y: 0)
        let accounts = snapshot.accounts ?? []
        details.usage = accounts.first { $0.key == selectedUsageAccountKey } ?? accounts.first
        usageDetailView = details
        container.addSubview(details)
        AppLog.write("usage detail key=\(selectedUsageAccountKey ?? "") frame=\(details.frame)")
        return container
    }

    private func configureTouchBar() {
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = mainIdentifiers
    }

    /// 主层 = 单个容器 item（内含 4 模块 + 空槽，手动布局）。
    /// 用单容器而非多独立 item：present 时只挂载 1 个 item，消除"逐个出现"的卡顿。
    private var mainIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.mainContainer]
    }

    private var detailIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.detailContainer]
    }

    private var usageIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.usageContainer]
    }

    private var systemIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.systemContainer]
    }

    private var clipboardIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.clipboardContainer]
    }

    private func configureMenuBar() {
        guard let button = statusItem.button else { return }
        duoMenuIcon = DuoMenuIcon(button: button)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Bar Control"
        rebuildMenu()
    }

    /// 插拔电源自动切换策略：接上充电器回到负载均衡，拔掉（出门）切到优先放电。
    private var lastKnownExternalPower: Bool?

    @objc private func toggleDeviceAutoReturnRow(_ row: WindowActionRow) {
        let next = !PowerFlowPolicyStore.autoReturnEnabled
        PowerFlowPolicyStore.autoReturnEnabled = next
        row.setSwitchState(on: next, animated: true)
        rebuildMenu()
        AppLog.write("device auto-return=\(next)")
    }

    @objc private func showLowBatteryThresholdMenu(_ row: WindowActionRow) {
        let isMac = row.identifier?.rawValue != "deviceLowThreshold"
        let menu = NSMenu()
        for value in [20, 25, 30, 35, 40, 50] {
            let item = NSMenuItem(
                title: "\(value)%",
                action: #selector(selectLowBatteryThreshold(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = value
            item.representedObject = isMac ? "mac" : "device"
            let current = isMac ? PowerFlowPolicyStore.macLowPercent : PowerFlowPolicyStore.deviceLowPercent
            item.state = current == value ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: row.bounds.width - 80, y: 4), in: row)
    }

    @objc private func selectLowBatteryThreshold(_ sender: NSMenuItem) {
        if (sender.representedObject as? String) == "mac" {
            PowerFlowPolicyStore.macLowPercent = sender.tag
            settingsRows["macLowThreshold"]?.setValueText("\(sender.tag)%", symbol: "laptopcomputer", animated: false)
        } else {
            PowerFlowPolicyStore.deviceLowPercent = sender.tag
            settingsRows["deviceLowThreshold"]?.setValueText("\(sender.tag)%", symbol: "ipad", animated: false)
        }
        AppLog.write(
            "low battery threshold mac=\(PowerFlowPolicyStore.macLowPercent) device=\(PowerFlowPolicyStore.deviceLowPercent)"
        )
    }

    private func reloadComponentSettings() {
        guard let panel = orderPanel else { return }
        panel.contentView = makeComponentSettingsContent()
        reloadSlotPreview()
        reloadOrderRows()
        reloadCustomRows()
    }

    private var lastObservedDeviceBatteryPercent: Int?
    private var lastChargerHintAt = Date.distantPast

    private func applyAutomaticPowerPolicy(for metrics: SystemMetrics) {
        defer { lastKnownExternalPower = metrics.externalPower }
        guard PowerFlowPolicyStore.autoReturnEnabled else { return }
        let priority = PowerFlowPolicy.lowBatteryPriority(
            macBattery: metrics.batteryPercent,
            deviceBattery: metrics.externalBatteryPercent
        )
        if PowerFlowPolicyStore.manualOverride {
            let threshold = PowerFlowPolicyStore.autoReturnThreshold
            let currentDevicePercent = metrics.externalBatteryPercent
            let crossedThreshold = PowerFlowPolicyStore.manualBaseDevicePercent.map { base in
                base < threshold && (currentDevicePercent ?? base) >= threshold
            } ?? false
            let thresholdReturn = PowerFlowPolicyStore.autoReturnEnabled
                && crossedThreshold
                && PowerFlowPolicyStore.current != .balanced
            if priority == .keep, thresholdReturn {
                PowerFlowPolicyStore.manualOverride = false
                PowerFlowPolicyStore.manualBaseDevicePercent = nil
                AppLog.write("power policy manual override cleared: device reached threshold")
            } else if PowerFlowPolicy.shouldHoldManualSelection(manualOverride: true, priority: priority) {
                return
            } else {
                PowerFlowPolicyStore.manualOverride = false
                PowerFlowPolicyStore.manualBaseDevicePercent = nil
                AppLog.write("power policy manual override cleared by auto rule")
            }
        }
        let next: PowerFlowPolicy
        let reason: String
        switch priority {
        case .bothLow:
            next = .charging
            reason = "both low → prioritize Mac"
        case .charging:
            next = .charging
            reason = "Mac \(metrics.batteryPercent ?? 0)% below \(PowerFlowPolicyStore.macLowPercent)%"
        case .discharging:
            next = .discharging
            reason = "device \(metrics.externalBatteryPercent ?? 0)% below \(PowerFlowPolicyStore.deviceLowPercent)%"
        case .keep:
            guard PowerFlowPolicyStore.current != .balanced else { return }
            next = .balanced
            reason = "back above thresholds"
        }
        let previous = PowerFlowPolicyStore.current
        guard previous != next else { return }
        if PowerNotification.shouldPost(previous: previous, next: next, priority: priority) {
            PowerNotification.post(
                title: "电量都偏低，已优先保本机",
                body: "本机 \(metrics.batteryPercent ?? 0)%，外接设备 \(metrics.externalBatteryPercent ?? 0)%，已切到「优先充电」。"
            )
        }
        PowerFlowPolicyStore.current = next
        powerFlowView?.syncPolicySelection(next)
        ChargingLimitController.shared.update(policy: next, metrics: metrics, userInitiated: false)
        AppLog.write("power policy auto=\(next.title) \(reason)")
    }

    /// 重建菜单栏。四个模块分组按 Touch Bar 主层组件顺序（componentOrder）排列，
    /// 因此移动 Touch Bar 组件顺序时菜单栏分组顺序会同步跟随。
    private func rebuildMenu() {
        guard !mainMenuIsOpen else { return }
        let menu = NSMenu()
        menu.delegate = self
        let sections = InlineMenuSections(menu: menu, expanded: expandedMenuSections)
        sections.onToggle = { [weak self] expanded in
            guard let self else { return }
            self.expandedMenuSections = expanded
            if expanded.contains(MainComponent.systemMonitor.rawValue) {
                self.powerFlowView?.startAnimating()
            } else {
                self.powerFlowView?.stopAnimating()
            }
        }
        sections.onBadgeAction = { [weak self] action in
            self?.performMenuSummaryAction(action)
        }
        inlineMenuSections = sections
        let powerFlow = PowerFlowPanelView()
        powerFlow.onPolicyChange = { [weak self] _ in
            self?.refreshAfterPowerPolicyChange()
        }
        powerFlow.metrics = systemMetrics
        powerFlow.interfaceSpecs = interfaceSpecs
        menu.minimumWidth = max(370, powerFlow.frame.width)
        powerFlowView = powerFlow
        if MainComponent.systemMonitor.isVisibleInMenu {
            let section = PowerMenuSectionView(width: menu.minimumWidth, panel: powerFlow)
            section.controls.onEco = { [weak self] in self?.toggleSystemLowPowerMode() }
            section.onEcoTap = { [weak self] in self?.toggleSystemLowPowerMode() }
            section.onLimitStep = { [weak self] delta in
                guard let self else { return }
                let next = min(100, max(80, PowerFlowPolicyStore.maximumChargePercent + delta))
                guard next != PowerFlowPolicyStore.maximumChargePercent else { return }
                self.setMaximumChargePercent(next)
            }
            section.controls.onStep = { [weak self] delta in
                guard let self else { return }
                let next = min(100, max(80, PowerFlowPolicyStore.maximumChargePercent + delta))
                guard next != PowerFlowPolicyStore.maximumChargePercent else { return }
                self.setMaximumChargePercent(next)
            }
            powerMenuControls = section.controls
            refreshPowerMenuControls()
            let powerItem = NSMenuItem()
            powerItem.view = section
            menu.addItem(powerItem)
            menu.addItem(.separator())
        }

        let windowOpeners: [MainComponent: () -> Void] = [
            .sidecar: openSidecarWindow,
            .clipboard: openClipboardWindow,
        ]
        var menuComponents = componentOrder.filter { $0 != .systemMonitor && $0.isVisibleInMenu }
        if !menuComponents.contains(.keyboardLock) { menuComponents.append(.keyboardLock) }
        let counts = ServiceMonitor.cachedSnapshot
        var scheduledRun = 0, scheduledTotal = 0, residentRun = 0, residentTotal = 0
        let services = ServiceMonitor.services()
        for (service, state) in zip(services, counts.states) {
            if service.isScheduled {
                scheduledTotal += 1; if state == .running { scheduledRun += 1 }
            } else {
                residentTotal += 1; if state == .running { residentRun += 1 }
            }
        }
        // 新电脑没有配置任何服务时，不占用菜单空间；装好后自动出现。
        if !services.isEmpty {
            let serviceRow = ServiceCountsMenuRow(width: menu.minimumWidth)
            serviceRow.update(scheduledRunning: scheduledRun, scheduledTotal: scheduledTotal,
                              residentRunning: residentRun, residentTotal: residentTotal,
                              unknown: counts.states.allSatisfy { $0 == .unknown })
            serviceRow.onPress = { [weak self] in self?.openServicesWindow() }
            let servicesItem = NSMenuItem()
            servicesItem.view = serviceRow
            menu.addItem(servicesItem)
            servicesWindowMenuItem = servicesItem
            menu.addItem(.separator())
        }
        let showClipboard = menuComponents.contains(.clipboard)
        let showKeyboard = menuComponents.contains(.keyboardLock)
        if showClipboard || showKeyboard {
            let pair = ClipboardKeyboardMenuRow(width: menu.minimumWidth,
                                               clipboard: showClipboard, keyboard: showKeyboard)
            pair.onClipboard = { [weak self] in self?.openClipboardWindow() }
            pair.onKeyboard = { [weak self] in self?.toggleKeyboardLock() }
            pair.update(count: clipboardHistory.entries.count, keyboard: keyboardLockPresentation)
            let item = NSMenuItem()
            item.view = pair
            menu.addItem(item)
            compactModuleRow = pair
        }
        menu.addItem(.separator())
        menu.addItem(.separator())

        for component in menuComponents where component != .clipboard && component != .keyboardLock {
            let item = NSMenuItem(title: component.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            if component != .aiCoding {
                item.submenu = makeModuleSubmenu(for: component)
            }
            sections.append(item, id: component.rawValue, summary: menuSummary(for: component),
                            badges: menuBadges(for: component),
                            opensWindow: windowOpeners[component])
        }


        let settingsItem = NSMenuItem(title: "Touch Bar 设置", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "设置")
        sections.append(settingsItem, id: "settings", summary: updateMenuSummary,
                        opensWindow: openSettingsWindow)
        settingsWindowMenuItem = settingsItem

        // “关于”不再放在展开菜单的主模块列表中；设置窗口侧栏仍保留“关于”分类。
        menu.addItem(.separator())
        let yieldItem = NSMenuItem()
        let yieldRow = ApplicationYieldMenuRow(width: menu.minimumWidth)
        yieldRow.onChange = { [weak self] in
            self?.toggleYieldForFrontmostApp()
            self?.refreshApplicationYieldRow()
        }
        yieldItem.view = yieldRow
        applicationYieldRow = yieldRow
        menu.addItem(yieldItem)
        refreshApplicationYieldRow()

        menu.addItem(.separator())
        let quitRow = MenuCommandRow(width: menu.minimumWidth, title: "退出 Bar Control", symbol: "power")
        quitRow.onPress = { [weak self] in self?.quit() }
        let quitItem = NSMenuItem()
        quitItem.view = quitRow
        menu.addItem(quitItem)
        statusItem.menu = menu
        updatePersistentMenuItem()
        updateBrightnessMenuItem()
        refreshServicesMenuItem()
    }

    private func refreshApplicationYieldRow() {
        let front = frontmostForeignApp
        applicationYieldRow?.update(name: front?.localizedName,
                                    enabled: TouchBarYieldPolicy.shouldYield(bundleID: front?.bundleIdentifier))
    }

    private func refreshPowerMenuControls() {
        let controller = ChargingLimitController.shared
        powerMenuControls?.update(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                  busy: isChangingLowPowerMode,
                                  maximum: PowerFlowPolicyStore.maximumChargePercent,
                                  effective: controller.snapshot.isEnabled ? controller.snapshot.limitPercent : 100,
                                  supported: controller.snapshot.isSupported)
    }

    private func toggleSystemLowPowerMode() {
        guard !isChangingLowPowerMode else { return }
        let target = !ProcessInfo.processInfo.isLowPowerModeEnabled
        isChangingLowPowerMode = true
        refreshPowerMenuControls()
        // 系统授权窗口出现前关闭正在跟踪的菜单。
        statusItem.menu?.cancelTracking()
        Task { [weak self] in
            let error = await LowPowerModeCommand.apply(enabled: target)
            guard let self else { return }
            self.isChangingLowPowerMode = false
            self.refreshPowerMenuControls()
            if let error {
                let alert = NSAlert()
                alert.messageText = "省电模式未更改"
                alert.informativeText = error
                alert.runModal()
            }
            AppLog.write("low power mode requested=\(target) error=\(error ?? "none")")
        }
    }

    /// Runs after the status menu closes: a nested pop-up during menu tracking
    /// is ignored by AppKit.
    private func setMaximumChargePercent(_ percent: Int) {
        let previous = PowerFlowPolicyStore.maximumChargePercent
        PowerFlowPolicyStore.maximumChargePercent = percent
        let controller = ChargingLimitController.shared
        controller.update(policy: PowerFlowPolicyStore.current, metrics: systemMetrics, userInitiated: true)
        if let error = controller.lastError {
            PowerFlowPolicyStore.maximumChargePercent = previous
            statusItem.menu?.cancelTracking()
            let alert = NSAlert()
            alert.messageText = "充电上限未更改"
            alert.informativeText = error
            alert.runModal()
        }
        refreshPowerMenuControls()
    }

    /// 充电优先仍掉电时给出可解释的原因：适配器功率小于整机 + 外设负载。
    private func diagnoseChargerBottleneck(_ metrics: SystemMetrics) {
        guard PowerFlowPolicyStore.current == .charging,
              metrics.externalPower,
              let input = metrics.inputWatts,
              let system = metrics.systemWatts,
              let battery = metrics.batteryWatts,
              battery < -0.5,
              metrics.externalOutputWatts > 1 else { return }
        guard Date().timeIntervalSince(lastChargerHintAt) > 900 else { return }
        lastChargerHintAt = Date()
        let output = String(format: "%.1f", metrics.externalOutputWatts)
        let shortfall = String(format: "%.1f", system - input)
        PowerNotification.post(
            title: "充电器功率不足，电池仍在放电",
            body: "适配器 \(String(format: "%.1f", input)) W，整机 \(String(format: "%.1f", system)) W，其中外接设备 \(output) W。缺口 \(shortfall) W 由电池补上；换更大功率充电器或拔掉设备即可。"
        )
        AppLog.write("charger bottleneck input=\(input) system=\(system) outputs=\(output)")
    }

    private var servicesSummary: String {
        let value = ServiceMonitor.cachedSnapshot
        if value.states.allSatisfy({ $0 == .unknown }) { return "正在读取服务状态…" }
        return "\(value.runningCount)/\(value.totalCount) 运行中 · 常驻与定时任务"
    }

    private var yieldMenuTitle: String {
        guard let front = frontmostForeignApp else { return "当前应用：不适用" }
        let name = front.localizedName ?? front.bundleIdentifier ?? "当前应用"
        return TouchBarYieldPolicy.shouldYield(bundleID: front.bundleIdentifier)
            ? "\(name)：取消让位"
            : "\(name)：在此应用让位"
    }

    @objc private func toggleYieldForFrontmostApp() {
        guard let front = frontmostForeignApp,
              let bundleID = front.bundleIdentifier else { return }
        let next = !TouchBarYieldPolicy.shouldYield(bundleID: bundleID)
        TouchBarYieldPolicy.setEnabled(next, for: bundleID)
        manualYieldBypass = false
        textFocusEditing = false
        evaluateTouchBarYield()
        rebuildMenu()
        AppLog.write("yield app \(bundleID)=\(next)")
    }

    private var serviceBadges: [MenuSummaryBadge] {
        let states = ServiceMonitor.cachedSnapshot.states
        let services = ServiceMonitor.services()
        return [(false, "常驻", "server.rack"), (true, "定时", "clock")].map { scheduled, title, symbol in
            let group = zip(services, states).filter { $0.0.isScheduled == scheduled }.map { $0.1 }
            let count = group.filter { $0 == .running }.count
            let unknown = group.allSatisfy { $0 == .unknown }
            return MenuSummaryBadge(title: title, value: unknown ? "读取中" : "\(count)/\(group.count) 运行",
                                    symbol: symbol, tone: count > 0 ? .green : .secondary,
                                    action: .openServiceLogs)
        }
    }

    private func updateMenuSummary(for component: MainComponent) {
        if component == .clipboard || component == .keyboardLock {
            compactModuleRow?.update(count: clipboardHistory.entries.count, keyboard: keyboardLockPresentation)
            return
        }
        if component == .systemMonitor { refreshPowerMenuControls(); return }
        inlineMenuSections?.updateSummary(menuSummary(for: component), for: component.rawValue,
                                           badges: menuBadges(for: component))
    }

    /// 收起状态的状态标签可直接执行常用动作；菜单先关闭，Touch Bar 才能切换到详情页。
    private func performMenuSummaryAction(_ action: MenuSummaryAction) {
        AppLog.write("menu summary action=\(action)")
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case .openUsage(let key):
                self.showUsageDetails(key)
            case .openAIDetails:
                self.showDetails()
            case .openClipboard:
                self.showClipboardHistory()
            case .toggleSidecar:
                self.openSidecar()
            case .showSystemDetails:
                self.showSystemDetails()
            case .openSettings:
                self.openSettingsWindow()
            case .openCustomizer:
                self.showComponentOrder()
            case .openServiceLogs:
                self.openServiceLogsFolder()
            case .toggleKeyboardLock:
                self.toggleKeyboardLock()
            case .openSidecarWindow:
                self.openSidecarWindow()
            case .openClipboardWindow:
                self.openClipboardWindow()
            }
        }
    }

    private func menuBadges(for component: MainComponent) -> [MenuSummaryBadge] {
        switch component {
        case .sidecar:
            if sidecarStatus.state == "connecting" {
                return [MenuSummaryBadge(title: "iPad", value: "连接中", symbol: "arrow.triangle.2.circlepath",
                                         tone: .orange, action: .openSidecarWindow)]
            }
            guard let devices = SidecarConnectionMonitor.connectedDevices else {
                return [MenuSummaryBadge(title: "随航", value: "读取中", symbol: "ipad", tone: .secondary,
                                         action: .openSidecarWindow)]
            }
            return [MenuSummaryBadge(title: devices.isEmpty ? "iPad" : devices.joined(separator: "、"),
                                     value: devices.isEmpty ? "未连接" : "● 已连接", symbol: "ipad.landscape",
                                     tone: devices.isEmpty ? .secondary : .green,
                                     action: .openSidecarWindow)]
        case .aiCoding:
            let badges = MenuSummaryText.supplierBadges(accounts: snapshot.accounts ?? [], platforms: snapshot.platforms ?? [])
            if badges.isEmpty {
                return [MenuSummaryBadge(title: "供应商", value: "暂无数据", symbol: "creditcard",
                                         tone: .secondary, action: nil)]
            }
            // 供应商摘要徽章：只读状态，不再跳转窗口。
            return badges.map { badge in
                MenuSummaryBadge(title: badge.title, value: badge.value, symbol: badge.symbol,
                                 tone: badge.tone, clientID: badge.clientID,
                                 action: badge.clientID != nil ? .openUsage(badge.clientID!) : nil)
            }
        case .clipboard:
            return [MenuSummaryBadge(
                title: "", value: "\(clipboardHistory.entries.count) 条 · \(clipboardHistory.isPaused ? "已暂停" : "记录中")",
                symbol: clipboardHistory.isPaused ? "pause.circle" : "doc.on.clipboard",
                tone: clipboardHistory.isPaused ? .orange : .green,
                action: .openClipboardWindow
            )]
        case .systemMonitor:
            let watts = systemMetrics.systemWatts.map { String(format: "%.1f W", $0) } ?? "采样中"
            let memory = systemMetrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--"
            return [MenuSummaryBadge(title: "整机", value: watts, symbol: "bolt.fill", tone: .orange,
                                     action: .showSystemDetails),
                    MenuSummaryBadge(title: "内存", value: memory, symbol: "memorychip", tone: .purple,
                                     action: .showSystemDetails)]
        case .keyboardLock:
            let presentation = keyboardLockPresentation
            return [MenuSummaryBadge(
                title: "键盘",
                value: presentation.permissionMissing ? "需要辅助功能权限" : (presentation.locked ? "已锁定" : "可输入"),
                symbol: presentation.symbol,
                tone: presentation.permissionMissing ? .orange : (presentation.locked ? .purple : .green),
                action: .toggleKeyboardLock
            )]
        }
    }

    private func menuSummary(for component: MainComponent) -> String {
        switch component {
        case .sidecar:
            return MenuSummaryText.sidecar(state: sidecarStatus.state, message: sidecarStatus.message,
                                           connectedDevices: SidecarConnectionMonitor.connectedDevices)
        case .aiCoding:
            return MenuSummaryText.suppliers(accounts: snapshot.accounts ?? [], platforms: snapshot.platforms ?? [])
        case .clipboard:
            return "\(clipboardHistory.entries.count) 条历史 · \(clipboardHistory.isPaused ? "已暂停记录" : "正在记录")"
        case .systemMonitor:
            let watts = systemMetrics.systemWatts.map { String(format: "%.1f W", $0) } ?? "采样中"
            let memory = systemMetrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--"
            return "整机 \(watts) · 内存 \(memory)"
        case .keyboardLock:
            let presentation = keyboardLockPresentation
            if presentation.permissionMissing {
                return "缺少辅助功能权限，点按打开系统设置授权"
            }
            return presentation.locked
                ? "已锁定 · 触控栏/触控板仍可操作 · 接电源自动解锁"
                : "未锁定 · 接电源自动解锁已\(KeyboardLockController.shared.autoUnlockOnPower ? "开启" : "关闭")"
        }
    }

    // MARK: - Independent detail windows

    private func openServicesWindow() {
        statusItem.menu?.cancelTracking()
        let state = ServiceMonitor.cachedSnapshot
        let services = ServiceMonitor.services()
        let accessory = WindowDesign.metric(
            text: "运行中", value: "\(state.runningCount)/\(state.totalCount)", color: .systemGreen
        )
        MenuDetailWindowController.shared.show(
            id: "services",
            title: "服务",
            subtitle: servicesSummary,
            size: NSSize(width: 600, height: 610),
            accessory: accessory
        ) {
            self.makeServicesWindowBody(snapshot: state, services: services)
        }
        ServiceMonitor.refreshDetailsIfNeeded { [weak self] detailed in
            guard let self else { return }
            self.refreshServicesWindowBody(
                snapshot: detailed.snapshot,
                services: services,
                details: detailed.details
            )
        }
    }

    /// Rebuilds only the services page content. The detail window's shared
    /// header and appearance handling stays untouched.
    private func refreshServicesWindowBody(
        snapshot: ServiceMonitor.Snapshot,
        services: [ServiceMonitor.Service],
        details: [ServiceMonitor.Detail]
    ) {
        guard let menuWindow = NSApp.windows.first(where: { $0.title == "服务" }),
              menuWindow.isVisible,
              let content = menuWindow.contentView,
              let scroll = content.subviews.first(where: { $0.identifier?.rawValue == "detail-scroll" }) as? NSScrollView,
              let body = scroll.documentView
        else { return }
        let replacement = makeServicesWindowBody(
            snapshot: snapshot,
            services: services,
            details: details
        )
        // frame 布局的 documentView：NSScrollView 会自动按 frame.height 产生滚动。
        scroll.documentView = replacement
        MenuDetailWindowController.shared.attach(body: replacement)
    }

    /// Service groups are built from value data up front, then rendered on the
    /// main actor. That keeps the UI closure small and avoids actor-isolated
    /// helper calls escaping into a nonisolated closure.
    /// 方案 D：顶部统计头 + 分组服务行。
    private func makeServicesWindowBody(
        snapshot: ServiceMonitor.Snapshot,
        services: [ServiceMonitor.Service],
        details: [ServiceMonitor.Detail] = []
    ) -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 552, height: 500))
        var y: CGFloat = 0

        // —— 顶部统计卡 ——
        let running = snapshot.states.filter { $0 == .running }.count
        let stopped = snapshot.states.filter { $0 == .stopped }.count
        let onDemand = snapshot.states.filter { $0 == .onDemand }.count
        let hero = WindowDesign.card(frame: NSRect(x: 0, y: y, width: container.frame.width, height: 92))
        hero.autoresizingMask = [.width]
        hero.addSubview(stateIconView(symbol: "server.rack", accent: .controlAccentColor, frame: NSRect(x: 20, y: 33, width: 26, height: 26)))
        let heroTitle = NSTextField(labelWithString: "服务")
        heroTitle.font = .systemFont(ofSize: 17, weight: .bold)
        heroTitle.textColor = .labelColor
        // 右侧三个统计数字占约 156+16pt，标题/副标题最多用到 heroW-212。
        let heroTextWidth = max(120, hero.frame.width - 268)
        // 实际统计区 3×52 + 2×8 间距 + 24 右边距 = 200；文字区再留 12pt 呼吸 → -212。
        heroTitle.frame = NSRect(x: 60, y: 26, width: max(100, heroTextWidth - 40), height: 22)
        heroTitle.autoresizingMask = [.width]
        hero.addSubview(heroTitle)
        let heroSub = NSTextField(labelWithString: "\(running + stopped + onDemand) 项服务 · 每 15 秒自动刷新")
        heroSub.font = .systemFont(ofSize: 11)
        heroSub.textColor = .secondaryLabelColor
        heroSub.lineBreakMode = .byTruncatingTail
        heroSub.frame = NSRect(x: 60, y: 50, width: max(100, heroTextWidth - 40), height: 16)
        heroSub.autoresizingMask = [.width]
        hero.addSubview(heroSub)
        var metricX = hero.frame.width - 24
        for (value, caption, color) in [
            ("\(running)", "运行中", NSColor.systemGreen),
            ("\(stopped)", "已停止", NSColor.systemRed),
            ("\(onDemand)", "按需", NSColor.systemOrange),
        ].reversed() {
            let m = WindowDesign.heroMetric(value: value, caption: caption, color: color)
            m.frame = NSRect(x: metricX - 52, y: 26, width: 52, height: 40)
            m.autoresizingMask = [.minXMargin]
            hero.addSubview(m)
            metricX -= 60
        }
        container.addSubview(hero)
        y += 106

        let groups: [(String, String, [(ServiceMonitor.Service, ServiceMonitor.State)], Int)] = {
            let all = zip(services, snapshot.states)
            let resident = all.filter { !$0.0.isScheduled }
            let scheduled = all.filter { $0.0.isScheduled }
            return [
                ("常驻服务", "server.rack", resident, 0),
                ("定时任务", "clock", scheduled, resident.count),
            ]
        }()

        for (title, symbol, group, indexOffset) in groups {
            let section = WindowDesign.section(
                title: title,
                count: group.count,
                symbol: symbol,
                accent: group.contains(where: { $0.1 == .running }) ? .systemGreen : .secondaryLabelColor
            )
            section.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
            container.addSubview(section)
            y += 30
            for (groupIndex, (service, serviceState)) in group.enumerated() {
                let isRunning = serviceState == .running
                let row = WindowDesign.card(
                    frame: NSRect(x: 0, y: y, width: container.frame.width, height: 62),
                    tint: nil
                )
                let rowWidth = row.frame.width
                let stateColor: NSColor = isRunning ? .systemGreen
                    : (serviceState == .onDemand ? .systemOrange : .systemRed)
                let dot = WindowDesign.statusDot(color: stateColor, glowing: isRunning)
                dot.frame = NSRect(x: 16, y: 26, width: 9, height: 9)
                row.addSubview(dot)
                let title = NSTextField(labelWithString: service.name)
                title.font = .systemFont(ofSize: 13, weight: .semibold)
                title.textColor = .labelColor
                title.lineBreakMode = .byTruncatingTail
                title.frame = NSRect(x: 37, y: 10, width: rowWidth - 287, height: 18)
                title.autoresizingMask = [.width]
                row.addSubview(title)
                let role = NSTextField(labelWithString: service.role)
                role.font = .systemFont(ofSize: 11)
                role.textColor = .secondaryLabelColor
                role.lineBreakMode = .byTruncatingTail
                role.frame = NSRect(x: 37, y: 28, width: rowWidth - 287, height: 15)
                role.autoresizingMask = [.width]
                row.addSubview(role)
                let detail = details.indices.contains(indexOffset + groupIndex)
                    ? details[indexOffset + groupIndex] : nil
                let diagnosticText: String = {
                    var parts = [service.kind.diagnosticTitle]
                    if let identifier = detail?.identifier { parts.append(identifier) }
                    if let modified = detail?.latestLogModified {
                        parts.append("日志 " + ServiceMonitor.formattedLogTime(modified))
                    }
                    return parts.joined(separator: " · ")
                }()
                let diagnostic = NSTextField(labelWithString: diagnosticText)
                diagnostic.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
                diagnostic.textColor = .tertiaryLabelColor
                diagnostic.lineBreakMode = .byTruncatingTail
                diagnostic.frame = NSRect(x: 37, y: 44, width: rowWidth - 287, height: 12)
                diagnostic.autoresizingMask = [.width]
                row.addSubview(diagnostic)

                // 右侧操作按钮 + 状态徽章，从右往左排
                var rightX = rowWidth - 14
                if service.folderPath != nil {
                    let folderBtn = WindowDesign.actionButton(
                        "文件夹",
                        target: ServiceMonitorActionRouter.shared,
                        action: #selector(ServiceMonitorActionRouter.open(_:))
                    )
                    folderBtn.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
                    ServiceMonitorActionRouter.shared.register(
                        id: folderBtn.identifier!.rawValue, service: service
                    )
                    folderBtn.frame = NSRect(x: rightX - 74, y: 19, width: 74, height: 24)
                    folderBtn.autoresizingMask = [.minXMargin]
                    row.addSubview(folderBtn)
                    rightX -= 80
                }
                if service.appPath != nil {
                    let appBtn = WindowDesign.actionButton(
                        "打开 App",
                        target: ServiceMonitorActionRouter.shared,
                        action: #selector(ServiceMonitorActionRouter.openApp(_:))
                    )
                    appBtn.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
                    ServiceMonitorActionRouter.shared.register(
                        id: appBtn.identifier!.rawValue, service: service
                    )
                    appBtn.frame = NSRect(x: rightX - 80, y: 19, width: 80, height: 24)
                    appBtn.autoresizingMask = [.minXMargin]
                    row.addSubview(appBtn)
                    rightX -= 86
                }
                let stateLabel: String
                switch serviceState {
                case .running: stateLabel = "运行中"
                case .stopped: stateLabel = "已停止"
                case .onDemand: stateLabel = "按需"
                case .unknown: stateLabel = "未知"
                }
                let stateChip = WindowDesign.statusPill(text: stateLabel, color: stateColor, width: 52)
                stateChip.frame.origin = NSPoint(x: rightX - 52, y: 21)
                stateChip.autoresizingMask = [.minXMargin]
                row.addSubview(stateChip)

                container.addSubview(row)
                y += 70
            }
            y += 12
        }

        let logs = WindowDesign.actionButton(
            "打开全部服务日志", target: self,
            action: #selector(openServiceLogsFolderWithoutMenu)
        )
        logs.frame = NSRect(x: 0, y: y, width: 156, height: 28)
        container.addSubview(logs)
        // 设置 container 实际内容高度，documentView 用 frame 布局时 NSScrollView 会
        // 根据 frame.height 与 clipView.bounds.height 的差值产生滚动。
        container.frame.size.height = y + 28 + 16
        return container
    }

    private func stateIconView(symbol: String, accent: NSColor, frame: NSRect) -> NSImageView {
        let v = NSImageView(frame: frame)
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        v.contentTintColor = accent
        return v
    }

    private func stateDot(_ state: ServiceMonitor.State, frame: NSRect) -> NSImageView {
        let view = NSImageView(frame: frame)
        view.image = Self.stateDot(state)
        return view
    }

    // MARK: - 随航 / AI Coding / 剪贴板 独立详情窗口

    private func openSidecarWindow() {
        statusItem.menu?.cancelTracking()
        let devices = SidecarConnectionMonitor.connectedDevices
        let state = sidecarStatus
        MenuDetailWindowController.shared.show(
            id: "sidecar",
            title: "随航与通用控制",
            subtitle: sidecarSubtitle(state: state, devices: devices),
            size: NSSize(width: 560, height: 480)
        ) {
            self.makeSidecarWindowBody(state: state, devices: devices)
        }
        SidecarConnectionMonitor.refreshIfNeeded { [weak self] in
            guard let self else { return }
            self.refreshSidecarWindow()
        }
    }

    private func refreshSidecarWindow() {
        let devices = SidecarConnectionMonitor.connectedDevices
        let state = sidecarStatus
        guard let menuWindow = NSApp.windows.first(where: { $0.title == "随航与通用控制" }),
              menuWindow.isVisible,
              let content = menuWindow.contentView,
              let scroll = content.subviews.first(where: { $0.identifier?.rawValue == "detail-scroll" }) as? NSScrollView
        else { return }
        let replacement = makeSidecarWindowBody(state: state, devices: devices)
        scroll.documentView = replacement
    }

    private func sidecarSubtitle(state: SidecarStatus, devices: [String]?) -> String {
        if state.state == "connecting" { return "正在连接…" }
        if let devices, !devices.isEmpty { return "已连接：\(devices.joined(separator: "、"))" }
        return "未连接 iPad · 点击下方按钮启动"
    }

    private func makeSidecarWindowBody(state: SidecarStatus, devices: [String]?) -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 512, height: 360))
        var y: CGFloat = 0

        let hero = WindowDesign.card(frame: NSRect(x: 0, y: y, width: container.frame.width, height: 80))
        hero.autoresizingMask = [.width]
        hero.addSubview(stateIconView(symbol: "ipad.landscape",
                                      accent: state.state == "success" ? .systemGreen : .controlAccentColor,
                                      frame: NSRect(x: 20, y: 27, width: 26, height: 26)))
        let title = NSTextField(labelWithString: state.message)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 60, y: 19, width: 320, height: 20)
        title.autoresizingMask = [.width]
        hero.addSubview(title)
        let detail = NSTextField(labelWithString: state.detail.isEmpty ? "iPad 随航 / 通用控制" : state.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 60, y: 41, width: 380, height: 15)
        detail.autoresizingMask = [.width]
        hero.addSubview(detail)
        container.addSubview(hero)
        y += 96

        let connectedList = WindowDesign.section(title: "已连接设备", symbol: "ipad",
                                                 accent: devices?.isEmpty == false ? .systemGreen : .secondaryLabelColor)
        connectedList.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
        container.addSubview(connectedList)
        y += 28
        let names = devices ?? []
        if names.isEmpty {
            let empty = NSTextField(labelWithString: "暂无 iPad 连接。启动随航后会显示设备名称。")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 16)
            empty.autoresizingMask = [.width]
            container.addSubview(empty)
            y += 26
        } else {
            for name in names {
                let row = WindowDesign.card(frame: NSRect(x: 0, y: y, width: container.frame.width, height: 48))
                row.autoresizingMask = [.width]
                let dot = WindowDesign.statusDot(color: .systemGreen, glowing: true)
                dot.frame = NSRect(x: 16, y: 20, width: 9, height: 9)
                row.addSubview(dot)
                let label = NSTextField(labelWithString: name)
                label.font = .systemFont(ofSize: 12.5, weight: .medium)
                label.textColor = .labelColor
                label.frame = NSRect(x: 37, y: 15, width: container.frame.width - 60, height: 18)
                label.autoresizingMask = [.width]
                row.addSubview(label)
                container.addSubview(row)
                y += 56
            }
        }
        y += 14

        let actions = WindowDesign.section(title: "操作", symbol: "bolt.horizontal.circle", accent: .controlAccentColor)
        actions.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
        container.addSubview(actions)
        y += 28
        let toggleBtn = WindowDesign.actionButton("切换随航", target: self, action: #selector(openSidecar))
        toggleBtn.frame = NSRect(x: 0, y: y, width: 120, height: 28)
        container.addSubview(toggleBtn)
        let fixBtn = WindowDesign.actionButton("修复随航黑屏", target: self, action: #selector(sidecarEnvironmentFix))
        fixBtn.frame = NSRect(x: 128, y: y, width: 130, height: 28)
        container.addSubview(fixBtn)
        let ctrlFixBtn = WindowDesign.actionButton("控制环境修复", target: self, action: #selector(controlEnvironmentFix))
        ctrlFixBtn.frame = NSRect(x: 266, y: y, width: 130, height: 28)
        container.addSubview(ctrlFixBtn)
        y += 44

        container.frame.size.height = y + 16
        return container
    }

    private func openClipboardWindow() {
        statusItem.menu?.cancelTracking()
        let entries = clipboardHistory.entries
        MenuDetailWindowController.shared.show(
            id: "clipboard",
            title: "剪贴板历史",
            subtitle: "\(entries.count) 条 · \(self.clipboardHistory.isPaused ? "已暂停记录" : "正在记录")",
            size: NSSize(width: 560, height: 560)
        ) {
            self.makeClipboardWindowBody(entries: entries, paused: self.clipboardHistory.isPaused)
        }
    }

    private func makeClipboardWindowBody(entries: [ClipboardHistoryStore.Entry], paused: Bool) -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 512, height: 420))
        var y: CGFloat = 0

        let hero = WindowDesign.card(frame: NSRect(x: 0, y: y, width: container.frame.width, height: 80))
        hero.autoresizingMask = [.width]
        hero.addSubview(stateIconView(symbol: paused ? "pause.circle" : "doc.on.clipboard",
                                      accent: paused ? .systemOrange : .systemGreen,
                                      frame: NSRect(x: 20, y: 27, width: 26, height: 26)))
        let title = NSTextField(labelWithString: paused ? "记录已暂停" : "正在记录剪贴板")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 60, y: 19, width: 280, height: 20)
        title.autoresizingMask = [.width]
        hero.addSubview(title)
        let detail = NSTextField(labelWithString: "\(entries.count) 条历史 · 最多保留 12 条")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 60, y: 41, width: 380, height: 15)
        detail.autoresizingMask = [.width]
        hero.addSubview(detail)
        container.addSubview(hero)
        y += 96

        let sec = WindowDesign.section(title: "历史条目", symbol: "clock.arrow.circlepath",
                                       accent: entries.isEmpty ? .secondaryLabelColor : .systemBlue)
        sec.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
        container.addSubview(sec)
        y += 28

        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "暂无历史。复制文本或图片后会自动记录。")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 16)
            empty.autoresizingMask = [.width]
            container.addSubview(empty)
            y += 26
        } else {
            for entry in entries {
                let isImage = entry.isImage
                let row = WindowDesign.card(frame: NSRect(x: 0, y: y, width: container.frame.width, height: 60))
                row.autoresizingMask = [.width]
                if let icon = entry.sourceIcon {
                    let iconView = NSImageView(frame: NSRect(x: 16, y: 16, width: 28, height: 28))
                    iconView.image = icon
                    row.addSubview(iconView)
                } else {
                    let dot = WindowDesign.statusDot(color: isImage ? .systemBlue : .systemGray, glowing: false)
                    dot.frame = NSRect(x: 16, y: 26, width: 9, height: 9)
                    row.addSubview(dot)
                }
                let previewText = entry.displayText.isEmpty ? "（空）" : entry.displayText
                let label = NSTextField(labelWithString: previewText)
                label.font = .systemFont(ofSize: 12)
                label.textColor = .labelColor
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 2
                label.frame = NSRect(x: 54, y: 10, width: container.frame.width - 180, height: 40)
                label.autoresizingMask = [.width]
                row.addSubview(label)
                let kindChip = WindowDesign.statusPill(text: isImage ? "图片" : "文本",
                                                       color: isImage ? .systemBlue : .systemGray, width: 40)
                kindChip.frame.origin = NSPoint(x: container.frame.width - 120, y: 20)
                kindChip.autoresizingMask = NSView.AutoresizingMask([.minXMargin])
                row.addSubview(kindChip)
                let copyBtn = NSButton(title: "复制", target: nil, action: nil)
                copyBtn.bezelStyle = .rounded
                copyBtn.controlSize = .small
                copyBtn.frame = NSRect(x: container.frame.width - 70, y: 16, width: 56, height: 26)
                copyBtn.autoresizingMask = NSView.AutoresizingMask([.minXMargin])
                row.addSubview(copyBtn)
                container.addSubview(row)
                y += 68
            }
        }
        y += 14

        let actions = WindowDesign.section(title: "操作", symbol: "hand.tap", accent: .controlAccentColor)
        actions.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
        container.addSubview(actions)
        y += 28
        let pauseBtn = WindowDesign.actionButton(paused ? "恢复记录" : "暂停记录",
                                                 target: self, action: #selector(toggleClipboardCapture))
        pauseBtn.frame = NSRect(x: 0, y: y, width: 110, height: 28)
        container.addSubview(pauseBtn)
        let clearBtn = WindowDesign.actionButton("清空历史", target: self, action: #selector(clearClipboardHistory))
        clearBtn.frame = NSRect(x: 118, y: y, width: 110, height: 28)
        container.addSubview(clearBtn)
        y += 44

        container.frame.size.height = y + 16
        return container
    }

    func runWindowDesignPreview() {
        NSApp.setActivationPolicy(.regular)
        let specs = InterfaceSpecsReader.read()

        func capture(_ window: NSWindow, _ name: String) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                MenuDetailWindowController.shared.refreshAppearance()
                window.displayIfNeeded()
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/barcontrol-real-\(name)-\(suffix).png"))
                }
            }
        }

        func visible(_ title: String) -> NSWindow? {
            NSApp.windows.first { $0.title == title && $0.isVisible }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            InterfaceDetailWindowController.shared.show(specs: specs, metrics: self.systemMetrics)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if let w = visible("接口与线缆详情") { capture(w, "interface") }
                self.openServicesWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if let w = visible("服务") { capture(w, "services") }
                    self.openSettingsWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if let w = visible("Touch Bar 设置") { capture(w, "settings") }
                        self.openSidecarWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if let w = visible("随航与通用控制") { capture(w, "sidecar") }
                            self.openClipboardWindow()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if let w = visible("剪贴板历史") { capture(w, "clipboard") }
                                AppLog.write("window design preview complete")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    func debugOpenSettingsWindow() { openSettingsWindow() }

    func debugOpenSettingsPower() {
        settingsCategoryIndex = 1
        openSettingsWindow()
    }

    func debugOpenSettingsAbout() {
        settingsCategoryIndex = 5
        openSettingsWindow()
    }

    func debugOpenSettingsHardware() {
        settingsCategoryIndex = 4
        openSettingsWindow()
    }

    func debugOpenSettingsYield() {
        settingsCategoryIndex = 2
        openSettingsWindow()
    }

    func debugOpenCustomizer() {
        settingsPane = .customizer
        openSettingsWindow()
    }

    func debugOpenMenuModules() { openMenuModulesWindow() }

    func debugOpenYieldAppsWindow() { openYieldAppsWindow() }

    func debugOpenAboutWindow() { openAboutWindow() }

    /// 从设置页进入关于页，验证同窗口返回层级与左上角返回按钮。
    func debugOpenAboutFromSettings() {
        openSettingsWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.openAboutWindow()
        }
    }

    /// 预览用：构造一个比当前版本高的示例版本，只渲染真实弹窗，不写入跳过状态。
    func debugShowUpdatePrompt() {
        let current = UpdateChecker.shared.currentVersion
        var numbers = current.numbers
        while numbers.count < 3 { numbers.append(0) }
        numbers[2] += 1
        let version = AppVersion(numbers.map(String.init).joined(separator: ".")) ?? AppVersion("0.0.1")!
        let release = SoftwareRelease(
            version: version,
            name: "示例更新：液态玻璃菜单与更新检查",
            notes: """
            新增
            · 发现新版本时弹窗提示，可跳过指定版本
            · 设置里新增「关于」页，显示版本、链接与开源许可

            改进
            · 菜单栏「Touch Bar 设置」右侧显示可更新版本
            · 自动检查更新默认开启，每 24 小时最多一次

            说明
            · 下载新版替换旧版即可，模块布局与设置会保留
            """,
            pageURL: UpdateChecker.releasesPage,
            publishedAt: Date(),
            assetURL: nil,
            assetSHA256: nil
        )
        UpdatePromptWindowController.shared.show(
            release: release,
            currentVersion: UpdateChecker.shared.currentVersionText,
            build: UpdateChecker.shared.currentBuildText
        )
    }

    /// 诊断：跳过一次网络请求，直接走生产链路 finishUpdateCheck → 弹窗，
    /// 用来验证“检测到更新后会不会弹”的接线（网络解析由单测覆盖）。
    func debugSimulateAvailableUpdate() {
        let current = UpdateChecker.shared.currentVersion
        var numbers = current.numbers
        while numbers.count < 3 { numbers.append(0) }
        numbers[2] += 1
        guard let version = AppVersion(numbers.map(String.init).joined(separator: ".")) else { return }
        let release = SoftwareRelease(
            version: version,
            name: "模拟更新：更新检查接线测试",
            notes: "这条更新由诊断入口构造，不会访问网络。\n用于验证检测到新版本后弹窗、跳过与冷却逻辑。",
            pageURL: UpdateChecker.releasesPage,
            publishedAt: Date()
        )
        finishUpdateCheck(UpdateCheckResult(outcome: .available(release), checkedAt: Date()))
    }

    /// 诊断：用本地 zip 走完整的 校验→解压→验签→替换 流程。
    /// 目标由 BARC_UPDATE_TARGET 指定，默认指向 /Applications。
    func runUpdateInstallProbe(zipPath: String, targetPath: String) {
        setenv("BARC_UPDATE_TARGET", targetPath, 1)
        setenv("BARC_UPDATE_NO_RELAUNCH", "1", 1)
        Task {
            do {
                let zip = URL(fileURLWithPath: zipPath)
                let digest = try UpdateInstaller.sha256(of: zip)
                let release = SoftwareRelease(
                    version: UpdateChecker.shared.currentVersion,
                    name: "本地探针",
                    notes: "",
                    pageURL: UpdateChecker.releasesPage,
                    publishedAt: Date(),
                    assetURL: zip,
                    assetSHA256: digest
                )
                try await UpdateInstaller.shared.install(release) { message, fraction in
                    print("UPDATE_INSTALL \(message) \(Int(fraction * 100))%")
                }
                print("UPDATE_INSTALL_STARTED")
            } catch {
                print("UPDATE_INSTALL_FAILED \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
        }
    }

    func runUpdateCheckProbe() {
        Task {
            let result = await UpdateChecker.shared.check(force: true)
            AppLog.write("update probe \(UpdateChecker.describe(result.outcome))")
            print("UPDATE_PROBE \(UpdateChecker.describe(result.outcome))")
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    private func openSettingsWindow() {
        statusItem.menu?.cancelTracking()
        MenuDetailWindowController.shared.show(
            id: "settings",
            title: "Touch Bar 设置",
            subtitle: "外观、常驻显示、自动亮度与硬件详情",
            size: NSSize(width: 900, height: 640),
            fullBleed: true
        ) {
            self.makeSettingsWindowBody()
        }
    }

    // MARK: - 更新与关于

    private var versionSummary: String {
        "\(UpdateChecker.shared.currentVersionText) (\(UpdateChecker.shared.currentBuildText))"
    }

    private var updateStatusText: String {
        if isCheckingForUpdates { return "正在检查更新…" }
        guard let result = lastUpdateResult else { return "尚未检查" }
        switch result.outcome {
        case let .available(release): return "可更新到 \(release.versionText)"
        case let .upToDate(latest): return latest.map { "已是最新版本 \($0)" } ?? "已是最新版本"
        case .noPublishedRelease: return "仓库还没有发布版本"
        case let .failed(message): return message
        }
    }

    private var updateStatusColor: NSColor {
        guard let result = lastUpdateResult else { return .secondaryLabelColor }
        switch result.outcome {
        case .available: return .systemGreen
        case .failed: return .systemOrange
        case .upToDate, .noPublishedRelease: return .secondaryLabelColor
        }
    }

    /// 设置行右侧只留很短的状态词，完整说明放在关于页。
    private var updateValueText: String {
        if isCheckingForUpdates { return "检查中" }
        guard let result = lastUpdateResult else { return "未检查" }
        switch result.outcome {
        case let .available(release): return release.versionText
        case .upToDate: return "已最新"
        case .noPublishedRelease: return "无版本"
        case let .failed(message):
            if message.contains("限流") { return "限流" }
            if message.contains("网络") { return "离线" }
            return "失败"
        }
    }

    private var updateRowSubtitle: String {
        guard let result = lastUpdateResult else {
            return "从 GitHub 读取版本信息，不发送设备数据"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "上次检查 \(formatter.string(from: result.checkedAt)) · 只访问 GitHub 公共仓库"
    }

    private var updateMenuSummary: String {
        guard case let .available(release)? = lastUpdateResult?.outcome else { return "" }
        return "\(release.versionText) 可更新"
    }

    @objc private func checkForUpdatesNow() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        refreshUpdateSurfaces()
        Task { [weak self] in
            guard let self else { return }
            let result = await UpdateChecker.shared.check(force: true)
            self.finishUpdateCheck(result)
        }
    }

    private func finishUpdateCheck(_ result: UpdateCheckResult) {
        isCheckingForUpdates = false
        lastUpdateResult = result
        refreshUpdateSurfaces()
        guard UpdateChecker.shared.shouldPrompt(result),
              case let .available(release) = result.outcome else { return }
        UpdatePromptWindowController.shared.show(
            release: release,
            currentVersion: UpdateChecker.shared.currentVersionText,
            build: UpdateChecker.shared.currentBuildText
        )
    }

    /// 检查更新会同时影响设置页、关于页和菜单摘要；只刷新当前可见的那一页。
    private func refreshUpdateSurfaces() {
        switch MenuDetailWindowController.shared.currentPageID {
        case "settings":
            MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
        case "about":
            MenuDetailWindowController.shared.updateIfVisible { self.makeAboutBody() }
        default:
            break
        }
        rebuildMenu()
    }

    @objc private func toggleAutoUpdate(_ row: WindowActionRow) {
        let next = !UpdateChecker.shared.autoCheckEnabled
        UpdateChecker.shared.autoCheckEnabled = next
        row.setSwitchState(on: next, animated: true)
        if next {
            scheduleAutomaticUpdateCheck()
            performAutomaticUpdateCheckIfDue()
        } else {
            updateCheckTimer?.invalidate()
            updateCheckTimer = nil
        }
        AppLog.write("update auto-check \(next)")
    }

    @objc private func openRepositoryPage() {
        NSWorkspace.shared.open(UpdateChecker.repositoryPage)
    }

    @objc private func openLinkRow(_ row: WindowActionRow) {
        guard let raw = row.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAboutWindow() {
        statusItem.menu?.cancelTracking()
        settingsCategoryIndex = 5
        settingsPane = .category
        openSettingsWindow()
    }

    private func makeAboutBody(width explicitWidth: CGFloat? = nil) -> NSView {
        let pageSize = MenuDetailWindowController.shared.pageSize
        let width = explicitWidth ?? max(460, pageSize.width - 96)
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: 540))

        let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)

        let name = NSTextField(labelWithString: "Bar Control")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.textColor = .labelColor
        name.frame = NSRect(x: 80, y: 2, width: width - 80, height: 28)
        container.addSubview(name)

        let version = NSTextField(labelWithString: "版本 \(versionSummary)")
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 80, y: 32, width: width - 80, height: 16)
        container.addSubview(version)

        let tagline = NSTextField(labelWithString: "Touch Bar 效率中枢 · 模块栏、功率、剪贴板与键盘锁")
        tagline.font = .systemFont(ofSize: 11)
        tagline.textColor = .tertiaryLabelColor
        tagline.lineBreakMode = .byTruncatingTail
        tagline.frame = NSRect(x: 80, y: 52, width: width - 80, height: 16)
        container.addSubview(tagline)

        var y: CGFloat = 84
        let updateCard = WindowCard(frame: NSRect(x: 0, y: y, width: width, height: 104),
                                    tint: nil, emphasized: false)
        container.addSubview(updateCard)

        let updateTitle = NSTextField(labelWithString: "更新")
        updateTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        updateTitle.textColor = .secondaryLabelColor
        updateTitle.frame = NSRect(x: 16, y: 12, width: 160, height: 16)
        updateCard.addSubview(updateTitle)

        let status = NSTextField(labelWithString: updateStatusText)
        status.font = .systemFont(ofSize: 12.5, weight: .medium)
        status.textColor = updateStatusColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 33, width: width - 150, height: 18)
        updateCard.addSubview(status)

        let statusDetail = NSTextField(labelWithString: updateRowSubtitle)
        statusDetail.font = .systemFont(ofSize: 10.5)
        statusDetail.textColor = .tertiaryLabelColor
        statusDetail.lineBreakMode = .byTruncatingTail
        statusDetail.frame = NSRect(x: 16, y: 56, width: width - 150, height: 14)
        updateCard.addSubview(statusDetail)

        let checkButton = NSButton(title: isCheckingForUpdates ? "检查中…" : "检查更新",
                                   target: self, action: #selector(checkForUpdatesNow))
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .regular
        checkButton.isEnabled = !isCheckingForUpdates
        checkButton.frame = NSRect(x: width - 116, y: 36, width: 100, height: 30)
        updateCard.addSubview(checkButton)
        y += 104 + 18

        func addSection(_ title: String, _ symbol: String) {
            let section = WindowDesign.section(title: title, symbol: symbol, accent: .systemPurple)
            section.frame = NSRect(x: 0, y: y, width: width, height: 22)
            section.autoresizingMask = [.width]
            container.addSubview(section)
            y += 28
        }

        func addRow(_ title: String, _ subtitle: String, _ symbol: String,
                    value: String? = nil, identifier: String? = nil,
                    action: Selector) -> WindowActionRow {
            let row = WindowActionRow(
                frame: NSRect(x: 0, y: y, width: width, height: 50),
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                value: value,
                toggle: false,
                symbolOff: nil,
                target: self,
                action: action
            )
            row.autoresizingMask = [.width]
            if let identifier {
                row.identifier = NSUserInterfaceItemIdentifier(identifier)
            }
            container.addSubview(row)
            y += 50 + 6
            return row
        }

        addSection("链接", "link")
        _ = addRow("项目主页", "github.com/\(UpdateChecker.repository)", "chevron.left.forwardslash.chevron.right",
                   identifier: UpdateChecker.repositoryPage.absoluteString, action: #selector(openLinkRow(_:)))
        _ = addRow("版本发布", "查看历史版本与下载页", "shippingbox",
                   identifier: UpdateChecker.releasesPage.absoluteString, action: #selector(openLinkRow(_:)))
        _ = addRow("问题反馈", "报告问题或提建议", "exclamationmark.bubble",
                   identifier: UpdateChecker.issuesPage.absoluteString, action: #selector(openLinkRow(_:)))

        addSection("维护", "wrench.and.screwdriver")
        copyVersionRow = addRow("复制版本信息", "粘贴到问题反馈里，便于定位版本", "doc.on.doc",
                                value: nil, action: #selector(copyVersionInfo))
        _ = addRow("开源许可", "MIT License · 在 GitHub 查看", "curlybraces",
                   identifier: "https://github.com/\(UpdateChecker.repository)/blob/main/LICENSE",
                   action: #selector(openLinkRow(_:)))

        let footer = NSTextField(labelWithString: "更新检查只读取 GitHub 公共仓库，不发送设备信息。")
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.frame = NSRect(x: 0, y: y + 6, width: width, height: 14)
        container.addSubview(footer)

        container.frame.size.height = max(400, y + 34)
        return container
    }

    @objc private func copyVersionInfo() {
        let info = "Bar Control \(versionSummary) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        copyVersionRow?.setValueText("已复制", symbol: "checkmark.circle", animated: true)
        AppLog.write("about copy version info")
    }

    func scheduleAutomaticUpdateCheck() {
        guard UpdateChecker.shared.autoCheckEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.performAutomaticUpdateCheckIfDue()
        }
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performAutomaticUpdateCheckIfDue() }
        }
    }

    private func performAutomaticUpdateCheckIfDue() {
        guard !isCheckingForUpdates else { return }
        let checker = UpdateChecker.shared
        guard UpdatePolicy.shouldAutoCheck(enabled: checker.autoCheckEnabled,
                                           lastCheckAt: checker.lastCheckAt,
                                           now: Date()) else { return }
        isCheckingForUpdates = true
        Task { [weak self] in
            guard let self else { return }
            let result = await checker.check(force: false)
            self.finishUpdateCheck(result)
        }
    }

    /// 「展开菜单显示」窗口：每个模块一行开关，控制它是否出现在菜单栏下拉菜单里。
    @objc private func openMenuModulesWindow() {
        statusItem.menu?.cancelTracking()
        MenuDetailWindowController.shared.push(
            id: "menuModules",
            title: "展开菜单显示",
            subtitle: "选择哪些模块出现在菜单栏下拉菜单里",
            size: NSSize(width: 520, height: 470)
        ) {
            self.makeMenuModulesBody()
        }
    }

    private func makeMenuModulesBody() -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 472, height: 330))
        var y: CGFloat = 0
        let section = WindowDesign.section(title: "模块", symbol: "list.bullet.rectangle", accent: .systemPurple)
        section.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
        container.addSubview(section)
        y += 28

        for component in MainComponent.allCases where component.isSoftwareAvailable {
            let visible = component.isVisibleInMenu
            let row = WindowActionRow(
                frame: NSRect(x: 0, y: y, width: container.frame.width, height: 50),
                title: component.title,
                subtitle: visible ? "显示在展开菜单里" : "已从展开菜单隐藏",
                symbol: component.symbol,
                value: nil,
                toggle: true,
                symbolOff: nil,
                target: self,
                action: #selector(toggleMenuModuleVisibility(_:))
            )
            row.identifier = NSUserInterfaceItemIdentifier(component.rawValue)
            row.setSwitchState(on: visible, animated: false)
            menuModuleRows[component] = row
            container.addSubview(row)
            y += 56
        }
        container.frame.size.height = y + 12
        return container
    }

    @objc private func toggleMenuModuleVisibility(_ row: WindowActionRow) {
        guard let raw = row.identifier?.rawValue,
              let component = MainComponent(rawValue: raw) else { return }
        let next = !component.isVisibleInMenu
        MainComponent.setVisibleInMenu(next, for: component)
        row.setSwitchState(on: next, animated: true)
        rebuildMenu()
        AppLog.write("menu module visibility \(component.rawValue)=\(next)")
    }

    /// 「让位应用」窗口：这些应用自己往 Touch Bar 中间放控件时，模块栏自动收起。
    /// 设置右栏的内联展开内容：菜单模块、让位应用、接口与线缆。
    private func makeSettingsInlineContent(id: String, width: CGFloat) -> NSView {
        switch id {
        case "menuModules":
            let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
            var y: CGFloat = 0
            for component in MainComponent.allCases where component.isSoftwareAvailable {
                let visible = component.isVisibleInMenu
                let sub = WindowActionRow(
                    frame: NSRect(x: 0, y: y, width: width, height: 46),
                    title: component.title,
                    subtitle: visible ? "显示在展开菜单里" : "已从展开菜单隐藏",
                    symbol: component.symbol,
                    value: nil,
                    toggle: true,
                    symbolOff: nil,
                    target: self,
                    action: #selector(toggleMenuModuleVisibility(_:))
                )
                sub.identifier = NSUserInterfaceItemIdentifier(component.rawValue)
                sub.setSwitchState(on: visible, animated: false)
                menuModuleRows[component] = sub
                container.addSubview(sub)
                y += 46 + 6
            }
            container.frame.size.height = y
            return container
        case "yieldApps":
            return makeYieldAppsBody(width: width)
        case "interface":
            let detail = InterfaceDetailContent.makeView(specs: interfaceSpecs, metrics: systemMetrics)
            detail.frame = NSRect(x: 0, y: 0, width: width, height: 40)
            detail.layoutSubtreeIfNeeded()
            let height = max(80, detail.fittingSize.height)
            detail.frame = NSRect(x: 0, y: 0, width: width, height: height)
            return detail
        default:
            return NSView(frame: .zero)
        }
    }

    @objc private func openCustomizerInSettings() {
        settingsPane = .customizer
        MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
    }

    @objc private func closeCustomizerPane() {
        settingsPane = .category
        MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
    }

    /// 组件编辑器直接嵌在设置右栏，带返回按钮，不再弹独立面板。
    private func makeCustomizerPane(x: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
        let pane = FlippedContainerView(frame: NSRect(x: x, y: 0, width: width, height: height))

        let back = NSButton(
            image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "返回设置") ?? NSImage(),
            target: self,
            action: #selector(closeCustomizerPane)
        )
        back.isBordered = false
        back.contentTintColor = .labelColor
        back.toolTip = "返回设置"
        back.frame = NSRect(x: 0, y: 58, width: 26, height: 26)
        pane.addSubview(back)

        let title = NSTextField(labelWithString: "自定义 Touch Bar 组件")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 32, y: 56, width: width - 32, height: 26)
        pane.addSubview(title)

        let subtitle = NSTextField(labelWithString: "排序、宽度、图标与文字")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 32, y: 88, width: width - 32, height: 18)
        pane.addSubview(subtitle)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 122, width: width, height: max(300, height - 122)))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let content = makeComponentSettingsContent()
        content.frame = NSRect(x: 0, y: 0, width: 620, height: content.frame.height)
        scroll.documentView = content
        pane.addSubview(scroll)

        reloadSlotPreview()
        reloadOrderRows()
        reloadCustomRows()
        return pane
    }

    @objc private func openYieldAppsWindow() {
        statusItem.menu?.cancelTracking()
        MenuDetailWindowController.shared.push(
            id: "yieldApps",
            title: "让位应用",
            subtitle: "这些应用使用 Touch Bar 时，模块栏自动收起",
            size: NSSize(width: 540, height: 640)
        ) {
            self.makeYieldAppsBody()
        }
    }

    private func makeYieldAppsBody(width: CGFloat = 492) -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: 420))
        var y: CGFloat = 0

        func addSection(_ title: String, _ symbol: String) {
            let section = WindowDesign.section(title: title, symbol: symbol, accent: .systemPurple)
            section.frame = NSRect(x: 0, y: y, width: container.frame.width, height: 22)
            section.autoresizingMask = [.width]
            container.addSubview(section)
            y += 28
        }

        func addRow(_ bundleID: String, note: String) {
            let row = WindowActionRow(
                frame: NSRect(x: 0, y: y, width: container.frame.width, height: 50),
                title: TouchBarYieldPolicy.displayName(for: bundleID),
                subtitle: "\(note) · \(bundleID)",
                symbol: "app",
                value: nil,
                toggle: true,
                symbolOff: nil,
                image: TouchBarYieldPolicy.icon(for: bundleID),
                target: self,
                action: #selector(toggleYieldApp(_:))
            )
            row.identifier = NSUserInterfaceItemIdentifier(bundleID)
            row.autoresizingMask = [.width]
            row.setSwitchState(on: TouchBarYieldPolicy.isEnabled(bundleID), animated: false)
            container.addSubview(row)
            y += 56
        }

        let installed = TouchBarYieldPolicy.installedDefaultIDs()
        if installed.isEmpty {
            let empty = NSTextField(labelWithString: "没有检测到内置的 Touch Bar 应用")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 8, y: y, width: container.frame.width - 16, height: 20)
            empty.autoresizingMask = [.width]
            container.addSubview(empty)
            y += 26
        } else {
            let systemApps = installed.filter { $0.hasPrefix("com.apple.") }
            let thirdPartyApps = installed.filter { !$0.hasPrefix("com.apple.") }
            if !systemApps.isEmpty {
                addSection("系统内置 · \(systemApps.count)", "apple.logo")
                systemApps.forEach { addRow($0, note: "系统内置") }
            }
            if !thirdPartyApps.isEmpty {
                if !systemApps.isEmpty { y += 6 }
                addSection("第三方 · \(thirdPartyApps.count)", "shippingbox")
                thirdPartyApps.forEach { addRow($0, note: "第三方") }
            }
        }

        let extras = TouchBarYieldPolicy.extraIDs().sorted()
        if !extras.isEmpty {
            y += 6
            addSection("手动添加 · \(extras.count)", "plus.app")
            extras.forEach { addRow($0, note: "手动添加") }
        }

        let learned = TouchBarYieldPolicy.installedLearnedIDs()
        if !learned.isEmpty {
            y += 6
            addSection("自动识别 · \(learned.count)", "sparkle.magnifyingglass")
            learned.forEach { addRow($0, note: "自动识别") }
        }

        if let front = frontmostForeignApp,
           let bundleID = front.bundleIdentifier,
           !TouchBarYieldPolicy.isDefault(bundleID) {
            y += 6
            addSection("当前前台应用", "cursorarrow.rays")
            addRow(bundleID, note: "当前前台")
        }

        y += 6
        let autoLearnRow = WindowActionRow(
            frame: NSRect(x: 0, y: y, width: container.frame.width, height: 50),
            title: "自动识别 Touch Bar 应用",
            subtitle: "检测到应用占用触控栏后自动让位，不用再逐个添加",
            symbol: "sparkle.magnifyingglass",
            value: nil,
            toggle: true,
            symbolOff: nil,
            target: self,
            action: #selector(toggleAutoLearn(_:))
        )
        autoLearnRow.autoresizingMask = [.width]
        autoLearnRow.setSwitchState(on: TouchBarYieldPolicy.autoLearnEnabled, animated: false)
        container.addSubview(autoLearnRow)
        y += 56

        y += 6
        let pickRow = WindowActionRow(
            frame: NSRect(x: 0, y: y, width: container.frame.width, height: 50),
            title: "添加其他应用…",
            subtitle: "名单里没有的应用，选中它的 .app 即可加入",
            symbol: "plus.circle",
            value: nil,
            toggle: false,
            symbolOff: nil,
            target: self,
            action: #selector(addYieldApp)
        )
        pickRow.autoresizingMask = [.width]
        container.addSubview(pickRow)
        y += 56

        container.frame.size.height = y + 16
        return container
    }

    @objc private func toggleAutoLearn(_ row: WindowActionRow) {
        let next = !TouchBarYieldPolicy.autoLearnEnabled
        TouchBarYieldPolicy.autoLearnEnabled = next
        row.setSwitchState(on: next, animated: true)
        AppLog.write("auto learn touch bar apps=\(next)")
    }

    /// 内置名单不可能覆盖所有应用（第三方 App 的 bundle id 也会变），
    /// 所以保留手动入口：选中 .app，读取它真实的 bundle id 加进名单。
    @objc private func addYieldApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "添加让位应用"
        panel.message = "选择会在 Touch Bar 上显示自己控件的应用"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var added: [String] = []
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else { continue }
            TouchBarYieldPolicy.setEnabled(true, for: bundleID)
            added.append(bundleID)
        }
        guard !added.isEmpty else { return }
        manualYieldBypass = false
        textFocusEditing = false
        evaluateTouchBarYield()
        AppLog.write("yield app added \(added.joined(separator: ","))")
        refreshSettingsWindow()
    }

    @objc private func toggleYieldApp(_ row: WindowActionRow) {
        guard let bundleID = row.identifier?.rawValue else { return }
        let next = !TouchBarYieldPolicy.isEnabled(bundleID)
        TouchBarYieldPolicy.setEnabled(next, for: bundleID)
        row.setSwitchState(on: next, animated: true)
        manualYieldBypass = false
        textFocusEditing = false
        evaluateTouchBarYield()
        AppLog.write("yield app \(bundleID)=\(next)")
    }

    private var enabledYieldAppCount: Int {
        let builtIn = TouchBarYieldPolicy.installedDefaultIDs()
            .filter { TouchBarYieldPolicy.isEnabled($0) }
            .count
        let learned = TouchBarYieldPolicy.installedLearnedIDs()
            .filter { TouchBarYieldPolicy.isEnabled($0) }
            .count
        return builtIn + TouchBarYieldPolicy.extraIDs().count + learned
    }

    private var textFocusYieldSubtitle: String {
        guard TouchBarYieldPolicy.textFocusYieldEnabled else {
            return "已关闭；只在名单内应用让位"
        }
        return TouchBarYieldPolicy.accessibilityTrusted
            ? "在输入框打字时让出系统输入建议区域"
            : "需要辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能"
    }

    @objc private func toggleTextFocusYield(_ row: WindowActionRow) {
        let next = !TouchBarYieldPolicy.textFocusYieldEnabled
        TouchBarYieldPolicy.textFocusYieldEnabled = next
        row.setSwitchState(on: next, animated: true)
        textFocusEditing = false
        evaluateTouchBarYield()
        AppLog.write("text focus yield=\(next) trusted=\(TouchBarYieldPolicy.accessibilityTrusted)")
    }

    /// 设置窗口内容：左侧分类栏 + 右侧内容区（参考 Loop Reminder 的两栏布局）。
    /// 把 SF Symbol 等比缩放到统一字形大小，再居中放进固定占位槽。
    /// 这样窄图标不会显得小、宽图标也不会把文字挤开。
    private func sidebarIcon(_ symbol: String, accessibilityDescription: String?,
                             box: CGFloat = 18, glyph: CGFloat = 14, pointSize: CGFloat = 13) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) else { return nil }
        let longest = max(base.size.width, base.size.height)
        guard longest > 0 else { return base }
        let scale = glyph / longest
        let size = NSSize(width: base.size.width * scale, height: base.size.height * scale)
        let canvas = NSImage(size: NSSize(width: box, height: box))
        canvas.lockFocus()
        let rect = NSRect(
            x: (box - size.width) / 2,
            y: (box - size.height) / 2,
            width: size.width,
            height: size.height
        )
        base.draw(in: rect)
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    private func makeSettingsWindowBody() -> NSView {
        let pageSize = MenuDetailWindowController.shared.pageSize
        struct RowSpec {
            let id: String
            let title: String
            let subtitle: String
            let action: Selector
            let symbol: String
            let symbolOff: String?
            let value: String?
            let toggle: Bool
            let on: Bool
        }
        let groups: [(String, String, String, [RowSpec])] = [
            ("显示与布局", "rectangle.3.group", "rectangle.on.rectangle", [
                RowSpec(id: "visible", title: "显示 / 收起模块栏",
                        subtitle: "立即显示或撤下模块栏，不影响常驻设置",
                        action: #selector(self.toggleMainBarVisibility),
                        symbol: "rectangle.on.rectangle",
                        symbolOff: "rectangle.on.rectangle.slash",
                        value: self.mainBarShown ? "已显示" : "已收起",
                        toggle: false, on: self.mainBarShown),
                RowSpec(id: "persistent", title: "在触控栏常驻显示模块",
                        subtitle: "启动、唤醒后自动恢复模块栏",
                        action: #selector(self.togglePersistentModules),
                        symbol: "pin.circle.fill",
                        symbolOff: "pin.circle",
                        value: nil,
                        toggle: true, on: self.persistentModules),
                RowSpec(id: "custom", title: "自定义 Touch Bar 组件",
                        subtitle: "排序、宽度、图标与文字，在右侧展开",
                        action: #selector(self.openCustomizerInSettings),
                        symbol: "slider.horizontal.3",
                        symbolOff: nil,
                        value: nil,
                        toggle: false, on: false),
                RowSpec(id: "menuModules", title: "展开菜单显示…",
                        subtitle: "选择哪些模块出现在菜单栏下拉菜单里",
                        action: #selector(self.openMenuModulesWindow),
                        symbol: "list.bullet.rectangle",
                        symbolOff: nil,
                        value: nil,
                        toggle: false, on: false),
            ]),
            ("电源", "battery.50percent", "battery.50percent", [
                RowSpec(id: "deviceAutoReturn", title: "低电量自动切换策略",
                        subtitle: "谁的电量最低就优先保谁；都低于阈值时优先保本机",
                        action: #selector(self.toggleDeviceAutoReturnRow(_:)),
                        symbol: "arrow.uturn.backward.circle.fill",
                        symbolOff: "arrow.uturn.backward.circle",
                        value: nil,
                        toggle: true, on: PowerFlowPolicyStore.autoReturnEnabled),
                RowSpec(id: "macLowThreshold", title: "本机低电量阈值",
                        subtitle: "低于该比例切到「优先充电」",
                        action: #selector(self.showLowBatteryThresholdMenu(_:)),
                        symbol: "laptopcomputer",
                        symbolOff: nil,
                        value: "\(PowerFlowPolicyStore.macLowPercent)%",
                        toggle: false, on: false),
                RowSpec(id: "deviceLowThreshold", title: "外接设备低电量阈值",
                        subtitle: "低于该比例切到「优先放电」给设备补电",
                        action: #selector(self.showLowBatteryThresholdMenu(_:)),
                        symbol: "ipad",
                        symbolOff: nil,
                        value: "\(PowerFlowPolicyStore.deviceLowPercent)%",
                        toggle: false, on: false),
                RowSpec(id: "balanced", title: "负载均衡区间",
                        subtitle: "充到上限停充，掉到下限再充",
                        action: #selector(self.noopBalancedRow),
                        symbol: "battery.50percent",
                        symbolOff: nil,
                        value: "\(PowerFlowPolicyStore.balancedLowerPercent)–\(PowerFlowPolicyStore.balancedUpperPercent)%",
                        toggle: false, on: false),
            ]),
            ("Touch Bar 让位", "rectangle.on.rectangle.slash", "rectangle.on.rectangle.slash", [
                RowSpec(id: "textFocusYield", title: "输入框聚焦时让位",
                        subtitle: self.textFocusYieldSubtitle,
                        action: #selector(self.toggleTextFocusYield(_:)),
                        symbol: "character.cursor.ibeam",
                        symbolOff: "character.cursor.ibeam",
                        value: nil,
                        toggle: true, on: TouchBarYieldPolicy.textFocusYieldEnabled),
                RowSpec(id: "yieldApps", title: "让位应用…",
                        subtitle: "这些应用使用 Touch Bar 时模块自动收起",
                        action: #selector(self.openYieldAppsWindow),
                        symbol: "app.badge.checkmark",
                        symbolOff: nil,
                        value: "\(self.enabledYieldAppCount) 个",
                        toggle: false, on: false),
            ]),
            ("亮度", "sun.max", "sun.max", [
                RowSpec(id: "brightness", title: "Touch Bar 自动亮度",
                        subtitle: "操作时 100%，空闲后回落到 80%",
                        action: #selector(self.toggleTouchBarMaximumBrightness),
                        symbol: "sun.max.fill",
                        symbolOff: "sun.max",
                        value: nil,
                        toggle: true, on: self.keepTouchBarMaximumBrightness),
                RowSpec(id: "duoPercent", title: "菜单栏图标显示电量数字",
                        subtitle: "三合一图标右侧显示当前电量百分比",
                        action: #selector(self.toggleDuoPercent),
                        symbol: "percent",
                        symbolOff: "percent",
                        value: nil,
                        toggle: true, on: UserDefaults.standard.integer(forKey: "duoIconPercentStyle.v1") == 1),
                RowSpec(id: "hideSystemBattery", title: "隐藏系统电量图标",
                        subtitle: "打开 Bar Control 时自动隐藏系统自带电量",
                        action: #selector(self.toggleHideSystemBattery),
                        symbol: "battery.100percent",
                        symbolOff: "battery.100percent.slash",
                        value: nil,
                        toggle: true, on: UserDefaults.standard.bool(forKey: "hideSystemBatteryIcon.v1")),
            ]),
            ("硬件", "cable.connector", "cable.connector", []),
            ("关于", "info.circle", "info.circle", []),
        ]

        let width = pageSize.width
        let height = pageSize.height
        settingsSidebarWidth = min(320, max(160, settingsSidebarWidth))
        let container = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        settingsRows.removeAll()
        settingsCategoryIndex = min(max(settingsCategoryIndex, 0), groups.count - 1)

        // 左栏
        let sidebarWidth = settingsSidebarWidth
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: height))
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.autoresizingMask = [.height]
        container.addSubview(sidebar)

        // 与内容区之间的分隔线兼拖拽把手：拖动可调整侧栏宽度。
        let divider = SidebarDragHandle(frame: NSRect(x: sidebarWidth - 2, y: 0, width: 5, height: height))
        divider.autoresizingMask = [.height]
        divider.currentWidth = sidebarWidth
        divider.onDrag = { [weak self] newWidth in
            guard let self else { return }
            self.settingsSidebarWidth = min(320, max(160, newWidth))
        }
        divider.onEnd = { [weak self] in
            guard let self else { return }
            MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
        }
        container.addSubview(divider)

        // NSVisualEffectView 不是 flipped，内部再套一层 flipped 画布，
        // 否则分类会从下往上排。
        let sidebarCanvas = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: height))
        sidebarCanvas.autoresizingMask = [.height]
        sidebar.addSubview(sidebarCanvas)

        var sideY: CGFloat = 72
        for (index, group) in groups.enumerated() {
            let button = SidebarItemButton(title: "", target: self, action: #selector(selectSettingsGroup(_:)))
            button.tag = index
            button.isSelected = index == settingsCategoryIndex
            button.isBordered = false
            button.frame = NSRect(x: 10, y: sideY, width: sidebarWidth - 20, height: 32)
            button.setAccessibilityLabel(group.0)
            // 固定图标槽 + 固定文字起点：图标只缩放自己，不参与文字排版。
            let iconView = SidebarPassthroughImageView(frame: NSRect(x: 8, y: 7, width: 18, height: 18))
            iconView.image = sidebarIcon(group.1, accessibilityDescription: group.0)
            iconView.imageScaling = .scaleProportionallyDown
            iconView.contentTintColor = index == settingsCategoryIndex ? .labelColor : .secondaryLabelColor
            button.addSubview(iconView)
            let label = SidebarPassthroughLabel(labelWithString: group.0)
            label.font = .systemFont(ofSize: 13, weight: index == settingsCategoryIndex ? .semibold : .regular)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 34, y: 7, width: button.frame.width - 44, height: 18)
            button.addSubview(label)
            sidebarCanvas.addSubview(button)
            sideY += 40
        }

        // 右栏
        let contentX = sidebarWidth + 28
        let contentWidth = width - contentX - 28

        if settingsPane == .customizer {
            container.addSubview(makeCustomizerPane(x: contentX, width: contentWidth, height: height))
            container.frame.size.height = max(height, 980)
            return container
        }

        let group = groups[settingsCategoryIndex]
        // 右栏独立滚动：接口详情/让位列表展开后内容会超过窗口高度。
        let pane = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 10))

        let titleLabel = NSTextField(labelWithString: group.0)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 0, y: 56, width: contentWidth, height: 26)
        pane.addSubview(titleLabel)

        let subtitles: [String: String] = [
            "显示与布局": "模块栏显示、常驻与自定义入口",
            "电源": "充电策略与自动回切阈值",
            "Touch Bar 让位": "前台应用与输入焦点时自动收起",
            "亮度": "Touch Bar 自动亮度与菜单栏图标",
            "硬件": "充电器、接口与线缆",
            "关于": "版本、更新与开源信息",
        ]
        let subtitleLabel = NSTextField(labelWithString: subtitles[group.0] ?? "")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 0, y: 88, width: contentWidth, height: 18)
        pane.addSubview(subtitleLabel)

        var y: CGFloat = 134
        if group.0 == "关于" {
            let about = makeAboutBody(width: contentWidth - 8)
            about.frame.origin = NSPoint(x: 0, y: y)
            pane.addSubview(about)
            y += about.frame.height + 16
        } else if group.0 == "硬件" {
            let detail = makeSettingsInlineContent(id: "interface", width: contentWidth)
            detail.frame.origin = NSPoint(x: 0, y: y)
            detail.autoresizingMask = [.width]
            pane.addSubview(detail)
            y += detail.frame.height + 16
        } else {
        let inlineIDs: Set<String> = ["menuModules", "yieldApps", "interface"]
        for spec in group.3 {
            let rowHeight: CGFloat = spec.id == "balanced" ? 78 : 50
            let isInline = inlineIDs.contains(spec.id)
            let expanded = settingsInlineExpanded.contains(spec.id)
            let action = isInline
                ? #selector(toggleSettingsInline(_:))
                : spec.action
            let row = WindowActionRow(
                frame: NSRect(x: 0, y: y, width: contentWidth, height: rowHeight),
                title: spec.title,
                subtitle: spec.subtitle,
                symbol: spec.symbol,
                value: isInline ? (expanded ? "收起" : "展开") : spec.value,
                toggle: spec.toggle,
                symbolOff: spec.symbolOff,
                target: self,
                action: action
            )
            if isInline {
                row.identifier = NSUserInterfaceItemIdentifier(spec.id)
                row.setValueText(expanded ? "收起" : "展开",
                                 symbol: spec.symbol,
                                 animated: false)
            }
            if spec.toggle {
                row.setSwitchState(on: spec.on, animated: false)
            } else if let symbolOff = spec.symbolOff {
                row.setValueText(spec.value ?? "", symbol: spec.on ? spec.symbol : symbolOff, animated: false)
            }
            settingsRows[spec.id] = row
            if spec.id == "macLowThreshold" || spec.id == "deviceLowThreshold" {
                row.identifier = NSUserInterfaceItemIdentifier(spec.id)
            }
            if spec.id == "balanced" {
                let lowerField = NSTextField(labelWithString: "下限")
                lowerField.font = .systemFont(ofSize: 10)
                lowerField.textColor = .secondaryLabelColor
                lowerField.frame = NSRect(x: contentWidth - 330, y: 44, width: 26, height: 14)
                row.addSubview(lowerField)
                let lowerSlider = NSSlider(
                    value: Double(PowerFlowPolicyStore.balancedLowerPercent),
                    minValue: 80, maxValue: Double(PowerFlowPolicyStore.balancedUpperPercent - 1),
                    target: self, action: #selector(changeBalancedLower(_:))
                )
                lowerSlider.frame = NSRect(x: contentWidth - 300, y: 41, width: 120, height: 18)
                lowerSlider.controlSize = .small
                row.addSubview(lowerSlider)
                let lowerValue = NSTextField(labelWithString: "\(PowerFlowPolicyStore.balancedLowerPercent)%")
                lowerValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                lowerValue.textColor = .secondaryLabelColor
                lowerValue.frame = NSRect(x: contentWidth - 172, y: 44, width: 40, height: 14)
                row.addSubview(lowerValue)
                balancedLowerSlider = lowerSlider
                balancedLowerLabel = lowerValue

                let upperField = NSTextField(labelWithString: "上限")
                upperField.font = .systemFont(ofSize: 10)
                upperField.textColor = .secondaryLabelColor
                upperField.frame = NSRect(x: contentWidth - 330, y: 16, width: 26, height: 14)
                row.addSubview(upperField)
                let upperSlider = NSSlider(
                    value: Double(PowerFlowPolicyStore.balancedUpperPercent),
                    minValue: Double(PowerFlowPolicyStore.balancedLowerPercent + 1), maxValue: 90,
                    target: self, action: #selector(changeBalancedUpper(_:))
                )
                upperSlider.frame = NSRect(x: contentWidth - 300, y: 13, width: 120, height: 18)
                upperSlider.controlSize = .small
                row.addSubview(upperSlider)
                let upperValue = NSTextField(labelWithString: "\(PowerFlowPolicyStore.balancedUpperPercent)%")
                upperValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                upperValue.textColor = .secondaryLabelColor
                upperValue.frame = NSRect(x: contentWidth - 172, y: 16, width: 40, height: 14)
                row.addSubview(upperValue)
                balancedUpperSlider = upperSlider
                balancedUpperLabel = upperValue
                row.setValueText("\(PowerFlowPolicyStore.balancedLowerPercent)–\(PowerFlowPolicyStore.balancedUpperPercent)%",
                                 symbol: "battery.50percent", animated: false)
            }
            pane.addSubview(row)
            y += rowHeight + 8

            if isInline && expanded {
                let inline = makeSettingsInlineContent(id: spec.id, width: contentWidth - 20)
                inline.frame.origin = NSPoint(x: 20, y: y)
                pane.addSubview(inline)
                y += inline.frame.height + 8
            }

        }

        }
        pane.frame.size.height = max(height, y + 24)
        let paneScroll = NSScrollView(frame: NSRect(x: contentX, y: 0, width: contentWidth, height: height))
        paneScroll.hasVerticalScroller = true
        paneScroll.autohidesScrollers = true
        paneScroll.drawsBackground = false
        paneScroll.borderType = .noBorder
        paneScroll.documentView = pane
        container.addSubview(paneScroll)
        container.frame.size.height = height
        return container
    }

    func debugExpandInlineMenuModules() {
        settingsInlineExpanded.insert("menuModules")
        MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
    }

    @objc private func toggleSettingsInlineMenuModules(_ row: WindowActionRow) {
        toggleSettingsInline(row)
    }

    /// 设置页里的“展开/收起”行：只重建当前页，不新开窗口。
    @objc private func toggleSettingsInline(_ row: WindowActionRow) {
        guard let id = row.identifier?.rawValue else { return }
        if settingsInlineExpanded.contains(id) {
            settingsInlineExpanded.remove(id)
        } else {
            settingsInlineExpanded.insert(id)
        }
        MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
    }

    @objc private func selectSettingsGroup(_ sender: NSButton) {
        settingsCategoryIndex = sender.tag
        settingsPane = .category
        MenuDetailWindowController.shared.updateIfVisible { self.makeSettingsWindowBody() }
    }

    @objc private func toggleDuoPercent(_ row: WindowActionRow) {
        let next = UserDefaults.standard.integer(forKey: "duoIconPercentStyle.v1") == 1
            ? 0 : 1
        UserDefaults.standard.set(next, forKey: "duoIconPercentStyle.v1")
        row.setSwitchState(on: next == 1, animated: true)
        duoMenuIcon?.reloadStyle()
        AppLog.write("duo icon percent=\(next == 1)")
    }

    @objc private func toggleHideSystemBattery(_ row: WindowActionRow) {
        let defaults = UserDefaults.standard
        let next = !defaults.bool(forKey: "hideSystemBatteryIcon.v1")
        defaults.set(next, forKey: "hideSystemBatteryIcon.v1")
        row.setSwitchState(on: next, animated: true)
        DuoMenuIcon.applySystemBatteryVisibility()
        AppLog.write("hide system battery=\(next)")
    }

    @objc private func noopBalancedRow() {}

    @objc private func changeBalancedLower(_ sender: NSSlider) {
        PowerFlowPolicyStore.balancedLowerPercent = Int(sender.doubleValue.rounded())
        refreshBalancedRow()
        AppLog.write("balanced lower=\(PowerFlowPolicyStore.balancedLowerPercent)")
    }

    @objc private func changeBalancedUpper(_ sender: NSSlider) {
        PowerFlowPolicyStore.balancedUpperPercent = Int(sender.doubleValue.rounded())
        refreshBalancedRow()
        AppLog.write("balanced upper=\(PowerFlowPolicyStore.balancedUpperPercent)")
    }

    /// 两个滑块互相约束（下限 < 上限），并同步文案与实际策略。
    private func refreshBalancedRow() {
        let lower = PowerFlowPolicyStore.balancedLowerPercent
        let upper = PowerFlowPolicyStore.balancedUpperPercent
        balancedLowerSlider?.maxValue = Double(upper - 1)
        balancedLowerSlider?.doubleValue = Double(lower)
        balancedUpperSlider?.minValue = Double(lower + 1)
        balancedUpperSlider?.doubleValue = Double(upper)
        balancedLowerLabel?.stringValue = "\(lower)%"
        balancedUpperLabel?.stringValue = "\(upper)%"
        settingsRows["balanced"]?.setValueText("\(lower)–\(upper)%",
                                               symbol: "battery.50percent", animated: false)
        if PowerFlowPolicyStore.current == .balanced {
            ChargingLimitController.shared.update(policy: .balanced, metrics: systemMetrics, userInitiated: true)
        }
    }

    private func refreshSettingsWindow() {
        MenuDetailWindowController.shared.updateIfVisible { [weak self] in
            guard let self else { return NSView() }
            return self.makeSettingsWindowBody()
        }
    }

    @objc private func openServiceLogsFolderWithoutMenu() {
        openServiceLogsFolder()
    }

    /// 用缓存构建服务分组，由 InlineMenuSections 转为向下展开的行。
    private func buildServicesMenuItem() -> NSMenuItem {
        let snapshot = ServiceMonitor.cachedSnapshot
        let all = ServiceMonitor.services()
        // snapshot.states 与 all 一一对应。
        let resident = zip(all, snapshot.states).filter { !$0.0.isScheduled }
        let scheduled = zip(all, snapshot.states).filter { $0.0.isScheduled }

        let item = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        item.toolTip = "常驻服务与定时任务；绿点表示正在运行"
        item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "服务")

        let submenu = NSMenu(title: "服务监控")
        submenu.autoenablesItems = false
        submenu.addItem(buildServiceGroupItem(
            title: "常驻任务",
            running: resident.filter { $0.1 == .running }.count,
            total: resident.count,
            entries: resident
        ))
        submenu.addItem(buildServiceGroupItem(
            title: "定时任务",
            running: scheduled.filter { $0.1 == .running }.count,
            total: scheduled.count,
            entries: scheduled
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem("查看全部服务日志目录", #selector(openServiceLogsFolder)))
        item.submenu = submenu
        return item
    }

    /// 单个分组：折叠标题「● N/M 常驻任务」，展开后逐行列出状态与动作。
    private func buildServiceGroupItem(
        title: String,
        running: Int,
        total: Int,
        entries: [(ServiceMonitor.Service, ServiceMonitor.State)]
    ) -> NSMenuItem {
        let header = NSMenuItem(
            title: "\(runColorDot(running > 0)) \(running)/\(total) \(title)",
            action: nil,
            keyEquivalent: ""
        )
        header.toolTip = "绿点表示该组至少一个服务在运行"

        let group = NSMenu(title: title)
        group.autoenablesItems = false
        for (service, state) in entries {
            let row = NSMenuItem(title: serviceRowTitle(service, state: state), action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.image = Self.stateDot(state)
            group.addItem(row)
            if let action = service.action, let title = service.actionTitle {
                // 动作宿主是 BridgeActions，不能走 menuItem()（它把 target 设为 self），
                // 否则 selector 在 TouchBarController 上找不到，点击会静默失败。
                let actionItem = NSMenuItem(title: "    \(title)", action: nil, keyEquivalent: "")
                actionItem.target = ServiceMonitorActionRouter.shared
                actionItem.representedObject = service
                actionItem.action = #selector(ServiceMonitorActionRouter.runMenuItem(_:))
                group.addItem(actionItem)
            }
        }
        header.submenu = group
        return header
    }

    private func serviceRowTitle(_ service: ServiceMonitor.Service, state: ServiceMonitor.State) -> String {
        let label: String
        switch state {
        case .running: label = "运行中"
        case .stopped: label = "已停止"
        case .onDemand: label = "按需"
        case .unknown: label = "未知"
        }
        return "\(service.name) — \(label)（\(service.role)）"
    }

    /// 绿点前缀：用 SF Symbol 生成 12pt 模板图，NSMenuItem 标题前置 emoji 不稳定。
    private func runColorDot(_ on: Bool) -> String { on ? "●" : "○" }

    /// 状态点图标：绿=运行，灰=停止，黄=按需。
    static func stateDot(_ state: ServiceMonitor.State) -> NSImage? {
        let name: String
        let color: NSColor
        switch state {
        case .running: name = "circle.fill"; color = .systemGreen
        case .stopped: name = "circle.fill"; color = .systemGray
        case .onDemand: name = "circle.fill"; color = .systemYellow
        case .unknown: name = "questionmark.circle"; color = .secondaryLabelColor
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let sized = base.withSymbolConfiguration(config) ?? base
        sized.isTemplate = false
        // 用 NSImage tint：包一层并着色。
        let tinted = NSImage(size: sized.size, flipped: false) { rect in
            color.set()
            sized.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }

    @objc private func openServiceLogsFolder() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        NSWorkspace.shared.open(logs)
    }

    // MARK: - Keyboard lock

    @objc private func toggleKeyboardLock() {
        noteTouchBarInteraction()
        let controller = KeyboardLockController.shared
        let target = !controller.isLocked
        if !controller.setLocked(target, reason: "user") {
            openKeyboardLockPermissionSettings()
        }
        refreshKeyboardLockButton()
        updateMenuSummary(for: .keyboardLock)
    }

    @objc private func toggleKeyboardLockAutoUnlock() {
        let controller = KeyboardLockController.shared
        controller.setAutoUnlockOnPower(!controller.autoUnlockOnPower)
        updateMenuSummary(for: .keyboardLock)
    }

    @objc private func recheckKeyboardLockPermission() {
        KeyboardLockController.shared.refreshPermission()
        refreshKeyboardLockButton()
        updateMenuSummary(for: .keyboardLock)
    }

    @objc private func openKeyboardLockPermissionSettings() {
        statusItem.menu?.cancelTracking()
        KeyboardLockController.shared.requestPermission()
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 按 Touch Bar 模块生成对应的二级菜单，命令按模块语义归类。
    private func makeModuleSubmenu(for component: MainComponent) -> NSMenu {
        let submenu = NSMenu(title: component.title)
        switch component {
        case .sidecar:
            submenu.addItem(menuItem("切换随航", #selector(openSidecar)))
            submenu.addItem(menuItem("修复随航黑屏并重新连接", #selector(sidecarEnvironmentFix)))
            submenu.addItem(menuItem("控制环境修复", #selector(controlEnvironmentFix)))
        case .clipboard:
            submenu.addItem(menuItem("打开剪贴板历史", #selector(showClipboardHistory)))
            submenu.addItem(menuItem("暂停 / 恢复记录", #selector(toggleClipboardCapture)))
            submenu.addItem(menuItem("清空历史", #selector(clearClipboardHistory)))
        case .keyboardLock:
            let controller = KeyboardLockController.shared
            if controller.presentation.permissionMissing {
                submenu.addItem(menuItem("打开辅助功能授权…", #selector(openKeyboardLockPermissionSettings)))
                submenu.addItem(menuItem("我已授权，重新检测", #selector(recheckKeyboardLockPermission)))
            } else {
                submenu.addItem(menuItem(
                    controller.isLocked ? "解锁键盘" : "锁定键盘",
                    #selector(toggleKeyboardLock)
                ))
            }
            let autoUnlock = menuItem("接上电源时自动解锁", #selector(toggleKeyboardLockAutoUnlock))
            autoUnlock.state = controller.autoUnlockOnPower ? .on : .off
            submenu.addItem(autoUnlock)
            submenu.addItem(.separator())
            submenu.addItem(menuItem("打开辅助功能设置…", #selector(openKeyboardLockPermissionSettings)))
        case .aiCoding:
            // 简洁信息模式：AI coding 不提供二级菜单和窗口。
            break
        case .systemMonitor:
            // 已移入「自定义 Touch Bar 组件」面板；菜单栏不再提供该模块分组。
            break
        }
        return submenu
    }

    /// 子菜单展开时按最新快照刷新「AI Coding 显示」内容。
    /// 用内容指纹守卫：内容没变（例如刚切换了某个勾选）绝不重建，避免菜单在展开中被清空退出。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === aiDisplayMenu else { return }
        let key = (snapshot.accounts ?? []).map { "\($0.clientID)/\($0.key)" }.joined(separator: "|")
        guard key != aiDisplayMenuKey else { return }
        rebuildAIDisplayMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        let started = CACurrentMediaTime()
        lastTouchBarInteractionAt = Date()
        mainMenuIsOpen = true
        aiDisplayMenuOpen = true
        refreshApplicationYieldRow()
        refreshPowerMenuControls()
        // 首帧使用最近一次真实采样；冷启动显示已有占位，采样完成后原位更新。
        powerFlowView?.metrics = systemMetrics
        powerFlowView?.interfaceSpecs = interfaceSpecs
        inlineMenuSections?.updateSummary(servicesSummary, for: "services", badges: serviceBadges)
        for component in componentOrder {
            updateMenuSummary(for: component)
        }
        powerFlowView?.startAnimating()
        // 将采样调度到首帧之后，打开回调本身不做 IO。
        DispatchQueue.main.async { [weak self] in
            self?.refreshSystemMetrics()
            self?.refreshServicesMenuItem()
        }
        AppLog.write("menu open cached callback \(String(format: "%.1f", (CACurrentMediaTime() - started) * 1_000))ms")
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        mainMenuIsOpen = false
        aiDisplayMenuOpen = false
        if pendingAIQuotaRefresh {
            pendingAIQuotaRefresh = false
            quotaView?.update(with: snapshot.limits, platforms: snapshot.platforms, accounts: snapshot.accounts)
        }
        powerFlowView?.stopAnimating()
        // 跟踪期间不替换菜单；关闭后吸收最新服务、账户和开关状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildMenu()
        }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 右侧固定区只放一个独立图标：键盘锁。
    /// 以前这里还有 Bar Control 的入口图标，两项并排会让 DFR 把托盘项挤掉；
    /// 入口改到菜单栏的「显示 Touch Bar 模块栏」，固定区只留锁。
    /// 右侧固定区只放 Bar Control 入口；键盘锁只在模块胶囊里（用户选择）。
    /// DFR 偶尔会把托盘项“注册成功但不显示”，而用同一个 identifier 反复
    /// remove/add 无法打破这个状态。每次重绑换一个递增的 identifier，
    /// 让系统当成全新托盘项处理；模态锚点也跟着换。
    private func rotateControlStripIdentifier() {
        let key = ["touchBar", "Strip", "Identifier", "Generation", "v1"].joined()
        controlStripGeneration = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(controlStripGeneration, forKey: key)
        controlStripIdentifier = NSTouchBarItem.Identifier(
            "\(Item.keyboardLockStripBase).g\(controlStripGeneration)"
        )
    }

    private func installControlStripItem() {
        AppLog.write("control strip supported=\(ControlStrip.isSupported)")
        guard ControlStrip.isSupported else { return }
        // 用系统自带的 NSButtonTouchBarItem 渲染托盘项：自定义 NSView 在
        // ControlStrip 重启后会出现“窗口还在、内容不绘制”的幽灵状态。
        // 图标用位图重绘的 template 版本（缩放后的 NSImage 副本在固定区会
        // 渲染成空白），失败时才退回 SF Symbol。
        let logo = trayLogoImage()
            ?? NSImage(
                systemSymbolName: "chevron.left.forwardslash.chevron.right",
                accessibilityDescription: "显示 Bar Control"
            )
        guard let logo else { return }
        logo.isTemplate = true
        let item = NSButtonTouchBarItem(
            identifier: controlStripIdentifier,
            image: logo,
            target: self,
            action: #selector(showMain)
        )
        // 固定区空间紧张时系统会按优先级先隐藏低优先级项。
        item.visibilityPriority = NSTouchBarItem.Priority(rawValue: 1000)
        let added = ControlStrip.add(item)
        controlStripItem = added ? item : nil
        lastStripInstallAt = Date()
        AppLog.write("control strip add=\(added) id=\(controlStripIdentifier.rawValue) kind=button")
    }

    /// 把模板图的颜色烘进去：控制条的 template 渲染在这里会看不见。
    static func tinted(_ image: NSImage?, color: NSColor) -> NSImage? {
        guard let image else { return nil }
        let copy = NSImage(size: image.size)
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }

    static func fitted(_ image: NSImage?, _ side: CGFloat) -> NSImage? {
        guard let image, let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: side, height: side)
        return copy
    }

    private var lastLockStripCheck = Date.distantPast
    private var lastStripInstallAt = Date.distantPast
    private var stripBlankChecks = 0
    private var loggedCaptureBlocked = false

    /// 重新注册固定区托盘项（按 fn/小地球切到 F1–F12、或 DFR 丢弃后会用到）。
    private func reinstallControlStripItems() {
        let wasShown = mainBarShown && Date() >= mainBarHiddenUntil
        if let item = controlStripItem { ControlStrip.remove(item) }
        controlStripItem = nil
        rotateControlStripIdentifier()
        installControlStripItem()
        // 重绑后把模态重新挂到新锚点上，避免“重绑＝收起”。
        if wasShown { presentTouchBar() }
    }

    private var lastStripDiag = Date.distantPast
    private var lastStripDiagKey = ""

    /// ControlStrip 进程重启（唤醒、DFR 崩溃、切 F1–F12）后，旧的托盘窗口对象
    /// 仍会 report visible，但远端宿主已经没了——表现为图标凭空消失。
    /// 用 PID 变化作为“必须重绑”的硬信号。
    private var lastControlStripPID: pid_t = 0

    private func controlStripPID() -> pid_t {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier?.lowercased() == "com.apple.controlstrip" }?
            .processIdentifier ?? 0
    }

    private func ensureKeyboardLockStripAlive() {
        guard !isScreenLocked else { return }
        let stripPID = controlStripPID()
        if stripPID != 0 {
            if lastControlStripPID != 0, stripPID != lastControlStripPID {
                AppLog.write("ControlStrip restarted \(lastControlStripPID)->\(stripPID); re-registering")
                lastControlStripPID = stripPID
                reinstallControlStripItems()
                return
            }
            lastControlStripPID = stripPID
        }
        let window = controlStripItem?.view?.window
        let visible = window?.isVisible ?? false
        let occlusion = window?.occlusionState.rawValue ?? 0
        if Date().timeIntervalSince(lastStripDiag) > 10 {
            lastStripDiag = Date()
            let key = "v=\(visible) o=\(occlusion) f=\(window?.frame.debugDescription ?? "nil") shown=\(mainBarShown)"
            if key != lastStripDiagKey {
                lastStripDiagKey = key
                AppLog.write("strip diag \(key)")
            }
        }
        // 诊断探针：每 60 秒对固定区截图一次，量化“注册成功但不绘制”的状态。
        // 只在模态未显示且别的 App 未持锁时做，避免干扰。
        if !mainBarShown, Date() >= mainBarHiddenUntil,
           Date().timeIntervalSince(lastInvisibleProbeAt) > 60,
           controlStripItem != nil {
            lastInvisibleProbeAt = Date()
            let result = classifyRealTouchBar(stage: "strip-probe")
            AppLog.write("strip probe captured=\(result.captured) hasContent=\(result.hasContent)")
            if result.captured && !result.hasContent && visible {
                stripBlankChecks += 1
                if stripBlankChecks >= 2 {
                    stripBlankChecks = 0
                    AppLog.write("strip item blank twice; re-registering")
                    reinstallControlStripItems()
                    return
                }
            } else {
                stripBlankChecks = 0
            }
        }
        // 模态正在显示时不动锚点，否则触控栏会立刻收起。
        guard !mainBarShown else { return }
        guard window == nil || !visible else { return }
        guard Date().timeIntervalSince(lastLockStripCheck) > 5 else { return }
        lastLockStripCheck = Date()
        AppLog.write("control strip item not visible; re-registering")
        reinstallControlStripItems()
    }


    private func refresh() {
        KeyboardLockController.shared.refreshPermission()
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let next = await statusClient.fetch()
            snapshot = next
            isRefreshing = false
            updateVisibleStatus()
        }
    }

    /// 策略变更后立即采样，并在硬件重新协商期间短时追踪；不叠加并发读取。
    private func refreshAfterPowerPolicyChange() {
        powerPolicyRefreshTask?.cancel()
        refreshSystemMetrics()
        powerPolicyRefreshTask = Task { [weak self] in
            for _ in 0..<24 {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self else { return }
                self.refreshSystemMetrics()
            }
        }
    }

    private func refreshSystemMetrics() {
        if isMetricsRefreshing {
            // An IORegistry read can stall (notably right after wake). Without
            // this watchdog the 1s timer would silently stop updating the
            // panel forever.
            if let startedAt = metricsFetchStartedAt,
               Date().timeIntervalSince(startedAt) < 8 {
                return
            }
            AppLog.write("metrics refresh watchdog: previous fetch exceeded 8s")
        }
        isMetricsRefreshing = true
        metricsFetchStartedAt = Date()
        Task { [weak self] in
            let next = await SystemMetricsReader.fetch()
            guard let self else { return }
            systemMetrics = next
            duoMenuIcon?.update(battery: next.batteryPercent, charging: next.showsChargingIndicator)
            // 功率与设备走向先上屏，不等待接口/线缆详情的 IORegistry 扫描。
            lastPanelMetricsAt = Date()
            updateSystemMonitor()
            powerFlowView?.metrics = next
            systemDetailView?.metrics = next
            updateMenuSummary(for: .systemMonitor)
            let needsInterfaceSpecs = interfaceSpecsPowerState != next.externalPower
                || Date().timeIntervalSince(interfaceSpecsReadAt) > 30
            if needsInterfaceSpecs {
                interfaceSpecs = await Task.detached(priority: .utility) { InterfaceSpecsReader.read() }.value
                interfaceSpecsReadAt = Date()
                interfaceSpecsPowerState = next.externalPower
            }
            isMetricsRefreshing = false
            metricsFetchStartedAt = nil
            powerFlowView?.interfaceSpecs = interfaceSpecs
            InterfaceDetailWindowController.shared.updateIfVisible(
                specs: interfaceSpecs,
                metrics: next
            )
            // Auto rules only run after the panel has claimed the limit, so
            // an externally configured limit is never overwritten silently.
            self.applyAutomaticPowerPolicy(for: next)
            self.diagnoseChargerBottleneck(next)
            // 开启低电量自动策略时由 Bar Control 接管充电上限：
            // 只有「优先充电」才放开到 100%，其余策略保持 80–90% / 当前电量。
            ChargingLimitController.shared.update(
                policy: PowerFlowPolicyStore.current,
                metrics: next,
                userInitiated: PowerFlowPolicyStore.autoReturnEnabled
            )
            self.powerFlowView?.metrics = next
            let metricsKey = systemMonitorToolTip
            if lastLoggedMetrics.isEmpty {
                let adapter = next.adapterLimitWatts.map { String(format: "%.1f", $0) } ?? "--"
                let battery = next.batteryWatts.map { String(format: "%.1f", $0) } ?? "--"
                let input = next.inputWatts.map { String(format: "%.1f", $0) } ?? "--"
                let outputs = next.usbOutputs.map { "\($0.name):\(String(format: "%.1f", $0.watts))W" }.joined(separator: ",")
                AppLog.write("metrics \(metricsKey) adapter=\(adapter) input=\(input) battery=\(battery) usbOut=[\(outputs)] external=\(next.externalPower) iPadBattery=\(next.externalBatteryPercent.map(String.init) ?? "unknown")")
            }
            lastLoggedMetrics = metricsKey
        }
    }

    private func updateSystemMonitor() {
        guard let button = systemMonitorButton else { return }
        // 跑猫动画只反映本机净功耗：从整机读数里扣掉转发给外设的功率。
        button.watts = systemMetrics.localComputerWatts
            ?? systemMetrics.systemWatts
            ?? systemMetrics.sourceWatts
        button.toolTip = systemMonitorToolTip
        updateMainModuleWidths()
    }

    private var systemMonitorToolTip: String {
        let power = systemMetrics.systemWatts.map { String(format: "%.1f W", $0) } ?? "-- W"
        let memory = systemMetrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--"
        let gpu = systemMetrics.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "--"
        let cpuPower = systemMetrics.cpuWatts.map { String(format: "%.2f W", $0) } ?? "--"
        let gpuPower = systemMetrics.gpuWatts.map { String(format: "%.2f W", $0) } ?? "--"
        let temperature = systemMetrics.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "--"
        return "整机功率 \(power) · CPU 功率 \(cpuPower) · GPU 功率 \(gpuPower) · 内存占用 \(memory) · GPU 占用 \(gpu) · 电池温度 \(temperature)"
    }


    private func updateVisibleStatus() {
        refreshServicesMenuItem()
        for component in componentOrder {
            updateMenuSummary(for: component)
        }
        let color = stateColor
        aiActivityMark?.taskState = snapshot.state
        aiActivityMark?.activeCount = snapshot.activeCount
        if let aiCodingButton {
            let aiTitle = effectiveTitle(for: .aiCoding) ?? "AI coding"
            setVisibleTitle(aiCodingButton, text: aiTitle)
            aiCodingButton.contentTintColor = color
            aiCodingButton.toolTip = snapshot.activeCount > 0
                ? "\(snapshot.activeCount) 个任务运行中 · \(snapshot.label)"
                : "AI coding · \(snapshot.label)"
        }
        quotaView?.update(with: snapshot.limits, platforms: snapshot.platforms, accounts: snapshot.accounts)
        if let selectedUsageAccountKey {
            usageDetailView?.usage = snapshot.accounts?.first { $0.key == selectedUsageAccountKey }
        }
        updateSidecarButton(animated: true)

        statusItem.button?.toolTip = "AI coding · \(snapshot.label)"

        let statusKey = "\(snapshot.state):\(snapshot.activeCount):\(snapshot.label)"
        if statusKey != lastLoggedStatus {
            lastLoggedStatus = statusKey
            AppLog.write("status \(statusKey)")
        }
    }

    /// 服务探测不阻塞菜单或 3 秒状态刷新，跟踪期间只更新摘要。
    private func refreshServicesMenuItem() {
        ServiceMonitor.refreshIfNeeded { [weak self] _ in
            guard let self else { return }
            self.inlineMenuSections?.updateSummary(self.servicesSummary, for: "services", badges: self.serviceBadges)
            self.rebuildMenu()
        }
    }

    private func layoutAIActivityMark() {
        aiActivityMark?.frame = NSRect(x: 1, y: 2, width: 28, height: 26)
    }

    private var stateColor: NSColor {
        switch snapshot.state {
        case "running": return .systemGreen
        case "completed": return .systemBlue
        case "aborted": return .systemRed
        default: return .white
        }
    }

    private func refreshSidecarStatus() {
        SidecarConnectionMonitor.refreshIfNeeded { [weak self] in
            guard let self else { return }
            self.updateMenuSummary(for: .sidecar)
        }
        // 主模块只反映一次操作的短暂状态；连接与否在菜单摘要/详情窗口中展示。
        // 不根据“系统检测到 iPad”改写为 success，否则动画结束后无法回到默认双向态。
        let next = SidecarStatus.load(from: sidecarStateURL)
        // 结果页至少完整展示 minimumResultDisplay 秒，避免一闪而过。
        if next.state == "idle", let shownAt = sidecarTransientShownAt {
            let elapsed = Date().timeIntervalSince(shownAt)
            if elapsed < SidecarStatus.minimumResultDisplay {
                let remaining = SidecarStatus.minimumResultDisplay - elapsed
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.refreshSidecarStatus()
                }
                return
            }
            sidecarTransientShownAt = nil
        }
        if ["success", "failure"].contains(next.state), sidecarStatus.state != next.state {
            sidecarTransientShownAt = Date()
        }
        let previous = sidecarStatus
        let changed = next != sidecarStatus
        sidecarStatus = next
        if changed {
            updateMenuSummary(for: .sidecar)
        }
        if next.state == "connecting" {
            sidecarFrame = (sidecarFrame + 1) % 4
        } else if changed {
            sidecarFrame = 0
            sidecarSpinTimer?.invalidate()
            sidecarSpinTimer = nil
        }
        updateSidecarButton(animated: changed)
        if changed {
            AppLog.write("sidecar \(next.state):\(next.message):\(next.detail)")
        }
        if next.state == "idle", ["success", "failure"].contains(previous.state) {
            // 等系统交还触控栏（前台不是别人、随航空闲），最长等 8 秒，每 0.5 秒试一次。
            func attemptRestore(_ attempt: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    guard self.mainBarShown, Date() >= self.mainBarHiddenUntil else { return }
                    guard TouchBarPresentationPolicy.shouldAutoExpand(
                        persistent: self.persistentModules,
                        yieldingToApp: self.shouldYieldTouchBar,
                        systemOwnsTouchBar: self.systemOwnsTouchBar
                    ) else {
                        if attempt < 16 { attemptRestore(attempt + 1) }
                        else { AppLog.write("sidecar finished; bar still occupied, skip auto expand") }
                        return
                    }
                    AppLog.write("sidecar finished; restoring main Touch Bar (bar free)")
                    self.autoShowMain()
                }
            }
            attemptRestore(0)
        }
    }

    private var sidecarTitle: String {
        let suffix = sidecarStatus.detail.isEmpty ? "" : "  \(sidecarStatus.detail)"
        switch sidecarStatus.state {
        case "connecting":
            let frames = ["◐", "◓", "◑", "◒"]
            return "\(frames[sidecarFrame % frames.count]) \(sidecarStatus.message)\(suffix)"
        case "success": return "✓ \(sidecarStatus.message)\(suffix)"
        case "failure": return "✕ \(sidecarStatus.message)\(suffix)"
        default:
            if let override = effectiveTitle(for: .sidecar) { return override }
            return "随航 ⇄ 通用控制"
        }
    }

    private var sidecarColor: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch sidecarStatus.state {
        case "connecting": rgb = (48, 76, 112)
        case "success": rgb = (34, 112, 66)
        case "failure": rgb = (150, 45, 45)
        default: rgb = (38, 42, 50)
        }
        return NSColor(calibratedRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }

    private func updateSidecarButton(animated: Bool) {
        guard let sidecarButton else { return }
        let title = sidecarTitle
        let changed = sidecarButton.attributedTitle.string != title
        if animated, changed, let layer = sidecarButton.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "sidecarTitle")
        }
        setVisibleTitle(sidecarButton, text: title)
        sidecarButton.layer?.backgroundColor = sidecarColor.cgColor
        updateMainModuleWidths()
    }

    private var sidecarWidth: CGFloat {
        let configured = displayedModuleWidth(for: .sidecar)
        guard sidecarStatus.state != "idle" else { return configured }
        return max(configured, 184, pillWidth(title: sidecarTitle, button: sidecarButton, min: 72, max: 300))
    }

    private var aiCodingWidth: CGFloat {
        displayedModuleWidth(for: .aiCoding)
    }

    private var keyboardLockPresentation: KeyboardLockPresentation {
        KeyboardLockController.shared.presentation
    }

    private var keyboardLockColor: NSColor {
        let presentation = keyboardLockPresentation
        if presentation.permissionMissing {
            return NSColor(calibratedRed: 108 / 255, green: 74 / 255, blue: 22 / 255, alpha: 1)
        }
        return presentation.locked
            ? NSColor(calibratedRed: 138 / 255, green: 42 / 255, blue: 46 / 255, alpha: 1)
            : NSColor(calibratedRed: 52 / 255, green: 58 / 255, blue: 68 / 255, alpha: 1)
    }

    private var keyboardLockWidth: CGFloat {
        // 只有图标，宽度固定成单图标胶囊。
        MainComponent.keyboardLock.defaultWidth
    }

    private func refreshKeyboardLockButton() {
        guard let button = keyboardLockButton else { return }
        let presentation = keyboardLockPresentation
        let stateChanged = lastKeyboardLockState != presentation.locked
        lastKeyboardLockState = presentation.locked
        setVisibleTitle(button, text: "")
        if !keyboardLockAnimating || stateChanged {
            button.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: presentation.title)
                ?? button.image
        }
        button.layer?.backgroundColor = keyboardLockColor.cgColor
        button.setAccessibilityLabel(presentation.title)
        button.toolTip = presentation.permissionMissing
            ? "键盘锁缺少辅助功能权限，点按打开系统设置"
            : (presentation.locked
                ? "键盘已锁定：鼠标、触控板与 Touch Bar 仍可用；接电源会自动解锁"
                : "点按锁定键盘（只吞硬件键盘事件，触控栏与触控板不受影响）")
        if stateChanged, !presentation.permissionMissing {
            animateKeyboardLockIcon(to: presentation.locked)
        }
        updateMainModuleWidths()
    }


    /// 键盘锁只有图标，切换时用「开锁↔闭锁」几帧翻转 + 一次轻微弹跳代替文字动画，
    /// 手感对齐随航模块的即时反馈。
    private func animateKeyboardLockIcon(to locked: Bool) {
        guard let button = keyboardLockButton else { return }
        keyboardLockAnimationTimer?.invalidate()
        keyboardLockAnimationFrames = locked
            ? ["lock.open.fill", "lock.rotation.open", "lock.rotation", "lock.fill"]
            : ["lock.fill", "lock.rotation", "lock.rotation.open", "lock.open.fill"]
        keyboardLockAnimationFrame = 0
        keyboardLockAnimating = true
        if let layer = button.layer {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.16
            pulse.duration = 0.08
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(pulse, forKey: "keyboardLockPulse")
        }
        applyKeyboardLockFrame()
        let timer = Timer(timeInterval: 0.065, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceKeyboardLockAnimation() }
        }
        keyboardLockAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyKeyboardLockFrame() {
        guard keyboardLockAnimationFrames.indices.contains(keyboardLockAnimationFrame),
              let button = keyboardLockButton else { return }
        let symbol = keyboardLockAnimationFrames[keyboardLockAnimationFrame]
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: keyboardLockPresentation.title)
            ?? button.image
    }

    private func advanceKeyboardLockAnimation() {
        guard keyboardLockAnimating else {
            keyboardLockAnimationTimer?.invalidate()
            keyboardLockAnimationTimer = nil
            return
        }
        keyboardLockAnimationFrame += 1
        if keyboardLockAnimationFrame < keyboardLockAnimationFrames.count {
            applyKeyboardLockFrame()
            return
        }
        keyboardLockAnimationTimer?.invalidate()
        keyboardLockAnimationTimer = nil
        keyboardLockAnimating = false
        let presentation = keyboardLockPresentation
        keyboardLockButton?.image = NSImage(
            systemSymbolName: presentation.symbol,
            accessibilityDescription: presentation.title
        ) ?? keyboardLockButton?.image
    }

    private func displayedModuleWidth(for component: MainComponent) -> CGFloat {
        if component.supportsIconAndTextCustomization, effectiveTitle(for: component) == "" {
            return 44
        }
        return configuredWidth(for: component)
    }

    private func configuredWidth(for component: MainComponent) -> CGFloat {
        componentWidths[component] ?? component.defaultWidth
    }

    private func pillWidth(title: String, button: NSButton?, min: CGFloat, max: CGFloat, iconOnly: CGFloat = 44) -> CGFloat {
        guard !title.isEmpty else { return iconOnly }
        let font = button?.font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return Swift.min(max, Swift.max(min, textWidth + 56))
    }

    /// 更新主层每个模块 item view 的宽度约束。
    /// 模块是独立 NSTouchBarItem，宽度由 widthAnchor 约束决定（系统按 defaultItemIdentifiers
    /// 顺序排布、空槽位用空占位 item 占位）；这里只更新各模块当前应显示的宽度。
    /// 呈现后 1 秒内按 20ms 轮询窗口真实宽度，只在宽度变化时重排。
    private func schedulePostPresentLayout() {
        var attempts = 0
        var lastWidth: CGFloat = -1
        var didDeepRecover = false
        func tick() {
            // 这个兜底只针对主层；详情/系统/剪贴板层的窗口不是主容器，
            // 用主容器宽度判断会误判 0 宽并触发深度重建，把详情踢回主层。
            guard touchBar.defaultItemIdentifiers == mainIdentifiers else { return }
            attempts += 1
            let elapsed = Double(attempts) * 0.02
            let width = mainContainerView?.window?.frame.width ?? 0
            if width >= 200 {
                if abs(width - lastWidth) > 0.5 {
                    lastWidth = width
                    updateMainModuleWidths()
                }
            } else if elapsed > 0.3, !didDeepRecover, mainBarShown,
                      !systemOwnsTouchBar,
                      Date().timeIntervalSince(lastDeepRecoveryAt) > 10 {
                // 随航重连/显示排列恢复时，DFR 模态可能一直保持 0 宽。
                // 普通 present 救不回来，这里主动做一次深度重建。
                didDeepRecover = true
                AppLog.write("post-present width still 0; deep rebuild")
                lastSelfHealAt = .distantPast
                healDFR(deep: true, reason: "post-present zero width")
                return
            }
            if attempts < 150 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { tick() }
            }
        }
        tick()
    }

    private func updateMainModuleWidths() {
        layoutMainButtons()
    }

    /// 主层单容器内的布局：4 模块 + 空槽按槽位顺序水平排布，空槽平摊剩余空间。
    /// 首槽贴左、末槽贴右；所有子视图一次性设 frame，无独立 item 挂载，无卡顿。
    private func layoutMainButtons() {
        guard let container = mainContainerView else { return }
        let slots = effectiveSlots
        var widths: [CGFloat] = []
        for slot in slots {
            if let component = slot {
                switch component {
                case .sidecar: widths.append(sidecarWidth)
                case .aiCoding: widths.append(aiCodingWidth)
                case .systemMonitor: widths.append(configuredWidth(for: .systemMonitor))
                case .clipboard: widths.append(displayedModuleWidth(for: .clipboard))
                case .keyboardLock: widths.append(keyboardLockWidth)
                }
            } else {
                widths.append(MainComponent.emptySlotWidth)
            }
        }
        let gap: CGFloat = Self.modalItemGap
        // item 容器被系统放在窗口关闭钮区之后（容器原点≈窗口 x64），容器右侧超出窗口
        // 的不可见。因此模块从容器内 0 起排，铺到「窗口宽 - 关闭钮区(64) - 右留白(8)」
        // 即容器内 0..692 → 屏幕 64..756，末槽恰好贴触控栏右缘。
        // 窗口宽度异常（0 或过窄，系统暂未分配空间）时退回标准宽度布局：
        // 不做错误压缩，宽度一旦恢复内容立即正确。
        let rawWindowWidth = container.window?.frame.width ?? 0
        let effectiveWindowWidth = rawWindowWidth >= 200 ? rawWindowWidth : Self.fallbackModalWidth
        let availableWidth = effectiveWindowWidth - Self.modalLeadingOffset - Self.modalRightMargin
        let contentWidth = max(100, availableWidth)
        let natural = widths.reduce(0, +) + gap * CGFloat(max(0, slots.count - 1))
        let emptyCount = slots.filter { $0 == nil }.count
        let share = emptyCount > 0 ? max(0, contentWidth - natural) / CGFloat(emptyCount) : 0

        // 容器在系统模态里的原点会随关闭钮显示与否变化（实测 64 或 0）。
        // 布局按固定 64 设计，这里把差值补回容器内坐标，保证屏幕上的绝对位置不变，
        // 进入/退出自定义面板、菜单栏成为前台应用时都不会整排前移。
        // 注意：container.frame.origin.x 是它在父视图内的坐标（通常 0），
        // 真正的系统模态偏移要把容器原点转换到窗口坐标才拿得到。
        let containerOriginX = container.convert(.zero, to: nil).x
        let rowStart = max(0, Self.modalLeadingOffset - containerOriginX)
        var x: CGFloat = rowStart
        for (index, slot) in slots.enumerated() {
            var w = widths[index]
            if slot == nil {
                w = MainComponent.emptySlotWidth + share
                mainEmptySlotViews[index]?.frame = NSRect(x: x, y: 0, width: w, height: 30)
            } else {
                switch slot! {
                case .sidecar: sidecarButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                case .aiCoding:
                    aiCodingButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                    layoutAIActivityMark()
                case .systemMonitor: systemMonitorButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                case .clipboard: clipboardButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                case .keyboardLock: keyboardLockButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                }
            }
            x += w + gap
        }
        // 防溢出：若内容超出可用宽（极端情况），按比例压缩空槽，保证末槽不出屏。
        if x - gap - rowStart > contentWidth, emptyCount > 0 {
            let overflow = x - gap - rowStart - contentWidth
            let perEmpty = overflow / CGFloat(emptyCount)
            var shrinkX: CGFloat = rowStart
            for (index, slot) in slots.enumerated() {
                let w = widths[index] + (slot == nil ? share - perEmpty : 0)
                if slot == nil {
                    mainEmptySlotViews[index]?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                } else {
                    switch slot! {
                    case .sidecar: sidecarButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    case .aiCoding:
                        aiCodingButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                        layoutAIActivityMark()
                    case .systemMonitor: systemMonitorButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    case .clipboard: clipboardButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    case .keyboardLock: keyboardLockButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    }
                }
                shrinkX += w + gap
            }
        }
        // 隐藏未安装对应软件（不在有效槽位）的模块按钮。
        let active = Set(slots.compactMap { $0 })
        let allModules: [(MainComponent, NSView?)] = [
            (.sidecar, sidecarButton), (.aiCoding, aiCodingButton),
            (.systemMonitor, systemMonitorButton), (.clipboard, clipboardButton),
            (.keyboardLock, keyboardLockButton)
        ]
        for (component, button) in allModules {
            button?.isHidden = !active.contains(component)
        }
        let layoutKey = "\(Int(containerOriginX))-\(Int(rowStart))-\(Int(contentWidth))"
        if layoutKey != lastLayoutLogKey {
            lastLayoutLogKey = layoutKey
            AppLog.write("layout origin=\(Int(containerOriginX)) rowStart=\(Int(rowStart)) content=\(Int(contentWidth))")
        }
    }

    /// 把剩余空间平摊给所有空槽：首槽贴左、末槽贴右，模块停留在各自槽位的比例位置上。
    /// 这是槽位的绝对网格语义——空槽越多的区段空隙越大，模块不会被整体推走。
    private func pillButton(
        title: String,
        symbol: String,
        action: Selector,
        background: NSColor
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = NSButton(frame: .zero)
        button.cell = PaddedPillButtonCell(textCell: title)
        button.title = title
        button.image = image
        button.target = self
        button.action = #selector(pillButtonPressed(_:))
        button.identifier = NSUserInterfaceItemIdentifier(NSStringFromSelector(action))
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = background.cgColor
        button.layer?.cornerRadius = 8
        button.layer?.masksToBounds = true
        applyPillBorder(to: button)
        setVisibleTitle(button, text: title)
        return button
    }

    private func applyPillBorder(to button: NSButton?) {
        guard let button else { return }
        button.layer?.borderWidth = showPillBorders ? 1.25 : 0
        button.layer?.borderColor = showPillBorders ? NSColor.white.withAlphaComponent(0.38).cgColor : nil
    }

    private func updatePersistentMenuItem() {
        persistentMenuItem?.state = persistentModules ? .on : .off
    }

    /// 切换常驻模式：开启时以无关闭钮的系统模态长驻中间区域，关闭时撤下模块栏。
    @objc private func togglePersistentModules() {
        persistentModules.toggle()
        UserDefaults.standard.set(persistentModules, forKey: DefaultsKey.persistentModules)
        if persistentModules {
            showMain()
        } else {
            mainBarShown = false
            mainBarHiddenUntil = Date().addingTimeInterval(3)
            ControlStrip.dismiss(touchBar)
        }
        updatePersistentMenuItem()
        AppLog.write("persistent modules=\(persistentModules)")
        settingsRows["persistent"]?.setSwitchState(on: persistentModules, animated: true)
        settingsRows["visible"]?.setValueText(
            mainBarShown ? "已显示" : "已收起",
            symbol: mainBarShown ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash",
            animated: true
        )
    }

    private func updateBrightnessMenuItem() {
        brightnessMenuItem?.state = keepTouchBarMaximumBrightness ? .on : .off
    }

    private func maintainTouchBarBrightness(macIdleOverride: TimeInterval? = nil) {
        guard keepTouchBarMaximumBrightness, !isScreenLocked else { return }
        let now = Date()
        let idle = TouchBarBrightnessPolicy.isIdle(
            touchBarIdle: now.timeIntervalSince(lastTouchBarInteractionAt),
            macIdle: macIdleOverride ?? TouchBarBrightnessPolicy.macIdleTime(),
            delay: touchBarIdleDelay
        )
        let target = idle ? touchBarIdleDimmingStep : touchBarActiveDimmingStep
        let before = touchBarPower.currentDimmingStep()
        // 系统接管/唤醒后，即使客户端仍报告相同档位，也定期重新下发目标档位。
        let force = now.timeIntervalSince(lastBrightnessReassertionAt) >= 5
        _ = touchBarPower.dimIfVisible(to: target, force: force)
        if force || before != target { lastBrightnessReassertionAt = now }
        let after = touchBarPower.currentDimmingStep()
        // 只在真正改变档位时记录，避免每 5 秒刷一条日志。
        if before != after || appliedDimmingStep != after {
            appliedDimmingStep = after
            AppLog.write(
                "Touch Bar brightness \(idle ? "idle" : "active") step \(before.map(String.init) ?? "unknown") -> \(after.map(String.init) ?? "unknown")"
            )
        }
        // 调光档位不是实际背光。按 Touch Bar 的真实 display ID 控制亮度，
        // 防止系统自动亮度把活跃档 0 仍压到约 12 nit。
        guard let actual = touchBarPower.actualBrightness(), actual.display_state == 2 else { return }
        let level = idle ? TouchBarBrightnessPolicy.idleBrightness : TouchBarBrightnessPolicy.activeBrightness
        let changed = lastActualBrightnessTarget != level
        if TouchBarBrightnessPolicy.shouldAdjust(current: actual.brightness, target: level, targetChanged: changed) {
            guard touchBarPower.setActualBrightness(level) else { return }
        }
        lastActualBrightnessTarget = level
        let readback = touchBarPower.actualBrightness() ?? actual
        let key = String(format: "%d/%.2f/%.2f/%.0f", readback.display_id, level, readback.brightness, readback.nits)
        if key != lastActualBrightnessLog {
            lastActualBrightnessLog = key
            AppLog.write(String(
                format: "Touch Bar actual brightness %@ display=%d target=%.2f readback=%.3f nits=%.0f",
                idle ? "idle" : "active", readback.display_id, level, readback.brightness, readback.nits
            ))
        }
    }

    /// 主层、详情页和滑动都记作操作；高频触摸只需每 0.2 秒补一次亮度。
    private func noteTouchBarInteraction() {
        guard Date().timeIntervalSince(lastTouchBarInteractionAt) >= 0.2 else { return }
        lastTouchBarInteractionAt = Date()
        maintainTouchBarBrightness()
    }

    /// 主层胶囊统一经过这里转发原 action，以便每次点按都先提亮 Touch Bar。
    @objc private func pillButtonPressed(_ sender: NSButton) {
        noteTouchBarInteraction()
        guard let raw = sender.identifier?.rawValue else { return }
        _ = self.perform(NSSelectorFromString(raw), with: sender)
    }

    private func setVisibleTitle(_ button: NSButton, text: String) {
        button.title = text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: button.font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
    }

    private func iconButton(symbol: String, description: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.toolTip = description
        return button
    }

    private func barControlIconImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "BarControlTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    /// 把 36pt 模板图重绘成 20pt 的独立位图（2x）。
    /// 直接给 NSButtonTouchBarItem 一个缩放过的 NSImage 副本，固定区会画成空白。
    private func trayLogoImage(side: CGFloat = 20) -> NSImage? {
        TrayIconRenderer.render(source: barControlIconImage(), side: side)
    }

    @objc private func showDetails() {
        noteTouchBarInteraction()
        touchBar.principalItemIdentifier = nil
        detailLayerActive = true
        detailYieldBypassUntil = Date().addingTimeInterval(10)
        touchBar.defaultItemIdentifiers = detailIdentifiers
        presentTouchBar()
    }

    private func showUsageDetails(_ key: String) {
        noteTouchBarInteraction()
        selectedUsageAccountKey = key
        touchBar.principalItemIdentifier = nil
        detailLayerActive = true
        detailYieldBypassUntil = Date().addingTimeInterval(10)
        touchBar.defaultItemIdentifiers = usageIdentifiers
        presentTouchBar()
    }

    @objc private func showClipboardHistory() {
        noteTouchBarInteraction()
        touchBar.principalItemIdentifier = nil
        detailLayerActive = true
        detailYieldBypassUntil = Date().addingTimeInterval(10)
        touchBar.defaultItemIdentifiers = clipboardIdentifiers
        presentTouchBar()
    }

    @objc private func toggleClipboardCapture() {
        clipboardHistory.togglePaused()
        AppLog.write("clipboard capture paused=\(clipboardHistory.isPaused)")
    }

    @objc private func clearClipboardHistory() {
        clipboardHistory.clear()
    }

    @objc private func showSystemDetails() {
        noteTouchBarInteraction()
        AppLog.write("show system detail")
        // metrics 每秒由计时器刷新；这里不再额外触发，避免切换瞬间与重排竞争。
        touchBar.principalItemIdentifier = nil
        detailLayerActive = true
        detailYieldBypassUntil = Date().addingTimeInterval(10)
        if touchBar.defaultItemIdentifiers != systemIdentifiers {
            touchBar.defaultItemIdentifiers = systemIdentifiers
        }
        presentTouchBar()
        // 详情视图已绑定 systemDetailView.metrics；切换后立即用最新采样刷一次。
        systemDetailView?.metrics = systemMetrics
    }

    /// 立即收起模块栏（不动常驻开关）。
    private func hideMainBar() {
        mainBarShown = false
        userHiddenMainBar = true
        yieldDismissed = false
        mainBarHiddenUntil = Date().addingTimeInterval(3)
        ControlStrip.dismiss(touchBar)
        AppLog.write("main bar hidden by user")
    }

    /// 收起后 3 秒内的自动“确认/恢复”全部跳过，防止刚收起又被弹回。
    private var mainBarHiddenUntil = Date.distantPast

    @objc private func toggleMainBarVisibility() {
        if mainBarShown {
            hideMainBar()
        } else {
            showMain()
        }
        settingsRows["visible"]?.setValueText(
            mainBarShown ? "已显示" : "已收起",
            symbol: mainBarShown ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash",
            animated: true
        )
    }

    /// 用户主动显示：清除“手动收起”，并在本次停留期间绕过让位规则，
    /// 方便在其他应用里临时使用模块（切应用后恢复自动让位）。
    @objc private func showMain() {
        detailLayerActive = false
        detailYieldBypassUntil = Date().addingTimeInterval(3)
        userHiddenMainBar = false
        manualYieldBypass = true
        yieldDismissed = false
        presentMainBar()
    }

    /// 自动恢复：尊重用户收起、让位状态、随航合成和 3 秒防抖。
    private func autoShowMain() {
        guard TouchBarPresentationPolicy.shouldAutoExpand(
            persistent: persistentModules,
            yieldingToApp: shouldYieldTouchBar,
            systemOwnsTouchBar: systemOwnsTouchBar
        ), !userHiddenMainBar, Date() >= mainBarHiddenUntil else { return }
        presentMainBar()
    }

    /// 实际呈现主层。
    private func presentMainBar() {
        noteTouchBarInteraction()
        // 连点防抖：0.35s 内的重复调用直接忽略，避免 dismiss→present 造成“闪一下又收起”。
        let now = Date()
        if now.timeIntervalSince(lastMainShowRequestAt) < 0.35 { return }
        lastMainShowRequestAt = now
        mainBarShown = true
        touchBar.principalItemIdentifier = nil
        // 已是主层标识时跳过重设，避免触发系统逐项重排（重新唤出时模块分批出现的卡顿）。
        if touchBar.defaultItemIdentifiers != mainIdentifiers {
            touchBar.defaultItemIdentifiers = mainIdentifiers
        }
        presentTouchBar()
    }

    /// 每 0.8 秒判定一次：前台应用是否要中间区域。
    /// 名单内应用直接让位；其余应用再看文本输入焦点（输入建议会占中间）。
    private func evaluateTouchBarYield() {
        guard persistentModules, !isScreenLocked else { return }
        guard let front = frontmostForeignApp else {
            textFocusEditing = false
            applyYieldState(false)
            return
        }
        if manualYieldBypass || userHiddenMainBar {
            applyYieldState(false)
            return
        }
        if TouchBarYieldPolicy.shouldYield(bundleID: front.bundleIdentifier) {
            textFocusEditing = false
            applyYieldState(true)
            return
        }
        guard TouchBarYieldPolicy.textFocusYieldEnabled,
              TouchBarYieldPolicy.accessibilityTrusted else {
            textFocusEditing = false
            applyYieldState(false)
            return
        }
        guard !yieldProbeInFlight,
              Date().timeIntervalSince(lastYieldProbeAt) >= 0.5 else { return }
        yieldProbeInFlight = true
        lastYieldProbeAt = Date()
        let pid = front.processIdentifier
        let bundleID = front.bundleIdentifier ?? "?"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let editing = TouchBarYieldPolicy.focusedElementIsTextInput(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.yieldProbeInFlight = false
                guard self.frontmostForeignApp?.processIdentifier == pid,
                      !self.manualYieldBypass else { return }
                if self.textFocusEditing != editing {
                    self.textFocusEditing = editing
                    AppLog.write("text focus yield=\(editing) app=\(bundleID)")
                }
                self.applyYieldState(self.shouldYieldTouchBar)
            }
        }
    }

    private func applyYieldState(_ yielded: Bool) {
        if yielded {
            guard !yieldDismissed else { return }
            detailLayerActive = false
            yieldDismissed = true
            guard mainBarShown else { return }
            mainBarShown = false
            ControlStrip.dismiss(touchBar)
            AppLog.write(
                "bar yielded app=\(frontmostForeignApp?.bundleIdentifier ?? "-") textFocus=\(textFocusEditing)"
            )
            return
        }
        guard yieldDismissed else { return }
        yieldDismissed = false
        guard !userHiddenMainBar,
              !UniversalControlWatchdog.isSystemOwnsTouchBar(sidecarState: sidecarStatus.state),
              Date() >= mainBarHiddenUntil else { return }
        AppLog.write("bar restored after yield")
        presentMainBar()
    }

    private var lastPresentedAt = Date.distantPast
    /// 当前是否停在某个详情层；输入建议出现时要把触控栏交还系统。
    private var detailLayerActive = false
    /// 点击模块进入详情是明确操作意图，这段时间内不让输入焦点抢走触控栏。
    private var detailYieldBypassUntil = Date.distantPast
    private var lastMainShowRequestAt = Date.distantPast

    /// 前台的外来应用（不是我们自己）。
    private var frontmostForeignApp: NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }

    /// 当前是否应该把 Touch Bar 中间区域让给前台应用。
    /// 用户主动点固定栏图标后，本次切换保持在最上层，直到应用切换或再次收起。
    private var shouldYieldTouchBar: Bool {
        guard let front = frontmostForeignApp else { return false }
        if manualYieldBypass || detailLayerActive || Date() < detailYieldBypassUntil { return false }
        if TouchBarYieldPolicy.shouldYield(bundleID: front.bundleIdentifier) { return true }
        return TouchBarYieldPolicy.shouldYieldForTextFocus(
            isEditing: textFocusEditing,
            isTyping: TouchBarYieldPolicy.isActivelyTyping()
        )
    }

    private var systemOwnsTouchBar: Bool {
        UniversalControlWatchdog.isSystemOwnsTouchBar(sidecarState: sidecarStatus.state)
    }

    /// 当前呈现的那一层自己的窗口；详情层不能用主层容器判断。
    private var activeTouchBarWindow: NSWindow? {
        guard let identifier = touchBar.defaultItemIdentifiers.first?.rawValue else { return nil }
        return touchBarItems[identifier]?.view?.window
    }

    /// 用户按 Fn、或在系统设置里选择 F1–F12 后，Touch Bar 会整条换成原生功能键。
    /// 用实体截图识别该模式；确认后才切回 App 控制条并重呈现，避免 30 秒一次的
    /// 截图/重启 ControlStrip 打扰正常使用。
    private func repairNativeTouchBarModeIfNeeded() {
        guard !isScreenLocked,
              TouchBarPresentationPolicy.shouldRepairNativeMode(
                  mainBarShown: mainBarShown,
                  yieldingToApp: shouldYieldTouchBar
              ),
              touchBar.defaultItemIdentifiers == mainIdentifiers else { return }
        let result = classifyRealTouchBar(stage: "mode-check")
        guard result.captured, result.nativeKeys else { return }
        AppLog.write("touch bar is in native F1-F12 mode; restoring app control strip")
        ControlStrip.restoreAppControlMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.reinstallControlStripItems()
        }
    }

    /// 常驻自愈：期望显示主层但模块已消失（窗口丢失/按钮无 window）时重新呈现。
    private func dfrSelfHealIfNeeded() {
        ensureRescueEntryPoints()
        ensureKeyboardLockStripAlive()
        ensureUsableSlots()
        // 详情层没有主层按钮窗口；只在主层检查，否则切换详情后会被误判为模态消失，
        // watchdog 随即把详情层强制切回主层。
        guard persistentModules,
              mainBarShown,
              !yieldDismissed,
              touchBar.defaultItemIdentifiers == mainIdentifiers else {
            degenerateWindowChecks = 0
            return
        }
        // 锁屏期间系统接管触控栏，present 会被忽略：跳过自愈，等解锁通知统一恢复。
        guard !isScreenLocked else {
            degenerateWindowChecks = 0
            return
        }
        // 别的 App 在前台时不抢触控栏（常驻打开也不抢）：以前这里会反复 present，
        // 把 Safari 等应用的触控栏内容盖掉。用户点入口图标仍能立即唤回。
        // 通用控制/随航活动时系统拥有触控栏：不截图、不自愈、不抢，
        // 否则会和系统合成互相踩（表现为模块栏被顶掉/闪烁）。
        guard !UniversalControlWatchdog.isSystemOwnsTouchBar(sidecarState: sidecarStatus.state) else {
            degenerateWindowChecks = 0
            return
        }
        guard Date() >= mainBarHiddenUntil,
              TouchBarPresentationPolicy.shouldSelfHeal(
            persistent: persistentModules,
            yieldingToApp: shouldYieldTouchBar,
            userHidden: userHiddenMainBar
        ) else {
            degenerateWindowChecks = 0
            return
        }
        let windows = [sidecarButton, aiCodingButton, systemMonitorButton, clipboardButton]
            .compactMap { $0?.window }

        // 视图存在、坐标正常，但系统模态中间区实际为空（只剩叉号）。
        // 每 10 秒才截一次实体 Touch Bar，连续两次为空才做普通重呈现。
        if windows.isEmpty == false,
           !UniversalControlWatchdog.isSystemOwnsTouchBar(sidecarState: sidecarStatus.state),
           Date().timeIntervalSince(lastInvisibleProbeAt) > 60 {
            lastInvisibleProbeAt = Date()
            let result = classifyRealTouchBar(stage: "watchdog")
            if result.captured, !result.hasContent {
                invisibleTouchBarChecks += 1
                AppLog.write("touch bar visually empty checks=\(invisibleTouchBarChecks)")
                if invisibleTouchBarChecks >= 2 {
                    invisibleTouchBarChecks = 0
                    healDFR(deep: false, reason: "visually empty")
                }
            } else {
                invisibleTouchBarChecks = 0
            }
        }

        // 情况 A0：槽位有模块但按钮全部为 nil（主层容器尚未重建）。
        // 不能只看 windows.isEmpty——nil 按钮和 nil 窗口可能是不同故障形态。
        if windows.isEmpty,
           [sidecarButton, aiCodingButton, systemMonitorButton, clipboardButton]
               .allSatisfy({ $0 == nil }) {
            degenerateWindowChecks = 0
            healDFR(deep: true, reason: "main buttons missing")
            return
        }

        // 情况 A：模态整体消失（主层按钮全部失去窗口）→ 立即恢复。
        if windows.isEmpty {
            degenerateWindowChecks = 0
            healDFR(deep: false, reason: "modal gone")
            return
        }

        // 情况 B：窗口仍在但宽度退化。
        // 注意：0 宽可能是正常瞬态（打开详情层/系统临时回收模态后会自行恢复），
        // 不能立即深度重建，否则会反复闪烁甚至消失。先普通重试，持续退化才升级。
        let degenerate = windows.allSatisfy { $0.frame.width < 200 }
        guard degenerate else {
            degenerateWindowChecks = 0
            return
        }
        degenerateWindowChecks += 1
        let widths = windows.map { Int($0.frame.width) }.map(String.init).joined(separator: ",")
        // 自动识别：前台应用把我们的系统模态压成 0 宽，说明它自己往触控栏放了内容。
        // 先等下一次检查（约 1.6 秒）确认不是瞬态，再记下这个应用并立即让位。
        // 这期间不要重呈现——重呈现会把它的触控栏盖掉，也就是“闪一下又抢回来”。
        if TouchBarYieldPolicy.autoLearnEnabled,
           Date().timeIntervalSince(frontmostChangedAt) < 15,
           let front = frontmostForeignApp,
           let bundleID = front.bundleIdentifier,
           !bundleID.isEmpty,
           bundleID != "com.apple.finder" {
            guard degenerateWindowChecks >= 2 else { return }
            let learned = TouchBarYieldPolicy.learn(bundleID)
            AppLog.write(
                "auto yield app=\(bundleID) learned=\(learned) widths=[\(widths)]"
            )
            degenerateWindowChecks = 0
            applyYieldState(true)
            rebuildMenu()
            return
        }
        if degenerateWindowChecks == 1 {
            AppLog.write("dfr watchdog: degenerate window detected widths=[\(widths)]")
            healDFR(deep: false, reason: "degenerate window")
        } else if degenerateWindowChecks >= 3, Date().timeIntervalSince(lastDeepRecoveryAt) > 30 {
            AppLog.write("dfr watchdog: degenerate window persists widths=[\(widths)]")
            healDFR(deep: true, reason: "degenerate persisted")
        }
    }

    /// 恢复 DFR 呈现。deep=true 时彻底重建 NSTouchBar 实例——
    /// 系统会记住某实例的零宽退化状态（实测 coords win 宽 0、重复 present 与
    /// 重注册托盘项均无效），换全新实例是唯一能打破该状态的方式。
    private func healDFR(deep: Bool, reason: String) {
        // 冷却 10 秒，避免系统瞬态回收模态时被反复重建，导致 Touch Bar 闪烁/消失。
        guard Date().timeIntervalSince(lastSelfHealAt) > 10 else { return }
        lastSelfHealAt = Date()
        AppLog.write("dfr self-heal (\(reason), deep=\(deep)): re-presenting")
        if deep {
            lastDeepRecoveryAt = Date()
            rebuildTouchBarFromScratch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.autoShowMain()
            }
            return
        }
        ControlStrip.dismiss(touchBar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.autoShowMain()
        }
    }

    /// 入口自愈：无论主层、详情层还是自定义面板状态如何，都要保住两个恢复入口。
    /// 1. Control Strip 托盘项必须存在且可见；
    /// 2. 菜单栏图标必须存在且菜单可用。
    /// 这样即使所有模块都被清空、主层窗口退化或某个详情层打不开，用户仍能通过
    /// Control Strip 或菜单栏“显示主 Touch Bar / 自定义组件”找回。
    private func ensureRescueEntryPoints() {
        if controlStripItem == nil {
            AppLog.write("rescue: control strip item missing; re-registering")
            installControlStripItem()
        }
        if statusItem.button == nil {
            AppLog.write("rescue: recreating menu bar status item")
            configureMenuBar()
        }
        if statusItem.menu == nil {
            AppLog.write("rescue: rebuilding empty menu bar menu")
            rebuildMenu()
        }
    }

    /// 自定义配置保险：如果槽位里没有任何可用模块，恢复默认布局并保留空槽。
    /// 触发场景包括旧配置残留、软件路径变化导致所有模块不可用，或手动清空全部槽位。
    private func ensureUsableSlots() {
        guard componentOrder.isEmpty else { return }
        // A saved layout is user data. If its modules are temporarily
        // unavailable, leave it untouched; only a truly empty configuration
        // gets an in-memory fallback and that fallback is never persisted.
        if componentSlots.contains(where: { $0 != nil }) {
            AppLog.write("rescue: configured slots unavailable; preserving saved layout")
            return
        }
        AppLog.write("rescue: empty slot configuration; showing fallback without overwriting preferences")
        componentSlots = Array(MainComponent.allCases.filter { $0.isSoftwareAvailable })
        while componentSlots.count < MainComponent.slotCount {
            componentSlots.append(nil)
        }
        rebuildMenu()
        updateMainModuleWidths()
    }

    /// 键盘锁是后加的模块：只在第一次升级时放进第一个空槽，之后完全尊重用户布局。
    /// 没有空槽就什么都不做，由用户在自定义面板里自己加。
    private func placeKeyboardLockInEmptySlotOnce() {
        let key = "keyboardLock.slotMigration.v1"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard MainComponent.keyboardLock.isSoftwareAvailable,
              !componentSlots.contains(.keyboardLock) else { return }
        guard let index = componentSlots.firstIndex(where: { $0 == nil }) else {
            AppLog.write("keyboard lock: no empty slot, waiting for manual placement")
            return
        }
        componentSlots[index] = .keyboardLock
        MainComponent.saveSlots(componentSlots)
        AppLog.write("keyboard lock: placed in empty slot \(index)")
        rebuildMenu()
        updateMainModuleWidths()
    }

    /// 彻底重建 touchBar：清空 item 缓存与视图引用，换一个全新 NSTouchBar 实例，
    /// 重新注册 Control Strip 托盘项，供系统按新实例重新分配宽度。
    private func rebuildTouchBarFromScratch() {
        AppLog.write("dfr self-heal: rebuilding touchBar from scratch")
        ControlStrip.dismiss(touchBar)
        if let item = controlStripItem {
            ControlStrip.remove(item)
        }
        controlStripItem = nil
        touchBarItems.removeAll()
        mainContainerView = nil
        mainEmptySlotViews.removeAll()
        touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = mainIdentifiers
        installControlStripItem()
        degenerateWindowChecks = 0
    }

    private func presentTouchBar() {
        guard ControlStrip.isSupported else {
            AppLog.write("present skipped: unsupported")
            return
        }
        AppLog.write("ensure DFR visible=\(touchBarPower.ensureVisible())")
        // 反复 present 同一 touchBar 而不 dismiss 会让 DFR 模态状态错乱，
        // 表现为“只剩左 X / 整条消失”。这里在再次呈现前先退掉旧模态。
        // 只有模态确实还挂着时才先退掉；让位刚 dismiss 过的情况下再 dismiss
        // 会让系统播放一次“收起又弹出”，看起来就是闪一下。
        let modalAttached = [sidecarButton, aiCodingButton, systemMonitorButton]
            .compactMap { $0?.window }.isEmpty == false
        if modalAttached, Date().timeIntervalSince(lastPresentedAt) < 2.0 {
            ControlStrip.dismiss(touchBar)
        }
        lastPresentedAt = Date()
        // 关闭钮固定显示：进入自定义面板/菜单栏会让 App 成为前台应用，若此时关闭钮
        // 由系统按前台状态显隐，模态起始偏移会在 0 与 64 之间跳变，整排图标跟着移动。
        // 固定为 true 后偏移稳定；布局侧仍有原点补偿，双保险。
        AppLog.write("present modal=\(ControlStrip.present(touchBar, from: controlStripIdentifier)) ids=\(touchBar.defaultItemIdentifiers.map(\.rawValue))")
        // 系统（尤其通用控制/随航切换时）偶发把刚呈现的模态立刻收掉：
        // 1 秒后确认一次，没挂上就再挂一次（只补一次，避免和系统对着抢）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.mainBarShown, Date() >= self.mainBarHiddenUntil else { return }
            // 输入建议/系统界面占用触控栏时不要再抢，否则详情层会和键盘提示来回闪。
            guard !self.shouldYieldTouchBar, !self.systemOwnsTouchBar else { return }
            guard self.activeTouchBarWindow == nil else { return }
            AppLog.write("modal vanished after present; re-asserting once")
            _ = ControlStrip.present(self.touchBar, from: Item.controlStrip)
        }
        // 弹入动画期间轮询真实窗口宽度：首帧用 fallback 宽度，窗口一挂上就立即校正，
        // 不再等 0.8 秒后才重排（那一次重排就是“弹出后卡一下”）。
        schedulePostPresentLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let coords: [(String, NSButton?)] = [
                ("sidecar", self.sidecarButton), ("ai", self.aiCodingButton),
                ("sys", self.systemMonitorButton)
            ]
            let parts = coords.map { name, button -> String in
                guard let button else { return "\(name)=nil" }
                let windowPoint = button.convert(button.bounds, to: nil)
                return "\(name)=x\(Int(windowPoint.origin.x)) w\(Int(windowPoint.width))"
            }
            AppLog.write("coords \(parts.joined(separator: " ")) win=\(String(describing: self.sidecarButton?.window?.frame))")
        }
        guard keepTouchBarMaximumBrightness else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.maintainTouchBarBrightness()
        }
    }

    @objc private func openSidecar() {
        guard sidecarStatus.state != "connecting" else {
            AppLog.write("sidecar launch skipped: already connecting")
            return
        }
        // 点击本身先给反馈，再启动子进程；子进程 open() 可能阻塞一两百毫秒。
        let previousState = sidecarStatus.state
        if previousState == "success" || previousState == "failure" {
            NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.SidecarPilot")
                .forEach { _ = $0.terminate() }
        }
        beginSidecarConnectingLocally()
        // 回读到的真实阶段仍会覆盖这里的占位文案。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", "-g",
            "--env", "SIDECAR_PILOT_NATIVE_HOST=1",
            "/Applications/随航管家.app"
        ]
        do {
            try process.run()
            AppLog.write("sidecar launch native-host")
        } catch {
            AppLog.write("sidecar launch failed=\(error.localizedDescription)")
            openApplication(path: "/Applications/随航管家.app")
        }
    }

    /// 点按后立刻反馈：本地切到 connecting 并启动旋转帧，避免几百毫秒“按了没反应”。
    private func beginSidecarConnectingLocally() {
        sidecarStatus = SidecarStatus(state: "connecting", message: "正在连接 iPad", detail: "准备")
        sidecarFrame = 1
        updateSidecarButton(animated: true)
        startSidecarSpinTimer()
        AppLog.write("sidecar local connecting feedback")
    }

    /// 独立 0.25 秒旋转计时器：仍由状态文件驱动最终结果，但动画不等文件。
    private func startSidecarSpinTimer() {
        sidecarSpinTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.sidecarStatus.state == "connecting" else {
                    self.sidecarSpinTimer?.invalidate()
                    self.sidecarSpinTimer = nil
                    return
                }
                self.sidecarFrame = (self.sidecarFrame + 1) % 4
                self.updateSidecarButton(animated: false)
            }
        }
        sidecarSpinTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 断开并重新建立 Sidecar 会话；不重启 WindowServer 或整台 Mac。
    @objc private func sidecarEnvironmentFix() {
        guard sidecarStatus.state != "connecting" else {
            AppLog.write("sidecar repair skipped: already connecting")
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.SidecarPilot")
            .forEach { _ = $0.terminate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", "-g",
            "--env", "SIDECAR_PILOT_NATIVE_HOST=1",
            "--env", "SIDECAR_PILOT_ACTION=repair",
            "/Applications/随航管家.app"
        ]
        do {
            try process.run()
            AppLog.write("sidecar repair launched")
        } catch {
            AppLog.write("sidecar repair launch failed=\(error.localizedDescription)")
        }
    }

    /// 控制环境修复：动作待定义（用户提供具体修复命令后接入）。
    @objc private func controlEnvironmentFix() {
        AppLog.write("control environment fix triggered (action pending definition)")
    }

    @objc private func togglePillBorders() {
        showPillBorders.toggle()
        UserDefaults.standard.set(showPillBorders, forKey: DefaultsKey.showPillBorders)
        [sidecarButton, aiCodingButton].forEach(applyPillBorder)
        AppLog.write("pill borders=\(showPillBorders)")
    }

    @objc private func toggleTouchBarMaximumBrightness() {
        keepTouchBarMaximumBrightness.toggle()
        UserDefaults.standard.set(
            keepTouchBarMaximumBrightness,
            forKey: DefaultsKey.keepTouchBarMaximumBrightness
        )
        updateBrightnessMenuItem()
        if keepTouchBarMaximumBrightness {
            lastTouchBarInteractionAt = Date()
            maintainTouchBarBrightness()
        } else {
            appliedDimmingStep = nil
        }
        AppLog.write("Touch Bar automatic brightness=\(keepTouchBarMaximumBrightness)")
        settingsRows["brightness"]?.setSwitchState(on: keepTouchBarMaximumBrightness, animated: true)
    }

    @objc private func showInterfaceDetails() {
        interfaceSpecs = InterfaceSpecsReader.read()
        InterfaceDetailWindowController.shared.show(
            specs: interfaceSpecs,
            metrics: systemMetrics
        )
    }

    /// One system authorization prompt installs the privileged helper used by
    /// the 优先放电 policy; a successful install removes this menu item on the
    /// next menu rebuild.
    @objc private func installDischargeHelper() {
        Task { @MainActor in
            let controller = AdapterDischargeController.shared
            let ok = await controller.installHelper()
            let alert = NSAlert()
            if ok {
                alert.messageText = "放电辅助组件已安装"
                alert.informativeText = controller.lastError
                    ?? "现在选择「优先放电」会断开充电器，切回其他策略或退出 App 时自动恢复。"
                alert.alertStyle = .informational
                rebuildMenu()
            } else {
                alert.messageText = "放电辅助组件未安装"
                alert.informativeText = controller.lastError ?? "已取消。"
                alert.alertStyle = .warning
            }
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func setPowerRunnerStyle(_ style: PowerRunnerStyle) {
        powerRunnerStyle = style
        style.save()
        systemMonitorButton?.setStyle(style)
        if let button = systemMonitorButton {
            stylePicker?.selectItem(withTag: PowerRunnerStyle.allCases.firstIndex(of: style) ?? 0)
            button.toolTip = systemMonitorToolTip
        }
        AppLog.write("power runner style=\(style.rawValue)")
    }

    @objc private func selectPowerRunnerStyle(_ sender: NSPopUpButton) {
        guard PowerRunnerStyle.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        setPowerRunnerStyle(PowerRunnerStyle.allCases[sender.indexOfSelectedItem])
    }

    /// 「AI Coding 显示」菜单内容：勾选展示哪些软件、哪些供应商。
    /// 行使用自定义视图内嵌勾选按钮——普通菜单项点击后系统必然关闭菜单，视图菜单项不会。
    /// 默认勾选 = 当前账户，或数据源声明应默认展示的账户。
    private func rebuildAIDisplayMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        defer {
            aiDisplayMenuKey = (snapshot.accounts ?? []).map { "\($0.clientID)/\($0.key)" }.joined(separator: "|")
        }
        let platformOverrides = UserDefaults.standard.dictionary(forKey: "aiCodingPlatformOverrides.v1") as? [String: Bool] ?? [:]
        let providerOverrides = UserDefaults.standard.dictionary(forKey: "aiCodingProviderOverrides.v1") as? [String: Bool] ?? [:]
        let accounts = snapshot.accounts ?? []
        var clientOrder: [String] = []
        for account in accounts where !clientOrder.contains(account.clientID) {
            clientOrder.append(account.clientID)
        }
        guard !clientOrder.isEmpty else {
            let hint = NSMenuItem(title: "尚未检测到 AI 软件数据", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return
        }
        for clientID in clientOrder {
            let group = accounts.filter { $0.clientID == clientID }
            guard let first = group.first else { continue }
            let hasDefault = group.contains { $0.showByDefault ?? $0.isCurrent }
            let shown = platformOverrides[clientID] ?? hasDefault
            menu.addItem(makeAIRow(
                title: first.clientLabel,
                checked: shown,
                identifier: clientID,
                action: #selector(toggleAIPlatformVisible(_:)),
                indent: false
            ))
            for usage in group {
                let providerShown = providerOverrides[usage.key] ?? usage.showByDefault ?? usage.isCurrent
                menu.addItem(makeAIRow(
                    title: "· \(usage.accountLabel)",
                    checked: providerShown,
                    identifier: usage.key,
                    action: #selector(toggleAIProviderVisible(_:)),
                    indent: true
                ))
            }
        }
    }

    /// 菜单项行（自定义视图）：点击勾选不会关闭菜单。
    private func makeAIRow(title: String, checked: Bool, identifier: String, action: Selector, indent: Bool) -> NSMenuItem {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: indent ? 54 : 38, y: 4, width: 242, height: 16)
        label.font = indent ? .systemFont(ofSize: 12) : .systemFont(ofSize: 13, weight: .medium)
        label.textColor = indent ? .secondaryLabelColor : .labelColor
        row.addSubview(label)
        let check = NSButton(checkboxWithTitle: "", target: self, action: action)
        check.identifier = NSUserInterfaceItemIdentifier(identifier)
        check.state = checked ? .on : .off
        check.frame = NSRect(x: 304, y: 1, width: 22, height: 22)
        row.addSubview(check)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = row
        return item
    }

    @objc private func toggleAIPlatformVisible(_ sender: NSButton) {
        guard let clientID = sender.identifier?.rawValue else { return }
        var overrides = UserDefaults.standard.dictionary(forKey: "aiCodingPlatformOverrides.v1") as? [String: Bool] ?? [:]
        overrides[clientID] = sender.state == .on
        UserDefaults.standard.set(overrides, forKey: "aiCodingPlatformOverrides.v1")
        refreshAIQuotaAfterToggle()
        AppLog.write("ai coding platform \(clientID) shown=\(sender.state == .on)")
    }

    @objc private func toggleAIProviderVisible(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        var overrides = UserDefaults.standard.dictionary(forKey: "aiCodingProviderOverrides.v1") as? [String: Bool] ?? [:]
        overrides[key] = sender.state == .on
        UserDefaults.standard.set(overrides, forKey: "aiCodingProviderOverrides.v1")
        refreshAIQuotaAfterToggle()
        AppLog.write("ai coding provider \(key) shown=\(sender.state == .on)")
    }

    /// 勾选后刷新触控栏；若 AI 菜单正展开则延迟到菜单关闭，保证菜单不退出。
    private func refreshAIQuotaAfterToggle() {
        if aiDisplayMenuOpen {
            pendingAIQuotaRefresh = true
            return
        }
        quotaView?.update(with: snapshot.limits, platforms: snapshot.platforms, accounts: snapshot.accounts)
    }

    @objc private func showComponentOrder() {
        if orderPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 800),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "自定义 Touch Bar 组件"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self
            let content = makeComponentSettingsContent()
            panel.setContentSize(content.frame.size)
            panel.contentView = content
            orderPanel = panel
        }
        reloadSlotPreview()
        reloadOrderRows()
        reloadCustomRows()
        // 打开设置窗口不改变 Touch Bar 模态。实测 App 激活时系统可能因前台状态切换
        // 移除关闭钮并释放模态，导致中间区域只剩托盘叉号；固定交还主层更稳。
        orderPanel?.center()
        orderPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if persistentModules { showMain() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === orderPanel else { return }
        // 设置面板不再撤下 Touch Bar；关闭时只核对状态，健康主层无需再次 present。
        if persistentModules {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.dfrSelfHealIfNeeded()
            }
        }
    }

    /// 自定义面板内容。单独构造，系统深浅色切换时整体重建，避免旧背景色残留。
    private func makeComponentSettingsContent() -> NSView {
        let content = WindowPageView(frame: NSRect(x: 0, y: 0, width: 620, height: 800))
        if let appearance = orderPanel?.appearance {
            content.appearance = appearance
        }
        content.wantsLayer = true
        // 画布也用 flipped：下面所有 y 都是“从上往下”递增，
        // 否则放进设置右栏的滚动视图后整页顺序会上下颠倒。
        let canvas = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 620, height: 800))
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(canvas)

        // 按模块数量动态排版，避免固定 y 坐标在行数变化后互相压住。
        let placedCount = max(1, componentOrder.count)
        let customCount = max(1, MainComponent.allCases.filter { $0.isSoftwareAvailable }.count)
        let rowsHeight = CGFloat(placedCount) * 44 + CGFloat(max(0, placedCount - 1)) * 7
        let customHeight = CGFloat(customCount) * 44 + CGFloat(max(0, customCount - 1)) * 7

        var y: CGFloat = 20
        let reset = NSButton(title: "恢复默认布局", target: self, action: #selector(resetComponentOrder))
        reset.frame = NSRect(x: 20, y: y, width: 116, height: 28)
        reset.bezelStyle = .rounded
        reset.contentTintColor = .labelColor
        canvas.addSubview(reset)
        y += 28 + 16

        let moduleTitle = NSTextField(labelWithString: "已放置模块")
        moduleTitle.frame = NSRect(x: 20, y: y, width: 560, height: 20)
        moduleTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        moduleTitle.textColor = .labelColor
        canvas.addSubview(moduleTitle)
        y += 20 + 10

        let stack = NSStackView(frame: NSRect(x: 20, y: y, width: 580, height: rowsHeight))
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 7
        orderStack = stack
        canvas.addSubview(stack)
        y += rowsHeight + 16

        let title = NSTextField(labelWithString: "Touch Bar 预览")
        title.frame = NSRect(x: 20, y: y, width: 300, height: 24)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        canvas.addSubview(title)

        let borderCheck = NSButton(checkboxWithTitle: "按钮描边", target: self, action: #selector(togglePillBorders))
        borderCheck.state = showPillBorders ? .on : .off
        borderCheck.frame = NSRect(x: 480, y: y + 2, width: 120, height: 24)
        borderCheck.contentTintColor = .labelColor
        canvas.addSubview(borderCheck)
        y += 24 + 10

        let preview = NSView(frame: NSRect(x: 20, y: y, width: 580, height: 40))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = (content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.07, alpha: 1)
            : NSColor(calibratedWhite: 0.86, alpha: 1)
        ).cgColor
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        canvas.addSubview(preview)
        let previewStack = NSStackView()
        previewStack.orientation = .horizontal
        previewStack.alignment = .centerY
        previewStack.spacing = 6
        previewStack.distribution = .fill
        previewStack.frame = NSRect(x: 6, y: 5, width: 568, height: 30)
        preview.addSubview(previewStack)
        slotPreviewStack = previewStack
        slotPreviewButtons = []
        y += 40 + 6

        let subtitle = NSTextField(labelWithString: "点击槽位放入或清空模块；格子按宽度比例铺满，空槽位吃掉剩余空间。")
        subtitle.frame = NSRect(x: 20, y: y, width: 580, height: 20)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        canvas.addSubview(subtitle)
        y += 20 + 18

        let iconTitle = NSTextField(labelWithString: "模块图标与文字")
        iconTitle.frame = NSRect(x: 20, y: y, width: 560, height: 20)
        iconTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        iconTitle.textColor = .labelColor
        canvas.addSubview(iconTitle)
        y += 20 + 8

        let iconHint = NSTextField(labelWithString: "图标可选「模块默认图标」或任意 SF Symbol；文字可选「模块默认名称」「无（纯图标）」「自定义文字」。")
        iconHint.frame = NSRect(x: 20, y: y, width: 580, height: 18)
        iconHint.font = .systemFont(ofSize: 11)
        iconHint.textColor = .secondaryLabelColor
        canvas.addSubview(iconHint)
        y += 18 + 10

        let customStackView = NSStackView(frame: NSRect(x: 20, y: y, width: 580, height: customHeight))
        customStackView.orientation = .vertical
        customStackView.alignment = .width
        customStackView.distribution = .fill
        customStackView.spacing = 7
        customStack = customStackView
        canvas.addSubview(customStackView)
        y += customHeight + 10

        let height = max(800, y)
        canvas.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        content.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        return content
    }

    /// 系统深浅色切换时重建面板内容，让语义色在当前外观下重新解析。
    func windowDidChangeEffectiveAppearance(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === orderPanel else { return }
        panel.contentView = makeComponentSettingsContent()
        reloadSlotPreview()
        reloadOrderRows()
        reloadCustomRows()
    }

    /// 「模块图标与文字」区：每个可定制模块一行——图标下拉（SF Symbol）+ 文字输入。
    private func reloadCustomRows() {
        guard let customStack else { return }
        for view in customStack.arrangedSubviews {
            customStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let modules = MainComponent.allCases.filter { $0.isSoftwareAvailable }
        let isDark = customStack.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rowBackground = isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.98, alpha: 1)
        customStack.frame.size.height = CGFloat(modules.count) * 44
            + CGFloat(max(0, modules.count - 1)) * 7
        for component in modules {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 44))
            row.appearance = customStack.effectiveAppearance
            row.wantsLayer = true
            row.layer?.backgroundColor = rowBackground.cgColor
            row.layer?.cornerRadius = 7
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true

            let iconView = NSImageView(frame: NSRect(x: 12, y: 12.5, width: 19, height: 19))
            iconView.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            iconView.contentTintColor = .labelColor
            row.addSubview(iconView)

            let nameLabel = NSTextField(labelWithString: component.title)
            nameLabel.frame = NSRect(x: 38, y: 12, width: 96, height: 20)
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.textColor = .labelColor
            row.addSubview(nameLabel)

            guard component.supportsIconAndTextCustomization else {
                guard component == .systemMonitor else {
                    // 键盘锁的图标与文字跟随锁定状态，不能自定义，这里只给说明。
                    let note = NSTextField(labelWithString: "只显示图标，图形随锁定状态变化")
                    note.frame = NSRect(x: 138, y: 12, width: 320, height: 20)
                    note.font = .systemFont(ofSize: 12)
                    note.textColor = .secondaryLabelColor
                    row.addSubview(note)
                    customStack.addArrangedSubview(row)
                    continue
                }
                let picker = NSPopUpButton(frame: NSRect(x: 138, y: 8, width: 148, height: 28))
                for (index, style) in PowerRunnerStyle.allCases.enumerated() {
                    let item = NSMenuItem(title: style.title, action: nil, keyEquivalent: "")
                    item.tag = index
                    picker.menu?.addItem(item)
                }
                picker.selectItem(withTag: PowerRunnerStyle.allCases.firstIndex(of: powerRunnerStyle) ?? 0)
                picker.target = self
                picker.action = #selector(selectPowerRunnerStyle)
                picker.toolTip = "选择功率动画样式"
                stylePicker = picker
                row.addSubview(picker)

                let detail = NSButton(
                    title: "打开整机详情",
                    target: self,
                    action: #selector(showSystemDetails)
                )
                detail.frame = NSRect(x: 294, y: 8, width: 120, height: 28)
                detail.bezelStyle = .rounded
                row.addSubview(detail)
                customStack.addArrangedSubview(row)
                continue
            }

            // 图标：默认图标 + SF Symbol 清单（菜单项直接显示图标本身）。
            let popup = NSPopUpButton(frame: NSRect(x: 138, y: 8, width: 150, height: 28))
            popup.identifier = NSUserInterfaceItemIdentifier(component.rawValue)
            let defaultIconItem = NSMenuItem(title: "模块默认图标", action: nil, keyEquivalent: "")
            defaultIconItem.representedObject = ""
            popup.menu?.addItem(defaultIconItem)
            var names = Self.symbolChoices
            let builtIn = component.symbol
            if !names.contains(builtIn) { names.insert(builtIn, at: 0) }
            let current = storedIcon(for: component)
            if !current.isEmpty && !names.contains(current) { names.append(current) }
            for name in names {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = name
                item.image = NSImage(systemSymbolName: name, accessibilityDescription: name)
                popup.menu?.addItem(item)
            }
            popup.selectItem(at: current.isEmpty ? 0 : ((names.firstIndex(of: current) ?? -1) + 1))
            popup.target = self
            popup.action = #selector(changeModuleIcon)
            popup.toolTip = "选择 \(component.title) 的图标（SF Symbol）"
            row.addSubview(popup)

            // 文字三选一：模块默认名称 / 无（纯图标）/ 自定义文字。
            let mode = storedTextMode(for: component)
            let textPopup = NSPopUpButton(frame: NSRect(x: 294, y: 8, width: 122, height: 28))
            textPopup.identifier = NSUserInterfaceItemIdentifier(component.rawValue)
            for (title, rawValue) in [("模块默认名称", ModuleTextMode.defaultName), ("无", ModuleTextMode.none), ("自定义文字", ModuleTextMode.custom)] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = rawValue.rawValue
                textPopup.menu?.addItem(item)
            }
            textPopup.selectItem(at: [ModuleTextMode.defaultName, .none, .custom].firstIndex(of: mode) ?? 0)
            textPopup.target = self
            textPopup.action = #selector(changeModuleTextMode)
            textPopup.toolTip = "选择 \(component.title) 的文字显示方式"
            row.addSubview(textPopup)

            let field = NSTextField(frame: NSRect(x: 424, y: 10, width: 144, height: 24))
            field.identifier = NSUserInterfaceItemIdentifier(component.rawValue)
            field.placeholderString = "输入文字"
            field.stringValue = storedLabel(for: component)
            field.isEnabled = mode == .custom
            field.target = self
            field.action = #selector(changeModuleLabel)
            field.toolTip = "自定义文字（选择「自定义文字」后可用）"
            row.addSubview(field)

            customStack.addArrangedSubview(row)
        }

    }

    @objc private func changeModuleIcon(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let component = MainComponent(rawValue: raw),
              let name = sender.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: Self.moduleIconPrefix + component.rawValue)
        refreshModuleAppearance()
    }

    @objc private func changeModuleTextMode(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let component = MainComponent(rawValue: raw),
              let mode = sender.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: Self.moduleTextModePrefix + component.rawValue)
        reloadCustomRows()
        refreshModuleAppearance()
    }

    @objc private func changeModuleLabel(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue,
              let component = MainComponent(rawValue: raw) else { return }
        let label = sender.stringValue.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(label, forKey: Self.moduleLabelPrefix + component.rawValue)
        refreshModuleAppearance()
    }

    /// 把当前存储的自定义图标/文字立即套用到已存在的按钮上。
    private func refreshModuleAppearance() {
        updateModuleButtonAppearance(for: .sidecar, button: sidecarButton)
        updateModuleButtonAppearance(for: .aiCoding, button: aiCodingButton)
        updateModuleButtonAppearance(for: .clipboard, button: clipboardButton)
        refreshKeyboardLockButton()
        updateSidecarButton(animated: false)
        updateMainModuleWidths()
        reloadSlotPreview()
        reloadOrderRows()
    }

    private func updateModuleButtonAppearance(for component: MainComponent, button: NSButton?) {
        guard let button else { return }
        let icon = storedIcon(for: component).isEmpty ? component.symbol : storedIcon(for: component)
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: component.title) ?? button.image
        if let label = effectiveTitle(for: component) {
            setVisibleTitle(button, text: label)
        } else {
            setVisibleTitle(button, text: component.title == "随航与通用控制" ? "随航 ⇄ 通用控制" : component.title)
        }
    }

    /// 渲染 Touch Bar 预览条的 6 个槽位格子。每个格子是一个按钮：
    /// 有模块则显示图标+短名，空槽位显示虚线框 + "空"；点击弹出槽位选择菜单。
    /// 布局直接镜像实体条：相同的起始偏移(64)、间距(8)、弹性占位（最后模块前、推到最右），
    /// 整条按比例缩放到预览宽度——保证预览与实际位置一致。
    private func reloadSlotPreview() {
        guard let previewContainer = slotPreviewStack?.superview else { return }
        for button in slotPreviewButtons {
            button.removeFromSuperview()
        }
        slotPreviewButtons = []

        // 各槽位真实渲染宽（与 layoutMainButtons 同源）：模块用动态宽，空槽位 48。
        let slots = effectiveSlots
        var slotWidths: [CGFloat] = []
        var lastModuleIndex = -1
        for (index, slot) in slots.enumerated() {
            if let component = slot {
                let width: CGFloat
                switch component {
                case .sidecar: width = sidecarWidth
                case .aiCoding: width = aiCodingWidth
                case .systemMonitor: width = configuredWidth(for: .systemMonitor)
                case .clipboard: width = displayedModuleWidth(for: .clipboard)
                case .keyboardLock: width = keyboardLockWidth
                }
                slotWidths.append(width)
                lastModuleIndex = index
            } else {
                slotWidths.append(MainComponent.emptySlotWidth)
            }
        }
        guard lastModuleIndex >= 0 else { return }
        // 与 layoutMainButtons 同公式：剩余空间平摊给空槽，模块停留在槽位的比例位置。
        let natural = Self.modalLeadingOffset
            + slotWidths.reduce(0, +)
            + Self.modalItemGap * CGFloat(max(0, slots.count - 1))
        let available = Self.fallbackModalWidth - Self.modalRightMargin
        let emptyCount = componentSlots.filter { $0 == nil }.count
        let share = emptyCount > 0 ? max(0, available - natural) / CGFloat(emptyCount) : 0
        var realWidths = slotWidths
        for (index, slot) in componentSlots.enumerated() where slot == nil {
            realWidths[index] = MainComponent.emptySlotWidth + share
        }

        // 实体条 756pt → 预览条内容宽（左右各留 6pt），按比例缩放摆放。
        let scale = (previewContainer.bounds.width - 12) / Self.fallbackModalWidth
        let scaledGap = Self.modalItemGap * scale
        var x = Self.modalLeadingOffset * scale + 6

        func placeSlot(_ slotIndex: Int, realWidth: CGFloat) {
            let slot = slots[slotIndex]
            let buttonWidth = realWidth * scale
            let slotButton = NSButton()
            slotButton.cell = CompactSlotButtonCell(textCell: "")
            let previewTitle = slot.flatMap { effectiveTitle(for: $0) }
            slotButton.imagePosition = (previewTitle?.isEmpty == true) ? .imageOnly : .imageLeading
            slotButton.isBordered = false
            slotButton.font = .systemFont(ofSize: 11, weight: .medium)
            slotButton.tag = slotIndex
            slotButton.target = self
            slotButton.action = #selector(slotMenuAction)
            slotButton.wantsLayer = true
            slotButton.layer?.cornerRadius = 6
            let isDark = previewContainer.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if let component = slot {
                let symbol: String
                if component == .keyboardLock {
                    symbol = keyboardLockPresentation.symbol
                } else {
                    symbol = storedIcon(for: component).isEmpty ? component.symbol : storedIcon(for: component)
                }
                let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: component.title)
                let image = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
                slotButton.image = image
                if component == .keyboardLock {
                    slotButton.title = ""
                    slotButton.imagePosition = .imageOnly
                } else {
                    slotButton.title = effectiveTitle(for: component) ?? component.shortTitle
                }
                slotButton.contentTintColor = isDark ? .white : .black
                slotButton.layer?.backgroundColor = NSColor(calibratedWhite: isDark ? 0.32 : 0.66, alpha: 1).cgColor
            } else {
                slotButton.title = "空"
                slotButton.contentTintColor = isDark
                    ? NSColor(calibratedWhite: 0.78, alpha: 1)
                    : NSColor(calibratedWhite: 0.30, alpha: 1)
                slotButton.layer?.borderWidth = 1
                slotButton.layer?.borderColor = NSColor(calibratedWhite: isDark ? 0.5 : 0.55, alpha: 1).cgColor
                slotButton.layer?.backgroundColor = NSColor(calibratedWhite: isDark ? 0.18 : 0.78, alpha: 1).cgColor
            }
            slotButton.frame = NSRect(x: x, y: 5, width: buttonWidth, height: 30)
            previewContainer.addSubview(slotButton)
            slotPreviewButtons.append(slotButton)
            x += buttonWidth + scaledGap
        }

        for index in 0..<slots.count {
            placeSlot(index, realWidth: realWidths[index])
        }
    }

    /// 点击预览槽位：弹出菜单列出四个模块 + 清空此位，选择后更新槽位并重排。
    @objc private func slotMenuAction(_ sender: NSButton) {
        let slotIndex = sender.tag
        guard componentSlots.indices.contains(slotIndex) else { return }
        let menu = NSMenu(title: "槽位 \(slotIndex + 1)")
        for component in MainComponent.allCases where component.isSoftwareAvailable {
            let isOccupied = componentSlots.contains(component) && componentSlots[slotIndex] != component
            let title = isOccupied ? "(已占用) " : ""
            let item = NSMenuItem(title: title + component.title, action: #selector(assignComponentToSlot), keyEquivalent: "")
            item.target = self
            item.tag = slotIndex
            item.representedObject = component.rawValue as NSString
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清空此位", action: #selector(clearComponentSlot), keyEquivalent: "")
        clear.target = self
        clear.tag = slotIndex
        menu.addItem(clear)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func assignComponentToSlot(_ sender: NSMenuItem) {
        let slotIndex = sender.tag
        guard componentSlots.indices.contains(slotIndex),
              let raw = sender.representedObject as? String,
              let component = MainComponent(rawValue: raw) else { return }
        // 若该模块已在别处，先移除，保证一个模块只占一位。
        if let existing = componentSlots.firstIndex(of: component), existing != slotIndex {
            componentSlots[existing] = nil
        }
        componentSlots[slotIndex] = component
        applyComponentSettings(reloadRows: true)
    }

    @objc private func clearComponentSlot(_ sender: NSMenuItem) {
        let slotIndex = sender.tag
        guard componentSlots.indices.contains(slotIndex) else { return }
        componentSlots[slotIndex] = nil
        applyComponentSettings(reloadRows: true)
    }

    private func reloadOrderRows() {
        guard let orderStack else { return }
        for view in orderStack.arrangedSubviews {
            orderStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let placed = componentOrder
        if placed.isEmpty {
            let empty = NSTextField(labelWithString: "尚未放置任何模块，请在上方点击槽位选择。")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 13)
            empty.frame = NSRect(x: 0, y: 0, width: 520, height: 40)
            orderStack.addArrangedSubview(empty)
            return
        }
        orderStack.frame.size.height = CGFloat(placed.count) * 44
            + CGFloat(max(0, placed.count - 1)) * 7
        let isDark = orderStack.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rowBackground = isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.98, alpha: 1)
        for (index, component) in placed.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 44))
            row.appearance = orderStack.effectiveAppearance
            row.wantsLayer = true
            row.layer?.backgroundColor = rowBackground.cgColor
            row.layer?.cornerRadius = 7
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true

            let slotTag = NSTextField(labelWithString: "槽 \(componentIndex(for: component) + 1)")
            slotTag.frame = NSRect(x: 8, y: 12, width: 36, height: 20)
            slotTag.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            slotTag.textColor = .secondaryLabelColor
            row.addSubview(slotTag)

            let icon = NSImageView(frame: NSRect(x: 48, y: 12.5, width: 19, height: 19))
            icon.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            icon.contentTintColor = .labelColor
            row.addSubview(icon)

            let label = NSTextField(labelWithString: component.title)
            label.frame = NSRect(x: 76, y: 12, width: 116, height: 20)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            row.addSubview(label)


            let range = component.widthRange
            let width = configuredWidth(for: component)
            let slider = NSSlider(
                value: Double(width),
                minValue: Double(range.lowerBound),
                maxValue: Double(range.upperBound),
                target: self,
                action: #selector(changeComponentWidth)
            )
            slider.frame = NSRect(x: 200, y: 8, width: 177, height: 26)
            let iconOnly = component == .keyboardLock
                || (component.supportsIconAndTextCustomization && effectiveTitle(for: component) == "")
            slider.isEnabled = !iconOnly
            slider.isContinuous = true
            slider.tag = index
            slider.toolTip = iconOnly ? "纯图标自动使用 44 pt；显示文字后恢复已保存宽度" : "\(component.title) 宽度"
            row.addSubview(slider)

            let widthLabel = NSTextField(labelWithString: iconOnly ? "自动 44" : "\(Int(width)) pt")
            widthLabel.identifier = NSUserInterfaceItemIdentifier("width.\(component.rawValue)")
            widthLabel.frame = NSRect(x: 380, y: 12, width: 50, height: 20)
            widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            widthLabel.textColor = .secondaryLabelColor
            widthLabel.alignment = .right
            row.addSubview(widthLabel)

            // 显示开关：勾选 = 放在槽位里；取消勾选 = 从触控栏撤下（槽位留空）。
            let toggle = NSButton(checkboxWithTitle: "显示", target: self, action: #selector(toggleComponentVisibility(_:)))
            toggle.state = .on
            toggle.identifier = NSUserInterfaceItemIdentifier("visible.\(component.rawValue)")
            toggle.frame = NSRect(x: 438, y: 13, width: 74, height: 20)
            toggle.font = .systemFont(ofSize: 11)
            toggle.contentTintColor = .labelColor
            row.addSubview(toggle)

            orderStack.addArrangedSubview(row)
        }
    }

    /// 返回组件当前所在的槽位下标；不在任何槽位时返回 0（防御）。
    private func componentIndex(for component: MainComponent) -> Int {
        componentSlots.firstIndex(of: component) ?? 0
    }

    @objc private func changeComponentWidth(_ sender: NSSlider) {
        guard componentOrder.indices.contains(sender.tag) else { return }
        let component = componentOrder[sender.tag]
        let range = component.widthRange
        let width = min(range.upperBound, max(range.lowerBound, CGFloat(sender.doubleValue))).rounded()
        componentWidths[component] = width
        UserDefaults.standard.set(Double(width), forKey: MainComponent.widthPrefix + component.rawValue)
        if let label = sender.superview?.subviews.compactMap({ $0 as? NSTextField }).first(where: {
            $0.identifier?.rawValue == "width.\(component.rawValue)"
        }) {
            label.stringValue = "\(Int(width)) pt"
        }
        applyComponentSettings(reloadRows: false)
    }

    @objc private func toggleComponentVisibility(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("visible."),
              let component = MainComponent(rawValue: String(raw.dropFirst("visible.".count))) else { return }
        componentSlots = ComponentVisibilityPolicy.applying(
            to: componentSlots, component: component, show: sender.state == .on
        )
        applyComponentSettings(reloadRows: true)
        AppLog.write("component visibility \(component.rawValue)=\(sender.state == .on)")
    }

    @objc private func resetComponentOrder() {
        // 默认：可用模块依次放入前几槽，未安装软件的模块不放入，其余槽留空。
        componentSlots = Array<MainComponent?>(MainComponent.allCases.filter { $0.isSoftwareAvailable })
        while componentSlots.count < MainComponent.slotCount {
            componentSlots.append(nil)
        }
        componentWidths = Dictionary(uniqueKeysWithValues: MainComponent.allCases.map { ($0, $0.defaultWidth) })
        for component in MainComponent.allCases {
            UserDefaults.standard.set(Double(component.defaultWidth), forKey: MainComponent.widthPrefix + component.rawValue)
        }
        applyComponentSettings(reloadRows: true)
    }

    private func applyComponentSettings(reloadRows: Bool) {
        MainComponent.saveSlots(componentSlots)
        if reloadRows {
            reloadSlotPreview()
            reloadOrderRows()
        }
        // 更新各模块 item 的宽度（systemMonitor 内容 + 宽度一起刷新）。
        updateSystemMonitor()
        // 关键：只改 defaultItemIdentifiers，让系统按新槽位顺序/显隐自动重排。
        // 绝不重建 item（makeItemForIdentifier 已缓存同一实例）、绝不做帧动画、
        // 绝不反复 present——否则会走 NSTouchBar delegate、中断模态并让 Control Strip 图标消失。
        touchBar.defaultItemIdentifiers = mainIdentifiers
        rebuildMenu()
        AppLog.write("component settings slots=\(componentSlots.map { $0?.rawValue ?? "~" }) widths=\(componentWidths)")
    }

    private func openApplication(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TouchBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TouchBarController()
        self.controller = controller
        if let probeIndex = CommandLine.arguments.firstIndex(of: "--provider-continuity-probe"),
           CommandLine.arguments.indices.contains(probeIndex + 2) {
            controller.runProviderContinuityProbe(
                providerName: CommandLine.arguments[probeIndex + 1],
                threadID: CommandLine.arguments[probeIndex + 2]
            )
            return
        }
        if CommandLine.arguments.contains("--app-server-restart-smoke-test") {
            controller.runAppServerRestartSmokeTest()
            return
        }
        controller.start()
        PowerNotification.requestAuthorization()
        registerLoginItem()
        controller.scheduleAutomaticUpdateCheck()
        if CommandLine.arguments.contains("--open-about") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenAboutWindow() }
        }
        if CommandLine.arguments.contains("--open-about-from-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenAboutFromSettings() }
        }
        if CommandLine.arguments.contains("--update-simulate-available") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { controller.debugSimulateAvailableUpdate() }
        }
        if CommandLine.arguments.contains("--update-prompt-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { controller.debugShowUpdatePrompt() }
        }
        if CommandLine.arguments.contains("--update-check-probe") {
            controller.runUpdateCheckProbe()
        }
        if let probeIndex = CommandLine.arguments.firstIndex(of: "--update-install-probe"),
           CommandLine.arguments.count > probeIndex + 2 {
            controller.runUpdateInstallProbe(
                zipPath: CommandLine.arguments[probeIndex + 1],
                targetPath: CommandLine.arguments[probeIndex + 2]
            )
        }
        if CommandLine.arguments.contains("--settings-resize-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MenuDetailWindowController.shared.debugResize(to: NSSize(width: 1180, height: 820))
            }
        }
        if CommandLine.arguments.contains("--open-settings-hardware") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsHardware() }
        }
        if CommandLine.arguments.contains("--open-settings-yield") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsYield() }
        }
        if CommandLine.arguments.contains("--open-settings-about") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsAbout() }
        }
        if CommandLine.arguments.contains("--open-settings-power") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsPower() }
        }
        if CommandLine.arguments.contains("--settings-inline-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { controller.debugExpandInlineMenuModules() }
        }
        if CommandLine.arguments.contains("--nav-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.debugOpenSettingsWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { controller.debugOpenMenuModules() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                MenuDetailWindowController.shared.debugGoBack()
            }
        }
        if CommandLine.arguments.contains("--open-menu-modules") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.debugOpenMenuModules()
            }
        }
        if CommandLine.arguments.contains("--open-customizer") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.debugOpenCustomizer()
            }
        }
        if CommandLine.arguments.contains("--open-yield-apps") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.debugOpenYieldAppsWindow()
            }
        }
        if CommandLine.arguments.contains("--open-settings") {
            // 调试用：直接打开 Touch Bar 设置窗口，方便无鼠标环境核对行交互。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.debugOpenSettingsWindow()
            }
        }
        if CommandLine.arguments.contains("--settings-position-probe") {
            controller.runSettingsPositionProbe()
        } else if CommandLine.arguments.contains("--smoke-test") {
            controller.runSmokeTest()
        } else if CommandLine.arguments.contains("--remote-protocol-smoke-test") {
            controller.runRemoteProtocolSmokeTest()
        } else if CommandLine.arguments.contains("--flow-animation-preview") {
            controller.runPowerFlowAnimationPreview()
        } else if CommandLine.arguments.contains("--flow-animation-variants") {
            controller.runGreenFlowAnimationVariantPreviews()
        } else if CommandLine.arguments.contains("--power-telemetry-probe") {
            controller.runLivePowerTelemetryProbe()
        } else if CommandLine.arguments.contains("--charging-limit-probe") {
            controller.runChargingLimitProbe()
        } else if CommandLine.arguments.contains("--inline-menu-preview") {
            controller.runInlineMenuPreview()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--window-design-preview") {
            controller.runWindowDesignPreview()
        } else if CommandLine.arguments.contains("--menu-interaction-preview") {
            controller.runMenuInteractionPreview()
        } else if CommandLine.arguments.contains("--menu-open-probe") {
            controller.runMenuOpenProbe()
        } else if CommandLine.arguments.contains("--interface-specs-previews") {
            controller.runInterfaceSpecsPreviews()
        } else if CommandLine.arguments.contains("--install-power-helper") {
            controller.runInstallPowerHelperProbe()
        } else if CommandLine.arguments.contains("--style-previews") {
            controller.runStylePreviews()
        } else if CommandLine.arguments.contains("--render-main") {
            controller.runMainRender()
        }
    }



    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AdapterDischargeController.shared.restoreSynchronously()
        // 退出即解锁：事件监听随进程消失，键盘本身会恢复；这里同步清掉持久化状态，
        // 避免下次启动时突然又把键盘锁上。
        KeyboardLockController.shared.onChange = nil
        _ = KeyboardLockController.shared.setLocked(false, reason: "app-terminate")
        controller?.stop()
    }

    private func registerLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
            let statusName = switch service.status {
            case .notRegistered: "notRegistered"
            case .enabled: "enabled"
            case .requiresApproval: "requiresApproval"
            case .notFound: "notFound"
            @unknown default: "unknown"
            }
            AppLog.write("login item status=\(statusName)")
        } catch {
            AppLog.write("login item registration failed: \(error.localizedDescription)")
        }
    }
}

@main
@MainActor
struct CodexTouchBarApp {
    static func main() {
        if CommandLine.arguments.contains("--keyboard-lock-probe") {
            exit(KeyboardLockProbe.run())
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
