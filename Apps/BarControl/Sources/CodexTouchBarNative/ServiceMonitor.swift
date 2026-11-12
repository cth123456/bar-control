import AppKit

/// 后台服务监控：Bar Control 菜单里的“服务”分组。
///
/// 目标是让常驻服务状态一眼可见，而不是靠 `launchctl print` 排查：
/// - 折叠标题显示“N/M 运行中”，N 用绿点表示；
/// - 展开后每个服务一行：名称、用途、当前状态（运行中 / 已停止 / 按需）；
/// - 行内附带常用的打开 / 启动动作，全部走用户当前会话的 launchctl / open。
@MainActor
enum ServiceMonitor {

    // MARK: - 服务定义

    /// 单个受监控服务。`kind` 决定健康检查方式，避免误报。
    enum Kind: Equatable, Sendable {
        /// launchd 用户域常驻或定时任务：按 Label 判断是否加载。
        case launchAgent(label: String)
        /// App 是否在运行（按进程名精确匹配）。
        case app(processName: String)
        /// 本机 HTTP 端口是否返回 200。
        case http(port: Int, path: String)

        var diagnosticTitle: String {
            switch self {
            case .launchAgent: return "LaunchAgent"
            case .app: return "进程"
            case .http: return "HTTP"
            }
        }
    }

    struct Service: Equatable {
        let name: String
        let role: String
        let kind: Kind
        /// 展开菜单里显示的动作；`nil` 表示“随系统自启，无需操作”。
        let actionTitle: String?
        /// 通用动作模板。不再依赖 TouchBarController 的硬编码 Selector。
        let action: ServiceAction?
        /// 独立的关联 App 路径；与“打开功能文件夹”可以同时出现。
        let associatedAppPath: String?
        /// true=定时任务（每天/每 N 分钟触发一次）；false=常驻服务。
        let isScheduled: Bool
        /// 用于“跳转到整个功能文件夹”的目录；为空时退回 Logs 根目录。
        let logDirectory: String?

        var diagnosticSubject: String {
            switch kind {
            case .launchAgent(let label): return label
            case .app(let processName): return processName
            case .http(let port, _): return "127.0.0.1:\(port)"
            }
        }

        var scheduleLabel: String {
            isScheduled ? "定时" : "常驻"
        }

        var appPath: String? {
            associatedAppPath ?? {
                if case .app(let path) = action { return path }
                return nil
            }()
        }

        var folderPath: String? {
            if case .reveal(let path) = action { return path }
            return nil
        }

        /// 是否是这台机器上真实存在的服务。注册表只是模板，
        /// 新电脑上未安装的条目不应该出现在服务页或菜单里。
        func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
            switch kind {
            case .launchAgent(let label):
                let agents = [
                    home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path,
                    "/Library/LaunchAgents/\(label).plist",
                    "/Library/LaunchDaemons/\(label).plist",
                ]
                if agents.contains(where: exists) { return true }
                return logDirectory.map { directoryExists($0, home: home, exists: exists) } ?? false
            case .app(let processName):
                if let appPath, exists(appPath) { return true }
                return exists("/Applications/\(processName).app")
            case .http:
                if let appPath, exists(appPath) { return true }
                return logDirectory.map { directoryExists($0, home: home, exists: exists) } ?? false
            }
        }

