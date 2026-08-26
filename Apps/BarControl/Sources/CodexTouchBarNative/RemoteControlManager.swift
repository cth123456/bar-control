import AppKit
import Foundation

@MainActor
final class RemoteControlManager {
    private enum DefaultsKey {
        static let latestThreadID = "remoteControl.latestThreadID.v1"
        static let threadModelOverrides = "remoteControl.threadModelOverrides.v1"
    }

    private let eventStore = RemoteEventStore()
    private lazy var appServer = CodexAppServerClient(eventStore: eventStore)
    private lazy var cloudRelay = CloudKitRelay(eventStore: eventStore)
    private let interpreter = LocalCommandInterpreter()
    private let providerStore = CCSwitchProviderStore()
    private var eventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var providerMonitorTask: Task<Void, Never>?
    private var modelMonitorTask: Task<Void, Never>?
    private var windowController: RemoteControlWindowController?
    private var lastKnownProviderID: String?
    private var lastKnownModelID: String?
    private var threadModelOverrides: [String: String] = [:]

    private(set) var events: [RemoteEvent] = []
    private(set) var providers: [RemoteProviderSummary] = []
    private(set) var models: [RemoteModelSummary] = []
    private(set) var currentModelName: String?
    private(set) var statusText = "正在启动"
    private(set) var cloudStatusText = "未连接"
    private(set) var latestThreadID: String? = UserDefaults.standard.string(
        forKey: DefaultsKey.latestThreadID
    )
    private(set) var isStarted = false

    var onChange: (() -> Void)?

    func start() {
        guard startupTask == nil else { return }
        threadModelOverrides = UserDefaults.standard.dictionary(
            forKey: DefaultsKey.threadModelOverrides
        ) as? [String: String] ?? [:]
        eventTask = Task { [weak self, eventStore] in
            let history = await eventStore.events(limit: 500)
            await MainActor.run {
                self?.events = history
                if self?.latestThreadID == nil,
                   let threadID = history.reversed().compactMap(\.threadID).first {
                    self?.rememberThread(threadID)
                }
                self?.notifyChange()
            }
            let stream = await eventStore.stream()
            for await event in stream {
                await MainActor.run {
                    self?.receive(event)
                }
            }
        }
        startupTask = Task { [weak self] in
            guard let self else { return }
            RelayFileLog.append("manager.start: begin")
            var shouldReloadDesktop = false
            do {
                let compatibility = try providerStore.reconcileCodexConfiguration()
                shouldReloadDesktop = compatibility.changed
                lastKnownModelID = compatibility.modelID
                RelayFileLog.append(
                    "manager.start: provider compatibility ready active=\(compatibility.activeProviderID) model=\(compatibility.modelID ?? "nil") changed=\(compatibility.changed)"
                )
            } catch {
                RelayFileLog.append("manager.start: provider compatibility error \(error)")
            }
            await refreshProviders()
            await refreshModels()
            do {
                try await appServer.start()
                statusText = "Codex 已连接"
                RelayFileLog.append("manager.start: appServer started")
                do {
                    try await resumeExistingThreadIfNeeded(
                        latestThreadID,
                        cwd: RemoteControlConstants.defaultWorkingDirectory,
                        sessionID: "startup-reconcile"
                    )
                } catch {
                    RelayFileLog.append("manager.start: saved thread resume error \(error)")
                }
            } catch {
                statusText = "Codex 连接失败：\(error.localizedDescription)"
                RelayFileLog.append("manager.start: appServer error \(error)")
            }
            RelayFileLog.append("manager.start: starting cloud relay")
            await cloudRelay.start { [weak self] command in
                await self?.handle(command)
            }
            cloudStatusText = await cloudRelay.currentStatus().label
            RelayFileLog.append("manager.start: relay status \(cloudStatusText)")
            startProviderMonitor()
            startModelMonitor()
            isStarted = true
            notifyChange()
            if shouldReloadDesktop {
                restartCodexDesktopApp(threadID: latestThreadID)
            }
        }
    }

    func stop() {
        startupTask?.cancel()
        eventTask?.cancel()
        providerMonitorTask?.cancel()
        modelMonitorTask?.cancel()
        startupTask = nil
        eventTask = nil
        providerMonitorTask = nil
        modelMonitorTask = nil
        Task {
            await cloudRelay.stop()
            await appServer.shutdown()
        }
        isStarted = false
    }

