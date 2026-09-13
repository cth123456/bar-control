import Foundation
import PowerTelemetrySupport

/// Controls the charger disconnect ("优先放电") through the optional
/// privileged helper `barcontrol-power-helper`, installed once with
/// install-power-helper.command. Every write is verified by reading the
/// CHIE key back, and any disconnect this app owns is restored on quit,
/// on policy change, and when the Mac drops below 20%.
@MainActor
final class AdapterDischargeController {
    static let shared = AdapterDischargeController()
    nonisolated static let helperPath = "/Library/PrivilegedHelperTools/barcontrol-power-helper"
    private static let ownedCutKey = "adapterCutOwnedByBarControl"

    private(set) var helperInstalled = false
    /// True when the charger is currently disconnected (reads CHIE).
    private(set) var isCut = false
    private(set) var lastError: String?
    private var isBusy = false

    private init() {
        refresh()
        if UserDefaults.standard.bool(forKey: Self.ownedCutKey),
           PowerFlowPolicyStore.current != .discharging {
            // A previous run left the charger disconnected but the standing
            // policy no longer asks for it (or the app quit uncleanly while
            // charging was selected); restore first.
            setCut(false, reason: "startup-restore")
        }
    }

    var ownedCut: Bool {
        UserDefaults.standard.bool(forKey: Self.ownedCutKey)
    }

    func refresh() {
        helperInstalled = FileManager.default.isExecutableFile(atPath: Self.helperPath)
        var raw: UInt8 = 0
        if bcpt_adapter_control_read(&raw) == 1 {
            isCut = raw != 0
        }
    }

    /// Balances the charger against the selected policy. Only a fresh user
    /// selection starts a disconnect; recovering to any other policy always
    /// reconnects.
    func handlePolicySelection(_ policy: PowerFlowPolicy) {
        refresh()
        if policy == .discharging {
            guard helperInstalled else {
                lastError = "未安装放电组件"
                return
            }
            setCut(true, reason: "policy-discharge")
        } else if ownedCut {
            setCut(false, reason: "policy-\(policy)")
        }
    }

    static func shouldKeepCut(
        policy: PowerFlowPolicy,
        macBatteryPercent: Int?
    ) -> Bool {
        guard policy == .discharging else { return false }
        if let macBatteryPercent, macBatteryPercent < 20 { return false }
        return true
    }

    /// Runs on every metrics refresh: only an owned disconnect is managed,
    /// and a low Mac battery always reconnects so the system's own <20%
    /// charging rule can take over.
    func maintainSafety(policy: PowerFlowPolicy, metrics: SystemMetrics) {
        refresh()
        guard ownedCut else { return }
        if !Self.shouldKeepCut(policy: policy, macBatteryPercent: metrics.batteryPercent) {
            setCut(false, reason: "safety-restore")
        }
    }

    /// Applies the standing policy once per app run. Quitting always
    /// reconnects the charger, so a launch with 优先放电 selected re-cuts it
    /// (never below 20% Mac battery).
    private var appliedStandingPolicy = false
    func applyStandingPolicyIfNeeded(policy: PowerFlowPolicy, metrics: SystemMetrics) {
        guard !appliedStandingPolicy else { return }
        appliedStandingPolicy = true
        guard policy == .discharging, helperInstalled else { return }
        guard let percent = metrics.batteryPercent, percent >= 20 else { return }
        refresh()
        guard !isCut else { return }
        setCut(true, reason: "standing-policy")
    }

    struct HelperResult: Sendable {
        let ok: Bool
        let message: String?
    }

    func setCut(_ cut: Bool, reason: String) {
        guard helperInstalled else {
            lastError = "未安装放电组件"
            AppLog.write("adapter-cut \(cut ? "on" : "off") skipped reason=\(reason) error=helper-missing")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            let result = await Self.runHelper(["discharge", cut ? "on" : "off"])
            guard let self else { return }
            self.isBusy = false
            var raw: UInt8 = 0
            let readBack = bcpt_adapter_control_read(&raw) == 1
            if result.ok, readBack, (raw != 0) == cut {
                self.lastError = nil
                self.isCut = raw != 0
                UserDefaults.standard.set(cut, forKey: Self.ownedCutKey)
                AppLog.write(
                    "adapter-cut \(cut ? "on" : "off") reason=\(reason) verified chie=\(raw)"
                )
            } else {
                self.lastError = Self.humanReadableFailure(result.message)
                if readBack {
                    self.isCut = raw != 0
                    UserDefaults.standard.set(raw != 0, forKey: Self.ownedCutKey)
                }
                AppLog.write(
                    "adapter-cut \(cut ? "on" : "off") failed reason=\(reason) helper=\(result.message ?? "nil") chie=\(readBack ? String(raw) : "unreadable")"
                )
            }
        }
    }

