import AppKit
import ApplicationServices
import Darwin
import Foundation

private let betterDisplay = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
private let targetDevice: String = {
    let environment = ProcessInfo.processInfo.environment["SIDECAR_PILOT_DEVICE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let environment, !environment.isEmpty { return environment }
    return UserDefaults.standard.string(forKey: "TargetDevice")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()
private let nativeHostMode = ProcessInfo.processInfo.environment["SIDECAR_PILOT_NATIVE_HOST"] == "1"

private struct CommandResult {
    let status: Int32
    let output: String
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let controller = PilotViewController()
    private var statusItem: NSStatusItem?
    private var previousApp: NSRunningApplication?
    private var didUseSystemUI = false
    private let stateLock = NSLock()
    private var _cancelled = false
    private let launchTime = Date()

    private var cancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _cancelled
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.SidecarPilot")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if duplicate && !nativeHostMode {
            NSApp.terminate(nil)
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.accessory)
        controller.onCancel = { [weak self] in self?.requestCancel() }
        if !nativeHostMode {
            let statusWindow = NSWindow(
                contentRect: NSRect(x: -9000, y: -9000, width: 460, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            statusWindow.contentViewController = controller
            statusWindow.isReleasedWhenClosed = false
            statusWindow.touchBar = controller.makeTouchBar()
            statusWindow.makeKeyAndOrderFront(nil)
            statusWindow.makeFirstResponder(controller.view)
            window = statusWindow
            NSApp.activate(ignoringOtherApps: true)
        }

        if !nativeHostMode {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.title = "◌ 随航"
            statusItem?.button?.toolTip = "随航管家正在连接"
        }

        updateUI("正在检查连接…", detail: "准备", spinning: true)
        log("launch")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runPipeline()
        }
    }

    private func requestCancel() {
        stateLock.lock()
        _cancelled = true
        stateLock.unlock()
        updateUI("已取消连接", detail: "取消", spinning: false, success: false)
        log("cancelled by user")
    }

    private func runPipeline() {
        guard !targetDevice.isEmpty else {
            finish(success: false, message: "尚未配置 iPad", detail: "请先设置设备名称")
            return
        }
        if confirmConnected() {
            disconnectSidecar()
            return
        }

        let methods = orderedMethods()
        for (index, method) in methods.enumerated() {
            if cancelled {
                finish(success: false, message: "已取消连接", detail: "取消")
                return
            }

            let stage = "\(index + 1)/\(methods.count)"
            updateUI("\(method.label)中…", detail: stage, spinning: true)
            log("attempt \(stage) \(method.rawValue)")
            let started = Date()
            let commandResult = perform(method)
            reclaimTouchBar()
            log("command \(method.rawValue) returned status=\(commandResult.status)")
            if commandResult.status != 0 {
                log("command \(method.rawValue) failed: \(commandResult.output)")
            }

            let success = waitForConnection(timeout: method.timeout)
            let duration = Date().timeIntervalSince(started)
            record(method: method, success: success, duration: duration)
            if success {
                finish(success: true, message: "随航连接成功", detail: elapsedText())
                return
            }
            log("timeout \(method.rawValue) after \(String(format: "%.1f", duration))s")
        }

        let reason = diagnoseFailure()
        finish(success: false, message: reason, detail: "全部失败")
    }

    private func disconnectSidecar() {
        updateUI("断开随航中…", detail: "切换", spinning: true)
        log("attempt disconnect")
        let commandResult = runBetterDisplay(["set", "-sidecarConnected=off", "-specifier=\(targetDevice)"])
        log("command disconnect returned status=\(commandResult.status)")
        if commandResult.status != 0 {
            log("command disconnect failed: \(commandResult.output)")
            finish(success: false, message: "随航断开失败", detail: "请重试")
            return
        }

        if waitForDisconnection(timeout: 12) {
            log("Sidecar disconnected; preserving Universal Control process")
            finish(success: true, message: "随航已断开", detail: "通用控制自动恢复")
        } else {
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
            return runBetterDisplay(["set", "-sidecarConnected=on", "-specifier=\(targetDevice)"])
        case .reconnect:
            _ = runBetterDisplay(["set", "-sidecarConnected=off", "-specifier=\(targetDevice)"])
            if sleepCheckingCancel(2.0) == false {
                return CommandResult(status: 130, output: "cancelled")
            }
            return runBetterDisplay(["set", "-sidecarConnected=on", "-specifier=\(targetDevice)"])
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
        let quick = runBetterDisplay(["get", "-sidecarConnected", "-specifier=\(targetDevice)"])
        guard quick.status == 0, quick.output.trimmingCharacters(in: .whitespacesAndNewlines) == "on" else {
            return false
        }
        let displays = runCommand("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"])
        return displays.status == 0 && displays.output.contains("Sidecar Display")
    }

    private func confirmDisconnected() -> Bool {
        let quick = runBetterDisplay(["get", "-sidecarConnected", "-specifier=\(targetDevice)"])
        guard quick.status == 0, quick.output.trimmingCharacters(in: .whitespacesAndNewlines) == "off" else {
            return false
        }
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
        if !FileManager.default.fileExists(atPath: betterDisplay) {
            return "未找到 BetterDisplay"
        }
        if !AXIsProcessTrusted() {
            return "请允许随航管家使用辅助功能"
        }
        return "三种方案均未连接"
    }

    private func finish(success: Bool, message: String, detail: String) {
        log("finish success=\(success) message=\(message)")
        updateUI(message, detail: detail, spinning: false, success: success)
        DispatchQueue.main.asyncAfter(deadline: .now() + (nativeHostMode ? 1.2 : 4.0)) { [weak self] in
            self?.restoreFocusAndQuit()
        }
    }

    private func reclaimTouchBar() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !nativeHostMode, let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.controller.view)
            NSApp.activate(ignoringOtherApps: true)
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

    private func runBetterDisplay(_ arguments: [String]) -> CommandResult {
        guard let command = arguments.first, command == "get" || command == "set" else {
            return CommandResult(status: 64, output: "unsupported BetterDisplay command")
        }
        return runCommand(betterDisplay, arguments, timeout: 8)
    }

}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