    private func startProviderMonitor() {
        providerMonitorTask?.cancel()
        lastKnownProviderID = Self.currentProviderIDFromSettings()
        providerMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.monitorProviderChange()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func startModelMonitor() {
        modelMonitorTask?.cancel()
        lastKnownModelID = providerStore.currentModelFromConfig()
        modelMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.monitorModelChange()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func monitorModelChange() async {
        guard let currentID = providerStore.currentModelFromConfig() else { return }
        if lastKnownModelID == nil {
            lastKnownModelID = currentID
            return
        }
        guard currentID != lastKnownModelID else { return }
        lastKnownModelID = currentID
        RelayFileLog.append("model change detected: \(currentID)")
        let name = models.first(where: { $0.id == currentID })?.name ?? currentID
        do {
            _ = try providerStore.reconcileCodexConfiguration()
            try await appServer.restart()
            try await resumeExistingThreadIfNeeded(
                latestThreadID,
                cwd: RemoteControlConstants.defaultWorkingDirectory,
                sessionID: "model-monitor"
            )
            _ = try? await eventStore.append(
                sessionID: "model-monitor",
                kind: .modelChanged,
                title: "模型已切换并匹配原会话",
                text: name,
                threadID: latestThreadID,
                metadata: ["modelID": currentID, "continuity": "same-thread"]
            )
            await refreshModels()
            restartCodexDesktopApp(threadID: latestThreadID)
        } catch {
            RelayFileLog.append("model auto reconcile failed: \(error)")
            _ = try? await eventStore.append(
                sessionID: "model-monitor",
                kind: .error,
                title: "模型自动匹配失败",
                text: error.localizedDescription,
                threadID: latestThreadID
            )
        }
    }

    private func monitorProviderChange() async {
        guard let currentID = Self.currentProviderIDFromSettings() else { return }
        if lastKnownProviderID == nil {
            lastKnownProviderID = currentID
            return
        }
        guard currentID != lastKnownProviderID else { return }
        lastKnownProviderID = currentID
        RelayFileLog.append("provider change detected: \(currentID)")

        var provider = providers.first(where: { $0.id == currentID })
        if provider == nil {
            provider = (try? await providerStore.providers())?.first(where: { $0.id == currentID })
        }
        guard let provider else {
            RelayFileLog.append("provider change: unknown provider \(currentID)")
            return
        }
        do {
            let compatibility = try providerStore.reconcileCodexConfiguration(provider: provider)
            try await appServer.restart()
            try await resumeExistingThreadIfNeeded(
                latestThreadID,
                cwd: RemoteControlConstants.defaultWorkingDirectory,
                sessionID: "provider-monitor"
            )
            RelayFileLog.append("provider model synced for \(provider.name)")
            _ = try? await eventStore.append(
                sessionID: "provider-monitor",
                kind: .providerChanged,
                title: "自动匹配完成",
                text: provider.name,
                threadID: latestThreadID,
                metadata: [
                    "providerID": provider.id,
                    "activeConfigProvider": compatibility.activeProviderID,
                    "continuity": "same-thread"
                ]
            )
            restartCodexDesktopApp(threadID: latestThreadID)
        } catch {
            RelayFileLog.append("provider auto reconcile failed: \(error)")
            _ = try? await eventStore.append(
                sessionID: "provider-monitor",
                kind: .error,
                title: "自动匹配失败",
                text: error.localizedDescription,
                threadID: latestThreadID
            )
        }
    }

    private static func currentProviderIDFromSettings() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/settings.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["currentProviderCodex"] as? String
    }

    func showWindow() {
        if windowController == nil {
            windowController = RemoteControlWindowController(manager: self)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func submit(text: String, cwd: String?, threadID: String? = nil) {
        let command = RemoteCommand(
            sourceDeviceID: "mac-\(Host.current().localizedName ?? "local")",
            type: .prompt,
            text: text,
            cwd: cwd,
            threadID: threadID
        )
        Task { await handle(command) }
    }

    func stopCurrentTurn() {
        Task {
            do {
                try await appServer.interrupt()
                statusText = "正在停止 Codex"
            } catch {
                statusText = error.localizedDescription
            }
            notifyChange()
        }
    }

    func answerApproval(event: RemoteEvent, accepted: Bool) {
        guard let requestID = event.rpcRequestID else { return }
        Task {
            do {
                try await appServer.respondToApproval(requestID: requestID, accepted: accepted)
                try await recordApprovalResolution(
                    requestID: requestID,
                    accepted: accepted,
                    sessionID: event.sessionID,
                    event: event
                )
            } catch {
                statusText = "确认失败：\(error.localizedDescription)"
                notifyChange()
            }
        }
    }

    func switchProvider(id: String) {
        let command = RemoteCommand(
            sourceDeviceID: "mac",
            type: .switchProvider,
            providerID: id
        )
        Task { await handle(command) }
    }

    func refreshProviders() async {
        do {
            providers = try await providerStore.providers()
        } catch {
            statusText = "读取 CC Switch 失败：\(error.localizedDescription)"
        }
        notifyChange()
    }

    func refreshModels() async {
        guard let providerID = Self.currentProviderIDFromSettings() else {
            models = []
            currentModelName = nil
            notifyChange()
            return
        }
        models = providerStore.modelCatalog(providerID: providerID)
        currentModelName = models.first(where: \.isCurrent)?.name ?? providerStore.currentModelFromConfig()
        notifyChange()
    }

    func clearHistory() {
        Task {
            do {
                try await eventStore.clearHistory()
                events.removeAll()
                notifyChange()
            } catch {
                statusText = "清理记录失败：\(error.localizedDescription)"
                notifyChange()
            }
        }
    }

    func handle(_ command: RemoteCommand) async {
        do {
            switch command.type {
            case .prompt:
                await interpretAndExecute(command)
            case .steer:
                do {
                    try await appServer.steer(command.text, sessionID: command.id.uuidString)
                    statusText = "已追加到当前任务"
                } catch {
                    await recordBenignTurnMiss(sessionID: command.id.uuidString, error: error)
                }
            case .stop:
                do {
                    try await appServer.interrupt()
                    statusText = "正在停止 Codex"
                } catch {
                    await recordBenignTurnMiss(sessionID: command.id.uuidString, error: error)
                }
            case .approve, .decline:
                guard let requestID = command.approvalRequestID else {
                    throw CodexAppServerError.invalidResponse("确认指令缺少 requestID")
                }
                try await appServer.respondToApproval(
                    requestID: requestID,
                    accepted: command.type == .approve
                )
                try await recordApprovalResolution(
                    requestID: requestID,
                    accepted: command.type == .approve,
                    sessionID: command.id.uuidString,
                    event: nil
                )
            case .switchProvider:
                guard let value = command.providerID ?? Self.nonEmpty(command.text) else {
                    throw CCSwitchError.providerNotFound("")
                }
                try await performProviderSwitch(
                    value,
                    sessionID: command.id.uuidString,
                    threadID: command.threadID ?? latestThreadID,
                    cwd: command.cwd
                )
            case .switchModel:
                guard let value = command.modelID ?? Self.nonEmpty(command.text) else {
                    throw CCSwitchError.modelNotFound("")
                }
                try await performModelSwitch(
                    value,
                    sessionID: command.id.uuidString,
                    threadID: command.threadID ?? latestThreadID,
                    cwd: command.cwd
                )
            case .listProviders:
                await refreshProviders()
                let list = providers.map { ($0.isCurrent ? "✓ " : "") + $0.name }.joined(separator: "\n")
                _ = try await eventStore.append(
                    sessionID: command.id.uuidString,
                    kind: .actionProgress,
                    title: "Codex 供应商",
                    text: list
                )
            case .listModels:
                await refreshModels()
                let list = models.map { ($0.isCurrent ? "✓ " : "") + $0.name }.joined(separator: "\n")
                _ = try await eventStore.append(
                    sessionID: command.id.uuidString,
                    kind: .actionProgress,
                    title: "Codex 模型",
                    text: list
                )
            case .listThreads:
                try await emitThreadListEvent(sessionID: command.id.uuidString)
            case .setPinned:
                guard let threadID = command.threadID else {
                    throw CodexAppServerError.invalidResponse("置顶指令缺少会话 ID")
                }
                let pinned = command.text == "1"
                let ok = await providerStore.setThreadPinned(threadID: threadID, pinned: pinned)
                _ = try await eventStore.append(
                    sessionID: command.id.uuidString,
                    kind: .actionProgress,
                    title: ok ? (pinned ? "已置顶" : "已取消置顶") : "置顶失败",
                    text: ok
                        ? "会话 …\(threadID.suffix(8)) 的置顶状态已同步到 Codex"
                        : "Codex 状态库暂时被占用，请稍后重试",
                    threadID: threadID
                )
                if ok {
                    try await emitThreadListEvent(sessionID: command.id.uuidString)
                }
            case .loadThreadHistory:
                guard let threadID = command.threadID else {
                    throw CodexAppServerError.invalidResponse("读取会话消息缺少会话 ID")
                }
                // 优先直接解析 rollout 落地文件（Codex+ 等第三方客户端的主流做法），
                // 不受 app-server 活动写者/paginated lineage 影响；文件缺失时退回 thread/read。
                let extras = await providerStore.threadExtras()
                var messages: [JSONValue] = []
                var usedRollout = false
                var rolloutPath = extras[threadID]?.rolloutPath
                if rolloutPath == nil || rolloutPath!.isEmpty {
                    // state_5 可能被 daemon 锁住读不到，改用 thread/list 返回的 path 字段兜底。
                    if let list = try? await appServer.listThreads(limit: 50),
                       let data = list["data"]?.arrayValue,
                       let item = data.first(where: { $0["id"]?.stringValue == threadID }) {
                        rolloutPath = item["path"]?.stringValue
                        RelayFileLog.append(
                            "loadThreadHistory path from thread/list: \(rolloutPath ?? "nil")"
                        )
                    }
                }
                RelayFileLog.append(
                    "loadThreadHistory extras=\(extras.count) thread=\(threadID) path=\(rolloutPath ?? "nil")"
                )
                if let rolloutPath, !rolloutPath.isEmpty,
                   FileManager.default.isReadableFile(atPath: rolloutPath) {
                    usedRollout = true
                    RelayFileLog.append("loadThreadHistory readable=true")
                    let url = URL(fileURLWithPath: rolloutPath)
                    messages = await Task.detached {
                        RolloutHistoryParser.extractMessages(from: url)
                    }.value
                    RelayFileLog.append(
                        "loadThreadHistory rollout path=\(rolloutPath) messages=\(messages.count)"
                    )
                } else {
                    RelayFileLog.append(
                        "loadThreadHistory rollout unavailable readable=\(FileManager.default.isReadableFile(atPath: rolloutPath ?? ""))"
                    )
                }
                if usedRollout {
                    let data = try JSONEncoder().encode(messages)
                    let text = String(decoding: data, as: UTF8.self)
                    _ = try await eventStore.append(
                        sessionID: command.id.uuidString,
                        kind: .transcript,
                        title: "Codex 会话消息",
                        text: text,
                        threadID: threadID
                    )
                } else {
                    do {
                        let appMessages = try await appServer.threadMessages(threadID: threadID)
                        let data = try JSONEncoder().encode(appMessages)
                        let text = String(decoding: data, as: UTF8.self)
                        _ = try await eventStore.append(
                            sessionID: command.id.uuidString,
                            kind: .transcript,
                            title: "Codex 会话消息",
                            text: text,
                            threadID: threadID
                        )
                    } catch {
                        RelayFileLog.append("loadThreadHistory failed: \(error.localizedDescription)")
                        _ = try await eventStore.append(
                            sessionID: command.id.uuidString,
                            kind: .warning,
                            title: "历史读取失败",
                            text: "该会话正文暂不可读：\(error.localizedDescription)",
                            threadID: threadID
                        )
                        // thread/read 可能把 app-server 卡在“活动写者”上，重启它以恢复后续请求。
                        try? await appServer.restart()
                    }
                }
            case .healthCheck:
                _ = try await appServer.listThreads(limit: 1)
                _ = try await eventStore.append(
                    sessionID: command.id.uuidString,
                    kind: .connection,
                    title: "连接正常",
                    text: "Codex app-server 可用"
                )
            }
        } catch {
            statusText = "执行失败：\(error.localizedDescription)"
            _ = try? await eventStore.append(
                sessionID: command.id.uuidString,
                kind: .error,
                title: "执行失败",
                text: error.localizedDescription
            )
        }
        cloudStatusText = await cloudRelay.currentStatus().label
        notifyChange()
    }

    /// 通过官方 app-server thread/list 读取最近会话摘要，合并桌面端置顶/按会话模型信息，
    /// 供手机端展示历史会话列表。带 5 秒兜底，避免 app-server 无响应时卡死中继指令循环。
    private func listThreadSummaries() async -> [[String: Any]] {
        do {
            let result = try await appServer.listThreads(limit: 50)
            let extras = await providerStore.threadExtras()
            var summaries: [[String: Any]] = []
            for item in (result["data"]?.arrayValue ?? []) {
                guard let id = item["id"]?.stringValue, !id.isEmpty else { continue }
                let updatedAt = item["updatedAt"]?.int64Value ?? 0
                let extra = extras[id]
                let cwd = item["cwd"]?.stringValue ?? ""
                summaries.append([
                    "id": id,
                    "title": item["name"]?.stringValue ?? "",
                    "preview": item["preview"]?.stringValue ?? "",
                    "model": extra?.model ?? item["modelProvider"]?.stringValue ?? "",
                    "updated_ms": updatedAt * 1000,
                    "pinned": extra?.pinned ?? false,
                    "active": item["status"]?["type"]?.stringValue == "active",
                    "cwd": cwd,
                    "projectFolder": Self.projectFolderName(
                        cwd: cwd,
                        gitURL: item["gitInfo"]?["originUrl"]?.stringValue
                    )
                ])
            }
            return summaries
        } catch {
            RelayFileLog.append("listThreads failed: \(error.localizedDescription)")
            return []
        }
    }

    private func emitThreadListEvent(sessionID: String) async throws {
        let summaries = await listThreadSummaries()
        let data = try JSONSerialization.data(withJSONObject: summaries, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .actionProgress,
            title: "Codex 会话列表",
            text: text
        )
    }

    /// 该会话若设置过专属模型，返回其模型 ID；否则返回 nil（调用方回退到全局默认）。
    private func resolvedModelID(for threadID: String?) -> String? {
        guard let threadID, let id = threadModelOverrides[threadID], !id.isEmpty else { return nil }
        return id
    }

    private func persistThreadModelOverrides() {
        UserDefaults.standard.set(threadModelOverrides, forKey: DefaultsKey.threadModelOverrides)
    }

    nonisolated private static func projectFolderName(cwd: String, gitURL: String?) -> String {
        if let gitURL, !gitURL.isEmpty,
           let url = URL(string: gitURL) {
            let name = url.lastPathComponent
                .replacingOccurrences(of: ".git", with: "")
            if !name.isEmpty { return name }
        }
        let trimmed = cwd.split(separator: "/").last.map(String.init) ?? ""
        return trimmed.isEmpty ? cwd : trimmed
    }

    private func interpretAndExecute(_ command: RemoteCommand) async {
        await refreshProviders()
        statusText = "本地模型正在理解指令"
        notifyChange()
        let intent = await interpreter.interpret(command.text, providers: providers)
        _ = try? await eventStore.append(
            sessionID: command.id.uuidString,
            kind: .localIntent,
            title: "本地模型",
            text: intent.explanation,
            metadata: [
                "action": intent.action.rawValue,
                "confidence": String(format: "%.2f", intent.confidence)
            ]
        )

        do {
            switch intent.action {
            case .prompt:
                let prompt = intent.prompt ?? command.text
                let executableCommand = RemoteCommand(
                    id: command.id,
                    createdAt: command.createdAt,
                    sourceDeviceID: command.sourceDeviceID,
                    type: .prompt,
                    text: prompt,
                    cwd: command.cwd,
                    threadID: command.threadID,
                    providerID: nil,
                    modelID: resolvedModelID(for: command.threadID)
                        ?? providerStore.currentModelFromConfig(),
                    approvalRequestID: nil
                )
                do {
                    rememberThread(try await appServer.startTurn(command: executableCommand))
                } catch {
                    guard executableCommand.threadID != nil else { throw error }
                    // 桌面端 app-server 正持有该会话的写锁，任何第二个进程都无法续写同一 rollout。
                    // 此时不重试原会话（重试只会反复失败+重启），改在新会话里继续，并通知手机。
                    if error.localizedDescription.localizedCaseInsensitiveContains("active writer") {
                        let fallback = RemoteCommand(
                            id: executableCommand.id,
                            createdAt: executableCommand.createdAt,
                            sourceDeviceID: executableCommand.sourceDeviceID,
                            type: .prompt,
                            text: executableCommand.text,
                            cwd: executableCommand.cwd,
                            threadID: nil,
                            providerID: nil,
                            modelID: executableCommand.modelID,
                            approvalRequestID: nil
                        )
                        let newThreadID = try await appServer.startTurn(command: fallback)
                        rememberThread(newThreadID)
                        // 把按会话模型覆盖一起带到新会话，否则后续消息会退回全局默认模型。
                        if let modelID = executableCommand.modelID {
                            threadModelOverrides[newThreadID] = modelID
                            persistThreadModelOverrides()
                        }
                        _ = try await eventStore.append(
                            sessionID: command.id.uuidString,
                            kind: .actionProgress,
                            title: "已切换新会话",
                            text: "原会话正在桌面端运行，无法从手机续写；消息已在新会话中继续",
                            threadID: newThreadID,
                            metadata: [
                                "originalThreadID": executableCommand.threadID ?? "",
                                "modelID": executableCommand.modelID ?? ""
                            ]
                        )
                        statusText = "已在新会话继续（原会话在桌面端运行）"
                        notifyChange()
                        break
                    }
                    _ = try? await eventStore.append(
                        sessionID: command.id.uuidString,
                        kind: .warning,
                        title: "正在修复原会话",
                        text: "正在重新匹配当前供应商和模型，不会新建会话",
                        threadID: executableCommand.threadID
                    )
                    _ = try providerStore.reconcileCodexConfiguration()
                    try await appServer.restart()
                    rememberThread(try await appServer.startTurn(command: executableCommand))
                }
                statusText = "Codex 正在执行"
            case .steer:
                do {
                    try await appServer.steer(intent.prompt ?? command.text, sessionID: command.id.uuidString)
                    statusText = "已追加到当前任务"
                } catch {
                    await recordBenignTurnMiss(sessionID: command.id.uuidString, error: error)
                }
            case .stop:
                do {
                    try await appServer.interrupt()
                    statusText = "正在停止 Codex"
                } catch {
                    await recordBenignTurnMiss(sessionID: command.id.uuidString, error: error)
                }
            case .switchProvider:
                guard let providerName = intent.providerName else {
                    throw CCSwitchError.providerNotFound(command.text)
                }
                try await performProviderSwitch(
                    providerName,
                    sessionID: command.id.uuidString,
                    threadID: command.threadID ?? latestThreadID,
                    cwd: command.cwd
                )
            case .listProviders:
                let list = providers.map { ($0.isCurrent ? "✓ " : "") + $0.name }.joined(separator: "\n")
                _ = try await eventStore.append(
                    sessionID: command.id.uuidString,
                    kind: .actionProgress,
                    title: "Codex 供应商",
                    text: list
                )
                statusText = "已读取供应商"
            case .status:
                _ = try await appServer.listThreads(limit: 1)
                _ = try await eventStore.append(
                    sessionID: command.id.uuidString,
                    kind: .connection,
                    title: "运行状态",
                    text: "\(statusText) · \(cloudStatusText)"
                )
            case .unknown:
                throw CodexAppServerError.invalidResponse(intent.explanation)
            }
        } catch {
            statusText = "执行失败：\(error.localizedDescription)"
            _ = try? await eventStore.append(
                sessionID: command.id.uuidString,
                kind: .error,
                title: "执行失败",
                text: error.localizedDescription
            )
        }
        notifyChange()
    }

    private func performProviderSwitch(
        _ value: String,
        sessionID: String,
        threadID: String?,
        cwd: String?
    ) async throws {
        let provider = try await providerStore.resolve(value)
        if provider.isCurrent {
            _ = try providerStore.reconcileCodexConfiguration(provider: provider)
            try await resumeExistingThreadIfNeeded(
                threadID,
                cwd: cwd ?? RemoteControlConstants.defaultWorkingDirectory,
                sessionID: sessionID
            )
            _ = try await eventStore.append(
                sessionID: sessionID,
                kind: .providerChanged,
                title: "已经在使用 \(provider.name)",
                text: provider.name,
                threadID: threadID,
                metadata: ["continuity": "same-thread"]
            )
            return
        }
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .actionStarted,
            title: "正在切换账号",
            text: provider.name,
            threadID: threadID
        )
        statusText = "正在通过 CC Switch 切换到 \(provider.name)"
        notifyChange()

        try providerStore.activateProviderDirect(provider)
        let switched = provider
        // 切换供应商后旧供应商的模型 ID 不再可用，清空按会话模型覆盖，回退到新供应商默认模型。
        threadModelOverrides.removeAll()
        persistThreadModelOverrides()
        let compatibility = try providerStore.reconcileCodexConfiguration(provider: switched)
        lastKnownProviderID = switched.id
        lastKnownModelID = compatibility.modelID
        if let threadID { rememberThread(threadID) }
        try await appServer.restart()
        try await resumeExistingThreadIfNeeded(
            threadID,
            cwd: cwd ?? RemoteControlConstants.defaultWorkingDirectory,
            sessionID: sessionID
        )
        await refreshProviders()
        await refreshModels()
        _ = try? await appServer.listThreads(limit: 1)
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .providerChanged,
            title: "切换成功",
            text: switched.name,
            threadID: threadID,
            metadata: [
                "providerID": switched.id,
                "modelID": compatibility.modelID ?? "",
                "activeConfigProvider": compatibility.activeProviderID,
                "verified": "cc-switch+compatibility+same-thread",
                "continuity": "same-thread"
            ]
        )
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .actionProgress,
            title: "原会话已匹配",
            text: threadID == nil
                ? "账号与模型已经匹配；下一条指令会继续当前选择的会话"
                : "账号与模型已经匹配，会话 …\(threadID!.suffix(8)) 保持不变",
            threadID: threadID
        )
        statusText = "已切换到 \(switched.name)，原会话可继续"
        restartCodexDesktopApp(threadID: threadID)
    }

