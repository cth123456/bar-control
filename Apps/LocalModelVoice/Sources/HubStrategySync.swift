import Darwin
import Foundation

/// 统一网关策略的真实落盘层。
///
/// 职责边界就写死在这里，UI 层不直接 spawn 进程：
/// - `targets()` 只挑**真实存在**的客户端配置（Codex / ZCode / Claude Code / OpenCode）；
/// - `previews()` 一律在临时目录的**副本**上干跑 `--sync-agent`，再 `diff` 出改动，所以“预览”永远没有副作用；
/// - `apply()` 才真正让 `unified_router.py --sync-agent` 写盘，写入与备份都由脚本自己完成；
///   所有客户端（含 Codex）统一写入 4230 default Agent，语音助手单独保留 4202。
enum HubStrategySync {

    // MARK: - 类型

    enum Client: String, CaseIterable {
        case codex
        case zcode
        case claude
        case opencode

        var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .zcode: return "ZCode"
            case .claude: return "Claude Code"
            case .opencode: return "OpenCode"
            }
        }

        /// 与 `unified_router.py` 里 `--sync-client` 认的路径保持一致。
        var relativePath: String {
            switch self {
            case .codex: return ".codex/config.toml"
            case .zcode: return ".zcode/v2/config.json"
            case .claude: return ".claude/settings.json"
            case .opencode: return ".config/opencode/opencode.json"
            }
        }
    }

    /// 一个真实存在的写入目标。
    struct Target {
        var client: Client
        var fileURL: URL
        var isWritable: Bool
        var displayPath: String

        var displayName: String { client.displayName }
    }

    /// 干跑出来的改动预览。
    struct Preview {
        var client: Client
        var baseURL: String?
        /// 已裁剪的 `+` / `-` 行，带前缀，方便原样贴进确认框。
        var changes: [String]
        /// 未裁剪的总改动行数。
        var totalChanges: Int
        /// 干跑失败时的原因（成功为 nil）。
        var note: String?
    }

    struct GatewayInfo {
        var enabled: Bool
        var host: String
        var port: Int
        var baseURL: String
    }

    /// 探活/写入要打的那个地址：脚本将来写进客户端的 `base_url` 就是由它拼出来的。
    struct Endpoint: Equatable {
        var host: String
        var port: Int

        var label: String { "\(host):\(port)" }
    }

    /// 一次真实写入的结果。
    struct Outcome {
        var client: Client
        var fileURL: URL
        var ok: Bool
        var baseURL: String?
        var backupName: String?
        var message: String

        /// 通知里的一行（人工措辞，不出现进程/退出码）。
        var line: String {
            if ok {
                let target = baseURL.map { " → \($0)" } ?? ""
                let backup = backupName.map { "，备份 \($0)" } ?? ""
                return "已写入 \(client.displayName)\(target)\(backup)"
            }
            return "\(client.displayName) 未写入：\(message)"
        }
    }

    enum Failure: LocalizedError {
        case missingScript
        case missingTargets(into: [Client])
        case badPort
        case unparsable(String)

        var errorDescription: String? {
            switch self {
            case .missingScript:
                return "找不到 unified_router.py：等它装进应用支持目录后再试"
            case .missingTargets(let clients):
                let names = clients.map(\.displayName).joined(separator: " / ")
                return "没有检测到可写入的客户端配置（找过 \(names)）"
            case .badPort:
                return "统一网关还没配端口：先在「本地路由」里打开网关再切这个策略"
            case .unparsable(let detail):
                return "脚本输出无法解析：\(detail)"
            }
        }
    }

    /// 执行环境：一次性把解释器、脚本、router.json 三样凑齐，方便复用与替换。
    struct Runner {
        var pythonURL: URL
        var scriptURL: URL
        var configURL: URL

        var environment: [String: String] {
            var env = ProcessInfo.processInfo.environment
            // 和 RouterStore 读同一份配置，避免脚本另找一份 router.json 而读不到网关设置。
            env["LOCAL_SIRI_ROUTER_CONFIG"] = configURL.path
            return env
        }
    }

    /// macOS 自带解释器；不用 PATH 查找，避免 .app 里环境不同就找不到。
    static let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
    private static let diffURL = URL(fileURLWithPath: "/usr/bin/diff")

    // MARK: - 目标

    /// 真实存在的客户端配置；返回顺序固定为 Codex → ZCode。
    ///
    /// `home` 只有自检会传（拿临时目录当 home 量菜单结论），日常调用用真实家目录。
    static func targets(fileManager: FileManager = .default, home: URL? = nil) -> [Target] {
        let root = home ?? fileManager.homeDirectoryForCurrentUser
        return Client.allCases.compactMap { client in
            let url = root.appendingPathComponent(client.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return Target(
                client: client,
                fileURL: url,
                isWritable: fileManager.isWritableFile(atPath: url.path),
                displayPath: displayPath(for: url, home: root)
            )
        }
    }

    /// 「统一网关」策略管理所有已授权的客户端；4202 仅保留给语音助手的
    /// Jev/模型策略链，Codex 也通过这里统一接入 4230 Agent 网关。
    static func gatewayTargets(fileManager: FileManager = .default, home: URL? = nil) -> [Target] {
        targets(fileManager: fileManager, home: home)
    }

    /// 本机存在、但脚本不支持自动写入的客户端名称。
    static func readOnlyClientNames(fileManager: FileManager = .default) -> [String] {
        []
    }

    /// 没有任何客户端配置时，用来组装“找过哪些路径”的提示。
    static func missingAllError() -> Failure {
        .missingTargets(into: Client.allCases)
    }

    private static func displayPath(for url: URL, home: URL) -> String {
        let path = url.path
        let prefix = home.path
        guard path.hasPrefix(prefix) else { return path }
        return "~" + path.dropFirst(prefix.count)
    }

    // MARK: - 子进程

    struct CommandResult {
        var launched: Bool
        var exitCode: Int32
        var stdout: String
        var stderr: String

        /// 报错时给人看的一句话。
        var firstLine: String {
            let text = stderr.isEmpty ? stdout : stderr
            let line = text.split(separator: "\n").first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return launched ? "退出码 \(exitCode)" : "进程没能启动"
        }
    }

    /// 读干跑/写入的 stdout：脚本会额外打印人读的日志，所以只截最外层那个 JSON 对象。
    static func jsonObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func run(_ runner: Runner, arguments: [String]) -> CommandResult {
        runTool(
            executable: runner.pythonURL,
            arguments: [runner.scriptURL.path] + arguments,
            environment: runner.environment
        )
    }

    /// 把命令跑完并把 stdout/stderr 全部收回来（读两个管道，避免写满缓冲区把子进程卡住）。
    static func runTool(executable: URL, arguments: [String], environment: [String: String]) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        func drain(_ pipe: Pipe, into sink: @escaping (Data) -> Void) {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    sink(chunk)
                }
            }
        }

        drain(outPipe) { chunk in lock.lock(); outData.append(chunk); lock.unlock() }
        drain(errPipe) { chunk in lock.lock(); errData.append(chunk); lock.unlock() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(launched: false, exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        process.waitUntilExit()
        // 进程退出后管道里可能还剩最后一段，等一小会儿；超时也不影响已经收到的内容。
        _ = group.wait(timeout: .now() + 10)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let out = outData
        let err = errData
        lock.unlock()

        return CommandResult(
            launched: true,
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    /// 脚本写客户端配置的统一入口（干跑与真写只差 `--sync-path` 指向哪）。
    static func syncArguments(client: Client, path: URL) -> [String] {
        ["--sync-agent", "--sync-client", client.rawValue, "--sync-path", path.path]
    }

    // MARK: - 网关信息

    static func gatewayInfo(_ runner: Runner) -> GatewayInfo? {
        let result = run(runner, arguments: ["--gateway-info"])
        guard result.exitCode == 0, let object = jsonObject(from: result.stdout) else { return nil }
        return GatewayInfo(
            enabled: (object["enabled"] as? Bool) ?? false,
            host: (object["host"] as? String) ?? "",
            port: (object["port"] as? Int) ?? 0,
            baseURL: (object["base_url"] as? String) ?? ""
        )
    }

    // MARK: - 探活

    /// 客户端将来真正会去连的那个地址。
    ///
    /// 以脚本自己给出的 `base_url` 为准——那才是会被写进客户端配置的字符串；
    /// 解不出来才退回它返回的 host/port，最后才用 router.json 里的端口号兜底。
    static func endpoint(info: GatewayInfo?, fallbackPort: Int) -> Endpoint? {
        if let info, let parsed = endpoint(inBaseURL: info.baseURL) { return parsed }
        if let info, info.port > 0, !info.host.isEmpty {
            return Endpoint(host: info.host, port: info.port)
        }
        guard fallbackPort > 0 else { return nil }
        return Endpoint(host: "127.0.0.1", port: fallbackPort)
    }

    /// 从 `base_url` 里解出 host:port；没写端口就按 scheme 补 80/443。
    static func endpoint(inBaseURL baseURL: String) -> Endpoint? {
        let text = baseURL.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        if let port = url.port { return Endpoint(host: host, port: port) }
        switch url.scheme?.lowercased() {
        case "https": return Endpoint(host: host, port: 443)
        case "http": return Endpoint(host: host, port: 80)
        default: return nil
        }
    }

    /// 网关是不是真的有东西在监听这个 host:port —— 真开一次 TCP 连接，不是看配置说什么。
    ///
    /// 只信 `--gateway-info` 是不够的：网关进程死了之后它照样返回 `enabled: true` 和拼好的
    /// `base_url`（`base_url` 是按 host/port 拼字符串来的，跟进程死活无关）。照它写盘就会写出
    /// 一条指向死端口的「幽灵链路」：客户端配置显示已指向网关，实际上一个字节都送不到。
    static func isListening(host: String, port: Int, timeout: TimeInterval = 1) -> Bool {
        guard port > 0, port <= 65535, !host.isEmpty else { return false }

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let head = list else { return false }
        defer { freeaddrinfo(head) }

        for node in sequence(first: head, next: { $0.pointee.ai_next }) {
            let fd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if fd < 0 { continue }
            defer { close(fd) }

            // 不设超时的话，连一个被丢弃的地址会卡到系统默认的几十秒。
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)

            let started = Date()
            let code = connect(fd, node.pointee.ai_addr, node.pointee.ai_addrlen)
            if code == 0 { return true }
            guard errno == EINPROGRESS else { continue }

            // 非阻塞 connect 要等可写：可写且 SO_ERROR 为 0 才算连上。
            // 等待用 poll 而不是 select：fd_set 在 C 里全靠宏操作，Swift 这边一个都调不到。
            let deadline = started.addingTimeInterval(timeout)
            var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            while Date() < deadline {
                let ready = poll(&writable, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == 0 { return true }
                break
            }
        }
        return false
    }

    // MARK: - 干跑预览

    static func previews(_ runner: Runner, targets: [Target]) -> [Preview] {
        // The confirmation dialog is scrollable; truncating each client to six
        // diff lines made it impossible to audit the actual write.
        targets.map { preview(runner, target: $0, maxLines: 256) }
    }

    /// 在临时目录的副本上干跑，拿到 base_url 与真实 diff——原文件一个字都不动。
    static func preview(
        _ runner: Runner,
        target: Target,
        fileManager: FileManager = .default,
        maxLines: Int = 6
    ) -> Preview {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("hub-strategy-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // 副本保留客户端目录标记（.codex / .config/opencode 等）：
            // unified_router.py 通过真实路径选择写入器，不能只把文件名扔到临时根目录。
            let parts = target.fileURL.standardizedFileURL.pathComponents
            let markerIndex = parts.firstIndex {
                [".codex", ".zcode", ".claude", ".config"].contains($0)
            }
            let relative = markerIndex.map { parts[$0...].joined(separator: "/") }
                ?? target.fileURL.lastPathComponent
            let copy = directory.appendingPathComponent(relative)
            try fileManager.createDirectory(at: copy.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            try fileManager.copyItem(at: target.fileURL, to: copy)

            let result = run(runner, arguments: syncArguments(client: target.client, path: copy))
            guard result.exitCode == 0 else {
                return Preview(client: target.client, baseURL: nil, changes: [], totalChanges: 0,
                               note: "脚本预览失败：\(result.firstLine)")
            }

            let baseURL = jsonObject(from: result.stdout).flatMap { $0["base_url"] as? String }
            let diff = changedLines(original: target.fileURL, copy: copy, runner: runner)
            return Preview(client: target.client, baseURL: baseURL,
                           changes: Array(diff.prefix(maxLines)), totalChanges: diff.count, note: nil)
        } catch {
            return Preview(client: target.client, baseURL: nil, changes: [], totalChanges: 0,
                           note: "预览失败：\(error.localizedDescription)")
        }
    }

    /// 原文件 vs 干跑副本的差异行（带 +/- 前缀，去掉 diff 的文件头）。
    static func changedLines(original: URL, copy: URL, runner: Runner) -> [String] {
        let result = runTool(
            executable: diffURL,
            arguments: ["-u", original.path, copy.path],
            environment: runner.environment
        )
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            guard let first = line.first, first == "+" || first == "-" else { return nil }
            if line.hasPrefix("+++") || line.hasPrefix("---") { return nil }
            return line
        }
    }

    // MARK: - 真写

    /// 逐个客户端真写。任何一个失败都不影响其它客户端，失败原因原样带回。
    static func apply(_ runner: Runner, targets: [Target]) -> [Outcome] {
        targets.map { target in
            let result = run(runner, arguments: syncArguments(client: target.client, path: target.fileURL))
            guard result.exitCode == 0 else {
                return Outcome(client: target.client, fileURL: target.fileURL, ok: false,
                               baseURL: nil, backupName: nil, message: result.firstLine)
            }
            guard let object = jsonObject(from: result.stdout) else {
                return Outcome(client: target.client, fileURL: target.fileURL, ok: false,
                               baseURL: nil, backupName: nil,
                               message: "写入结果读不出来（\(result.firstLine)）")
            }
            return Outcome(
                client: target.client,
                fileURL: target.fileURL,
                ok: true,
                baseURL: object["base_url"] as? String,
                backupName: (object["backup"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
                message: "写入完成"
            )
        }
    }

    // MARK: - 给某个客户端加一个模型（客户端配置 + 它自己的 Agent，一次做完）

    /// 干跑「把模型池里的一条线路加进这个客户端」的预览。
    ///
    /// 事实全部来自脚本的 `--plan-agent-model`，三件事分开记账：
    /// - `bindingWillBeAdded`：这条线路会绑到**客户端自己的** Agent 上（不只是写进客户端配置文件）；
    /// - `agentWillBeCreated`：那个 Agent 条目还不存在，这次会一起新建；
    /// - `changes`：真 diff —— 脚本自己在临时副本上算的，原文件一个字节没动。
    ///
    /// 为什么要分开：老流程只改客户端配置文件，Agent 那条线路全靠「先点一次同步网关」，
    /// 于是界面说的「已同步」和客户端真能用的模型是两回事。界面现在只照这几个字段说实话。
    struct AgentModelPreview {
        var client: Client
        var fileURL: URL
        var displayPath: String
        /// 客户端自己的 Agent id（Codex 固定 `codex`，ZCode 从它配置里读）。
        var agentID: String
        var agentWillBeCreated: Bool
        var bindingWillBeAdded: Bool
        /// 脚本算出来的模型名（客户端配置里这次会出现的那条线路）。
        var model: String?
        /// 客户端配置里这次会出现的模型名清单。
        var clientModels: [String]
        var gatewayBaseURL: String?
        /// 已裁剪的 `+` / `-` 行，带前缀，方便原样贴进确认框。
        var changes: [String]
        /// 未裁剪的总改动行数。
        var totalChanges: Int
        var changed: Bool
        /// 干跑失败时的原因（成功为 nil）。
        var note: String?

        /// 这次是不是真有事可做：线路要新绑，或者客户端配置真的会变。
        ///
        /// 两件都不成立就是「客户端已经在用这条线路了」——这时候不该弹确认框去写一个空操作。
        var isWorthApplying: Bool {
            note == nil && (bindingWillBeAdded || changed)
        }
    }

    /// 一次真实的「加模型」结果：客户端文件与 Agent 线路各自做没做到。
    struct AgentModelOutcome {
        var client: Client
        var fileURL: URL
        var displayPath: String
        var ok: Bool
        var agentID: String
        var bindingAdded: Bool
        var model: String?
        var clientModels: [String]
        var baseURL: String?
        var backupName: String?
        var message: String

        /// 通知里的一行（人工措辞，不出现进程/退出码）。
        var line: String {
            let title = model ?? "这个模型"
            guard ok else { return "\(client.displayName) 未加入 \(title)：\(message)" }
            var parts = ["\(client.displayName) 已加入 \(title)"]
            parts.append(client == .codex
                         ? "已记入 router.json 的 client_assignments.codex"
                         : (bindingAdded
                            ? "线路已绑到 Agent「\(agentID)」"
                            : "线路早就在 Agent「\(agentID)」上"))
            if let baseURL, !baseURL.isEmpty { parts.append("走 \(baseURL)") }
            if let backupName { parts.append("备份 \(backupName)") }
            return parts.joined(separator: "，")
        }
    }

    /// 干跑与真写只差第一个参数（`--plan-agent-model` / `--add-agent-model`）。
    ///
    /// `--sync-path` 这里给的是**真实**路径：脚本自己在临时副本上算 diff（预览时连它自己那份
    /// router.json 的写入都挪进了临时目录），所以预览没有副作用，App 不用再复制一份文件。
    static func agentModelArguments(
        client: Client,
        path: URL,
        providerID: String,
        model: String,
        apply: Bool
    ) -> [String] {
        var arguments = [
            apply ? "--add-agent-model" : "--plan-agent-model",
            "--sync-client", client.rawValue,
            "--sync-path", path.path,
        ]
        // 所有客户端统一归 AI助手的 default Agent；4202 只由语音链路单独使用。
        arguments += ["--sync-agent-id", "default"]
        // 池里的线路 id：脚本直接复用已配置好的连接（不复制 Key，也不新建连接）。
        if !providerID.isEmpty { arguments += ["--provider-id", providerID] }
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    /// 干跑：只读 JSON，不落盘。
    static func previewAgentModel(
        _ runner: Runner,
        client: Client,
        fileURL: URL,
        displayPath: String,
        providerID: String,
        model: String,
        maxLines: Int = 256
    ) -> AgentModelPreview {
        let fallback = AgentModelPreview(
            client: client, fileURL: fileURL, displayPath: displayPath,
            agentID: client.rawValue, agentWillBeCreated: false, bindingWillBeAdded: false,
            model: nil, clientModels: [], gatewayBaseURL: nil,
            changes: [], totalChanges: 0, changed: false, note: nil
        )
        let result = run(
            runner,
            arguments: agentModelArguments(client: client, path: fileURL,
                                           providerID: providerID, model: model, apply: false)
        )
        guard result.exitCode == 0, let object = jsonObject(from: result.stdout) else {
            var failed = fallback
            failed.note = "干跑失败：\(result.firstLine)"
            return failed
        }
        let diff = changeLines(from: object["diff"])
        var preview = fallback
        preview.agentID = (object["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? client.rawValue
        preview.agentWillBeCreated = object["agent_created"] as? Bool ?? false
        preview.bindingWillBeAdded = object["binding_added"] as? Bool ?? false
        preview.model = object["model"] as? String
        preview.clientModels = object["models"] as? [String] ?? []
        preview.gatewayBaseURL = object["gateway_base_url"] as? String
        preview.changes = Array(diff.prefix(maxLines))
        preview.totalChanges = diff.count
        preview.changed = object["changed"] as? Bool ?? !diff.isEmpty
        return preview
    }

    /// 真写：脚本一次做完「绑线路到客户端自己的 Agent」+「客户端配置指向网关并带上这条模型」。
    static func applyAgentModel(
        _ runner: Runner,
        client: Client,
        fileURL: URL,
        displayPath: String,
        providerID: String,
        model: String
    ) -> AgentModelOutcome {
        let result = run(
            runner,
            arguments: agentModelArguments(client: client, path: fileURL,
                                           providerID: providerID, model: model, apply: true)
        )
        func failure(_ message: String) -> AgentModelOutcome {
            AgentModelOutcome(
                client: client, fileURL: fileURL, displayPath: displayPath, ok: false,
                agentID: client.rawValue, bindingAdded: false, model: nil, clientModels: [],
                baseURL: nil, backupName: nil, message: message
            )
        }
        guard result.exitCode == 0 else { return failure(result.firstLine) }
        guard let object = jsonObject(from: result.stdout) else {
            return failure("写入结果读不出来（\(result.firstLine)）")
        }
        return AgentModelOutcome(
            client: client,
            fileURL: fileURL,
            displayPath: displayPath,
            ok: true,
            agentID: (object["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? client.rawValue,
            bindingAdded: object["binding_added"] as? Bool ?? false,
            model: object["model"] as? String,
            clientModels: object["models"] as? [String] ?? [],
            baseURL: object["gateway_base_url"] as? String,
            backupName: (object["backup"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
            message: "写入完成"
        )
    }

    /// 脚本的 diff 数组 → 只留 `+` / `-` 行（去掉文件头，和同步网关的预览一个口味）。
    static func changeLines(from raw: Any?) -> [String] {
        guard let raw = raw as? [String] else { return [] }
        return raw.compactMap { line in
            guard let first = line.first, first == "+" || first == "-" else { return nil }
            if line.hasPrefix("+++") || line.hasPrefix("---") { return nil }
            // 确认框是用户可见内容，网关密钥不能因为脚本版本较旧而被带出来。
            return line.replacingOccurrences(of: "sk-gateway-[A-Za-z0-9._-]+",
                                              with: "sk-gateway-（已隐藏）",
                                              options: .regularExpression)
        }
    }

    /// 客户端清单里的 id / 名字 / 路径 → 脚本认的客户端。
    ///
    /// 池里的客户端行可能是老数据（只有路径、没有 id），所以三种线索都认一遍。
    static func client(id: String, name: String, path: String) -> Client? {
        let idKey = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nameKey = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathKey = (path as NSString).expandingTildeInPath.lowercased()
        return Client.allCases.first { client in
            client.rawValue == idKey
                || client.displayName.lowercased() == nameKey
                || pathKey.hasSuffix(client.relativePath)
        }
    }

    /// 加模型的确认文案：先说清「会动哪两个地方（客户端配置 + 它自己的 Agent）」，再贴真 diff。
    static func agentModelConfirmText(_ preview: AgentModelPreview, model: String) -> String {
        let name = preview.client.displayName
        let requestedModel = preview.client == .codex ? model : (preview.model ?? model)
        var lines: [String] = []
        lines.append("给 \(name) 加模型：\(requestedModel)")
        if preview.client == .codex {
            lines.append("① " + (preview.bindingWillBeAdded
                                 ? "记录到 router.json 的 client_assignments.codex"
                                 : "已经记录在 router.json 的 client_assignments.codex"))
            lines.append("② Codex 配置文件不改，继续 custom → 4202")
        } else {
            lines.append(
                "① " + (preview.bindingWillBeAdded
                        ? "把这条线路绑到 \(name) 自己的 Agent「\(preview.agentID)」"
                        : "线路已经在 Agent「\(preview.agentID)」上了")
            )
            var second = "② 改客户端配置 \(preview.displayPath)"
            if preview.agentWillBeCreated {
                second += "，同时新建 Agent「\(preview.agentID)」"
            }
            lines.append(second)
            if let gateway = preview.gatewayBaseURL, !gateway.isEmpty {
                lines.append("    改完后客户端走本地网关 \(gateway)")
            }
        }
        lines.append("")
        if preview.changes.isEmpty {
            lines.append("    这个客户端的配置不用改。")
        } else {
            lines.append(contentsOf: preview.changes.map { "    \($0)" })
            if preview.totalChanges > preview.changes.count {
                lines.append("    …共 \(preview.totalChanges) 行改动")
            }
        }
        if !preview.clientModels.isEmpty {
            lines.append("")
            lines.append("    客户端会有这些模型：" + preview.clientModels.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    /// 干跑说明这次没什么可加的时候，横幅要说的那句实话。
    ///
    /// 横幅只有一行，所以这里也只拼一行：客户端名字 + 线路在不在它自己的 Agent 上 + 配置文件改不改。
    /// （多行文本塞进单行横幅只会被截掉，用户看到的就成了半句话。）
    static func agentModelNothingToDoText(_ preview: AgentModelPreview, model: String) -> String {
        if preview.client == .codex {
            return "Codex 已在 client_assignments.codex 里记录 \(model)，配置继续保持 custom → 4202"
        }
        var parts = ["\(preview.client.displayName) 已经在用 \(preview.model ?? model) 了，这次没什么可加的"]
        parts.append(
            preview.bindingWillBeAdded
                ? "线路还要新绑到它自己的 Agent「\(preview.agentID)」"
                : "线路早就在它自己的 Agent「\(preview.agentID)」上"
        )
        parts.append(
            "客户端配置 \(preview.displayPath)"
                + (preview.changed ? "会有 \(preview.totalChanges) 行改动" : "不用改")
        )
        return parts.joined(separator: "，")
    }

    // MARK: - 从模型池里加一个模型进客户端

    /// 模型池里那一行的「加进客户端」菜单里的一项。
    ///
    /// 菜单只列脚本真能自动写入的两个客户端；点不了的那项也照样列出来，只是写明为什么点不了 ——
    /// 直接藏掉，用户只会以为功能没了，进而去手动改配置（那才是真的没人拦）。
    struct AgentModelMenuItem: Identifiable {
        var client: Client
        var title: String
        /// 这次真会写到的那个文件（人话路径，例如 ~/.codex/config.toml）。
        var displayPath: String
        /// 点下去真会写盘时才为 true。
        var enabled: Bool
        /// 现在点不了的原因；能点时 nil。
        var blockedReason: String?

        var id: String { client.rawValue }
    }

    /// 菜单结论只由两个可查的事实决定：这条线路在池里启用没有（读回的 router.json）、
    /// 目标文件在不在且能不能写（FileManager）。所以「菜单点不点得动」跟「点下去真会怎样」是同一件事。
    static func agentModelMenu(lineEnabled: Bool,
                               fileManager: FileManager = .default,
                               home: URL? = nil) -> [AgentModelMenuItem] {
        let root = home ?? fileManager.homeDirectoryForCurrentUser
        let found = targets(fileManager: fileManager, home: root)
        return Client.allCases.map { client in
            let path = displayPath(for: root.appendingPathComponent(client.relativePath), home: root)
            func item(enabled: Bool, reason: String?) -> AgentModelMenuItem {
                AgentModelMenuItem(client: client, title: "加进 \(client.displayName)",
                                   displayPath: path, enabled: enabled, blockedReason: reason)
            }
            // 三道闸门的顺序就是用户能动手的顺序：先看线路自己的开关，再看文件在不在、能不能写。
            if !lineEnabled {
                return item(enabled: false, reason: "这条线路在模型池里是停用的：先在供应商卡片里启用它，再往客户端里加")
            }
            guard let target = found.first(where: { $0.client == client }) else {
                return item(enabled: false, reason: "没找到 \(path)：先让 \(client.displayName) 跑一次，生成配置文件")
            }
            guard target.isWritable else {
                return item(enabled: false, reason: "\(path) 现在不可写（文件权限或只读卷）：改不动，就不让它可点")
            }
            return item(enabled: true, reason: nil)
        }
    }

    /// 确认之前、以及真写之前的那道闸门：干跑自己报错了没有？网关还在不在？
    ///
    /// 返回 nil = 放行；返回字符串 = 必须停下来原样告诉用户的那句话。
    /// 干跑的 note 最具体（它就是真实失败原因），所以排在网关状态前面。
    /// 调用方传的 `gatewayReachable` 是刚探测出来的事实，不是猜的。
    static func agentModelGate(_ preview: AgentModelPreview, gatewayReachable: Bool) -> String? {
        if let note = preview.note { return note }
        if !gatewayReachable {
            return "网关刚刚掉线了：\(preview.displayPath) 一个字都没改，先重新启动网关"
        }
        return nil
    }

    /// 写入之后的核实结论。
    struct AgentModelVerification {
        var ok: Bool
        /// 通知横幅里的那一行（单行；不出现进程、退出码这类词）。
        var line: String
    }

    /// 写完不能只看退出码。这里用两次真实的读回把「到底成没成」钉死：
    /// ① 脚本写完自己解析客户端文件后报出的模型清单；② 重跑一次干跑（它读的是真文件）。
    /// 再加上「网关现在还在不在」——加进去是为了能用，指向一个死网关等于没加。
    static func verifyAgentModelWrite(
        _ outcome: AgentModelOutcome,
        runner: Runner,
        providerID: String,
        model: String,
        gatewayReachable: Bool
    ) -> AgentModelVerification {
        guard outcome.ok else {
            return AgentModelVerification(
                ok: false,
                line: "\(outcome.client.displayName) 没加上 \(model)：\(outcome.message)"
            )
        }
        // Codex 的脚本返回的是当前 config.toml 中的默认模型（例如 gpt-6-luna），
        // 不是本次要加入 router.json 的目标模型。Codex 真正的写入对象是
        // router.json 的 client_assignments.codex，因此核验必须使用请求目标；
        // 其它客户端仍沿用脚本读回的模型名。
        let expected = (
            outcome.client == .codex
                ? model
                : (outcome.model ?? model)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        func listsModel(_ names: [String]) -> Bool {
            names.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(expected) == .orderedSame
            }
        }
        guard !expected.isEmpty, listsModel(outcome.clientModels) else {
            return AgentModelVerification(
                ok: false,
                line: "写入没有落地：\(outcome.displayPath) 读回来没有 \(expected)，这次写入不算数"
            )
        }
        var parts = ["\(outcome.client.displayName) 已加进 \(expected)"]
        parts.append(outcome.client == .codex
                     ? "已记入 router.json 的 client_assignments.codex"
                     : (outcome.bindingAdded
                        ? "线路已绑到 Agent「\(outcome.agentID)」"
                        : "线路本来就在 Agent「\(outcome.agentID)」上"))
        if let backup = outcome.backupName, !backup.isEmpty { parts.append("备份 \(backup)") }
        // 重跑干跑：它还说有事要做，就说明这次没落全；它读回的文件里也该已经有这条模型了。
        let again = previewAgentModel(runner, client: outcome.client, fileURL: outcome.fileURL,
                                      displayPath: outcome.displayPath,
                                      providerID: providerID, model: model)
        if let note = again.note {
            return AgentModelVerification(
                ok: false,
                line: "写入做了，但复跑没能读回来（\(note)）：这条算不确定，自己去 \(outcome.displayPath) 看一眼"
            )
        }
        if !listsModel(again.clientModels) {
            return AgentModelVerification(
                ok: false,
                line: "复跑读回 \(outcome.displayPath) 里没有 \(expected)：这次写入可能没落到这个文件上"
            )
        }
        if again.isWorthApplying {
            return AgentModelVerification(
                ok: false,
                line: "复跑脚本还说有事要做（\(again.totalChanges) 行）：这次写入可能没落全，再点一次加进 \(outcome.client.displayName)"
            )
        }
        parts.append("读回 \(outcome.displayPath) 里有 \(expected)")
        parts.append(outcome.client == .codex
                     ? "Codex 继续走 custom → 4202"
                     : (gatewayReachable
                        ? "网关在跑"
                        : "但网关现在连不上：这条线路暂时用不了，先重新启动网关"))
        return AgentModelVerification(ok: gatewayReachable, line: parts.joined(separator: "，"))
    }

    /// 加模型的确认框要展示的东西：标题说清「谁家的哪条线路加进哪个客户端」，正文交给现成的 diff 文案。
    struct AgentModelWritePrompt {
        var preview: AgentModelPreview
        var model: String
        /// 这条线路在池子里的来源（供应商连接名），用来在标题里说清加的是哪一条。
        var providerLabel: String

        var messageText: String {
            let source = providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedModel = preview.client == .codex ? model : (preview.model ?? model)
            return "把 \(source.isEmpty ? "这条线路" : source) 的 \(requestedModel) 加进 \(preview.client.displayName)？"
        }

        var informativeText: String { agentModelConfirmText(preview, model: model) }
    }

    // MARK: - 确认文案

    static func confirmText(
        targets: [Target],
        previews: [Preview],
        readOnlyClients: [String],
        gatewayBaseURL: String?
    ) -> String {
        var lines: [String] = []
        lines.append("写入前脚本会自己备份，改坏了可以用备份还原。")
        if let gatewayBaseURL, !gatewayBaseURL.isEmpty {
            lines.append("客户端会指向本地网关 \(gatewayBaseURL)")
        }
        for target in targets {
            lines.append("")
            let preview = previews.first { $0.client == target.client }
            let permission = target.isWritable ? "" : "（只读，可能写不进去）"
            var head = "• \(target.displayName) · \(target.displayPath)\(permission)"
            if let baseURL = preview?.baseURL, !baseURL.isEmpty, baseURL != gatewayBaseURL {
                head += " → \(baseURL)"
            }
            lines.append(head)
            if let note = preview?.note {
                lines.append("    \(note)")
                continue
            }
            for change in preview?.changes ?? [] {
                lines.append("    \(change)")
            }
            let total = preview?.totalChanges ?? 0
            if total > (preview?.changes.count ?? 0) {
                lines.append("    …共 \(total) 行改动")
            } else if total == 0 {
                lines.append("    已经是统一网关的样子，无需改动")
            }
        }
        let missing = Client.allCases
            .filter { client in !targets.contains { $0.client == client } }
            .map(\.displayName)
        if !missing.isEmpty {
            lines.append("")
            lines.append("没检测到配置：" + missing.joined(separator: "、"))
        }
        if !readOnlyClients.isEmpty {
            lines.append("只读（脚本不支持自动写入）：" + readOnlyClients.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}

extension HubStrategySync {

    /// 确认框要展示的全部事实：写哪些文件、每个文件会改成什么样、网关地址。
    ///
    /// 视图层只负责把 `messageText` / `informativeText` 摆出来，不再自己拼字符串 ——
    /// 这样「确认框说的」和「脚本会做的」永远是同一份数据算出来的。
    struct WritePrompt {
        var targets: [Target]
        var previews: [Preview]
        var readOnlyClients: [String]

        /// 脚本真读到的网关地址，非空。
        ///
        /// 为什么不是可选的：地址读不出来的时候，确认框只能写一句没人能证实的话
        /// （旧文案「本地网关（暂未读到端口，脚本会用当前 router.json 里的设置）」就是这种许愿——
        /// 那时脚本会照 router.json 里现有的设置写，而那个值恰恰是这里读不到的那个）。
        /// 现在的做法是把「读不到地址」交给闸门去拒绝执行，所以确认框能构造出来，
        /// 就一定有一个真地址；`informativeText` 里也因此不留任何兜底文案。
        private let address: String

        /// 兼容既有调用点的可选读法：因为 `address` 非空，它恒为 `.some`。
        var baseURL: String? { address }

        /// `baseURL` 只收非空字符串：空白地址在这里就构造不出确认框。
        init(targets: [Target], previews: [Preview], readOnlyClients: [String], baseURL: String) {
            self.targets = targets
            self.previews = previews
            self.readOnlyClients = readOnlyClients
            self.address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var messageText: String {
            "把客户端配置指向统一网关？"
        }

        var informativeText: String {
            """
            目标：\(address)
            客户端清单：\(targets.map { "\($0.displayName)（\($0.displayPath)）" }.joined(separator: "、"))

            \(confirmText(targets: targets, previews: previews,
                          readOnlyClients: readOnlyClients, gatewayBaseURL: address))

            写入前脚本会先把原文件备份成同名 .ai-assistant-backup-<时间戳> 文件。
            """
        }
    }
}
