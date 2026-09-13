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

    static func load(from url: URL) -> SidecarStatus {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .idle }
        let parts = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2, ["idle", "connecting", "success", "failure"].contains(parts[0]) else {
            return .idle
        }
        return SidecarStatus(
            state: parts[0],
            message: parts[1].isEmpty ? "随航 ⇄ 通用控制" : parts[1],
            detail: parts.count >= 3 ? parts[2] : ""
        )
    }
}

private struct LocalModelStatus: Equatable {
    let state: String
    let message: String

    static let idle = LocalModelStatus(state: "idle", message: "")

    static func parse(_ content: String) -> LocalModelStatus {
        let parts = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        let active = ["recording", "recognizing", "thinking", "preparing_speech", "speaking"]
        guard parts.count >= 2, active.contains(parts[0]) else { return .idle }
        return LocalModelStatus(state: parts[0], message: parts[1])
    }

    static func load(stateURL: URL, pidURL: URL) -> LocalModelStatus {
        guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 || errno == EPERM,
              let content = try? String(contentsOf: stateURL, encoding: .utf8) else { return .idle }
        return parse(content)
    }
}

/// 模块 item 的固定尺寸透明容器。系统按 item 视图的 intrinsicContentSize 决定 item
/// 尺寸并会改写直接子视图，所以按钮必须包在容器里、容器报告精确的「宽×30」。
@MainActor
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

