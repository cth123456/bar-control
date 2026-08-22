import AppKit
import Darwin
import QuartzCore
import ServiceManagement

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
final class TouchBarController: NSObject, NSTouchBarDelegate, NSMenuDelegate {
    private enum Item {
        static let mainContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.mainContainer.v7")
        static let detailContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.detailContainer.v7")
        static let systemContainer = NSTouchBarItem.Identifier("CodexTouchBarNative.systemContainer.v1")
        static let controlStrip = NSTouchBarItem.Identifier("CodexTouchBarNative.controlStrip")
    }

    private enum DefaultsKey {
        static let showPillBorders = "showPillBorders.v1"
        static let keepTouchBarMaximumBrightness = "keepTouchBarMaximumBrightness.v1"
    }

    private let touchBar = NSTouchBar()
    private let statusClient = CodexStatusClient()
    private lazy var touchBarPower = TouchBarPower()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var controlStripItem: NSCustomTouchBarItem?
    private weak var aiCodingButton: NSButton?
    private weak var sidecarButton: NSButton?
    private weak var systemMonitorButton: PowerRunnerButton?
    private weak var backButton: NSButton?
    private weak var voiceButton: NSButton?
    private weak var controlStripButton: NSButton?
    private weak var quotaView: QuotaView?
    private weak var sessionView: SessionStripView?
    private weak var systemDetailView: SystemDetailStripView?
    private weak var powerFlowView: PowerFlowView?
    private weak var borderMenuItem: NSMenuItem?
    private weak var brightnessMenuItem: NSMenuItem?
    private var runnerMenuItems: [NSMenuItem] = []
    private var componentOrder = MainComponent.loadOrder()
    private var componentVisibility = MainComponent.loadVisibility()
    private var componentWidths = MainComponent.loadWidths()
    private var showPillBorders = UserDefaults.standard.bool(forKey: DefaultsKey.showPillBorders)
    private var keepTouchBarMaximumBrightness: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.keepTouchBarMaximumBrightness) != nil else { return true }
        return defaults.bool(forKey: DefaultsKey.keepTouchBarMaximumBrightness)
    }()
    private var powerRunnerStyle = PowerRunnerStyle.load()
    private var orderPanel: NSPanel?
    private weak var orderStack: NSStackView?
    private var snapshot = CodexSnapshot.loading
    private var refreshTimer: Timer?
    private var sidecarTimer: Timer?
    private var metricsTimer: Timer?
    private var brightnessTimer: Timer?
    private var isRefreshing = false
    private var isMetricsRefreshing = false
    private var didCreateVisibleItem = false
    private weak var statusMenuHeader: NSMenuItem?
    private var lastLoggedStatus = ""
    private var lastLoggedMetrics = ""
    private var sidecarStatus = SidecarStatus.idle
    private var sidecarFrame = 0
    private var localModelStatus = LocalModelStatus.idle
    private var localModelFrame = 0
    private var systemMetrics = SystemMetrics.unavailable
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
        AppLog.reset()
        AppLog.write("start bundle=\(Bundle.main.bundlePath)")
        AppLog.write("menu items=\(statusItem.menu?.items.map(\.title) ?? [])")
        NSApp.touchBar = touchBar
        installControlStripItem()
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
        if let controlStripItem {
            ControlStrip.remove(controlStripItem)
        }
        controlStripItem = nil
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
            let flowPreview = PowerFlowView()
            flowPreview.metrics = .preview
            assert(PowerFlowView.flowSpeed(for: 80) > PowerFlowView.flowSpeed(for: 5))
            assert(PowerFlowView.flowSpeed(for: 0) == 0)
            assert(PowerFlowView.dashPhase(for: 20, frame: 3, reversed: false) < 0)
            assert(PowerFlowView.dashPhase(for: 20, frame: 3, reversed: true) > 0)
            flowPreview.startAnimating()
            assert(flowPreview.isAnimating)
            self.renderPreview(flowPreview, name: "power-flow")
            self.renderPreview(self.makePowerFlowMaterialPreview(metrics: .preview), name: "power-flow-menu-material")
            let liveFlowPreview = PowerFlowView()
            liveFlowPreview.metrics = liveMetrics
            self.renderPreview(liveFlowPreview, name: "power-flow-live")
            let noOutputFlowPreview = PowerFlowView()
            noOutputFlowPreview.metrics = .previewWithoutOutputs
            self.renderPreview(noOutputFlowPreview, name: "power-flow-no-outputs")
            self.renderPreview(
                self.makePowerFlowMaterialPreview(metrics: .previewWithoutOutputs),
                name: "power-flow-no-outputs-menu-material"
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
            let liveOrder = self.componentOrder
            let liveVisibility = self.componentVisibility
            let liveWidths = self.componentWidths
            self.localModelStatus = LocalModelStatus(state: "recording", message: "说话中")
            self.componentOrder = [.sidecar, .aiCoding, .localModel, .systemMonitor]
            let localBeforeRunner = self.makeMainContainer()
            assert((self.systemMonitorButton?.frame.maxX ?? .infinity) <= localBeforeRunner.bounds.maxX)
            self.renderPreview(localBeforeRunner, name: "local-model-before-runner")
            self.localModelStatus = .idle
            self.componentOrder = [.localModel, .systemMonitor, .sidecar, .aiCoding]
            self.renderPreview(self.makeMainContainer(), name: "main-custom-order")
            self.componentVisibility[.sidecar] = false
            self.componentVisibility[.localModel] = false
            self.componentWidths[.systemMonitor] = MainComponent.systemMonitor.widthRange.lowerBound
            self.renderPreview(self.makeMainContainer(), name: "main-compact-hidden")
            self.componentOrder = liveOrder
            self.componentVisibility = liveVisibility
            self.componentWidths = liveWidths
            self.showComponentOrder()
            if let settingsView = self.orderPanel?.contentView {
                self.renderPreview(settingsView, name: "component-order-settings")
            }
            self.orderPanel?.orderOut(nil)
            let detailView = self.makeDetailContainer()
            self.renderPreview(detailView, name: "detail")
            let liveSnapshot = self.snapshot
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
                ]
            )
            self.renderPreview(self.makeDetailContainer(), name: "detail-api-budget")
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

    private func renderPreview(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            AppLog.write("preview \(name) failed: bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
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

    private func renderSidecarPreview(_ status: SidecarStatus, name: String) {
        sidecarStatus = status
        sidecarFrame = 0
        let view = makeMainContainer()
        updateSidecarButton(animated: false)
        renderPreview(view, name: name)
    }

    private func makePowerFlowMaterialPreview(metrics: SystemMetrics) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 390))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let flow = PowerFlowView()
        flow.metrics = metrics
        container.addSubview(flow)
        return container
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        didCreateVisibleItem = true
        AppLog.write("make item \(identifier.rawValue)")
        switch identifier {
        case Item.mainContainer:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.visibilityPriority = .high
            item.view = makeMainContainer()
            return item
        case Item.detailContainer:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.visibilityPriority = .high
            item.view = makeDetailContainer()
            return item
        case Item.systemContainer:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.visibilityPriority = .high
            item.view = makeSystemContainer()
            return item
        default:
            return nil
        }
    }

    private func makeMainContainer() -> NSView {
        // Keep the custom item near its real maximum content width. A 900 pt
        // intrinsic width makes AppKit clip the item on Touch Bar models that
        // reserve more room for the Control Strip.
        let container = FixedTouchBarContainer(width: 400)

        let sidecar = pillButton(
            title: "随航 ⇄ 通用控制",
            symbol: "ipad.and.iphone",
            action: #selector(openSidecar),
            background: sidecarColor
        )
        sidecar.frame = NSRect(x: 0, y: 0, width: configuredWidth(for: .sidecar), height: 30)
        sidecarButton = sidecar
        container.addSubview(sidecar)

        let aiCoding = pillButton(
            title: "AI coding",
            symbol: "curlybraces.square.fill",
            action: #selector(showDetails),
            background: NSColor(calibratedRed: 48 / 255, green: 66 / 255, blue: 120 / 255, alpha: 1)
        )
        aiCoding.frame = NSRect(x: 186, y: 0, width: 92, height: 30)
        aiCodingButton = aiCoding
        container.addSubview(aiCoding)

        let systemMonitor = PowerRunnerButton(
            target: self,
            action: #selector(showSystemDetails),
            style: powerRunnerStyle
        )
        systemMonitor.frame = NSRect(x: 0, y: 0, width: configuredWidth(for: .systemMonitor), height: 30)
        systemMonitor.toolTip = systemMonitorToolTip
        systemMonitorButton = systemMonitor
        container.addSubview(systemMonitor)

        let voice = pillButton(
            title: "",
            symbol: "waveform.circle.fill",
            action: #selector(openVoiceAssistant),
            background: localModelColor
        )
        voice.frame = NSRect(x: 0, y: 0, width: 44, height: 30)
        voice.toolTip = "本地模型语音助手"
        voiceButton = voice
        container.addSubview(voice)

        updateVisibleStatus()
        updateSidecarButton(animated: false)
        updateLocalModelButton(animated: false)
        updateSystemMonitor()
        AppLog.write("main order=\(componentOrder.map(\.rawValue)) sidecar=\(sidecar.frame) ai=\(aiCoding.frame) system=\(systemMonitor.frame) voice=\(voice.frame)")
        return container
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

        let quota = QuotaView(width: 225)
        quota.frame.origin = NSPoint(x: 40, y: 0)
        quota.update(with: snapshot.limits, platforms: snapshot.platforms)
        quota.onOpenUsage = { [weak self] in
            self?.openApplication(path: "/Applications/CC Switch.app")
        }
        quotaView = quota
        container.addSubview(quota)

        let sessions = SessionStripView(width: 450)
        sessions.frame.origin = NSPoint(x: 273, y: 0)
        sessions.onOpen = { [weak self] id in self?.openCodexThread(id) }
        sessions.update(with: snapshot.activeThreads)
        sessionView = sessions
        container.addSubview(sessions)

        AppLog.write("detail frames back=\(back.frame) quota=\(quota.frame) sessions=\(sessions.frame)")
        return container
    }

    private func configureTouchBar() {
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = mainIdentifiers
    }

    private var mainIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.mainContainer]
    }

    private var detailIdentifiers: [NSTouchBarItem.Identifier] {
        [Item.detailContainer]
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

        let menu = NSMenu()
        menu.delegate = self
        let powerFlow = PowerFlowView()
        powerFlow.metrics = systemMetrics
        powerFlowView = powerFlow
        let powerItem = NSMenuItem()
        powerItem.view = powerFlow
        menu.addItem(powerItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("显示主 Touch Bar", #selector(showMain)))
        menu.addItem(menuItem("显示 Touch Bar 整机详情", #selector(showSystemDetails)))
        let moreItem = NSMenuItem(title: "更多操作", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu(title: "更多操作")
        moreMenu.addItem(menuItem("打开 AI coding 详情", #selector(showDetails)))
        moreMenu.addItem(menuItem("打开随航", #selector(openSidecar)))
        moreMenu.addItem(menuItem("打开语音助手", #selector(openVoiceAssistant)))
        moreMenu.addItem(menuItem("打开 CC Switch", #selector(openCCSwitch)))
        moreMenu.addItem(menuItem("打开当前 Codex 会话", #selector(openLatestCodexThread)))
        moreMenu.addItem(.separator())
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
        moreMenu.addItem(runnerItem)
        moreMenu.addItem(menuItem("自定义 Touch Bar 组件…", #selector(showComponentOrder)))
        let borderItem = menuItem("显示按钮描边", #selector(togglePillBorders))
        borderMenuItem = borderItem
        moreMenu.addItem(borderItem)
        let brightnessItem = menuItem("Touch Bar 保持最亮", #selector(toggleTouchBarMaximumBrightness))
        brightnessMenuItem = brightnessItem
        moreMenu.addItem(brightnessItem)
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)
        menu.addItem(menuItem("退出 Bar Control", #selector(quit)))
        statusItem.menu = menu
        updateBorderMenuItem()
        updateBrightnessMenuItem()
        updateRunnerMenuItems()
        updateVisibleStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshSystemMetrics()
        powerFlowView?.startAnimating()
        AppLog.write("power flow animation=start")
    }

    func menuDidClose(_ menu: NSMenu) {
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
        guard !isMetricsRefreshing else { return }
        isMetricsRefreshing = true
        Task { [weak self] in
            let next = await SystemMetricsReader.fetch()
            guard let self else { return }
            systemMetrics = next
            isMetricsRefreshing = false
            updateSystemMonitor()
            powerFlowView?.metrics = next
            systemDetailView?.metrics = next
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
        layoutMainButtons(animated: false)
    }

    private var systemMonitorToolTip: String {
        let power = systemMetrics.systemWatts.map { String(format: "%.1f W", $0) } ?? "-- W"
        let memory = systemMetrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--"
        let gpu = systemMetrics.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "--"
        let temperature = systemMetrics.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "--"
        return "整机功率 \(power) · 内存占用 \(memory) · GPU 占用 \(gpu) · 电池温度 \(temperature)"
    }


    private func updateVisibleStatus() {
        let color = stateColor
        if let aiCodingButton {
            setVisibleTitle(aiCodingButton, text: "AI coding")
            aiCodingButton.contentTintColor = color
        }
        controlStripButton?.contentTintColor = color
        quotaView?.update(with: snapshot.limits, platforms: snapshot.platforms)
        sessionView?.update(with: snapshot.activeThreads)
        updateSidecarButton(animated: true)

        statusItem.button?.toolTip = "AI coding · \(snapshot.label)"
        statusMenuHeader?.title = "AI coding · \(snapshot.label)"

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
        let presentation = localModelPresentation
        setVisibleTitle(voiceButton, text: presentation.title)
        voiceButton.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: "本地模型")
        voiceButton.image = voiceButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        voiceButton.imagePosition = presentation.title.isEmpty ? .imageOnly : .imageLeading
        voiceButton.layer?.backgroundColor = localModelColor.cgColor
        voiceButton.toolTip = presentation.title.isEmpty ? "本地模型语音助手" : "本地模型 · \(presentation.title)"
        layoutMainButtons(animated: animated)
    }

    private var sidecarTitle: String {
        let suffix = sidecarStatus.detail.isEmpty ? "" : "  \(sidecarStatus.detail)"
        switch sidecarStatus.state {
        case "connecting":
            let frames = ["◐", "◓", "◑", "◒"]
            return "\(frames[sidecarFrame % frames.count]) \(sidecarStatus.message)\(suffix)"
        case "success": return "✓ \(sidecarStatus.message)\(suffix)"
        case "failure": return "✕ \(sidecarStatus.message)\(suffix)"
        default: return "随航 ⇄ 通用控制"
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
        layoutMainButtons(animated: animated)
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
        guard !localModelPresentation.title.isEmpty else { return configured }
        return max(configured, pillWidth(title: localModelPresentation.title, button: voiceButton, min: 82, max: 82, iconOnly: 36))
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

    private func layoutMainButtons(animated: Bool) {
        var x: CGFloat = 0
        var frames: [(NSButton, NSRect)] = []
        for component in componentOrder {
            let entry: (NSButton?, CGFloat)
            switch component {
            case .sidecar: entry = (sidecarButton, sidecarWidth)
            case .aiCoding: entry = (aiCodingButton, aiCodingWidth)
            case .systemMonitor: entry = (systemMonitorButton, configuredWidth(for: .systemMonitor))
            case .localModel: entry = (voiceButton, localModelWidth)
            }
            guard let button = entry.0 else { continue }
            let visible = componentVisibility[component] ?? true
            button.isHidden = !visible
            guard visible else { continue }
            frames.append((button, NSRect(x: x, y: 0, width: entry.1, height: 30)))
            x += entry.1 + 6
        }

        guard animated else {
            frames.forEach { $0.0.frame = $0.1 }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            frames.forEach { $0.0.animator().frame = $0.1 }
        }
    }

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

    private func updateBorderMenuItem() {
        borderMenuItem?.state = showPillBorders ? .on : .off
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

    @objc private func showSystemDetails() {
        AppLog.write("show system detail")
        refreshSystemMetrics()
        touchBar.principalItemIdentifier = nil
        touchBar.defaultItemIdentifiers = systemIdentifiers
        presentTouchBar()
    }

    @objc private func showMain() {
        touchBar.principalItemIdentifier = nil
        touchBar.defaultItemIdentifiers = mainIdentifiers
        presentTouchBar()
    }

    private func presentTouchBar() {
        guard ControlStrip.isSupported else {
            AppLog.write("present skipped: unsupported")
            return
        }
        AppLog.write("ensure DFR visible=\(touchBarPower.ensureVisible())")
        AppLog.write("present modal=\(ControlStrip.present(touchBar, from: Item.controlStrip)) ids=\(touchBar.defaultItemIdentifiers.map(\.rawValue))")
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

    @objc private func openCCSwitch() {
        openApplication(path: "/Applications/CC Switch.app")
    }

    @objc private func togglePillBorders() {
        showPillBorders.toggle()
        UserDefaults.standard.set(showPillBorders, forKey: DefaultsKey.showPillBorders)
        [sidecarButton, aiCodingButton, voiceButton].forEach(applyPillBorder)
        updateBorderMenuItem()
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

    @objc private func showComponentOrder() {
        if orderPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 362),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "自定义 Touch Bar 组件"
            panel.isReleasedWhenClosed = false
            panel.level = .floating

            let content = NSView(frame: panel.contentView?.bounds ?? .zero)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let title = NSTextField(labelWithString: "主层组件")
            title.frame = NSRect(x: 20, y: 316, width: 520, height: 24)
            title.font = .systemFont(ofSize: 17, weight: .semibold)
            content.addSubview(title)

            let subtitle = NSTextField(labelWithString: "开关控制显示；拖动滑杆改变宽度；箭头调整位置，修改会立即生效。")
            subtitle.frame = NSRect(x: 20, y: 291, width: 520, height: 20)
            subtitle.textColor = .secondaryLabelColor
            content.addSubview(subtitle)

            let stack = NSStackView(frame: NSRect(x: 20, y: 61, width: 520, height: 220))
            stack.orientation = .vertical
            stack.alignment = .width
            stack.distribution = .fillEqually
            stack.spacing = 7
            orderStack = stack
            content.addSubview(stack)

            let reset = NSButton(title: "恢复默认布局", target: self, action: #selector(resetComponentOrder))
            reset.frame = NSRect(x: 20, y: 17, width: 116, height: 28)
            reset.bezelStyle = .rounded
            content.addSubview(reset)

            panel.contentView = content
            orderPanel = panel
        }
        reloadOrderRows()
        orderPanel?.center()
        orderPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reloadOrderRows() {
        guard let orderStack else { return }
        for view in orderStack.arrangedSubviews {
            orderStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, component) in componentOrder.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 49))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            row.layer?.cornerRadius = 7

            let visible = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleComponentVisibility))
            visible.frame = NSRect(x: 8, y: 11, width: 24, height: 24)
            visible.state = (componentVisibility[component] ?? true) ? .on : .off
            visible.tag = index
            visible.toolTip = "显示或隐藏 \(component.title)"
            row.addSubview(visible)

            let icon = NSImageView(frame: NSRect(x: 38, y: 14, width: 19, height: 19))
            icon.image = NSImage(systemSymbolName: component.symbol, accessibilityDescription: component.title)
            icon.contentTintColor = .labelColor
            row.addSubview(icon)

            let label = NSTextField(labelWithString: component.title)
            label.frame = NSRect(x: 66, y: 14, width: 116, height: 20)
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
            slider.frame = NSRect(x: 184, y: 10, width: 177, height: 26)
            slider.isContinuous = true
            slider.tag = index
            slider.toolTip = "\(component.title) 宽度"
            row.addSubview(slider)

            let widthLabel = NSTextField(labelWithString: "\(Int(width)) pt")
            widthLabel.identifier = NSUserInterfaceItemIdentifier("width.\(component.rawValue)")
            widthLabel.frame = NSRect(x: 366, y: 14, width: 54, height: 20)
            widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            widthLabel.textColor = .secondaryLabelColor
            widthLabel.alignment = .right
            row.addSubview(widthLabel)

            let up = iconButton(symbol: "chevron.up", description: "上移", action: #selector(moveComponentUp))
            up.frame = NSRect(x: 450, y: 9, width: 28, height: 28)
            up.isBordered = true
            up.bezelStyle = .texturedRounded
            up.contentTintColor = .labelColor
            up.tag = index
            up.isEnabled = index > 0
            row.addSubview(up)

            let down = iconButton(symbol: "chevron.down", description: "下移", action: #selector(moveComponentDown))
            down.frame = NSRect(x: 482, y: 9, width: 28, height: 28)
            down.isBordered = true
            down.bezelStyle = .texturedRounded
            down.contentTintColor = .labelColor
            down.tag = index
            down.isEnabled = index < componentOrder.count - 1
            row.addSubview(down)
            orderStack.addArrangedSubview(row)
        }
    }

    @objc private func moveComponentUp(_ sender: NSButton) {
        moveComponent(at: sender.tag, by: -1)
    }

    @objc private func moveComponentDown(_ sender: NSButton) {
        moveComponent(at: sender.tag, by: 1)
    }

    @objc private func toggleComponentVisibility(_ sender: NSButton) {
        guard componentOrder.indices.contains(sender.tag) else { return }
        let component = componentOrder[sender.tag]
        let visible = sender.state == .on
        componentVisibility[component] = visible
        UserDefaults.standard.set(visible, forKey: MainComponent.visibilityPrefix + component.rawValue)
        applyComponentSettings(reloadRows: false)
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

    private func moveComponent(at index: Int, by offset: Int) {
        let destination = index + offset
        guard componentOrder.indices.contains(index), componentOrder.indices.contains(destination) else { return }
        componentOrder.swapAt(index, destination)
        applyComponentSettings(reloadRows: true)
    }

    @objc private func resetComponentOrder() {
        componentOrder = MainComponent.allCases
        componentVisibility = Dictionary(uniqueKeysWithValues: MainComponent.allCases.map { ($0, true) })
        componentWidths = Dictionary(uniqueKeysWithValues: MainComponent.allCases.map { ($0, $0.defaultWidth) })
        for component in MainComponent.allCases {
            UserDefaults.standard.set(true, forKey: MainComponent.visibilityPrefix + component.rawValue)
            UserDefaults.standard.set(Double(component.defaultWidth), forKey: MainComponent.widthPrefix + component.rawValue)
        }
        applyComponentSettings(reloadRows: true)
    }

    private func applyComponentSettings(reloadRows: Bool) {
        MainComponent.saveOrder(componentOrder)
        if reloadRows { reloadOrderRows() }
        updateSystemMonitor()
        layoutMainButtons(animated: true)
        AppLog.write("component settings order=\(componentOrder.map(\.rawValue)) visible=\(componentVisibility) widths=\(componentWidths)")
    }

    @objc private func openLatestCodexThread() {
        if let id = snapshot.activeThreads.first?.id {
            openCodexThread(id)
        } else {
            openApplication(path: "/Applications/ChatGPT.app")
        }
    }

    private func openCodexThread(_ id: String) {
        guard let url = URL(string: "codex://threads/\(id)") else { return }
        NSWorkspace.shared.open(url)
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
        controller.start()
        registerLoginItem()
        if CommandLine.arguments.contains("--smoke-test") {
            controller.runSmokeTest()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
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