        private func directoryExists(_ path: String, home: URL,
                                     exists: (String) -> Bool) -> Bool {
            let resolved = path.hasPrefix("/") ? path : home.appendingPathComponent(path).path
            return exists(resolved)
        }
    }

    /// A declarative target a service can open. New services only need to
    /// provide these values; no TouchBarController code changes required.
    enum ServiceAction: Equatable {
        case app(path: String)
        case reveal(path: String)
    }

    // MARK: - Registry

    /// Template-based registry. Third-party or future services can extend
    /// this by writing `~/Library/Application Support/BarControl/services.json`
    /// with the same keys; built-ins stay ordered first.
    static func registry() -> [Service] {
        [
            Service(name: "Global Agent Memory", role: "Codex / Obsidian 持久记忆服务",
                    kind: .launchAgent(label: "com.global-memory"),
                    actionTitle: nil, action: nil,
                    associatedAppPath: nil,
                    isScheduled: false,
                    logDirectory: "Library/Logs/global-memory"),
            Service(name: "Magpie 模型路由", role: "本机 AI 路由入口（127.0.0.1:3425）",
                    kind: .http(port: 3425, path: "/v1/models"),
                    actionTitle: "打开功能文件夹", action: .reveal(path: ".config/magpie"),
                    associatedAppPath: "/Applications/magpie.app",
                    isScheduled: false, logDirectory: nil),
            Service(name: "quarkd 提链服务", role: "网盘网页面板后端（127.0.0.1:18790）",
                    kind: .http(port: 18790, path: "/health"),
                    actionTitle: "打开功能文件夹", action: .reveal(path: "Library/Logs/QuarkBridge"),
                    associatedAppPath: nil,
                    isScheduled: false, logDirectory: "Library/Logs/QuarkBridge"),
            Service(name: "Motrix 下载引擎", role: "网盘下载执行端（aria2 RPC 18120）",
                    kind: .app(processName: "Motrix"),
                    actionTitle: "打开 App", action: .app(path: "/Applications/Motrix.app"),
                    associatedAppPath: nil,
                    isScheduled: false, logDirectory: "Library/Logs/Motrix"),
            Service(name: "每日记忆维护", role: "每天 03:15 导出记忆并同步 Vault",
                    kind: .launchAgent(label: "com.local.daily-memory-maintenance"),
                    actionTitle: "打开功能文件夹", action: .reveal(path: "Library/Logs/DailyMemoryMaintenance"),
                    associatedAppPath: nil,
                    isScheduled: true, logDirectory: "Library/Logs/DailyMemoryMaintenance"),
            Service(name: "Ollama 按需休眠", role: "每 5 分钟在空闲时停掉 Ollama",
                    kind: .launchAgent(label: "com.local.ollama-idle-sleeper"),
                    actionTitle: nil, action: nil,
                    associatedAppPath: nil,
                    isScheduled: true,
                    logDirectory: "Library/Logs/ollama-idle-sleeper"),
            Service(name: "Telegram 签到", role: "每天 03:00 自动签到",
                    kind: .launchAgent(label: "app.telegram-checkin-manager.daily"),
                    actionTitle: "打开功能文件夹",
                    action: .reveal(path: "Library/Application Support/TelegramCheckinManager"),
                    associatedAppPath: nil,
                    isScheduled: true,
                    logDirectory: "Library/Application Support/TelegramCheckinManager"),
        ]
    }

    /// Discover extra services from the optional user registry file. Unknown
    /// entries are skipped, so partial JSON cannot break the built-ins.
    static func userServices() -> [Service] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BarControl/services.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([ServiceTemplate].self, from: data)
        else { return [] }
        return raw.compactMap(\.service)
    }

    struct ServiceTemplate: Codable {
        let name: String
        let role: String
        let kind: String
        let label: String?
        let processName: String?
        let port: Int?
        let path: String?
        let isScheduled: Bool?
        let appPath: String?
        let revealPath: String?
        let logDirectory: String?

        var service: Service? {
            let decodedKind: Kind?
            switch kind {
            case "launchAgent": decodedKind = label.map { .launchAgent(label: $0) }
            case "app": decodedKind = processName.map { .app(processName: $0) }
            case "http": decodedKind = (port != nil && path != nil) ? .http(port: port!, path: path!) : nil
            default: decodedKind = nil
            }
            guard let resolvedKind = decodedKind else { return nil }
            var action: ServiceAction?
            if let revealPath { action = .reveal(path: revealPath) }
            if action == nil, let appPath { action = .app(path: appPath) }
            return Service(
                name: name,
                role: role,
                kind: resolvedKind,
                actionTitle: action == nil ? nil : (revealPath == nil ? "打开 App" : "打开功能文件夹"),
                action: action,
                associatedAppPath: revealPath == nil ? nil : appPath,
                isScheduled: isScheduled ?? false,
                logDirectory: logDirectory
            )
        }
    }

    // MARK: - 清单

    /// 顺序即菜单顺序；新增服务时同步更新 `runningCount` 的总数。
    static func services() -> [Service] {
        (registry() + userServices()).filter { $0.isInstalled() }
    }

    // MARK: - 状态探测

    enum State: Sendable { case running, stopped, onDemand, unknown }

    struct Snapshot: Equatable, Sendable {
        let runningCount: Int
        let totalCount: Int
        let states: [State]
    }

    struct Detail: Equatable, Sendable {
        let state: State
        /// launchd PID, process PID, or HTTP status code.
        let identifier: String?
        let latestLogPath: String?
        let latestLogModified: Date?
    }

    struct DetailedSnapshot: Equatable, Sendable {
        let snapshot: Snapshot
        let details: [Detail]
    }

    static private(set) var cachedSnapshot: Snapshot = {
        let count = services().count
        return Snapshot(runningCount: 0, totalCount: count,
                        states: Array(repeating: .unknown, count: count))
    }()
    private static var refreshing = false
    private static var lastRefresh = Date.distantPast

    /// 菜单及状态计时器只读缓存；网络和进程探测在后台，最多每 15 秒一轮。
    static func refreshIfNeeded(onUpdate: @escaping @MainActor (Snapshot) -> Void) {
        guard !refreshing, Date().timeIntervalSince(lastRefresh) >= 15 else { return }
        refreshing = true
        let kinds = services().map(\.kind)
        Task {
            let next = await collect(kinds)
            cachedSnapshot = next
            lastRefresh = Date()
            refreshing = false
            onUpdate(next)
        }
    }

    /// Richer snapshot for the services window. Reuses the same probes but
    /// also captures PIDs / HTTP codes and the latest file per service folder.
    static func refreshDetailsIfNeeded(onUpdate: @escaping @MainActor (DetailedSnapshot) -> Void) {
        guard !refreshing, Date().timeIntervalSince(lastRefresh) >= 15 else { return }
        refreshing = true
        let items = services()
        Task {
            let next = await collectDetailed(items)
            cachedSnapshot = next.snapshot
            lastRefresh = Date()
            refreshing = false
            onUpdate(next)
        }
    }

    nonisolated static func collectDetailed(_ items: [Service]) async -> DetailedSnapshot {
        await Task.detached(priority: .utility) {
            let agents = run(["/bin/launchctl", "list"], timeout: 2)
            var states: [State] = []
            var details: [Detail] = []
            for service in items {
                let state: State
                var identifier: String?
                switch service.kind {
                case .launchAgent(let label):
                    if let line = agents?.split(separator: "\n").first(where: { $0.hasSuffix("\t" + label) }) {
                        let columns = line.split(separator: "\t")
                        let pid = columns.first.flatMap { Int($0) }
                        state = pid == nil ? .onDemand : .running
                        identifier = pid.map(String.init) ?? "on-demand"
                    } else {
                        state = agents == nil ? .unknown : .stopped
                    }
                case .app(let processName):
                    if let output = run(["/usr/bin/pgrep", "-x", processName], timeout: 2) {
                        let pid = output.split(separator: "\n").first.flatMap { Int($0) }
                        state = pid == nil ? .stopped : .running
                        identifier = pid.map(String.init)
                    } else {
                        state = .unknown
                    }
                case .http(let port, let path):
                    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
                        state = .unknown
                        continue
                    }
                    do {
                        let (_, response) = try await URLSession.shared.data(
                            for: URLRequest(url: url, timeoutInterval: 2)
                        )
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        state = (200..<300).contains(code) ? .running : .stopped
                        identifier = "HTTP \(code)"
                    } catch {
                        state = .stopped
                    }
                }
                states.append(state)
                let (logPath, logDate) = latestLog(in: service.logDirectory)
                details.append(Detail(state: state, identifier: identifier,
                                      latestLogPath: logPath, latestLogModified: logDate))
            }
            return DetailedSnapshot(
                snapshot: Snapshot(runningCount: states.filter { $0 == .running }.count,
                                   totalCount: states.count, states: states),
                details: details
            )
        }.value
    }

    nonisolated private static func latestLog(in relativeDirectory: String?) -> (String?, Date?) {
        guard let relativeDirectory else { return (nil, nil) }
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        guard let latest = files
            .filter({ !$0.hasDirectoryPath })
            .max(by: {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lhs < rhs
            })
        else { return (nil, nil) }
        let date = (try? latest.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return (latest.path, date)
    }

    static func formattedLogTime(_ date: Date?) -> String {
        guard let date else { return "无日志" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    nonisolated static func collect(_ kinds: [Kind]) async -> Snapshot {
        await Task.detached(priority: .utility) {
            // launchctl 的同一份输出可供所有任务复用。
            let agents = run(["/bin/launchctl", "list"], timeout: 2)
            var states: [State] = []
            for kind in kinds {
                switch kind {
                case .launchAgent(let label):
                    let line = agents?.split(separator: "\n").first { $0.hasSuffix("\t" + label) }
                    if let line {
                        states.append(line.split(separator: "\t").first == "-" ? .onDemand : .running)
                    } else {
                        states.append(agents == nil ? .unknown : .stopped)
                    }
                case .app(let processName):
                    let output = run(["/usr/bin/pgrep", "-x", processName], timeout: 2)
                    states.append(output.map { $0.isEmpty ? .stopped : .running } ?? .unknown)
                case .http(let port, let path):
                    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
                        states.append(.unknown)
                        continue
                    }
                    do {
                        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2))
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        states.append((200..<300).contains(code) ? .running : .stopped)
                    } catch {
                        states.append(.stopped)
                    }
                }
            }
            return Snapshot(runningCount: states.filter { $0 == .running }.count,
                            totalCount: states.count, states: states)
        }.value
    }

    /// 临时文件避免管道 availableData 在超时检查之前阻塞。
    nonisolated private static func run(_ command: [String], timeout: TimeInterval) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

}

// MARK: - 菜单接入（由 TouchBarController 调用）

/// 动作宿主：Selector 需要 `@objc` 成员，集中在这里避免污染 TouchBarController。
@MainActor
final class BridgeActions: NSObject {
    static let shared = BridgeActions()

    @objc func openMagpie() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/magpie.app")) }
    @objc func openMotrix() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Motrix.app")) }
    @objc func openQuarkdLog() { revealOrOpen(path: home().appendingPathComponent("Library/Logs/QuarkBridge/service-error.log").path) }
    @objc func openMaintenanceLog() { revealOrOpen(path: home().appendingPathComponent("Library/Logs/DailyMemoryMaintenance/launchd.err.log").path) }
    @objc func openTelegramLog() { revealOrOpen(path: home().appendingPathComponent("Library/Application Support/TelegramCheckinManager/scheduled-error.log").path) }

    private func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    private func revealOrOpen(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = "日志不存在"
            alert.informativeText = path
            alert.runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
