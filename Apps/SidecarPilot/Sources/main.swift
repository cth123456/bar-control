import AppKit
import ApplicationServices
import Darwin
import Foundation
import UniformTypeIdentifiers

private var targetDevice: String = {
    let environment = ProcessInfo.processInfo.environment["SIDECAR_PILOT_DEVICE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let environment, !environment.isEmpty { return environment }
    if let saved = try? Data(contentsOf: PilotConfiguration.url),
       let configuration = try? JSONDecoder().decode(PilotConfiguration.self, from: saved),
       !configuration.targetDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return configuration.targetDevice.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return UserDefaults.standard.string(forKey: "TargetDevice")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()
private let requestedAction = ProcessInfo.processInfo.environment["SIDECAR_PILOT_ACTION"] ?? ""
private let envNativeHost = ProcessInfo.processInfo.environment["SIDECAR_PILOT_NATIVE_HOST"] == "1"
/// 无窗口的明确动作：connect 只连接、不切换；供 iPad 快捷指令使用。
private let headlessConnectMode = requestedAction == "connect"
/// 普通启动（Finder / iPad 快捷指令的 open -n）默认也走 headless 连接：
/// 只连显示器、不弹设置窗口、连完退出。需要设置时加 --settings 或按住 Option。
private let settingsRequested = CommandLine.arguments.contains("--settings")
    || NSEvent.modifierFlags.contains(.option)
private let defaultHeadlessLaunch = !envNativeHost && !headlessConnectMode
    && requestedAction != "repair" && !settingsRequested
private let connectOnlyMode = headlessConnectMode || defaultHeadlessLaunch
private let nativeHostMode = envNativeHost || connectOnlyMode
private let repairMode = requestedAction == "repair"
private let isStandaloneLaunch = !nativeHostMode && !repairMode

private struct CommandResult {
    let status: Int32
    let output: String
}

private struct PilotConfiguration: Codable {
    var targetDevice: String

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SidecarPilot/configuration.json")
    }

    static func save(targetDevice: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PilotConfiguration(targetDevice: targetDevice))
        try data.write(to: url, options: .atomic)
    }

    static func loadTargetDevice() -> String {
        if let saved = try? Data(contentsOf: url),
           let configuration = try? JSONDecoder().decode(PilotConfiguration.self, from: saved),
           !configuration.targetDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configuration.targetDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return UserDefaults.standard.string(forKey: "TargetDevice")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// 随航的连接、断开和状态查询都走系统私有的 SidecarCore，也就是 BetterDisplay
/// `-sidecarConnected` 开关背后调用的同一套 `SidecarDisplayManager`，因此不再需要
/// 任何外部 App 常驻。私有框架没有头文件，只能通过 Objective-C 运行时按名字取类和选择器。
private enum SidecarBridge {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
    private static let frameworkLoaded = dlopen(frameworkPath, RTLD_NOW) != nil
    private static let stateLock = NSLock()
    private static var cachedManager: NSObject?
    private static var lookupFailed = false

    /// 连接回调可能在其他线程触发，用它把错误信息传回来。
    private final class CallbackBox {
        private let lock = NSLock()
        private var stored = ""

        var message: String {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    private static var manager: NSObject? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let cachedManager { return cachedManager }
        if lookupFailed { return nil }
        guard frameworkLoaded,
              let type = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              let shared = type.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject else {
            lookupFailed = true
            return nil
        }
        cachedManager = shared
        return shared
    }

    static var isAvailable: Bool { manager != nil }

    static func availableDeviceNames() -> [String] {
        guard let manager else { return [] }
        var pools = [
            devices(manager, "connectedDevices"),
            devices(manager, "recentDevices"),
            devices(manager, "devices")
        ]
        if let type = NSClassFromString("SidecarDevice") as? NSObject.Type,
           let discovered = type.perform(NSSelectorFromString("allDevices"))?.takeUnretainedValue() as? [NSObject] {
            pools.append(discovered)
        }
        return Array(Set(pools.flatMap { $0.map(name(of:)) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// 主动等待系统 relay 发现设备。新电脑首次打开时 allDevices 往往短暂为空，
    /// 只读一次会误报“没有设备”，所以按短间隔重试。
    static func discoverDeviceNames(waitFor seconds: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var names: [String] = []
        while true {
            names = availableDeviceNames()
            if !names.isEmpty || Date() >= deadline { return names }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private static func object(_ target: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector), let value = target.perform(selector) else { return nil }
        return value.takeUnretainedValue()
    }

    private static func devices(_ target: NSObject, _ name: String) -> [NSObject] {
        (object(target, name) as? [NSObject]) ?? []
    }

    private static func name(of device: NSObject) -> String {
        ((object(device, "name") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ candidate: String, _ wanted: String) -> Bool {
        candidate.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func isConnected(_ deviceName: String) -> Bool {
        guard let manager else { return false }
        return devices(manager, "connectedDevices").contains { matches(name(of: $0), deviceName) }
    }

    /// 待连接的设备要先出现在 relay 发现结果里，设备列表为空时短暂等待。
    private static func findDevice(named deviceName: String, pollFor seconds: TimeInterval) -> NSObject? {
        guard let manager else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            var pools = [devices(manager, "connectedDevices"), devices(manager, "devices")]
            if let type = NSClassFromString("SidecarDevice") as? NSObject.Type,
               let discovered = type.perform(NSSelectorFromString("allDevices"))?.takeUnretainedValue() as? [NSObject] {
                pools.append(discovered)
            }
            for pool in pools {
                if let hit = pool.first(where: { matches(name(of: $0), deviceName) }) { return hit }
            }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    static func setConnected(_ connected: Bool, device deviceName: String, timeout: TimeInterval) -> CommandResult {
        guard let manager else {
            return CommandResult(status: 1, output: "SidecarCore 不可用")
        }
        guard let device = findDevice(named: deviceName, pollFor: connected ? 3.0 : 0) else {
            return CommandResult(status: 1, output: "未找到随航设备 \(deviceName)")
        }

        let name = connected ? "connectToDevice:completion:" : "disconnectFromDevice:completion:"
        let selector = NSSelectorFromString(name)
        guard manager.responds(to: selector) else {
            return CommandResult(status: 1, output: "SidecarDisplayManager 不支持 \(name)")
        }

        let done = DispatchSemaphore(value: 0)
        let box = CallbackBox()
        let completion: @convention(block) (AnyObject?) -> Void = { error in
            box.message = error.map { "\($0)" } ?? ""
            done.signal()
        }
        _ = manager.perform(selector, with: device, with: unsafeBitCast(completion, to: AnyObject.self))

        guard done.wait(timeout: .now() + timeout) == .success else {
            return CommandResult(status: 124, output: "\(connected ? "连接" : "断开")请求超时")
        }
        return box.message.isEmpty
            ? CommandResult(status: 0, output: connected ? "on" : "off")
            : CommandResult(status: 1, output: box.message)
    }
}

private struct MethodStat: Codable {
    var attempts = 0
    var successes = 0
    var totalSeconds = 0.0
    var recent: [Bool] = []

    var successRate: Double {
        attempts == 0 ? 0 : Double(successes) / Double(attempts)
    }

    var averageSeconds: Double {
        attempts == 0 ? 99 : totalSeconds / Double(attempts)
    }
}

private struct Statistics: Codable {
    var version = 1
    var methods: [String: MethodStat] = [:]
}

private enum ConnectionMethod: String, CaseIterable {
    case direct
    case reconnect
    case systemUI

    var label: String {
        switch self {
        case .direct: return "直连"
        case .reconnect: return "重连"
        case .systemUI: return "系统连接"
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .direct: return 12
        case .reconnect: return 14
        case .systemUI: return 16
        }
    }
}

private final class PilotViewController: NSViewController, NSTouchBarDelegate {
    private let statusIdentifier = NSTouchBarItem.Identifier("local.codex.sidecarpilot.status")
    private let cancelIdentifier = NSTouchBarItem.Identifier("local.codex.sidecarpilot.cancel")
    private let detailIdentifier = NSTouchBarItem.Identifier("local.codex.sidecarpilot.detail")

    private let statusLabel = NSTextField(labelWithString: "正在准备…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    var onCancel: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 80))
    }

    override func makeTouchBar() -> NSTouchBar? {
        // 主屏不是内置屏时（iPad 作为主显示器/硬件镜像），AppKit 的
        // NSTouchBarFinder 在退出阶段会访问已释放的表，导致 SIGSEGV。
        // 这种布局下物理 Touch Bar 本来也没有可显示区域，直接不创建。
        guard CGDisplayIsBuiltin(CGMainDisplayID()) != 0 else { return nil }
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("local.codex.sidecarpilot.bar")
        bar.defaultItemIdentifiers = [cancelIdentifier, .flexibleSpace, statusIdentifier, detailIdentifier, .flexibleSpace]
        bar.customizationAllowedItemIdentifiers = [cancelIdentifier, statusIdentifier, detailIdentifier]
        bar.principalItemIdentifier = statusIdentifier
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == cancelIdentifier {
            let item = NSCustomTouchBarItem(identifier: identifier)
            cancelButton.target = self
            cancelButton.action = #selector(cancelTapped)
            cancelButton.bezelColor = .systemRed
            item.view = cancelButton
            item.customizationLabel = "取消随航连接"
            return item
        }

        if identifier == statusIdentifier {
            let item = NSCustomTouchBarItem(identifier: identifier)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            statusLabel.alignment = .center
            statusLabel.maximumNumberOfLines = 1
            let stack = NSStackView(views: [spinner, statusLabel])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 255).isActive = true
            item.view = stack
            item.customizationLabel = "随航连接状态"
            return item
        }

        if identifier == detailIdentifier {
            let item = NSCustomTouchBarItem(identifier: identifier)
            detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .center
            detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
            item.view = detailLabel
            item.customizationLabel = "连接阶段"
            return item
        }
        return nil
    }

    func update(message: String, detail: String, spinning: Bool, success: Bool? = nil) {
        statusLabel.stringValue = message
        detailLabel.stringValue = detail
        if spinning {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        if let success {
            statusLabel.textColor = success ? .systemGreen : .systemRed
        } else {
            statusLabel.textColor = .labelColor
        }
        cancelButton.isHidden = !spinning
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = PilotViewController()
    private var statusItem: NSStatusItem?
    private var previousApp: NSRunningApplication?
    private var didUseSystemUI = false
    private let stateLock = NSLock()
    private var _cancelled = false
    private let launchTime = Date()
    private var configurationWindow: NSWindow?
    private var deviceField: NSTextField?
    private var configurationMessage: NSTextField?
    private var connectionStatusLabel: NSTextField?
    private var connectionMethodLabel: NSTextField?
    private var connectionRouteLabel: NSTextField?
    private var diagnosticMessageLabel: NSTextField?
    private var discoveredDevices: [String] = []
    private var statusRefreshTimer: Timer?
    private var prerequisitesLabel: NSTextField?
    private var permissionLabel: NSTextField?
    private var devicePicker: NSPopUpButton?
    private var deviceRefreshTimer: Timer?
    private var isRefreshingDevices = false
    private var isPipelineRunning = false
    private var toggleOnConnect = false
    private var didAutoScan = false
    private let isNativeHost = nativeHostMode

    private var cancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _cancelled
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SIDECAR_PILOT_DISCOVERY_PROBE"] == "1" {
            let names = SidecarBridge.discoverDeviceNames(waitFor: 6)
            print("PROBE names=\(names) sidecarCore=\(SidecarBridge.isAvailable)")
            exit(names.isEmpty ? 2 : 0)
        }
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.SidecarPilot")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if duplicate && !nativeHostMode {
            NSApp.terminate(nil)
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.accessory)
        controller.onCancel = { [weak self] in self?.requestCancel() }
        // 不再创建带 touchBar 的隐藏窗口：任何启动方式（含 iPad 快捷指令直接拉起）
        // 都会让这个窗口/App 成为 Touch Bar 的 frontmost 提供者，把 Bar Control 的
        // 整排模块顶掉。只保留状态文件 + 菜单栏进度，不改 Touch Bar 归属。

        if !nativeHostMode {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.title = "随航管家"
            statusItem?.button?.toolTip = "打开随航管家配置"
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "连接随航…", action: #selector(connectFromMenu), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "断开随航…", action: #selector(disconnectFromMenu), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "配置…", action: #selector(openConfigurationFromMenu), keyEquivalent: ","))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q"))
            menu.items.forEach { $0.target = self }
            statusItem?.menu = menu
        }

        if targetDevice.isEmpty && !repairMode {
            writeTouchBarState(state: "idle", message: "请先配置随航设备", detail: "打开随航管家设置")
            showConfiguration()
        } else if nativeHostMode || repairMode {
            // connect 动作永远执行连接；native-host 的默认行为仍是切换。
            startPipeline(allowToggle: envNativeHost && !repairMode && !connectOnlyMode)
        } else {
            // 清掉上次异常退出可能遗留的 success/failure，避免 Bar Control
            // 一直停在绿色“连接成功 + 多少秒”的页面。
            writeTouchBarState(state: "idle", message: "随航 ⇄ 通用控制", detail: "")
            refreshConnectionStatus()
            showConfiguration()
        }
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshConnectionStatus()
        }
        deviceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshDeviceList()
        }
    }

    private func startPipeline(allowToggle: Bool = false) {
        stateLock.lock()
        _cancelled = false
        stateLock.unlock()
        toggleOnConnect = allowToggle
        isPipelineRunning = true
        updateUI("正在检查连接…", detail: "准备", spinning: true)
        log("launch")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.runPipeline() }
    }

    private func startDisconnectPipeline() {
        stateLock.lock()
        _cancelled = false
        stateLock.unlock()
        isPipelineRunning = true
        updateUI("正在断开随航…", detail: "准备", spinning: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.disconnectSidecar() }
    }

    @objc private func openConfigurationFromMenu() { showConfiguration() }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func connectFromMenu() {
        if let fieldValue = deviceField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !fieldValue.isEmpty {
            targetDevice = fieldValue
        }
        let saved = UserDefaults.standard.string(forKey: "TargetDevice") ?? ""
        let current = ((try? Data(contentsOf: PilotConfiguration.url))
            .flatMap { try? JSONDecoder().decode(PilotConfiguration.self, from: $0) }?.targetDevice) ?? saved
        if targetDevice.isEmpty { targetDevice = current.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !targetDevice.isEmpty else {
            configurationMessage?.textColor = .secondaryLabelColor
            configurationMessage?.stringValue = "正在搜索同一 Apple 账户的 iPad…"
            showConfiguration()
            // 新电脑首次连接时系统 relay 可能还没发现设备：主动等待并自动匹配唯一设备。
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let names = SidecarBridge.discoverDeviceNames(waitFor: 10)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyDiscoveredDevices(names)
                    if names.count == 1 {
                        self.deviceField?.stringValue = names[0]
                        self.saveAndConnect(device: names[0])
                    } else if names.count > 1 {
                        self.configurationMessage?.textColor = .secondaryLabelColor
                        self.configurationMessage?.stringValue = "发现 \(names.count) 台设备，请选择一台后再次点击连接。"
                    } else {
                        self.configurationMessage?.textColor = .systemRed
                        self.configurationMessage?.stringValue = self.usbIPadHint()
                            ?? "未发现 iPad。请确认同一 Apple 账户、Wi‑Fi/蓝牙已开启，或 USB 连接后选择“信任此电脑”。"
                    }
                }
            }
            return
        }
        saveAndConnect(device: targetDevice)
    }

    private func saveAndConnect(device: String) {
        targetDevice = device
        do {
            try PilotConfiguration.save(targetDevice: targetDevice)
            UserDefaults.standard.set(targetDevice, forKey: "TargetDevice")
        } catch {
            configurationMessage?.stringValue = "保存设备名称失败：\(error.localizedDescription)"
            showConfiguration()
            return
        }
        log("preflight device=\(targetDevice) sidecarCore=\(SidecarBridge.isAvailable) discovered=\(SidecarBridge.availableDeviceNames()) accessibility=\(AXIsProcessTrusted()) displays=\(displayDiagnosticsSummary())")
        startPipeline(allowToggle: false)
    }

    @objc private func disconnectFromMenu() {
        log("manual disconnect requested")
        startDisconnectPipeline()
    }

    @objc private func rescanDevices() {
        configurationMessage?.stringValue = "正在搜索同一 Apple 账户的 iPad…"
        configurationMessage?.textColor = .secondaryLabelColor
        log("discovery start wait=8s")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let names = SidecarBridge.discoverDeviceNames(waitFor: 8)
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("discovery names=\(names) sidecarCore=\(SidecarBridge.isAvailable)")
                self.applyDiscoveredDevices(names)
                if names.isEmpty {
                    self.configurationMessage?.stringValue = self.usbIPadHint()
                        ?? "未发现 iPad。请确认同一 Apple 账户、Wi‑Fi/蓝牙已开启，或 USB 连接后选择“信任此电脑”。"
                    self.configurationMessage?.textColor = .systemRed
                } else if names.count == 1 {
                    self.deviceField?.stringValue = names[0]
                    self.configurationMessage?.stringValue = "已找到 \(names[0])，点击“检查并连接”即可。"
                    self.configurationMessage?.textColor = .systemGreen
                } else {
                    self.configurationMessage?.stringValue = "发现 \(names.count) 台设备，请选择其中一台。"
                    self.configurationMessage?.textColor = .secondaryLabelColor
                }
            }
        }
    }

    private func applyDiscoveredDevices(_ devices: [String]) {
        discoveredDevices = devices
        guard let picker = devicePicker else { return }
        let selected = picker.indexOfSelectedItem > 0 ? picker.titleOfSelectedItem : nil
        picker.removeAllItems()
        picker.addItem(withTitle: devices.isEmpty ? "未发现设备，正在重试…" : "选择已发现设备…")
        picker.addItems(withTitles: devices)
        if let selected, devices.contains(selected) {
            picker.selectItem(withTitle: selected)
        } else if targetDevice.isEmpty, devices.count == 1 {
            picker.selectItem(withTitle: devices[0])
            deviceField?.stringValue = devices[0]
        } else {
            picker.selectItem(at: 0)
        }
    }

    /// 只读提示：USB 已插入但尚未被 Sidecar 发现时，给出具体下一步。
    private func usbIPadHint() -> String? {
        let result = runCommand("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"], timeout: 8)
        guard result.status == 0, result.output.contains("iPad") else { return nil }
        return "检测到 USB 连接的 iPad。请在 iPad 上点“信任”，并保持解锁后再重新扫描。"
    }

    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    private func refreshDeviceList() {
        guard configurationWindow?.isVisible == true, !isPipelineRunning else { return }
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = SidecarBridge.availableDeviceNames()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingDevices = false
                guard let picker = self.devicePicker else { return }
                self.discoveredDevices = devices
                let selected = picker.indexOfSelectedItem > 0 ? picker.titleOfSelectedItem : nil
                picker.removeAllItems()
                picker.addItem(withTitle: devices.isEmpty ? "未发现设备，正在重试…" : "选择已发现设备…")
                picker.addItems(withTitles: devices)
                if let selected, devices.contains(selected) {
                    picker.selectItem(withTitle: selected)
                } else if targetDevice.isEmpty && devices.count == 1 {
                    picker.selectItem(withTitle: devices[0])
                    self.deviceField?.stringValue = devices[0]
                    self.configurationMessage?.stringValue = "已自动选中：\(devices[0])。确认后点击检查并连接。"
                } else {
                    picker.selectItem(at: 0)
                }
            }
        }
    }

    private func refreshPermissionStatus() {
        permissionLabel?.stringValue = AXIsProcessTrusted()
            ? "辅助功能已授权；首次用系统界面兜底时，macOS 会弹出自动化请求，由用户批准。"
            : "备用系统界面连接需要辅助功能和自动化权限；直连与重连不依赖这两项。"
    }

    private func showConfiguration() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = self.configurationWindow {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 540))
            let title = NSTextField(labelWithString: "配置随航设备")
            title.font = .systemFont(ofSize: 20, weight: .semibold)
            title.frame = NSRect(x: 28, y: 496, width: 480, height: 28)
            content.addSubview(title)
            let version = NSTextField(labelWithString: Self.appVersionText)
            version.font = .systemFont(ofSize: 11)
            version.textColor = .tertiaryLabelColor
            version.alignment = .right
            version.frame = NSRect(x: 300, y: 502, width: 208, height: 16)
            content.addSubview(version)
            let status = NSTextField(labelWithString: "连接状态：正在查询…")
            status.font = .systemFont(ofSize: 13, weight: .medium)
            status.frame = NSRect(x: 28, y: 462, width: 480, height: 20)
            self.connectionStatusLabel = status
            content.addSubview(status)
            let method = NSTextField(labelWithString: "连接链路：无法判定；软件调用路径：尚无记录")
            method.textColor = .secondaryLabelColor
            method.frame = NSRect(x: 28, y: 438, width: 480, height: 18)
            self.connectionMethodLabel = method
            content.addSubview(method)
            let route = NSTextField(labelWithString: "当前会话链路：无法判定（USB / 无线）")
            route.textColor = .secondaryLabelColor
            route.frame = NSRect(x: 28, y: 416, width: 480, height: 18)
            self.connectionRouteLabel = route
            content.addSubview(route)
            let prerequisites = NSTextField(wrappingLabelWithString: "连接前请确认 Mac 与 iPad 型号及系统版本支持 Sidecar、登录同一 Apple 账户并开启双重认证和 Handoff。无线连接需 Wi‑Fi、蓝牙开启且设备在范围内；USB 连接需可传数据的线缆并在提示时信任此电脑。iPad 需解锁并开启“光标与键盘”。")
            prerequisites.textColor = .secondaryLabelColor
            prerequisites.frame = NSRect(x: 28, y: 356, width: 480, height: 54)
            self.prerequisitesLabel = prerequisites
            content.addSubview(prerequisites)
            let description = NSTextField(labelWithString: "链路无法可靠判定时显示“无法判定”；镜像/扩展模式由 macOS 与 iPad 决定，本 App 不修改。")
            description.frame = NSRect(x: 28, y: 332, width: 480, height: 18)
            content.addSubview(description)

            let deviceNames = SidecarBridge.availableDeviceNames()
            self.discoveredDevices = deviceNames
            let field = NSTextField(string: targetDevice)
            field.placeholderString = "例如：我的 iPad"
            let choices = NSPopUpButton(frame: NSRect(x: 28, y: 296, width: 480, height: 28), pullsDown: false)
            choices.addItem(withTitle: deviceNames.isEmpty ? "未发现设备，正在重试…" : "选择已发现设备…")
            choices.addItems(withTitles: deviceNames)
            if !targetDevice.isEmpty, deviceNames.contains(targetDevice) {
                choices.selectItem(withTitle: targetDevice)
            } else {
                choices.selectItem(at: 0)
            }
            choices.target = self
            choices.action = #selector(self.deviceChoiceChanged(_:))
            content.addSubview(choices)
            self.devicePicker = choices
            field.frame = NSRect(x: 28, y: 260, width: 480, height: 28)
            content.addSubview(field)
            self.deviceField = field

            let hint = NSTextField(wrappingLabelWithString: "列表为空时先完成上面的系统条件并等待刷新；也可手动输入系统“显示器”菜单中的设备名称。")
            hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 28, y: 232, width: 480, height: 20)
            content.addSubview(hint)
            let permissions = NSTextField(wrappingLabelWithString: "备用系统界面连接需要辅助功能和自动化权限；直连与重连不依赖这两项。")
            permissions.textColor = .secondaryLabelColor
            permissions.frame = NSRect(x: 28, y: 206, width: 480, height: 20)
            self.permissionLabel = permissions
            content.addSubview(permissions)
            let openPrivacy = NSButton(title: "打开辅助功能设置", target: self, action: #selector(self.openAccessibilitySettings))
            openPrivacy.frame = NSRect(x: 28, y: 168, width: 160, height: 30)
            content.addSubview(openPrivacy)
            let connect = NSButton(title: "检查并连接", target: self, action: #selector(self.connectFromMenu))
            connect.frame = NSRect(x: 196, y: 168, width: 96, height: 30)
            content.addSubview(connect)
            let disconnect = NSButton(title: "断开随航", target: self, action: #selector(self.disconnectFromMenu))
            disconnect.frame = NSRect(x: 300, y: 168, width: 96, height: 30)
            content.addSubview(disconnect)
            let displays = NSButton(title: "打开显示器设置", target: self, action: #selector(self.openDisplaySettings))
            displays.frame = NSRect(x: 404, y: 168, width: 108, height: 30)
            content.addSubview(displays)
            let message = NSTextField(labelWithString: "")
            message.frame = NSRect(x: 28, y: 136, width: 480, height: 18)
            self.configurationMessage = message
            content.addSubview(message)
            let save = NSButton(title: "保存", target: self, action: #selector(self.saveConfiguration))
            save.keyEquivalent = "\r"
            let rescan = NSButton(title: "重新扫描设备", target: self, action: #selector(self.rescanDevices))
            rescan.frame = NSRect(x: 28, y: 96, width: 120, height: 30)
            content.addSubview(rescan)
            save.frame = NSRect(x: 408, y: 50, width: 100, height: 30)
            content.addSubview(save)
            let export = NSButton(title: "导出诊断日志…", target: self, action: #selector(self.exportDiagnosticLog))
            export.frame = NSRect(x: 28, y: 50, width: 150, height: 30)
            content.addSubview(export)
            let diagnosticMessage = NSTextField(labelWithString: "")
            diagnosticMessage.font = .systemFont(ofSize: 11)
            diagnosticMessage.textColor = .secondaryLabelColor
            diagnosticMessage.frame = NSRect(x: 28, y: 24, width: 480, height: 18)
            self.diagnosticMessageLabel = diagnosticMessage
            content.addSubview(diagnosticMessage)

            let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "随航管家设置"
            window.contentView = content
            window.delegate = self
            window.center()
            self.configurationWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.refreshConnectionStatus()
            if targetDevice.isEmpty, deviceNames.count == 1 {
                self.deviceField?.stringValue = deviceNames[0]
                self.configurationMessage?.stringValue = "已自动选中唯一发现的设备；确认后点击检查并连接。"
            }
            self.refreshPermissionStatus()
            if targetDevice.isEmpty, !self.didAutoScan {
                self.didAutoScan = true
                self.rescanDevices()
            }
        }
    }

    @objc private func deviceChoiceChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem > 0 { deviceField?.stringValue = sender.titleOfSelectedItem ?? "" }
    }

    @objc private func saveConfiguration() {
        let value = (deviceField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            configurationMessage?.stringValue = "请输入或选择 iPad 名称。"
            configurationMessage?.textColor = .systemRed
            return
        }
        do {
            try PilotConfiguration.save(targetDevice: value)
            UserDefaults.standard.set(value, forKey: "TargetDevice")
            targetDevice = value
            configurationMessage?.stringValue = "已保存：\(value)"
            configurationMessage?.textColor = .systemGreen
            log("configuration saved for device \(value)")
            connectionStatusLabel?.stringValue = "连接状态：正在查询…"
            refreshConnectionStatus()
        } catch {
            configurationMessage?.stringValue = "保存失败：\(error.localizedDescription)"
            configurationMessage?.textColor = .systemRed
        }
    }

    @objc private func exportDiagnosticLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "随航管家诊断-\(Self.timestampForFilename()).zip"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                let archive = try self?.createDiagnosticArchive()
                guard let archive else { throw CocoaError(.fileWriteUnknown) }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: archive, to: destination)
                self?.diagnosticMessageLabel?.stringValue = "已导出：\(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self?.diagnosticMessageLabel?.stringValue = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private static func timestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var appVersionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private func createDiagnosticArchive() throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarPilot-Diagnostic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let devices = SidecarBridge.availableDeviceNames()
        let connected = !targetDevice.isEmpty && confirmConnected()
        let report = [
            "随航管家诊断报告",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "App 版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"))",
            "macOS：\(systemVersion)",
            "目标设备：\(targetDevice.isEmpty ? "未配置" : targetDevice)",
            "当前连接状态：\(connected ? "已连接" : "未连接或无法确认")",
            "SidecarCore：\(SidecarBridge.isAvailable ? "可用" : "不可用")",
            "辅助功能授权：\(AXIsProcessTrusted() ? "已授权" : "未授权")",
            "发现设备：\(devices.isEmpty ? "无" : devices.joined(separator: ", "))",
            "最近连接方式：\(loadLastConnectionMethod() ?? "无记录")",
            "当前会话链路：无法判定（USB / 无线；App 不推断传输链路）",
            "显示状态（只读）：\(displayDiagnosticsSummary())",
            "",
            "隐私说明：已移除当前用户主目录路径。报告包含设备名称、时间戳和随航相关系统日志。"
        ]
        let reportURL = temporaryDirectory.appendingPathComponent("诊断摘要.txt")
        try Data((report.joined(separator: "\n") + "\n").utf8).write(to: reportURL, options: .atomic)

        if FileManager.default.fileExists(atPath: logURL.path) {
            let applicationLog = try String(contentsOf: logURL, encoding: .utf8)
            let sanitized = redactHomePath(applicationLog)
            try Data(sanitized.utf8).write(to: temporaryDirectory.appendingPathComponent("SidecarPilot.log"), options: .atomic)
        }
        if FileManager.default.fileExists(atPath: lastConnectionURL.path) {
            let data = try Data(contentsOf: lastConnectionURL)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let safeValue: [String: Any] = ["method": value["method"] ?? "", "device": value["device"] ?? ""]
            let safeData = try JSONSerialization.data(withJSONObject: safeValue, options: [.prettyPrinted, .sortedKeys])
            try safeData.write(to: temporaryDirectory.appendingPathComponent("last-connection.json"), options: .atomic)
        }

        let systemLog = runCommand("/usr/bin/log", [
            "show", "--last", "30m", "--style", "compact",
            "--predicate", "process == \"SidecarPilot\" OR process == \"SidecarRelay\" OR process == \"SidecarDisplayAgent\""
        ], timeout: 12)
        if !systemLog.output.isEmpty {
            let sanitized = redactHomePath(systemLog.output)
            try Data(sanitized.utf8).write(to: temporaryDirectory.appendingPathComponent("macOS-Sidecar.log"), options: .atomic)
        }

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarPilot-Diagnostic-\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", temporaryDirectory.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }

    private func redactHomePath(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text.replacingOccurrences(of: home, with: "~")
    }

    /// 只读摘要，用于区分“当前已经是扩展/镜像状态”与“本 App 改动造成的”。
    /// 不调用任何显示配置接口，也不切换模式。
    private func displayDiagnosticsSummary() -> String {
        let result = runCommand("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], timeout: 8)
        guard result.status == 0 else { return "读取失败 status=\(result.status)" }
        let text = result.output
        let sidecar = text.contains("Sidecar Display")
        let mirrorKeys = ["spdisplays_mirror", "mirror", "Mirror"].filter { text.contains($0) }
        return "Sidecar Display=\(sidecar ? "是" : "否")；mirror字段=\(mirrorKeys.isEmpty ? "未出现" : mirrorKeys.joined(separator: "/"))"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 独立窗口关闭后停止轮询并退出，避免常驻进程持续跑
    /// system_profiler / SidecarCore 扫描，拖慢 Bar Control 的菜单展开。
    func windowWillClose(_ notification: Notification) {
        guard !nativeHostMode else { return }
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
        deviceRefreshTimer?.invalidate()
        deviceRefreshTimer = nil
        writeTouchBarState(state: "idle", message: "随航 ⇄ 通用控制", detail: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private func requestCancel() {
        stateLock.lock()
        _cancelled = true
        stateLock.unlock()
        updateUI("已取消连接", detail: "取消", spinning: false, success: false)
        log("cancelled by user")
    }

    private func runPipeline() {
        targetDevice = ProcessInfo.processInfo.environment["SIDECAR_PILOT_DEVICE"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? PilotConfiguration.loadTargetDevice()
        guard !targetDevice.isEmpty else {
            finish(success: false, message: "尚未配置 iPad", detail: "请先设置设备名称")
            return
        }
        setConnectionStatus("检查中", method: "检查系统和设备发现")
        if confirmConnected() {
            if repairMode {
                updateUI("正在重建随航连接…", detail: "断开", spinning: true)
                log("repair: disconnecting existing Sidecar session")
                let result = SidecarBridge.setConnected(false, device: targetDevice, timeout: 8)
                guard result.status == 0, waitForDisconnection(timeout: 12) else {
                    log("repair: disconnect failed status=\(result.status) output=\(result.output)")
                    finish(success: false, message: "随航断开失败", detail: "未执行重连")
                    return
                }
                guard sleepCheckingCancel(1.5) else {
                    finish(success: false, message: "已取消连接", detail: "取消")
                    return
                }
                log("repair: Sidecar display confirmed disconnected")
            } else {
                // 独立设置窗口里“连接”绝不反转成断开；只有 Bar Control 的 Touch Bar
                // 单键入口保留原有的“点一下切换”语义。
                if toggleOnConnect {
                    log("connected; toggle mode requested disconnect")
                    setConnectionStatus("已连接", method: "Bar Control 切换为断开")
                    disconnectSidecar()
                } else {
                    log("already connected; refusing implicit disconnect")
                    setConnectionStatus("已连接", method: "当前会话（无需重复连接）")
                    finish(success: true, message: "随航已连接", detail: "未执行额外连接或断开")
                    keepWindowAfterResult()
                }
                return
            }
        }

        let methods = orderedMethods()
        for (index, method) in methods.enumerated() {
            if cancelled {
                finish(success: false, message: "已取消连接", detail: "取消")
                return
            }

            let stage = "\(index + 1)/\(methods.count)"
            setConnectionStatus("连接中", method: "尝试：\(method.label)")
            updateUI("\(method.label)中…", detail: stage, spinning: true)
            log("attempt \(stage) \(method.rawValue)")
            let started = Date()
            let commandResult = perform(method)
            log("command \(method.rawValue) returned status=\(commandResult.status)")
            if commandResult.status != 0 {
                log("command \(method.rawValue) failed: \(commandResult.output)")
            }

            let success = waitForConnection(timeout: method.timeout)
            let duration = Date().timeIntervalSince(started)
            record(method: method, success: success, duration: duration)
            if success {
                setConnectionStatus("已连接", method: method.label)
                saveLastConnectionMethod(method.label)
                finish(success: true, message: "随航连接成功", detail: elapsedText())
                keepWindowAfterResult()
                return
            }
            log("timeout \(method.rawValue) after \(String(format: "%.1f", duration))s")
        }

        let reason = diagnoseFailure()
        setConnectionStatus("未连接", method: "三种方式均失败")
        saveLastConnectionMethod("失败（直连、重连、系统设置）")
        finish(success: false, message: reason, detail: "全部失败")
        keepWindowAfterResult()
    }

    private func disconnectSidecar() {
        setConnectionStatus("断开中", method: "SidecarCore")
        updateUI("断开随航中…", detail: "切换", spinning: true)
        log("attempt disconnect")
        let commandResult = SidecarBridge.setConnected(false, device: targetDevice, timeout: 8)
        log("command disconnect returned status=\(commandResult.status)")
        if commandResult.status != 0 {
            log("command disconnect failed: \(commandResult.output)")
            finish(success: false, message: "随航断开失败", detail: "请重试")
            return
        }

        if waitForDisconnection(timeout: 12) {
            setConnectionStatus("未连接", method: "SidecarCore 断开")
            // 不强制重启 UniversalControl：macOS 会在 Sidecar 会话关闭后自行恢复
            // 通用控制。强制 killall 会造成连续互通组件重启和输入/显示行为突变。
            log("Sidecar disconnected; leaving UniversalControl untouched")
            finish(success: true, message: "随航已断开", detail: "通用控制由 macOS 自动恢复")
        } else {
            keepWindowAfterResult()
            finish(success: false, message: "随航断开超时", detail: "请重试")
        }
    }

    private func orderedMethods() -> [ConnectionMethod] {
        let fixed = ConnectionMethod.allCases
        if let forced = ProcessInfo.processInfo.environment["SIDECAR_PILOT_METHOD"],
           let method = ConnectionMethod(rawValue: forced) {
            return [method]
        }
        let stats = loadStatistics()
        guard fixed.allSatisfy({ (stats.methods[$0.rawValue]?.attempts ?? 0) >= 5 }) else {
            return fixed
        }
        return fixed.sorted { lhs, rhs in
            score(stats.methods[lhs.rawValue]) > score(stats.methods[rhs.rawValue])
        }
    }

    private func score(_ stat: MethodStat?) -> Double {
        guard let stat else { return -1000 }
        return stat.successRate * 100 - min(stat.averageSeconds, 30)
    }

    private func perform(_ method: ConnectionMethod) -> CommandResult {
        switch method {
        case .direct:
            return SidecarBridge.setConnected(true, device: targetDevice, timeout: 8)
        case .reconnect:
            if SidecarBridge.isConnected(targetDevice) {
                _ = SidecarBridge.setConnected(false, device: targetDevice, timeout: 8)
            }
            if sleepCheckingCancel(2.0) == false {
                return CommandResult(status: 130, output: "cancelled")
            }
            return SidecarBridge.setConnected(true, device: targetDevice, timeout: 8)
        case .systemUI:
            didUseSystemUI = true
            guard AXIsProcessTrusted() else {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                return CommandResult(status: 77, output: "需要在系统设置中允许随航管家使用辅助功能")
            }
            guard let script = Bundle.main.path(forResource: "connect-sidecar", ofType: "applescript") else {
                return CommandResult(status: 2, output: "missing AppleScript resource")
            }
            return runCommand("/usr/bin/osascript", [script, targetDevice], timeout: 20)
        }
    }

    private func refreshConnectionStatus() {
        guard configurationWindow?.isVisible == true, !isPipelineRunning else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let connected = !targetDevice.isEmpty && self.confirmConnected()
            let method = connected ? (self.loadLastConnectionMethod() ?? "系统或 Bar Control 建立") : (self.loadLastConnectionMethod() ?? "—")
            self.setConnectionStatus(connected ? "已连接" : "未连接", method: method)
        }
    }

    private func setConnectionStatus(_ status: String, method: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectionStatusLabel?.stringValue = "连接状态：\(status)"
            self.connectionMethodLabel?.stringValue = "软件调用路径：\(method)"
            self.connectionRouteLabel?.stringValue = "当前会话链路：无法判定（USB / 无线）"
            self.statusItem?.button?.title = status == "已连接" ? "✓ 随航" : (status == "连接中" || status == "断开中" ? "◌ 随航" : "随航管家")
            self.statusItem?.button?.toolTip = "\(status) · \(method)"
        }
    }

    private func loadLastConnectionMethod() -> String? {
        guard let data = try? Data(contentsOf: lastConnectionURL),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return value["method"]
    }

    private func saveLastConnectionMethod(_ method: String) {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(["method": method, "device": targetDevice])
            try data.write(to: lastConnectionURL, options: .atomic)
        } catch { log("connection method write failed: \(error)") }
    }

    private func waitForConnection(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancelled { return false }
            if confirmConnected() { return true }
            if sleepCheckingCancel(0.75) == false { return false }
        }
        return confirmConnected()
    }

    private func confirmConnected() -> Bool {
        guard SidecarBridge.isConnected(targetDevice) else { return false }
        let displays = runCommand("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"])
        return displays.status == 0 && displays.output.contains("Sidecar Display")
    }

    private func confirmDisconnected() -> Bool {
        guard !SidecarBridge.isConnected(targetDevice) else { return false }
        let displays = runCommand("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"])
        return displays.status == 0 && !displays.output.contains("Sidecar Display")
    }

    private func waitForDisconnection(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancelled { return false }
            if confirmDisconnected() { return true }
            if sleepCheckingCancel(0.5) == false { return false }
        }
        return confirmDisconnected()
    }

    private func sleepCheckingCancel(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cancelled { return false }
            Thread.sleep(forTimeInterval: min(0.1, deadline.timeIntervalSinceNow))
        }
        return !cancelled
    }

    private func diagnoseFailure() -> String {
        let logs = runCommand("/usr/bin/log", [
            "show", "--last", "3m", "--style", "compact",
            "--predicate", "process == \"SidecarRelay\" OR process == \"SidecarDisplayAgent\""
        ]).output
        if logs.contains("SidecarErrorDomain") && logs.contains("-201") {
            return "iPad 无线服务超时 (-201)"
        }
        if !SidecarBridge.isAvailable {
            return "系统随航接口不可用"
        }
        if !AXIsProcessTrusted() {
            return "备用系统连接未获辅助功能授权；面板可打开授权设置"
        }
        return "三种方案均未连接"
    }

    private func finish(success: Bool, message: String, detail: String) {
        log("finish success=\(success) message=\(message)")
        isPipelineRunning = false
        updateUI(message, detail: detail, spinning: false, success: success)
        if nativeHostMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.writeTouchBarState(state: "idle", message: "随航 ⇄ 通用控制", detail: "")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.restoreFocusAndQuit()
            }
        } else {
            // 结果只短暂展示；随后回到空闲，避免 Bar Control 永久停在
            // “连接成功 + 多少秒”的绿色页。真实连接状态由 Bar Control 自行探测。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, !self.isPipelineRunning else { return }
                self.writeTouchBarState(state: "idle", message: "随航 ⇄ 通用控制", detail: "")
            }
        }
    }

    private func keepWindowAfterResult() {
        guard !nativeHostMode else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.configurationWindow?.isVisible == true else { return }
            self.refreshConnectionStatus()
            self.refreshPermissionStatus()
        }
    }

    private func restoreFocusAndQuit() {
        writeTouchBarState(state: "idle", message: "随航 ⇄ 通用控制", detail: "")
        if (didUseSystemUI || !nativeHostMode), let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        statusItem.map { NSStatusBar.system.removeStatusItem($0) }
        NSApp.terminate(nil)
    }

    private func updateUI(_ message: String, detail: String, spinning: Bool, success: Bool? = nil) {
        let state = spinning ? "connecting" : (success == true ? "success" : (success == false ? "failure" : "idle"))
        writeTouchBarState(state: state, message: message, detail: detail)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controller.update(message: message, detail: detail, spinning: spinning, success: success)
            if spinning {
                self.statusItem?.button?.title = "◌ \(detail)"
            } else {
                self.statusItem?.button?.title = success == true ? "✓ 随航" : "✕ 随航"
            }
        }
    }

    private func elapsedText() -> String {
        String(format: "%.1f 秒", Date().timeIntervalSince(launchTime))
    }

    private var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SidecarPilot", isDirectory: true)
    }

    private var statisticsURL: URL { supportDirectory.appendingPathComponent("statistics.json") }
    private var logURL: URL { supportDirectory.appendingPathComponent("SidecarPilot.log") }
    private var touchBarStateURL: URL { supportDirectory.appendingPathComponent("touchbar-state.tsv") }
    private var lastConnectionURL: URL { supportDirectory.appendingPathComponent("last-connection.json") }

    private func writeTouchBarState(state: String, message: String, detail: String) {
        let cleanMessage = message.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        let cleanDetail = detail.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        let content = "\(state)\t\(cleanMessage)\t\(cleanDetail)\n"
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: touchBarStateURL, options: .atomic)
        } catch {
            log("touch bar state write failed: \(error)")
        }
    }

    private func loadStatistics() -> Statistics {
        guard let data = try? Data(contentsOf: statisticsURL),
              let decoded = try? JSONDecoder().decode(Statistics.self, from: data) else {
            return Statistics()
        }
        return decoded
    }

    private func record(method: ConnectionMethod, success: Bool, duration: TimeInterval) {
        var statistics = loadStatistics()
        var stat = statistics.methods[method.rawValue] ?? MethodStat()
        stat.attempts += 1
        if success { stat.successes += 1 }
        stat.totalSeconds += duration
        stat.recent.append(success)
        if stat.recent.count > 20 { stat.recent.removeFirst(stat.recent.count - 20) }
        statistics.methods[method.rawValue] = stat
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(statistics)
            try data.write(to: statisticsURL, options: .atomic)
        } catch {
            log("statistics write failed: \(error)")
        }
    }

    private func log(_ line: String) {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let entry = "\(formatter.string(from: Date())) \(line)\n"
            let data = Data(entry.utf8)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Logging must never block Sidecar connection.
        }
    }

    private func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let termination = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in termination.signal() }

            let readGroup = DispatchGroup()
            let readLock = NSLock()
            var captured = Data()
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                readLock.lock()
                captured = data
                readLock.unlock()
                readGroup.leave()
            }

            let timedOut = termination.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if termination.wait(timeout: .now() + 2) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = termination.wait(timeout: .now() + 2)
                }
            }
            readGroup.wait()
            readLock.lock()
            let data = captured
            readLock.unlock()
            if timedOut {
                return CommandResult(status: 124, output: "command timed out after \(Int(timeout)) seconds\n" + String(decoding: data, as: UTF8.self))
            }
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }
    }

}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