    /// The helper prints one JSON line; surface its "note" instead of the
    /// raw payload in the panel.
    nonisolated static func humanReadableFailure(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "放电辅助组件执行失败" }
        if message.contains("password is required") {
            return "放电组件未正确安装（请重装）"
        }
        if let data = message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let note = object["note"] as? String,
           !note.isEmpty {
            return note
        }
        return message
    }

    // MARK: - One-time privileged install

    private static let sudoersTemplate = """
    # Bar Control 放电辅助组件：只允许下面这些固定命令免密执行。
    Cmnd_Alias BARCONTROL_POWER_WRITE = /Library/PrivilegedHelperTools/barcontrol-power-helper discharge on, /Library/PrivilegedHelperTools/barcontrol-power-helper discharge off
    Cmnd_Alias BARCONTROL_POWER_READ = /Library/PrivilegedHelperTools/barcontrol-power-helper status, /Library/PrivilegedHelperTools/barcontrol-power-helper probe
    ALL ALL = NOPASSWD: BARCONTROL_POWER_WRITE, BARCONTROL_POWER_READ
    """

    /// Source binary: the app bundle's own copy, or the sibling build product
    /// when running from `.build/release` during development.
    nonisolated static func bundledHelperPath() -> String? {
        if let executable = Bundle.main.executableURL {
            let inBundle = executable.deletingLastPathComponent()
                .appendingPathComponent("barcontrol-power-helper").path
            if FileManager.default.isExecutableFile(atPath: inBundle) {
                return inBundle
            }
        }
        let argv0 = CommandLine.arguments.first ?? ""
        let sibling = URL(fileURLWithPath: argv0)
            .deletingLastPathComponent()
            .appendingPathComponent("BarControlPowerHelper").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        return nil
    }

    /// Installs the helper + sudoers allowlist through one system
    /// authorization prompt (`osascript ... with administrator privileges`).
    /// Returns true on success; a user-cancelled prompt reports false.
    func installHelper() async -> Bool {
        if helperInstalled { return true }
        guard let source = Self.bundledHelperPath() else {
            lastError = "找不到内置放电组件"
            AppLog.write("install-helper failed: bundled binary missing")
            return false
        }
        let tempDir = FileManager.default.temporaryDirectory
        let sudoersURL = tempDir.appendingPathComponent("barcontrol-sudoers-\(getpid())")
        let scriptURL = tempDir.appendingPathComponent("barcontrol-install-\(getpid()).sh")
        do {
            try Self.sudoersTemplate.write(to: sudoersURL, atomically: true, encoding: .utf8)
            let quoted = { (path: String) -> String in
                "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
            }
            let script = """
            #!/bin/zsh
            set -euo pipefail
            /usr/sbin/visudo -c -f \(quoted(sudoersURL.path))
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /usr/bin/ditto \(quoted(source)) \(quoted(Self.helperPath))
            /usr/sbin/chown root:wheel \(quoted(Self.helperPath))
            /bin/chmod 755 \(quoted(Self.helperPath))
            /usr/bin/install -m 440 -o root -g wheel \(quoted(sudoersURL.path)) /etc/sudoers.d/barcontrol-power-helper
            /bin/rm -f \(quoted(sudoersURL.path))
            echo INSTALL_OK
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let result = await Self.runOsascript(
                scriptPath: scriptURL.path,
                prompt: "Bar Control 需要一次性安装放电辅助组件（用于「优先放电」断开充电器）"
            )
            try? FileManager.default.removeItem(at: sudoersURL)
            try? FileManager.default.removeItem(at: scriptURL)
            if result.ok {
                refresh()
                AppLog.write("install-helper success installed=\(helperInstalled)")
                if helperInstalled {
                    let probe = await Self.runHelper(["probe"])
                    if !probe.ok {
                        lastError = "组件已安装，但系统拒绝写入（\(Self.humanReadableFailure(probe.message))）"
                        AppLog.write("install-helper probe failed: \(probe.message ?? "nil")")
                    } else {
                        lastError = nil
                    }
                }
            } else {
                lastError = result.message
                AppLog.write("install-helper failed: \(result.message ?? "unknown")")
            }
            return result.ok
        } catch {
            lastError = "安装准备失败：\(error.localizedDescription)"
            AppLog.write("install-helper error: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private static func runOsascript(
        scriptPath: String,
        prompt: String
    ) async -> HelperResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Path and prompt only contain quotes/apostrophes we manage here.
            let escapedScript = scriptPath.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            process.arguments = [
                "-e",
                "do shell script \"/bin/zsh '\(escapedScript)'\" with administrator privileges with prompt \"\(escapedPrompt)\""
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return HelperResult(ok: false, message: error.localizedDescription)
            }
            let deadline = Date().addingTimeInterval(180)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning {
                process.terminate()
                return HelperResult(ok: false, message: "授权超时")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = process.terminationStatus == 0 && (text?.contains("INSTALL_OK") ?? false)
            return HelperResult(ok: ok, message: text?.isEmpty == false ? text : nil)
        }.value
    }

    /// Blocking best-effort restore for applicationWillTerminate. Uses
    /// `sudo -n` so it can never prompt or hang waiting for a password.
    func restoreSynchronously() {
        guard ownedCut,
              FileManager.default.isExecutableFile(atPath: Self.helperPath) else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", Self.helperPath, "discharge", "off"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            AppLog.write("adapter-cut restore on quit failed: \(error.localizedDescription)")
            return
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            UserDefaults.standard.set(false, forKey: Self.ownedCutKey)
        }
        AppLog.write("adapter-cut restore on quit status=\(process.terminationStatus)")
    }

    nonisolated static func runHelper(_ arguments: [String]) async -> HelperResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", helperPath] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return HelperResult(ok: false, message: error.localizedDescription)
            }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (text?.isEmpty == false) ? text : nil
            return HelperResult(ok: process.terminationStatus == 0, message: message)
        }.value
    }
}