private enum MainComponent: String, CaseIterable {
    case sidecar
    case aiCoding
    case systemMonitor
    case localModel

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
        case .sidecar:
            return manager.fileExists(atPath: "/Applications/随航管家.app")
        case .localModel:
            return manager.fileExists(atPath: "/Applications/本地模型.app")
        case .aiCoding:
            // AI coding 数据来自 Codex/CC Switch/ZCode 配置；装了任一即视为可用。
            if manager.fileExists(atPath: NSHomeDirectory() + "/.codex") { return true }
            if manager.fileExists(atPath: NSHomeDirectory() + "/.zcode/v2/config.json") { return true }
            if manager.fileExists(atPath: NSHomeDirectory() + "/.cc-switch/cc-switch.db") { return true }
            return manager.fileExists(atPath: "/Applications/ChatGPT.app")
        }
    }

    var title: String {
        switch self {
        case .sidecar: return "随航与通用控制"
        case .aiCoding: return "AI coding"
        case .systemMonitor: return "功率动画"
        case .localModel: return "本地模型"
        }
    }

    var symbol: String {
        switch self {
        case .sidecar: return "ipad.and.iphone"
        case .aiCoding: return "curlybraces.square.fill"
        case .systemMonitor: return "hare.fill"
        case .localModel: return "waveform.circle.fill"
        }
    }

    /// 预览格子使用的短名称。
    var shortTitle: String {
        switch self {
        case .sidecar: return "随航"
        case .aiCoding: return "AI"
        case .systemMonitor: return "功耗"
        case .localModel: return "本地"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .sidecar: return 146
        case .aiCoding: return 104
        case .systemMonitor: return 48
        case .localModel: return 44
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .sidecar: return 72...300
        case .aiCoding: return 72...180
        case .systemMonitor: return 36...72
        case .localModel: return 36...160
        }
    }

    static func loadOrder() -> [MainComponent] {
        guard let values = UserDefaults.standard.stringArray(forKey: defaultsKey) else { return allCases }
        var order: [MainComponent] = []
        for value in values {
            guard let component = MainComponent(rawValue: value), !order.contains(component) else { continue }
            order.append(component)
        }
        if !order.contains(.systemMonitor), let voiceIndex = order.firstIndex(of: .localModel) {
            order.insert(.systemMonitor, at: voiceIndex)
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
        var slots = Array<MainComponent?>(repeating: nil, count: slotCount)
        if let stored = UserDefaults.standard.stringArray(forKey: slotsKey) {
            for (index, value) in stored.enumerated() where index < slotCount {
                if let component = MainComponent(rawValue: value) {
                    slots[index] = component
                }
            }
            return slots
        }
        let legacyOrder = loadOrder()
        let legacyVisibility = loadVisibility()
        var cursor = 0
        for component in legacyOrder where legacyVisibility[component] ?? true {
            guard cursor < slotCount else { break }
            slots[cursor] = component
            cursor += 1
        }
        return slots
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
        static let localModel = NSTouchBarItem.Identifier("CodexTouchBarNative.localModel.v1")
        static let detailContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.detailContainer.v7")
        static let usageContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.usageContainer.v2")
        static let systemContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.systemContainer.v1")
        static let controlStrip = NSTouchBarItem.Identifier("CodexTouchBarNative.controlStrip")

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

    private let touchBar = NSTouchBar()
    private let statusClient = CodexStatusClient()
    private let remoteControl = RemoteControlManager()
    private lazy var touchBarPower = TouchBarPower()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var controlStripItem: NSCustomTouchBarItem?
    /// 主层/详情层各 item 的缓存：NSTouchBar delegate 要求同一 identifier 返回稳定实例，
    /// 绝不能每次 makeItem 都新建（否则模态/Control Strip 上下文会错乱、模块消失）。
    private var touchBarItems: [String: NSTouchBarItem] = [:]
    private weak var aiCodingButton: NSButton?
    private weak var sidecarButton: NSButton?
    private weak var systemMonitorButton: PowerRunnerButton?
    private weak var backButton: NSButton?
    private weak var voiceButton: NSButton?
    private weak var controlStripButton: NSButton?
    private weak var quotaView: QuotaView?
    private weak var usageDetailView: UsageDetailStripView?
    private weak var systemDetailView: SystemDetailStripView?
    private weak var powerFlowView: PowerFlowPanelView?
    private weak var brightnessMenuItem: NSMenuItem?
    private var runnerMenuItems: [NSMenuItem] = []
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
    /// 常驻模式：把模块栏以无关闭钮的系统模态长驻在触控栏中间区域（正常状态可见）。
    private var persistentModules: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.persistentModules) != nil else { return true }
        return defaults.bool(forKey: DefaultsKey.persistentModules)
    }()
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

    /// 本地模型生效的图标/文字：用户自定义优先，否则按状态内置。
    private var effectiveLocalModelTitle: String {
        if let title = effectiveTitle(for: .localModel) { return title }
        return localModelPresentation.title
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

    private var effectiveLocalModelSymbol: String {
        let icon = storedIcon(for: .localModel)
        return icon.isEmpty ? localModelPresentation.symbol : icon
    }
    private var snapshot = CodexSnapshot.loading
    private var selectedUsageAccountKey: String?
    private var refreshTimer: Timer?
    private var sidecarTimer: Timer?
    private var metricsTimer: Timer?
    private var brightnessTimer: Timer?
    private let universalControlWatchdog = UniversalControlWatchdog()
    private var isRefreshing = false
    private var isMetricsRefreshing = false
    private var metricsFetchStartedAt: Date?
    private var lastPanelMetricsAt: Date?
    private var didCreateVisibleItem = false
    private var lastLoggedStatus = ""
    private var lastLoggedMetrics = ""
    private var sidecarStatus = SidecarStatus.idle
    private var sidecarFrame = 0
    private var localModelStatus = LocalModelStatus.idle
    private var localModelFrame = 0
    private var systemMetrics = SystemMetrics.unavailable
    /// Charger and cable specifications, refreshed on the same 1 s cadence
    /// but changing far less often (only on plug/unplug).
    private var interfaceSpecs = InterfaceSpecs.empty
    private var smokeRetainedView: NSView?
    private var smokeRetainedWindow: NSWindow?
    private let sidecarStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SidecarPilot/touchbar-state.tsv")
    private let localModelStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM/touchbar-state.tsv")
    private let localModelPIDURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM/voice.pid")

    override init() {
        super.init()
        configureTouchBar()
        configureMenuBar()
    }

    func start() {
        // 后台预热跑猫等所有动画帧图，避免主线程首次读盘拖慢呈现。
        PowerRunnerButton.warmFramesInBackground()
        AppLog.reset()
        AppLog.write("start bundle=\(Bundle.main.bundlePath)")
        AppLog.write("menu items=\(statusItem.menu?.items.map(\.title) ?? [])")
        NSApp.touchBar = touchBar
        installControlStripItem()
        // 远程控制台已并入 phonecodex Mac app，BarControl 不再启动。
        if let switchIndex = CommandLine.arguments.firstIndex(of: "--switch-provider"),
           switchIndex + 1 < CommandLine.arguments.count {
            remoteControl.switchProvider(id: CommandLine.arguments[switchIndex + 1])
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshSidecarStatus()
        sidecarTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSidecarStatus() }
        }
        refreshSystemMetrics()
        let metricsTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemMetrics() }
        }
        self.metricsTimer = metricsTimer
        RunLoop.main.add(metricsTimer, forMode: .common)
        let brightnessTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maintainTouchBarBrightness() }
        }
        self.brightnessTimer = brightnessTimer
        RunLoop.main.add(brightnessTimer, forMode: .common)
        // The Control Strip registration is asynchronous. Presenting in the
        // same run-loop turn is silently ignored on recent macOS versions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showMain()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, !self.didCreateVisibleItem else { return }
            AppLog.write("no delegate item request after first present; retrying")
            self.showMain()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        sidecarTimer?.invalidate()
        sidecarTimer = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        brightnessTimer?.invalidate()
        brightnessTimer = nil
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

    func runSmokeTest() {
        AppLog.write("smoke test scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.renderPreview(self.makeMainContainer(), name: "main")
            assert(LocalModelStatus.parse("thinking\t思考中\n").state == "thinking")
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
            if let testIndex = PowerRunnerStyle.allCases.firstIndex(of: testRunnerStyle) {
                self.selectPowerRunnerStyle(self.runnerMenuItems[testIndex])
                assert(self.powerRunnerStyle == testRunnerStyle)
                assert(self.systemMonitorButton?.style == testRunnerStyle)
                assert(self.runnerMenuItems[testIndex].state == .on)
                self.powerRunnerStyle = savedRunnerStyle
                savedRunnerStyle.save()
                self.systemMonitorButton?.setStyle(savedRunnerStyle)
                self.updateRunnerMenuItems()
            }
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
            for state in ["recording", "recognizing", "thinking", "preparing_speech", "speaking"] {
                self.localModelStatus = LocalModelStatus(state: state, message: "")
                self.updateLocalModelButton(animated: false)
                self.renderPreview(self.makeMainContainer(), name: "local-model-\(state)")
            }
            self.localModelStatus = LocalModelStatus(state: "thinking", message: "云端思考中")
            self.renderPreview(self.makeMainContainer(), name: "local-model-cloud")
            self.localModelStatus = .idle
            let liveSlots = self.componentSlots
            let liveWidths = self.componentWidths
            self.localModelStatus = LocalModelStatus(state: "recording", message: "说话中")
            self.componentSlots = [.sidecar, .aiCoding, .localModel, .systemMonitor, nil, nil]
            let localBeforeRunner = self.makeMainContainer()
            self.renderPreview(localBeforeRunner, name: "local-model-before-runner")
            self.localModelStatus = .idle
            self.componentSlots = [.localModel, .systemMonitor, .sidecar, .aiCoding, nil, nil]
            self.renderPreview(self.makeMainContainer(), name: "main-custom-order")
            self.componentSlots = [nil, .localModel, nil, nil, nil, .sidecar]
            self.componentWidths[.systemMonitor] = MainComponent.systemMonitor.widthRange.lowerBound
            self.renderPreview(self.makeMainContainer(), name: "main-empty-slots")
            self.componentSlots = liveSlots
            self.componentWidths = liveWidths
            self.showComponentOrder()
            if let settingsView = self.orderPanel?.contentView {
                self.renderPreview(settingsView, name: "component-order-settings")
            }
            self.orderPanel?.orderOut(nil)
            let detailView = self.makeDetailContainer()
            self.renderPreview(detailView, name: "detail")
            let liveSnapshot = self.snapshot
            let now = Date().timeIntervalSince1970
            let sampleAccounts = [
                UsageAccount(
                    key: "codex:oauth:main", clientID: "codex", clientLabel: "Codex",
                    accountLabel: "主力 Plus", providerLabel: "OpenAI Official", isCurrent: true, isOfficial: true,
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
                    accountLabel: "卡扣AI", providerLabel: "API", isCurrent: false, isOfficial: false,
                    metricKind: "balance", remainingBalance: -0.1084, balanceUnit: "USD",
                    remainingPercent: nil, secondaryRemainingPercent: nil,
                    todayCost: 0, monthCost: 0, todayRequests: 0, todayTokens: 0,
                    cacheHitPercent: nil, successPercent: nil, modelLabel: "", metricsScope: "卡扣AI",
                    chartTitle: "余额趋势", chartUnit: "USD", latestAt: now,
                    history: [UsagePoint(timestamp: now, primary: -0.1084, secondary: nil)]
                ),
                UsageAccount(
                    key: "codex:provider:deepseek", clientID: "codex", clientLabel: "Codex",
                    accountLabel: "DeepSeek", providerLabel: "API", isCurrent: false, isOfficial: false,
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
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

    /// Headless check for the "first menu open shows an empty flow graph"
    /// regression. It forces the exact cold state the user hit (panel owns
    /// `SystemMetrics.unavailable`), then runs the same `menuWillOpen` path a
    /// real menu open takes, and renders the panel before/after so the fix
    /// can be judged from pixels instead of a real click.
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
            let after = self.powerFlowView?.metrics
            let afterWatts = after?.systemWatts.map { String(format: "%.2f", $0) } ?? "nil"
            AppLog.write(
                "menu-open-probe coldWatts=\(coldWatts) afterWatts=\(afterWatts) external=\(after?.externalPower ?? false) syncMs=\(String(format: "%.1f", syncMilliseconds))"
            )
            if let panel = self.powerFlowView {
                self.renderPreview(panel, name: "menu-open-probe-after")
            }
            self.menuDidClose(menu)
            NSApp.terminate(nil)
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

    /// `--render-main` 入口：渲染当前主层预览（含本地模型各状态）到 PNG 后退出。
    /// 用于排查主层/本地模型显示问题，不跑完整 smoke 断言。
    func runMainRender() {
        AppLog.write("render-main start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            for state in ["idle", "recording", "thinking", "speaking"] {
                self.localModelStatus = LocalModelStatus(state: state, message: state == "thinking" ? "本地思考" : "")
                self.updateLocalModelButton(animated: false)
                let view = self.makeMainContainer()
                self.renderPreview(view, name: "main-local-\(state)")
            }
            self.localModelStatus = .idle
            self.renderPreview(self.makeMainContainer(), name: "main-current")
            AppLog.write("render-main done")
            self.stop()
            exit(EXIT_SUCCESS)
        }
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
        container.addSubview(aiCoding)

        let systemMonitor = PowerRunnerButton(
            target: self,
            action: #selector(showSystemDetails),
            style: powerRunnerStyle
        )
        systemMonitor.toolTip = systemMonitorToolTip
        systemMonitorButton = systemMonitor
        container.addSubview(systemMonitor)

        let voice = pillButton(
            title: effectiveLocalModelTitle,
            symbol: effectiveLocalModelSymbol,
            action: #selector(openVoiceAssistant),
            background: localModelColor
        )
        voice.toolTip = "本地模型语音助手"
        voiceButton = voice
        container.addSubview(voice)

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
                view = pillButton(title: "随航 ⇄ 通用控制", symbol: "ipad.and.iphone", action: #selector(openSidecar), background: sidecarColor)
                width = configuredWidth(for: .sidecar)
            case .some(.aiCoding):
                view = pillButton(title: "AI coding", symbol: "curlybraces.square.fill", action: #selector(showDetails), background: NSColor(calibratedRed: 48 / 255, green: 66 / 255, blue: 120 / 255, alpha: 1))
                width = configuredWidth(for: .aiCoding)
            case .some(.systemMonitor):
                view = PowerRunnerButton(target: self, action: #selector(showSystemDetails), style: powerRunnerStyle)
                width = configuredWidth(for: .systemMonitor)
            case .some(.localModel):
                let title = effectiveLocalModelTitle
                view = pillButton(title: title, symbol: effectiveLocalModelSymbol, action: #selector(openVoiceAssistant), background: localModelColor)
                (view as? NSButton)?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
                width = localModelWidth
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
        let container = FixedTouchBarContainer(width: 495)
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

        let quota = QuotaView(width: 665)
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

    private func makeUsageContainer() -> NSView {
        let container = FixedTouchBarContainer(width: 730)
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

    private func configureMenuBar() {
        guard let button = statusItem.button else { return }
        let image = barControlIconImage() ?? NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: "AI coding"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Bar Control"
        rebuildMenu()
    }

    /// 重建菜单栏。四个模块分组按 Touch Bar 主层组件顺序（componentOrder）排列，
    /// 因此移动 Touch Bar 组件顺序时菜单栏分组顺序会同步跟随。
    private func rebuildMenu() {
        runnerMenuItems = []

        let menu = NSMenu()
        menu.delegate = self
        let powerFlow = PowerFlowPanelView()
        powerFlow.metrics = systemMetrics
        powerFlowView = powerFlow
        let powerItem = NSMenuItem()
        powerItem.view = powerFlow
        menu.addItem(powerItem)
        menu.addItem(.separator())

        for component in componentOrder {
            let item = NSMenuItem(title: component.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            item.submenu = makeModuleSubmenu(for: component)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Touch Bar 设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Touch Bar 设置")
        settingsMenu.addItem(menuItem("显示主 Touch Bar", #selector(showMain)))
        settingsMenu.addItem(menuItem("自定义 Touch Bar 组件…", #selector(showComponentOrder)))
        settingsMenu.addItem(menuItem("接口与线缆详情…", #selector(showInterfaceDetails)))
        let persistentItem = menuItem("在触控栏常驻显示模块", #selector(togglePersistentModules))
        persistentMenuItem = persistentItem
        settingsMenu.addItem(persistentItem)
        let brightnessItem = menuItem("Touch Bar 保持最亮", #selector(toggleTouchBarMaximumBrightness))
        brightnessMenuItem = brightnessItem
        settingsMenu.addItem(brightnessItem)
        if !AdapterDischargeController.shared.helperInstalled {
            settingsMenu.addItem(
                menuItem("安装放电辅助组件（优先放电）…", #selector(installDischargeHelper))
            )
        }
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(menuItem("退出 Bar Control", #selector(quit)))
        statusItem.menu = menu
        updatePersistentMenuItem()
        updateBrightnessMenuItem()
        updateRunnerMenuItems()
        updateVisibleStatus()
    }

    /// 按 Touch Bar 模块生成对应的二级菜单，命令按模块语义归类。
    private func makeModuleSubmenu(for component: MainComponent) -> NSMenu {
        let submenu = NSMenu(title: component.title)
        switch component {
        case .sidecar:
            submenu.addItem(menuItem("切换随航", #selector(openSidecar)))
            submenu.addItem(menuItem("随航环境修复", #selector(sidecarEnvironmentFix)))
            submenu.addItem(menuItem("控制环境修复", #selector(controlEnvironmentFix)))
        case .aiCoding:
            submenu.addItem(menuItem("打开 AI coding 详情", #selector(showDetails)))
            // AI Coding 显示：勾选展示哪些软件、哪些供应商（展开时按快照动态刷新）。
            let displayMenu = NSMenu(title: "AI Coding 显示")
            displayMenu.delegate = self
            aiDisplayMenu = displayMenu
            rebuildAIDisplayMenu(displayMenu)
            let displayItem = NSMenuItem(title: "AI Coding 显示", action: nil, keyEquivalent: "")
            displayItem.submenu = displayMenu
            submenu.addItem(displayItem)
        case .localModel:
            submenu.addItem(menuItem("打开语音助手", #selector(openVoiceAssistant)))
        case .systemMonitor:
            submenu.addItem(menuItem("显示 Touch Bar 整机详情", #selector(showSystemDetails)))
            let runnerItem = NSMenuItem(title: "Touch Bar 动图", action: nil, keyEquivalent: "")
            let runnerMenu = NSMenu(title: "Touch Bar 动图")
            runnerMenuItems = PowerRunnerStyle.allCases.enumerated().map { index, style in
                let item = NSMenuItem(title: style.title, action: #selector(selectPowerRunnerStyle), keyEquivalent: "")
                item.target = self
                item.tag = index
                runnerMenu.addItem(item)
                return item
            }
            runnerItem.submenu = runnerMenu
            submenu.addItem(runnerItem)
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
        if menu === aiDisplayMenu { aiDisplayMenuOpen = true }
        // Menu views draw synchronously the moment the menu opens, before any
        // async refresh can land. Read once right here so the first open
        // (and any open after sleep/wake) always shows real data instead of
        // an empty flow graph.
        let started = CACurrentMediaTime()
        let fresh = SystemMetricsReader.read()
        systemMetrics = fresh
        interfaceSpecs = InterfaceSpecsReader.read()
        powerFlowView?.metrics = fresh
        powerFlowView?.interfaceSpecs = interfaceSpecs
        systemDetailView?.metrics = fresh
        lastPanelMetricsAt = Date()
        let duration = (CACurrentMediaTime() - started) * 1_000
        AppLog.write(
            "menu open sync metrics\(String(format: " %.1fms", duration)) systemWatts=\(fresh.systemWatts.map { String(format: "%.2f", $0) } ?? "nil") battery=\(fresh.batteryWatts.map { String(format: "%.2f", $0) } ?? "nil")"
        )
        refreshSystemMetrics()
        powerFlowView?.startAnimating()
        AppLog.write("power flow animation=start")
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === aiDisplayMenu {
            aiDisplayMenuOpen = false
            if pendingAIQuotaRefresh {
                pendingAIQuotaRefresh = false
                quotaView?.update(with: snapshot.limits, platforms: snapshot.platforms, accounts: snapshot.accounts)
            }
        }
        powerFlowView?.stopAnimating()
        AppLog.write("power flow animation=stop")
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func installControlStripItem() {
        AppLog.write("control strip supported=\(ControlStrip.isSupported)")
        guard ControlStrip.isSupported else { return }
        let item = NSCustomTouchBarItem(identifier: Item.controlStrip)
        let button = iconButton(
            symbol: "chevron.left.forwardslash.chevron.right",
            description: "显示 Bar Control",
            action: #selector(showMain)
        )
        button.image = barControlIconImage() ?? button.image
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        item.view = button
        controlStripItem = item
        controlStripButton = button
        AppLog.write("control strip add=\(ControlStrip.add(item))")
    }

    private func refresh() {
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
            interfaceSpecs = InterfaceSpecsReader.read()
            isMetricsRefreshing = false
            metricsFetchStartedAt = nil
            lastPanelMetricsAt = Date()
            updateSystemMonitor()
            powerFlowView?.metrics = next
            powerFlowView?.interfaceSpecs = interfaceSpecs
            systemDetailView?.metrics = next
            InterfaceDetailWindowController.shared.updateIfVisible(
                specs: interfaceSpecs,
                metrics: next
            )
            // Auto rules only run after the panel has claimed the limit, so
            // an externally configured limit is never overwritten silently.
            ChargingLimitController.shared.update(
                policy: PowerFlowPolicyStore.current,
                metrics: next,
                userInitiated: false
            )
            AdapterDischargeController.shared.maintainSafety(
                policy: PowerFlowPolicyStore.current,
                metrics: next
            )
            AdapterDischargeController.shared.applyStandingPolicyIfNeeded(
                policy: PowerFlowPolicyStore.current,
                metrics: next
            )
            let metricsKey = systemMonitorToolTip
            if lastLoggedMetrics.isEmpty {
                let adapter = next.adapterLimitWatts.map { String(format: "%.1f", $0) } ?? "--"
                let battery = next.batteryWatts.map { String(format: "%.1f", $0) } ?? "--"
                let input = next.inputWatts.map { String(format: "%.1f", $0) } ?? "--"
                let outputs = next.usbOutputs.map { "\($0.name):\(String(format: "%.1f", $0.watts))W" }.joined(separator: ",")
                AppLog.write("metrics \(metricsKey) adapter=\(adapter) input=\(input) battery=\(battery) usbOut=[\(outputs)] external=\(next.externalPower)")
            }
            lastLoggedMetrics = metricsKey
        }
    }

    private func updateSystemMonitor() {
        guard let button = systemMonitorButton else { return }
        button.watts = systemMetrics.systemWatts ?? systemMetrics.sourceWatts
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
        let color = stateColor
        if let aiCodingButton {
            let aiTitle = effectiveTitle(for: .aiCoding) ?? "AI coding"
            setVisibleTitle(aiCodingButton, text: aiTitle)
            aiCodingButton.contentTintColor = color
        }
        controlStripButton?.contentTintColor = color
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

    private var stateColor: NSColor {
        switch snapshot.state {
        case "running": return .systemGreen
        case "completed": return .systemBlue
        case "aborted": return .systemRed
        default: return .white
        }
    }

    private func refreshSidecarStatus() {
        let next = SidecarStatus.load(from: sidecarStateURL)
        let previous = sidecarStatus
        let changed = next != sidecarStatus
        sidecarStatus = next
        if next.state == "connecting" {
            sidecarFrame = (sidecarFrame + 1) % 4
        } else if changed {
            sidecarFrame = 0
        }
        updateSidecarButton(animated: changed)
        if changed {
            AppLog.write("sidecar \(next.state):\(next.message):\(next.detail)")
        }
        if next.state == "idle", ["success", "failure"].contains(previous.state) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                AppLog.write("sidecar finished; restoring main Touch Bar")
                self?.showMain()
            }
        }
        refreshLocalModelStatus()
    }

    private func refreshLocalModelStatus() {
        let next = LocalModelStatus.load(stateURL: localModelStateURL, pidURL: localModelPIDURL)
        let changed = next != localModelStatus
        localModelStatus = next
        localModelFrame = next.state == "idle" ? 0 : (localModelFrame + 1) % 4
        updateLocalModelButton(animated: changed)
        if changed {
            AppLog.write("local model \(next.state):\(next.message)")
        }
    }

    private var localModelPresentation: (title: String, symbol: String) {
        switch localModelStatus.state {
        case "recording": return ("说话", ["record.circle", "stop.circle.fill"][localModelFrame % 2])
        case "recognizing": return ("识别", ["text.bubble", "text.bubble.fill"][localModelFrame % 2])
        case "thinking" where localModelStatus.message.contains("云端"):
            return ("云端", ["cloud", "cloud.fill"][localModelFrame % 2])
        case "thinking" where localModelStatus.message.contains("本地"):
            return ("本地", ["brain.head.profile", "sparkles"][localModelFrame % 2])
        case "thinking": return ("思考", ["brain.head.profile", "sparkles"][localModelFrame % 2])
        case "preparing_speech": return ("准备", ["speaker.wave.1", "speaker.wave.1.fill"][localModelFrame % 2])
        case "speaking": return ("播放", ["speaker.wave.2.fill", "speaker.wave.3.fill"][localModelFrame % 2])
        default: return ("", "waveform.circle.fill")
        }
    }

    private var localModelColor: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch localModelStatus.state {
        case "recording": rgb = (165, 42, 42)
        case "recognizing": rgb = (126, 87, 38)
        case "thinking" where localModelStatus.message.contains("云端"): rgb = (38, 91, 154)
        case "thinking": rgb = (70, 67, 150)
        case "preparing_speech", "speaking": rgb = (30, 105, 91)
        default: rgb = (76, 46, 112)
        }
        return NSColor(calibratedRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }

    private func updateLocalModelButton(animated: Bool) {
        guard let voiceButton else { return }
        let title = effectiveLocalModelTitle
        let symbol = effectiveLocalModelSymbol
        setVisibleTitle(voiceButton, text: title)
        // 与其他胶囊模块一致：使用默认符号渲染，不做单独的字号/字重配置。
        voiceButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "本地模型")
        voiceButton.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        voiceButton.layer?.backgroundColor = localModelColor.cgColor
        voiceButton.toolTip = title.isEmpty ? "本地模型语音助手" : "本地模型 · \(title)"
        updateMainModuleWidths()
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
        setVisibleTitle(sidecarButton, text: title)
        sidecarButton.layer?.backgroundColor = sidecarColor.cgColor
        updateMainModuleWidths()
    }

    private var sidecarWidth: CGFloat {
        let configured = configuredWidth(for: .sidecar)
        guard sidecarStatus.state != "idle" else { return configured }
        return max(configured, 184, pillWidth(title: sidecarTitle, button: sidecarButton, min: 72, max: 300))
    }

    private var aiCodingWidth: CGFloat {
        configuredWidth(for: .aiCoding)
    }

    private var localModelWidth: CGFloat {
        let configured = configuredWidth(for: .localModel)
        let title = effectiveLocalModelTitle
        guard !title.isEmpty else { return configured }
        return max(configured, pillWidth(title: title, button: voiceButton, min: 82, max: 82, iconOnly: 36))
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
                case .localModel: widths.append(localModelWidth)
                }
            } else {
                widths.append(MainComponent.emptySlotWidth)
            }
        }
        let gap: CGFloat = Self.modalItemGap
        // item 容器被系统放在窗口关闭钮区之后（容器原点≈窗口 x64），容器右侧超出窗口
        // 的不可见。因此模块从容器内 0 起排，铺到「窗口宽 - 关闭钮区(64) - 右留白(8)」
        // 即容器内 0..692 → 屏幕 64..756，末槽恰好贴触控栏右缘。
        let availableWidth = (container.window?.frame.width ?? Self.fallbackModalWidth)
            - Self.modalLeadingOffset - Self.modalRightMargin
        let contentWidth = max(100, availableWidth)
        let natural = widths.reduce(0, +) + gap * CGFloat(max(0, slots.count - 1))
        let emptyCount = slots.filter { $0 == nil }.count
        let share = emptyCount > 0 ? max(0, contentWidth - natural) / CGFloat(emptyCount) : 0

        var x: CGFloat = 0
        for (index, slot) in slots.enumerated() {
            var w = widths[index]
            if slot == nil {
                w = MainComponent.emptySlotWidth + share
                mainEmptySlotViews[index]?.frame = NSRect(x: x, y: 0, width: w, height: 30)
            } else {
                switch slot! {
                case .sidecar: sidecarButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                case .aiCoding: aiCodingButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                case .systemMonitor: systemMonitorButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                case .localModel: voiceButton?.frame = NSRect(x: x, y: 0, width: w, height: 30)
                }
            }
            x += w + gap
        }
        // 防溢出：若内容超出可用宽（极端情况），按比例压缩空槽，保证末槽不出屏。
        if x - gap > contentWidth, emptyCount > 0 {
            let overflow = x - gap - contentWidth
            let perEmpty = overflow / CGFloat(emptyCount)
            var shrinkX: CGFloat = 0
            for (index, slot) in slots.enumerated() {
                let w = widths[index] + (slot == nil ? share - perEmpty : 0)
                if slot == nil {
                    mainEmptySlotViews[index]?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                } else {
                    switch slot! {
                    case .sidecar: sidecarButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    case .aiCoding: aiCodingButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    case .systemMonitor: systemMonitorButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    case .localModel: voiceButton?.frame = NSRect(x: shrinkX, y: 0, width: w, height: 30)
                    }
                }
                shrinkX += w + gap
            }
        }
        // 隐藏未安装对应软件（不在有效槽位）的模块按钮。
        let active = Set(slots.compactMap { $0 })
        let allModules: [(MainComponent, NSView?)] = [
            (.sidecar, sidecarButton), (.aiCoding, aiCodingButton),
            (.systemMonitor, systemMonitorButton), (.localModel, voiceButton)
        ]
        for (component, button) in allModules {
            button?.isHidden = !active.contains(component)
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
        button.action = action
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
            ControlStrip.dismiss(touchBar)
        }
        updatePersistentMenuItem()
        AppLog.write("persistent modules=\(persistentModules)")
    }

    private func updateBrightnessMenuItem() {
        brightnessMenuItem?.state = keepTouchBarMaximumBrightness ? .on : .off
    }

    private func maintainTouchBarBrightness() {
        guard keepTouchBarMaximumBrightness else { return }
        let before = touchBarPower.currentDimmingStep()
        guard before != 1, touchBarPower.maximizeIfVisible() else { return }
        AppLog.write("Touch Bar dimming step \(before.map(String.init) ?? "unknown") -> \(touchBarPower.currentDimmingStep().map(String.init) ?? "unknown")")
    }

    private func setVisibleTitle(_ button: NSButton, text: String) {
        button.title = text
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

    @objc private func showDetails() {
        touchBar.principalItemIdentifier = nil
        touchBar.defaultItemIdentifiers = detailIdentifiers
        presentTouchBar()
    }

    private func showUsageDetails(_ key: String) {
        selectedUsageAccountKey = key
        touchBar.principalItemIdentifier = nil
        touchBar.defaultItemIdentifiers = usageIdentifiers
        presentTouchBar()
    }

    @objc private func showSystemDetails() {
        AppLog.write("show system detail")
        // metrics 每秒由计时器刷新；这里不再额外触发，避免切换瞬间与重排竞争。
        touchBar.principalItemIdentifier = nil
        if touchBar.defaultItemIdentifiers != systemIdentifiers {
            touchBar.defaultItemIdentifiers = systemIdentifiers
        }
        presentTouchBar()
        // 详情视图已绑定 systemDetailView.metrics；切换后立即用最新采样刷一次。
        systemDetailView?.metrics = systemMetrics
    }

    @objc private func showMain() {
        touchBar.principalItemIdentifier = nil
        // 已是主层标识时跳过重设，避免触发系统逐项重排（重新唤出时模块分批出现的卡顿）。
        if touchBar.defaultItemIdentifiers != mainIdentifiers {
            touchBar.defaultItemIdentifiers = mainIdentifiers
        }
        presentTouchBar()
    }

    private var lastPresentedAt = Date.distantPast

    /// 常驻自愈：期望显示主层但模块已消失（窗口丢失/按钮无 window）时重新呈现。
    private func dfrSelfHealIfNeeded() {
        guard persistentModules,
              touchBar.defaultItemIdentifiers == mainIdentifiers else { return }
        // 主层至少有一个按钮应挂在窗口上；全 nil 说明模态丢了。
        let anyWindowed = [sidecarButton, aiCodingButton, systemMonitorButton, voiceButton]
            .compactMap { $0?.window }
        if anyWindowed.isEmpty {
            AppLog.write("dfr self-heal: main layer vanished, re-presenting")
            ControlStrip.dismiss(touchBar)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showMain()
            }
        }
    }

    private func presentTouchBar() {
        guard ControlStrip.isSupported else {
            AppLog.write("present skipped: unsupported")
            return
        }
        AppLog.write("ensure DFR visible=\(touchBarPower.ensureVisible())")
        // 反复 present 同一 touchBar 而不 dismiss 会让 DFR 模态状态错乱，
        // 表现为“只剩左 X / 整条消失”。这里在再次呈现前先退掉旧模态。
        if Date().timeIntervalSince(lastPresentedAt) < 2.0 {
            ControlStrip.dismiss(touchBar)
        }
        lastPresentedAt = Date()
        // 常驻模式关闭系统关闭钮：模块栏长驻中间区域、无 X。
        AppLog.write("present modal=\(ControlStrip.present(touchBar, from: Item.controlStrip, showsCloseBox: !persistentModules)) ids=\(touchBar.defaultItemIdentifiers.map(\.rawValue))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            // 窗口挂载后按真实宽度重算布局（容器内手动排布）。
            self.updateMainModuleWidths()
            let coords: [(String, NSButton?)] = [
                ("sidecar", self.sidecarButton), ("ai", self.aiCodingButton),
                ("sys", self.systemMonitorButton), ("voice", self.voiceButton)
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
        if sidecarStatus.state == "success" || sidecarStatus.state == "failure" {
            NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.SidecarPilot")
                .forEach { _ = $0.terminate() }
        }
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

    /// 随航环境修复：动作待定义（用户提供具体修复命令后接入）。
    @objc private func sidecarEnvironmentFix() {
        AppLog.write("sidecar environment fix triggered (action pending definition)")
    }

    /// 控制环境修复：动作待定义（用户提供具体修复命令后接入）。
    @objc private func controlEnvironmentFix() {
        AppLog.write("control environment fix triggered (action pending definition)")
    }

    @objc private func openVoiceAssistant() {
        let url = URL(fileURLWithPath: "/Applications/本地模型.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                AppLog.write("open local model failed=\(error.localizedDescription)")
            }
        }
    }

    @objc private func togglePillBorders() {
        showPillBorders.toggle()
        UserDefaults.standard.set(showPillBorders, forKey: DefaultsKey.showPillBorders)
        [sidecarButton, aiCodingButton, voiceButton].forEach(applyPillBorder)
        AppLog.write("pill borders=\(showPillBorders)")
    }

    @objc private func toggleTouchBarMaximumBrightness() {
        keepTouchBarMaximumBrightness.toggle()
        UserDefaults.standard.set(
            keepTouchBarMaximumBrightness,
            forKey: DefaultsKey.keepTouchBarMaximumBrightness
        )
        updateBrightnessMenuItem()
        maintainTouchBarBrightness()
        AppLog.write("keep Touch Bar maximum brightness=\(keepTouchBarMaximumBrightness)")
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

    @objc private func selectPowerRunnerStyle(_ sender: NSMenuItem) {
        guard PowerRunnerStyle.allCases.indices.contains(sender.tag) else { return }
        let style = PowerRunnerStyle.allCases[sender.tag]
        powerRunnerStyle = style
        style.save()
        systemMonitorButton?.setStyle(style)
        updateRunnerMenuItems()
        AppLog.write("power runner style=\(style.rawValue)")
    }

    private func updateRunnerMenuItems() {
        for (index, item) in runnerMenuItems.enumerated() {
            item.state = PowerRunnerStyle.allCases[index] == powerRunnerStyle ? .on : .off
        }
    }

    /// 「AI Coding 显示」菜单内容：勾选展示哪些软件、哪些供应商。
    /// 行使用自定义视图内嵌勾选按钮——普通菜单项点击后系统必然关闭菜单，视图菜单项不会。
    /// 默认勾选 = 有当前在用账号/供应商的；未使用的软件、非当前的供应商默认不勾选。
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
            let hasCurrent = group.contains(where: \.isCurrent)
            let shown = platformOverrides[clientID] ?? hasCurrent
            menu.addItem(makeAIRow(
                title: first.clientLabel,
                checked: shown,
                identifier: clientID,
                action: #selector(toggleAIPlatformVisible(_:)),
                indent: false
            ))
            for usage in group {
                let providerShown = providerOverrides[usage.key] ?? usage.isCurrent
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
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: indent ? 26 : 10, y: 4, width: 216, height: 16)
        label.font = indent ? .systemFont(ofSize: 12) : .systemFont(ofSize: 13, weight: .medium)
        label.textColor = indent ? .secondaryLabelColor : .labelColor
        row.addSubview(label)
        let check = NSButton(checkboxWithTitle: "", target: self, action: action)
        check.identifier = NSUserInterfaceItemIdentifier(identifier)
        check.state = checked ? .on : .off
        check.frame = NSRect(x: 252, y: 1, width: 22, height: 22)
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
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "自定义 Touch Bar 组件"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self

            let content = NSView(frame: panel.contentView?.bounds ?? .zero)
            // 跟随系统深/浅色外观：不强制 appearance，所有语义色（windowBackground/
            // labelColor/secondaryLabelColor）自动适配深浅模式。
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let isDark = content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            let title = NSTextField(labelWithString: "Touch Bar 预览")
            title.frame = NSRect(x: 20, y: 640, width: 300, height: 24)
            title.font = .systemFont(ofSize: 17, weight: .semibold)
            content.addSubview(title)

            let borderCheck = NSButton(checkboxWithTitle: "按钮描边", target: self, action: #selector(togglePillBorders))
            borderCheck.state = showPillBorders ? .on : .off
            borderCheck.frame = NSRect(x: 480, y: 640, width: 120, height: 24)
            content.addSubview(borderCheck)

            let subtitle = NSTextField(labelWithString: "点击下方一个槽位，选择把哪个模块放进去，或清空该位。格子宽度按模块设置比例铺满，空槽位吃掉剩余空间。")
            subtitle.frame = NSRect(x: 20, y: 615, width: 580, height: 20)
            subtitle.textColor = .secondaryLabelColor
            content.addSubview(subtitle)

            // Touch Bar 预览条：胶囊底随系统深浅（深色近黑/浅色浅灰）+ 6 个可点击格子。
            let preview = NSView(frame: NSRect(x: 20, y: 555, width: 580, height: 40))
            preview.wantsLayer = true
            preview.layer?.backgroundColor = (isDark
                ? NSColor(calibratedWhite: 0.10, alpha: 1)
                : NSColor(calibratedWhite: 0.88, alpha: 1)
            ).cgColor
            preview.layer?.cornerRadius = 10
            preview.layer?.masksToBounds = true
            content.addSubview(preview)
            let previewStack = NSStackView()
            previewStack.orientation = .horizontal
            previewStack.alignment = .centerY
            previewStack.spacing = 6
            previewStack.distribution = .fill
            previewStack.frame = NSRect(x: 6, y: 5, width: 568, height: 30)
            preview.addSubview(previewStack)
            slotPreviewStack = previewStack
            slotPreviewButtons = []

            let moduleTitle = NSTextField(labelWithString: "已放置模块")
            moduleTitle.frame = NSRect(x: 20, y: 523, width: 560, height: 20)
            moduleTitle.font = .systemFont(ofSize: 14, weight: .semibold)
            content.addSubview(moduleTitle)

            let stack = NSStackView(frame: NSRect(x: 20, y: 295, width: 580, height: 220))
            stack.orientation = .vertical
            stack.alignment = .width
            stack.distribution = .fillEqually
            stack.spacing = 7
            orderStack = stack
            content.addSubview(stack)

            let iconTitle = NSTextField(labelWithString: "模块图标与文字")
            iconTitle.frame = NSRect(x: 20, y: 263, width: 560, height: 20)
            iconTitle.font = .systemFont(ofSize: 14, weight: .semibold)
            content.addSubview(iconTitle)

            let iconHint = NSTextField(labelWithString: "图标可选「模块默认图标」或任意 SF Symbol；文字可选「模块默认名称」「无（纯图标）」「自定义文字」。")
            iconHint.frame = NSRect(x: 20, y: 243, width: 580, height: 18)
            iconHint.font = .systemFont(ofSize: 11)
            iconHint.textColor = .secondaryLabelColor
            content.addSubview(iconHint)

            let customStackView = NSStackView(frame: NSRect(x: 20, y: 75, width: 580, height: 160))
            customStackView.orientation = .vertical
            customStackView.alignment = .width
            customStackView.distribution = .fillEqually
            customStackView.spacing = 7
            customStack = customStackView
            content.addSubview(customStackView)

            let reset = NSButton(title: "恢复默认布局", target: self, action: #selector(resetComponentOrder))
            reset.frame = NSRect(x: 20, y: 30, width: 116, height: 28)
            reset.bezelStyle = .rounded
            content.addSubview(reset)

            panel.contentView = content
            orderPanel = panel
        }
        reloadSlotPreview()
        reloadOrderRows()
        reloadCustomRows()
        // 打开设置面板会让 App 变前台，系统可能重置 DFR 模态；先主动收走，
        // 关闭面板时（windowWillClose）再恢复主层，避免“看面板没改就消失”。
        if persistentModules {
            ControlStrip.dismiss(touchBar)
        }
        orderPanel?.center()
        orderPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 面板关闭后恢复常驻主层（若之前在主层/常驻开启）。
        if persistentModules {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showMain()
            }
        }
    }

    /// 「模块图标与文字」区：每个可定制模块一行——图标下拉（SF Symbol）+ 文字输入。
    private func reloadCustomRows() {
        guard let customStack else { return }
        for view in customStack.arrangedSubviews {
            customStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for component in [MainComponent.sidecar, .aiCoding, .localModel] where component.isSoftwareAvailable {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 49))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            row.layer?.cornerRadius = 7

            let iconView = NSImageView(frame: NSRect(x: 12, y: 15, width: 19, height: 19))
            iconView.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            iconView.contentTintColor = .labelColor
            row.addSubview(iconView)

            let nameLabel = NSTextField(labelWithString: component.title)
            nameLabel.frame = NSRect(x: 38, y: 14, width: 96, height: 20)
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            row.addSubview(nameLabel)

            // 图标：默认图标 + SF Symbol 清单（菜单项直接显示图标本身）。
            let popup = NSPopUpButton(frame: NSRect(x: 138, y: 9, width: 150, height: 28))
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
            let textPopup = NSPopUpButton(frame: NSRect(x: 294, y: 9, width: 122, height: 28))
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

            let field = NSTextField(frame: NSRect(x: 424, y: 11, width: 144, height: 24))
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
        if let button = sidecarButton {
            let icon = storedIcon(for: .sidecar).isEmpty ? "ipad.and.iphone" : storedIcon(for: .sidecar)
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: button.title) ?? button.image
        }
        if let button = aiCodingButton {
            let icon = storedIcon(for: .aiCoding).isEmpty ? "curlybraces.square.fill" : storedIcon(for: .aiCoding)
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: button.title) ?? button.image
            let label = storedLabel(for: .aiCoding)
            setVisibleTitle(button, text: label.isEmpty ? "AI coding" : label)
        }
        updateSidecarButton(animated: false)
        updateLocalModelButton(animated: false)
        updateMainModuleWidths()
    }

    /// 渲染 Touch Bar 预览条的 6 个槽位格子。每个格子是一个按钮：
    /// 有模块则显示图标+短名，空槽位显示虚线框 + "空"；点击弹出槽位选择菜单。
    /// 布局直接镜像实体条：相同的起始偏移(64)、间距(8)、弹性占位（最后模块前、推到最右），
    /// 整条按比例缩放到预览宽度——保证预览与实际位置一致。
    private func reloadSlotPreview() {
        guard let previewContainer = slotPreviewStack?.superview else { return }
        let isDark = previewContainer.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
                case .localModel: width = localModelWidth
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
            slotButton.imagePosition = .imageLeading
            slotButton.isBordered = false
            slotButton.font = .systemFont(ofSize: 11, weight: .medium)
            slotButton.tag = slotIndex
            slotButton.target = self
            slotButton.action = #selector(slotMenuAction)
            slotButton.wantsLayer = true
            slotButton.layer?.cornerRadius = 6
            if isDark {
                // 深色预览条：格子深底浅字
                if let component = slot {
                    let icon = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
                    let image = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
                    slotButton.image = image
                    slotButton.title = component.shortTitle
                    slotButton.contentTintColor = .white
                    slotButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.32, alpha: 1).cgColor
                } else {
                    slotButton.title = "空"
                    slotButton.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1)
                    slotButton.layer?.borderWidth = 1
                    slotButton.layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 1).cgColor
                    slotButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
                }
            } else {
                // 浅色预览条：格子浅底深字，保证对比
                if let component = slot {
                    let icon = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
                    let image = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
                    slotButton.image = image
                    slotButton.title = component.shortTitle
                    slotButton.contentTintColor = .black
                    slotButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.62, alpha: 1).cgColor
                } else {
                    slotButton.title = "空"
                    slotButton.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1)
                    slotButton.layer?.borderWidth = 1
                    slotButton.layer?.borderColor = NSColor(calibratedWhite: 0.55, alpha: 1).cgColor
                    slotButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
                }
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
        for (index, component) in placed.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 49))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            row.layer?.cornerRadius = 7

            let slotTag = NSTextField(labelWithString: "槽 \(componentIndex(for: component) + 1)")
            slotTag.frame = NSRect(x: 8, y: 14, width: 36, height: 20)
            slotTag.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            slotTag.textColor = .secondaryLabelColor
            row.addSubview(slotTag)

            let icon = NSImageView(frame: NSRect(x: 48, y: 14, width: 19, height: 19))
            icon.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            icon.contentTintColor = .labelColor
            row.addSubview(icon)

            let label = NSTextField(labelWithString: component.title)
            label.frame = NSRect(x: 76, y: 14, width: 116, height: 20)
            label.font = .systemFont(ofSize: 13, weight: .medium)
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
            slider.frame = NSRect(x: 200, y: 10, width: 177, height: 26)
            slider.isContinuous = true
            slider.tag = index
            slider.toolTip = "\(component.title) 宽度"
            row.addSubview(slider)

            let widthLabel = NSTextField(labelWithString: "\(Int(width)) pt")
            widthLabel.identifier = NSUserInterfaceItemIdentifier("width.\(component.rawValue)")
            widthLabel.frame = NSRect(x: 384, y: 14, width: 54, height: 20)
            widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            widthLabel.textColor = .secondaryLabelColor
            widthLabel.alignment = .right
            row.addSubview(widthLabel)

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
        registerLoginItem()
        if CommandLine.arguments.contains("--smoke-test") {
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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
