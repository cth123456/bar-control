import Foundation

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case notRunning
    case invalidResponse(String)
    case remoteError(String)
    case writeFailed
    case noActiveTurn

    var errorDescription: String? {
        switch self {
        case .executableNotFound: return "没有找到 Codex CLI"
        case .notRunning: return "Codex app-server 没有运行"
        case .invalidResponse(let value): return "Codex 返回了无效响应：\(value)"
        case .remoteError(let value): return value
        case .writeFailed: return "无法向 Codex app-server 写入数据"
        case .noActiveTurn: return "当前没有可停止或追加指令的 Codex 任务"
        }
    }
}

actor CodexAppServerClient {
    private let eventStore: RemoteEventStore
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var nextRequestID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var startupTask: Task<Void, Error>?
    private var initialized = false
    private(set) var activeSessionID = "local"
    private(set) var activeThreadID: String?
    private(set) var activeTurnID: String?

    init(eventStore: RemoteEventStore) {
        self.eventStore = eventStore
    }

    func start() async throws {
        if initialized, process?.isRunning == true { return }
        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw CodexAppServerError.notRunning }
            try await self.performStart()
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func performStart() async throws {
        stopProcess(reason: nil)

        guard let executable = Self.codexExecutableURL() else {
            throw CodexAppServerError.executableNotFound
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus) }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeOutput(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeError(data) }
        }

        try process.run()
        self.process = process
        inputPipe = input
        outputPipe = output
        errorPipe = errors

        _ = try await sendRequestWithoutStarting(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("bar_control_remote"),
                    "title": .string("Bar Control Remote"),
                    "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true)
                ])
            ]),
            timeout: .seconds(15)
        )
        try sendNotification(method: "initialized", params: .object([:]))
        initialized = true
        _ = try? await eventStore.append(
            sessionID: activeSessionID,
            kind: .connection,
            title: "Codex 已连接",
            text: executable.path
        )
    }

    func restart() async throws {
        startupTask?.cancel()
        startupTask = nil
        stopProcess(reason: "正在重启 Codex 连接")
        try await start()
    }

    func shutdown() {
        startupTask?.cancel()
        startupTask = nil
        stopProcess(reason: nil)
    }

    @discardableResult
    func startTurn(command: RemoteCommand) async throws -> String {
        try await start()
        activeSessionID = command.id.uuidString
        let cwd = command.cwd ?? RemoteControlConstants.defaultWorkingDirectory
        let modelID = command.modelID

        let threadID: String
        if let requestedThreadID = command.threadID {
            threadID = try await resumeThread(
                threadID: requestedThreadID,
                cwd: cwd,
                modelID: modelID
            )
        } else {
            var params: [String: JSONValue] = [
                "cwd": .string(cwd),
                "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"),
                "sandbox": .string("workspace-write"),
                "threadSource": .string("user")
            ]
            if let modelID { params["model"] = .string(modelID) }
            let result = try await sendRequest(
                method: "thread/start",
                params: .object(params)
            )
            guard let created = result["thread"]?["id"]?.stringValue else {
                throw CodexAppServerError.invalidResponse("thread/start 缺少 thread.id")
            }
            threadID = created
        }
        activeThreadID = threadID
        _ = try await eventStore.append(
            sessionID: activeSessionID,
            kind: .userInput,
            title: "你的指令",
            text: command.text,
            threadID: threadID
        )

        var turnParams: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(cwd),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(command.text),
                    "text_elements": .array([])
                ])
            ])
        ]
        if let modelID { turnParams["model"] = .string(modelID) }
        let result = try await sendRequest(
            method: "turn/start",
            params: .object(turnParams)
        )
        activeTurnID = result["turn"]?["id"]?.stringValue
        return threadID
    }

    @discardableResult
    func resumeThread(threadID: String, cwd: String, modelID: String?) async throws -> String {
        try await start()
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(cwd),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            // 这里只验证并重新挂接原 thread，不需要把大型历史再次回传到手机中继。
            "excludeTurns": .bool(true)
        ]
        if let modelID { params["model"] = .string(modelID) }
        let result = try await sendRequest(
            method: "thread/resume",
            params: .object(params)
        )
        let resumedID = result["thread"]?["id"]?.stringValue ?? threadID
        activeThreadID = resumedID
        activeTurnID = nil
        return resumedID
    }

    func steer(_ text: String, sessionID: String) async throws {
        guard let threadID = activeThreadID, let turnID = activeTurnID else {
            throw CodexAppServerError.noActiveTurn
        }
        activeSessionID = sessionID
        _ = try await eventStore.append(
            sessionID: activeSessionID,
            kind: .userInput,
            title: "追加指令",
            text: text,
            threadID: threadID,
            turnID: turnID
        )
        _ = try await sendRequest(
            method: "turn/steer",
            params: .object([
                "threadId": .string(threadID),
                "expectedTurnId": .string(turnID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                        "text_elements": .array([])
                    ])
                ])
            ])
        )
    }

    func interrupt() async throws {
        guard let threadID = activeThreadID, let turnID = activeTurnID else {
            throw CodexAppServerError.noActiveTurn
        }
        _ = try await sendRequest(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }

    func respondToApproval(requestID: JSONValue, accepted: Bool) throws {
        guard process?.isRunning == true else { throw CodexAppServerError.notRunning }
        try sendEnvelope(.object([
            "id": requestID,
            "result": .object([
                "decision": .string(accepted ? "accept" : "decline")
            ])
        ]))
    }

    func listThreads(limit: Int = 20) async throws -> JSONValue {
        try await sendRequest(
            method: "thread/list",
            params: .object([
                "limit": .number(Double(limit)),
                "sortKey": .string("updated_at"),
                "modelProviders": .array([])
            ]),
            timeout: .seconds(10)
        )
    }

    /// 读取一个会话的历史消息（userMessage / agentMessage），按时间顺序返回
    /// [{role, text, seq}]，供手机端展示桌面 Codex 的既有对话正文。
    func threadMessages(threadID: String) async throws -> [JSONValue] {
        let result = try await sendRequest(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID),
                "includeTurns": .bool(true)
            ]),
            timeout: .seconds(10)
        )
        guard let turns = result["thread"]?["turns"]?.arrayValue else { return [] }
        var messages: [JSONValue] = []
        var seq = 0
        for turn in turns {
            for item in (turn["items"]?.arrayValue ?? []) {
                let type = item["type"]?.stringValue ?? ""
                let role: String?
                let text: String
                if type == "userMessage" {
                    role = "user"
                    text = Self.contentText(from: item["content"])
                } else if type == "agentMessage" {
                    role = "assistant"
                    text = item["text"]?.stringValue ?? ""
                } else {
                    role = nil
                    text = ""
                }
                guard let role, !text.isEmpty else { continue }
                let trimmed = String(text.prefix(4000))
                messages.append(.object([
                    "role": .string(role),
                    "text": .string(trimmed),
                    "seq": .number(Double(seq))
                ]))
                seq += 1
            }
        }
        return Array(messages.suffix(150))
    }

    private static func contentText(from value: JSONValue?) -> String {
        guard let blocks = value?.arrayValue else { return "" }
        return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    private func sendRequest(
        method: String,
        params: JSONValue,
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        try await start()
        return try await sendRequestWithoutStarting(method: method, params: params, timeout: timeout)
    }

    private func sendRequestWithoutStarting(
        method: String,
        params: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        guard process?.isRunning == true else { throw CodexAppServerError.notRunning }
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            do {
                try sendEnvelope(.object([
                    "id": .number(Double(requestID)),
                    "method": .string(method),
                    "params": params
                ]))
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.failPending(
                    requestID: requestID,
                    error: CodexAppServerError.remoteError("Codex 请求超时：\(method)")
                )
            }
        }
    }

    private func failPending(requestID: Int64, error: Error) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: error)
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        try sendEnvelope(.object([
            "method": .string(method),
            "params": params
        ]))
    }

    private func sendEnvelope(_ envelope: JSONValue) throws {
        guard let inputPipe, process?.isRunning == true else {
            throw CodexAppServerError.notRunning
        }
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.writeFailed
        }
    }

    private func consumeOutput(_ data: Data) async {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                await handleEnvelope(envelope)
            } catch {
                AppLog.write("app-server invalid JSON: \(error.localizedDescription)")
            }
        }
    }

    private func consumeError(_ data: Data) {
        errorBuffer.append(data)
        while let newline = errorBuffer.firstIndex(of: 0x0A) {
            let line = errorBuffer[..<newline]
            errorBuffer.removeSubrange(...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                AppLog.write("app-server stderr: \(Self.redactedLogLine(text))")
            }
        }
    }

    private func handleEnvelope(_ envelope: JSONValue) async {
        if let requestID = envelope["id"]?.int64Value, envelope["method"] == nil {
            guard let continuation = pending.removeValue(forKey: requestID) else { return }
            if let error = envelope["error"] {
                let message = error["message"]?.stringValue ?? "Codex 请求失败"
                continuation.resume(throwing: CodexAppServerError.remoteError(message))
            } else {
                continuation.resume(returning: envelope["result"] ?? .null)
            }
            return
        }

        guard let method = envelope["method"]?.stringValue else { return }
        let params = envelope["params"] ?? .object([:])
        let requestID = envelope["id"]
        await handleEvent(method: method, params: params, requestID: requestID)
    }

    private func handleEvent(method: String, params: JSONValue, requestID: JSONValue?) async {
        let threadID = params["threadId"]?.stringValue
            ?? params["thread"]?["id"]?.stringValue
            ?? activeThreadID
        let turnID = params["turnId"]?.stringValue
            ?? params["turn"]?["id"]?.stringValue
            ?? activeTurnID
        let item = params["item"]
        let itemID = params["itemId"]?.stringValue ?? item?["id"]?.stringValue

        if method == "thread/started", let threadID {
            activeThreadID = threadID
        }
        if method == "turn/started", let turnID {
            activeTurnID = turnID
        }

        let mapped: (RemoteEventKind, String, String, [String: String])?
        switch method {
        case "thread/started":
            mapped = (.connection, "会话已建立", threadID ?? "", [:])
        case "turn/started":
            mapped = (.turnStarted, "Codex 开始执行", "", [:])
        case "item/agentMessage/delta":
            mapped = (.agentMessageDelta, "Codex", params["delta"]?.stringValue ?? "", [:])
        case "item/plan/delta":
            mapped = (.planDelta, "计划", params["delta"]?.stringValue ?? "", [:])
        case "item/reasoning/summaryTextDelta":
            mapped = (.reasoningSummaryDelta, "思考摘要", params["delta"]?.stringValue ?? "", [:])
        case "item/commandExecution/outputDelta":
            mapped = (.commandOutputDelta, "终端输出", params["delta"]?.stringValue ?? "", [:])
        case "item/started":
            mapped = Self.startedItemEvent(item)
        case "item/completed":
            mapped = Self.completedItemEvent(item)
        case "turn/completed":
            let status = params["turn"]?["status"]?.stringValue ?? "completed"
            if status == "failed" {
                let message = params["turn"]?["error"]?["message"]?.stringValue ?? "Codex 执行失败"
                mapped = (.turnFailed, "执行失败", message, ["status": status])
            } else {
                mapped = (.turnCompleted, status == "interrupted" ? "已停止" : "执行完成", "", ["status": status])
            }
            activeTurnID = nil
        case "configWarning", "warning":
            mapped = (.warning, "Codex 警告", params["message"]?.stringValue ?? params["summary"]?.stringValue ?? "", [:])
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            let reason = params["reason"]?.stringValue
                ?? params["command"]?.stringValue
                ?? params["item"]?["command"]?.stringValue
                ?? "需要你的确认"
            mapped = (.approvalRequired, "等待确认", reason, ["method": method])
        default:
            mapped = nil
        }

        guard let mapped else { return }
        do {
            _ = try await eventStore.append(
                sessionID: activeSessionID,
                kind: mapped.0,
                title: mapped.1,
                text: mapped.2,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                rpcRequestID: requestID,
                metadata: mapped.3
            )
        } catch {
            AppLog.write("remote event append failed: \(error.localizedDescription)")
        }
    }

    private func processTerminated(status: Int32) async {
        let wasInitialized = initialized
        initialized = false
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        let waiters = pending.values
        pending.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: CodexAppServerError.remoteError("Codex app-server 已退出（\(status)）"))
        }
        if wasInitialized {
            _ = try? await eventStore.append(
                sessionID: activeSessionID,
                kind: .connection,
                title: "Codex 连接已断开",
                text: "退出状态 \(status)"
            )
        }
    }

    private func stopProcess(reason: String?) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        initialized = false
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        if let reason { AppLog.write(reason) }
    }

    private static func startedItemEvent(_ item: JSONValue?) -> (RemoteEventKind, String, String, [String: String])? {
        guard let item, let type = item["type"]?.stringValue else { return nil }
        switch type {
        case "commandExecution":
            let command = item["command"]?.stringValue
                ?? item["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? ""
            return (.actionStarted, "执行命令", command, ["itemType": type])
        case "fileChange": return (.actionStarted, "准备修改文件", "", ["itemType": type])
        case "mcpToolCall":
            return (.toolActivity, "调用工具", item["tool"]?.stringValue ?? item["server"]?.stringValue ?? "", ["itemType": type])
        case "webSearch": return (.toolActivity, "搜索网页", item["query"]?.stringValue ?? "", ["itemType": type])
        case "contextCompaction": return (.actionProgress, "整理会话上下文", "", ["itemType": type])
        default: return nil
        }
    }

    private static func completedItemEvent(_ item: JSONValue?) -> (RemoteEventKind, String, String, [String: String])? {
        guard let item, let type = item["type"]?.stringValue else { return nil }
        switch type {
        case "fileChange":
            let changes = item["changes"]?.arrayValue ?? []
            let count = changes.count
            let paths = changes.compactMap { $0["path"]?.stringValue }
            var metadata = ["itemType": type]
            if !paths.isEmpty {
                metadata["paths"] = paths.joined(separator: "\n")
            }
            return (.fileChange, "文件已修改", "\(count) 个文件", metadata)
        case "commandExecution":
            let status = item["status"]?.stringValue ?? "completed"
            let exitCode = item["exitCode"]?.stringValue ?? ""
            let command = item["command"]?.stringValue
                ?? item["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? ""
            var metadata = ["itemType": type, "status": status]
            let paths = Self.extractRedirectionPaths(from: command)
            if !paths.isEmpty {
                metadata["paths"] = paths.joined(separator: "\n")
            }
            return (.actionProgress, "命令结束", exitCode.isEmpty ? status : "退出码 \(exitCode)", metadata)
        case "mcpToolCall":
            let status = item["status"]?.stringValue ?? "completed"
            return (.toolActivity, "工具调用结束", status, ["itemType": type, "status": status])
        default: return nil
        }
    }

    private static func extractRedirectionPaths(from command: String) -> [String] {
        var paths: [String] = []
        let tokens = command.split(separator: " ", omittingEmptySubsequences: false)
        var pending = false
        for token in tokens {
            if token == ">" || token == ">>" || token == "1>" || token == "2>" || token == "2>>" {
                pending = true
                continue
            }
            if pending {
                let path = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("./") || path.hasPrefix("../") {
                    paths.append(path)
                }
                pending = false
                if paths.count >= 10 { break }
            }
        }
        return paths
    }

    private static func codexExecutableURL() -> URL? {
        // 会话格式随 Codex 桌面版本演进。必须优先使用桌面 App 自带的 CLI，
        // 否则 Homebrew 的旧版本可能无法恢复新版本写入的原会话。
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map {
            URL(fileURLWithPath: $0)
        }
    }

    private static func redactedLogLine(_ line: String) -> String {
        var result = line
        let patterns = ["token", "authorization", "api_key", "secret"]
        if patterns.contains(where: { result.lowercased().contains($0) }) {
            result = "[已隐藏可能包含凭据的 app-server 日志]"
        }
        return String(result.prefix(1_000))
    }
}
