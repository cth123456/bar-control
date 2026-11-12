import Foundation

final class UniversalControlWatchdog: @unchecked Sendable {
    // Device-loss logs do not prove a stalled link; restarting UC can break a healthy one.
    static let automaticRecoveryEnabled = false
    enum Event: Equatable {
        case remotePointerFocus
        case deviceLost
        case connectedCircle
    }

    /// 通用控制/随航活动期间，触控栏由系统合成（iPad 输入圈等）。
    /// 这段时间 BarControl 不应截图探测、不自愈、不抢呈现。
    static func isSystemOwnsTouchBar(sidecarState: String) -> Bool {
        sidecarState == "connecting"
            || sidecarState == "success"
            || sidecarState == "failure"
    }

    private let queue = DispatchQueue(label: "local.codex.barcontrol.universal-control-watchdog")
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var lastRemotePointerFocus: Date?
    private var pendingRecovery: DispatchWorkItem?
    private var lastRecovery = Date.distantPast
    private var stopped = true

    func start() {
        guard Self.automaticRecoveryEnabled else { return }
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            self.stopped = false
            self.launchLogStream()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pendingRecovery?.cancel()
            self.pendingRecovery = nil
            self.pipe?.fileHandleForReading.readabilityHandler = nil
            if self.process?.isRunning == true { self.process?.terminate() }
            self.process = nil
            self.pipe = nil
            self.buffer.removeAll(keepingCapacity: false)
        }
    }

    static func event(in line: String) -> Event? {
        if line.contains("FocusMove pointer=true") { return .remotePointerFocus }
        if line.contains("Device Lost") || line.contains("Device Unavailable") || line.contains("transitioned to unavailable") {
            return .deviceLost
        }
        if line.contains("Selected circle: ["),
           let start = line.range(of: "Selected circle: [")?.upperBound,
           let end = line[start...].firstIndex(of: "]"),
           line[start..<end].contains(",") {
            return .connectedCircle
        }
        return nil
    }

    private func launchLogStream() {
        guard !stopped, process == nil else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "compact", "--info", "--debug",
            "--predicate",
            "process == \"UniversalControl\" AND (eventMessage CONTAINS[c] \"FocusMove\" OR eventMessage CONTAINS[c] \"Device Lost\" OR eventMessage CONTAINS[c] \"Device Unavailable\" OR eventMessage CONTAINS[c] \"transitioned to unavailable\" OR eventMessage CONTAINS[c] \"Selected circle\")"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let owner = self else { return }
            owner.queue.async { owner.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let owner = self else { return }
            owner.queue.async { owner.handleLogStreamTermination() }
        }
        do {
            try process.run()
            self.process = process
            self.pipe = pipe
            AppLog.write("universal control watchdog started")
        } catch {
            AppLog.write("universal control watchdog start failed: \(error.localizedDescription)")
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.launchLogStream() }
        }
    }


    private func handleLogStreamTermination() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
        guard !stopped else { return }
        AppLog.write("universal control watchdog log stream exited; restarting")
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launchLogStream() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let event = Self.event(in: line) else { continue }
            handle(event)
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .remotePointerFocus:
            lastRemotePointerFocus = Date()
        case .connectedCircle:
            pendingRecovery?.cancel()
            pendingRecovery = nil
        case .deviceLost:
            let now = Date()
            guard let lastRemotePointerFocus,
                  now.timeIntervalSince(lastRemotePointerFocus) < 300,
                  now.timeIntervalSince(lastRecovery) >= 60,
                  pendingRecovery == nil else { return }
            AppLog.write("universal control watchdog detected active iPad device loss")
            let work = DispatchWorkItem { [weak self] in self?.recoverIfNeeded() }
            pendingRecovery = work
            queue.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private func recoverIfNeeded() {
        pendingRecovery = nil
        guard Self.automaticRecoveryEnabled else { return }
        guard !stopped else { return }
        guard !sidecarIsConnected() else {
            lastRemotePointerFocus = nil
            AppLog.write("universal control watchdog skipped: Sidecar is connected")
            return
        }

        lastRecovery = Date()
        let previousPID = command("/usr/bin/pgrep", ["-x", "UniversalControl"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard commandStatus("/usr/bin/killall", ["-KILL", "UniversalControl"]) == 0 else {
            AppLog.write("universal control watchdog recovery failed: killall")
            return
        }

        lastRemotePointerFocus = nil
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let currentPID = command("/usr/bin/pgrep", ["-x", "UniversalControl"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentPID.isEmpty, currentPID != previousPID {
                AppLog.write("universal control watchdog recovered: \(previousPID) -> \(currentPID)")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        AppLog.write("universal control watchdog recovery timed out")
    }

    private func sidecarIsConnected() -> Bool {
        command("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"])
            .contains("Sidecar Display")
    }

    private func command(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func commandStatus(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