    private func performModelSwitch(
        _ value: String,
        sessionID: String,
        threadID: String?,
        cwd: String?
    ) async throws {
        guard let providerID = providerStore.currentProviderID() else {
            throw CCSwitchError.databaseUnavailable
        }
        let catalog = providerStore.modelCatalog(providerID: providerID)
        let matcher = Self.normalized(value)
        let target = catalog.first(where: { $0.id == value || Self.normalized($0.name) == matcher })
            ?? RemoteModelSummary(id: value, name: value, isCurrent: false)

        // 按会话切换模型：只记录该会话的模型覆盖，后续指令经 thread/resume、turn/start 的
        // model 参数生效；不修改全局 config.toml、不重启 app-server（秒级生效）。
        if let threadID {
            let previous = resolvedModelID(for: threadID) ?? providerStore.currentModelFromConfig() ?? ""
            if previous == target.id {
                _ = try await eventStore.append(
                    sessionID: sessionID,
                    kind: .modelChanged,
                    title: "会话已经在使用 \(target.name)",
                    text: target.name,
                    threadID: threadID,
                    metadata: ["modelID": target.id, "mode": "thread"]
                )
                return
            }
            threadModelOverrides[threadID] = target.id
            persistThreadModelOverrides()
            statusText = "会话已切换到模型 \(target.name)"
            notifyChange()
            _ = try await eventStore.append(
                sessionID: sessionID,
                kind: .modelChanged,
                title: "会话模型已切换",
                text: target.name,
                threadID: threadID,
                metadata: ["modelID": target.id, "mode": "thread", "previous": previous]
            )
            return
        }

        let current = providerStore.currentModelFromConfig()
        if target.id == current {
            try await resumeExistingThreadIfNeeded(
                threadID,
                cwd: cwd ?? RemoteControlConstants.defaultWorkingDirectory,
                sessionID: sessionID
            )
            _ = try await eventStore.append(
                sessionID: sessionID,
                kind: .modelChanged,
                title: "已经在使用 \(target.name)",
                text: target.name,
                threadID: threadID,
                metadata: ["continuity": "same-thread"]
            )
            return
        }
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .actionStarted,
            title: "正在切换模型",
            text: target.name,
            threadID: threadID
        )
        statusText = "正在切换到模型 \(target.name)"
        notifyChange()

        try providerStore.setCurrentModel(target.id, providerID: providerID)
        let compatibility = try providerStore.reconcileCodexConfiguration()
        lastKnownModelID = target.id
        if let threadID { rememberThread(threadID) }
        try await appServer.restart()
        try await resumeExistingThreadIfNeeded(
            threadID,
            cwd: cwd ?? RemoteControlConstants.defaultWorkingDirectory,
            sessionID: sessionID
        )
        await refreshModels()
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .modelChanged,
            title: "模型已切换",
            text: target.name,
            threadID: threadID,
            metadata: [
                "modelID": target.id,
                "activeConfigProvider": compatibility.activeProviderID,
                "continuity": "same-thread"
            ]
        )
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .actionProgress,
            title: "原会话已匹配",
            text: threadID == nil
                ? "模型已经匹配；下一条指令会继续当前选择的会话"
                : "模型已经匹配，会话 …\(threadID!.suffix(8)) 保持不变",
            threadID: threadID
        )
        statusText = "已切换到 \(target.name)，原会话可继续"
    }

    private func resumeExistingThreadIfNeeded(
        _ threadID: String?,
        cwd: String,
        sessionID: String
    ) async throws {
        guard let threadID, !threadID.isEmpty else { return }
        let modelID = providerStore.currentModelFromConfig()
        let resumedID = try await appServer.resumeThread(
            threadID: threadID,
            cwd: cwd,
            modelID: modelID
        )
        guard resumedID == threadID else {
            throw CodexAppServerError.invalidResponse(
                "原会话恢复后 ID 发生变化：\(threadID) → \(resumedID)"
            )
        }
        rememberThread(resumedID)
        RelayFileLog.append(
            "same thread resumed session=\(sessionID) thread=\(resumedID) model=\(modelID ?? "nil")"
        )
    }

    private func rememberThread(_ threadID: String?) {
        guard let threadID, !threadID.isEmpty else { return }
        latestThreadID = threadID
        UserDefaults.standard.set(threadID, forKey: DefaultsKey.latestThreadID)
    }

    private func recordApprovalResolution(
        requestID: JSONValue,
        accepted: Bool,
        sessionID: String,
        event: RemoteEvent?
    ) async throws {
        _ = try await eventStore.append(
            sessionID: sessionID,
            kind: .approvalResolved,
            title: accepted ? "已批准一次" : "已拒绝",
            text: event?.text ?? "远程确认已送达 Codex",
            threadID: event?.threadID,
            turnID: event?.turnID,
            itemID: event?.itemID,
            rpcRequestID: requestID,
            metadata: ["decision": accepted ? "accept" : "decline"]
        )
    }

    func runProtocolSmokeTest() async -> Bool {
        let sessionID = UUID().uuidString
        do {
            await refreshProviders()
            guard !providers.isEmpty else {
                throw CodexAppServerError.invalidResponse("没有读取到 CC Switch 供应商")
            }
            let listIntent = await interpreter.interpret("列出供应商", providers: providers)
            guard listIntent.action == .listProviders else {
                throw CodexAppServerError.invalidResponse("本地指令分类器自检失败")
            }
            try await appServer.start()
            let command = RemoteCommand(
                id: UUID(uuidString: sessionID) ?? UUID(),
                sourceDeviceID: "mac-smoke-test",
                type: .prompt,
                text: "只回复 REMOTE_STREAM_OK，不调用工具。",
                cwd: FileManager.default.temporaryDirectory.path
            )
            _ = try await appServer.startTurn(command: command)
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(250))
                let emitted = await eventStore.events(sessionID: sessionID, limit: 500)
                guard emitted.contains(where: \.isTerminal) else { continue }
                let combinedReply = emitted
                    .filter { $0.kind == .agentMessageDelta }
                    .map(\.text)
                    .joined()
                let passed = combinedReply.contains("REMOTE_STREAM_OK")
                    && emitted.contains(where: { $0.kind == .turnStarted })
                    && emitted.contains(where: { $0.kind == .turnCompleted })
                _ = try await eventStore.append(
                    sessionID: sessionID,
                    kind: passed ? .connection : .error,
                    title: passed ? "远程协议自检通过" : "远程协议自检失败",
                    text: "事件数 \(emitted.count) · 流式回复 \(combinedReply)"
                )
                return passed
            }
            throw CodexAppServerError.remoteError("等待流式回复超时")
        } catch {
            _ = try? await eventStore.append(
                sessionID: sessionID,
                kind: .error,
                title: "远程协议自检失败",
                text: error.localizedDescription
            )
            return false
        }
    }

    /// 本机验收专用：执行与手机相同的 CC Switch 切换和原 thread 恢复，
    /// 但不重启 ChatGPT，便于连续验证 DeepSeek ↔ OpenAI 两个方向。
    func runProviderContinuityProbe(providerName: String, threadID: String) async -> Bool {
        let sessionID = "provider-continuity-probe-\(UUID().uuidString)"
        do {
            let target = try await providerStore.resolve(providerName)
            let switched = target.isCurrent ? target : try await providerStore.switchProvider(target)
            let compatibility = try providerStore.reconcileCodexConfiguration(provider: switched)
            try await appServer.restart()
            let resumedID = try await appServer.resumeThread(
                threadID: threadID,
                cwd: RemoteControlConstants.defaultWorkingDirectory,
                modelID: compatibility.modelID
            )
            guard resumedID == threadID else {
                throw CodexAppServerError.invalidResponse(
                    "连续性探针改变了 thread ID：\(threadID) → \(resumedID)"
                )
            }
            RelayFileLog.append(
                "provider continuity probe passed provider=\(switched.name) active=\(compatibility.activeProviderID) model=\(compatibility.modelID ?? "nil") thread=\(resumedID)"
            )
            _ = try? await eventStore.append(
                sessionID: sessionID,
                kind: .connection,
                title: "供应商连续性验证通过",
                text: "\(switched.name) · \(compatibility.modelID ?? "未指定模型")",
                threadID: resumedID,
                metadata: ["continuity": "same-thread", "probe": "true"]
            )
            return true
        } catch {
            RelayFileLog.append("provider continuity probe failed provider=\(providerName) error=\(error)")
            _ = try? await eventStore.append(
                sessionID: sessionID,
                kind: .error,
                title: "供应商连续性验证失败",
                text: error.localizedDescription,
                threadID: threadID,
                metadata: ["probe": "true"]
            )
            return false
        }
    }

    private func receive(_ event: RemoteEvent) {
        events.append(event)
        if events.count > 500 {
            events.removeFirst(events.count - 500)
        }
        if let threadID = event.threadID { rememberThread(threadID) }
        let paths = event.metadata["paths"]?
            .split(separator: "\n")
            .map(String.init) ?? []
        if !paths.isEmpty {
            Task { await cloudRelay.uploadFiles(paths: paths, event: event) }
        }
        switch event.kind {
        case .turnCompleted: statusText = event.title
        case .turnFailed, .error: statusText = event.text.isEmpty ? event.title : event.text
        case .approvalRequired: statusText = "等待你的确认"
        default: break
        }
        notifyChange()
    }

    private func notifyChange() {
        onChange?()
        windowController?.refresh()
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    /// 停止/追加指令在没有正在运行的任务时属于正常情况，不当作持续红报错。
    private func recordBenignTurnMiss(sessionID: String, error: Error) async {
        statusText = "当前没有正在执行的任务"
        _ = try? await eventStore.append(
            sessionID: sessionID,
            kind: .actionProgress,
            title: "提示",
            text: error.localizedDescription
        )
        notifyChange()
    }

    /// 切换供应商/模型成功后重启 ChatGPT/Codex，并重新打开原会话。
    /// 重启前先杀掉 Codex 的常驻 app-server daemon（不带 --stdio 的进程），确保它重新读取切换后的 config；
    /// Bar Control 自己的 app-server 是 --stdio 进程，用行尾锚定避免误杀。
    private func restartCodexDesktopApp(threadID: String?) {
        let bundleID = "com.openai.codex"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            // forceTerminate 不弹“是否关闭 Codex”确认框，否则重启会卡住
            app.forceTerminate()
        }
        Task {
            for _ in 0..<24 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            // 兜底：确认框/卡死时强制杀进程
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if !still.isEmpty {
                for app in still { app.forceTerminate() }
                try? await Task.sleep(for: .milliseconds(500))
                let pids = still.compactMap { $0.processIdentifier == 0 ? nil : String($0.processIdentifier) }
                if !pids.isEmpty {
                    let kill = Process()
                    kill.executableURL = URL(fileURLWithPath: "/bin/kill")
                    kill.arguments = ["-9"] + pids
                    try? kill.run()
                }
            }
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", "codex app-serve[r]$"]
            try? pkill.run()
            try? await Task.sleep(for: .milliseconds(800))
            let config = NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                configuration: config
            )
            guard let threadID,
                  let threadURL = URL(string: "codex://threads/\(threadID)")
            else { return }
            try? await Task.sleep(for: .seconds(1))
            _ = NSWorkspace.shared.open(threadURL)
        }
    }

}
