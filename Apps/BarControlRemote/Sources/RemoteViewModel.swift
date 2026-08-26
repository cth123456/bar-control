import Foundation
import UIKit

struct RemoteDisplayItem: Identifiable {
    let id: UUID
    let kind: RemoteEventKind
    let title: String
    let text: String
    let sequence: Int64
    let createdAt: Date
    let turnID: String?
    let itemID: String?
    let sessionID: String
    let threadID: String?
}

struct RemoteConversation: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var subtitle: String
    var updatedAt: Date
    var messageCount: Int
    var pinned: Bool
    var projectFolder: String
    var cwd: String
    var model: String
    var active: Bool

    init(
        id: String,
        title: String,
        subtitle: String,
        updatedAt: Date,
        messageCount: Int,
        pinned: Bool = false,
        projectFolder: String = "",
        cwd: String = "",
        model: String = "",
        active: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.pinned = pinned
        self.projectFolder = projectFolder
        self.cwd = cwd
        self.model = model
        self.active = active
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, updatedAt, messageCount, pinned, projectFolder, cwd, model, active
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "会话 \(id.prefix(8))"
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        projectFolder = try container.decodeIfPresent(String.self, forKey: .projectFolder) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(projectFolder, forKey: .projectFolder)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(model, forKey: .model)
        try container.encode(active, forKey: .active)
    }
}

struct RemoteThreadMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let seq: Int
    let createdAt: Date

    init(role: String, text: String, seq: Int, createdAt: Date = Date()) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.seq = seq
        self.createdAt = createdAt
    }
}

struct PendingMessage: Identifiable {
    let id = UUID()
    let text: String
    var threadID: String?
    var failed: Bool
    let createdAt: Date
}

private struct RemoteCache: Codable {
    var events: [RemoteEvent] = []
    var codexThreads: [RemoteConversation] = []
    var threadHistory: [String: [RemoteThreadMessage]] = [:]
    var providerNames: [String] = []
    var currentProviderName: String?
    var modelNames: [String] = []
    var currentModelName: String?
    var threadModels: [String: String] = [:]
}

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published private(set) var events: [RemoteEvent] = []
    @Published private(set) var connectionText = "正在连接"
    @Published private(set) var isConnected = false
    @Published private(set) var isSending = false
    @Published private(set) var providerNames: [String] = []
    @Published private(set) var currentProviderName: String?
    @Published private(set) var modelNames: [String] = []
    @Published private(set) var currentModelName: String?
    @Published private(set) var isNewConversation = false
    @Published private(set) var codexThreads: [RemoteConversation] = []
    @Published private(set) var threadHistory: [String: [RemoteThreadMessage]] = [:]
    @Published private(set) var loadingHistoryThreadID: String?
    @Published private(set) var threadModels: [String: String] = [:]
    @Published private(set) var isAwaitingResponse = false
    @Published private(set) var isSwitchingModel = false
    @Published private(set) var pendingMessages: [PendingMessage] = []
    @Published var showingLocalChat = false
    @Published var filterProject: String?
    @Published var prompt = ""
    @Published var workingDirectory = "/Users/mac/Documents/Obsidian Vault"
    @Published var errorMessage: String?
    @Published private(set) var files: [RemoteFileInfo] = []
    @Published var selectedThreadID: String?
    @Published var selectedConversationTitle = "远程 Codex"
    @Published var switchNotice: String?

    let speech = SpeechInputController()

    private let client = CloudKitRemoteClient()
    private var pollingTask: Task<Void, Never>?
    private var seenEventIDs: Set<UUID> = []
    private var didRequestProviders = false
    private var needsFileRefresh = false
    private var pendingNewText: String?
    private var pendingNewSentAt: Date?
    private var downloadedFiles: [String: URL] = [:]
    private var lastCacheSaveAt = Date.distantPast

    init() {
        let cache = Self.loadCache()
        events = cache.events
        codexThreads = cache.codexThreads
        threadHistory = cache.threadHistory
        providerNames = cache.providerNames
        currentProviderName = cache.currentProviderName
        modelNames = cache.modelNames
        currentModelName = cache.currentModelName
        threadModels = cache.threadModels
    }

    var latestThreadID: String? {
        events.reversed().compactMap(\.threadID).first
    }

    var conversations: [RemoteConversation] {
        var byID: [String: RemoteConversation] = [:]
        // 优先使用 Mac 同步来的 Codex 真实会话（有完整标题/预览/时间）
        for thread in codexThreads {
            byID[thread.id] = thread
        }
        // 再补中继事件里出现、但不在线程列表里的会话
        var buckets: [String: [RemoteEvent]] = [:]
        for event in events {
            guard let threadID = event.threadID, !threadID.isEmpty,
                  threadID != RemoteControlConstants.localChatThreadID,
                  event.title != "Codex 会话消息",
                  event.title != "历史读取失败",
                  event.title != "正在修复原会话" else { continue }
            buckets[threadID, default: []].append(event)
        }
        for (id, list) in buckets where byID[id] == nil {
            let sorted = list.sorted { $0.sequence < $1.sequence }
            let firstUser = sorted.first(where: { $0.kind == .userInput })?
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = firstUser.flatMap { $0.isEmpty ? nil : $0 } ?? "会话 \(id.prefix(8))"
            let last = sorted.last!
            let subtitle = last.text.isEmpty ? last.title : last.text
            byID[id] = RemoteConversation(
                id: id,
                title: String(title.prefix(40)),
                subtitle: String(subtitle.prefix(80)),
                updatedAt: last.createdAt,
                messageCount: sorted.count
            )
        }
        return byID.values.sorted { left, right in
            if left.pinned != right.pinned { return left.pinned && !right.pinned }
            return left.updatedAt > right.updatedAt
        }
    }

    var filteredConversations: [RemoteConversation] {
        guard let filterProject, !filterProject.isEmpty else { return conversations }
        return conversations.filter { $0.projectFolder == filterProject }
    }

    var projectFolders: [String] {
        Array(Set(codexThreads.map(\.projectFolder).filter { !$0.isEmpty })).sorted()
    }

    var projectPaths: [String: String] {
        var result: [String: String] = [:]
        for thread in codexThreads where !thread.projectFolder.isEmpty && !thread.cwd.isEmpty {
            if result[thread.projectFolder] == nil { result[thread.projectFolder] = thread.cwd }
        }
        return result
    }

    var currentProjectFolderName: String {
        let trimmed = workingDirectory.split(separator: "/").last.map(String.init) ?? ""
        return trimmed.isEmpty ? workingDirectory : trimmed
    }

    var selectedConversation: RemoteConversation? {
        guard let selectedThreadID else { return nil }
        return codexThreads.first { $0.id == selectedThreadID }
    }

    var selectedConversationIsActive: Bool {
        selectedConversation?.active ?? false
    }

    var currentThreadModelName: String? {
        guard let selectedThreadID else { return currentModelName }
        return threadModels[selectedThreadID] ?? selectedConversation?.model ?? currentModelName
    }

    var threadDisplayItems: [RemoteDisplayItem] {
        guard let selectedThreadID else { return [] }
        var items = historyItems(for: selectedThreadID)
        let live = displayItems.filter {
            $0.threadID == selectedThreadID && Self.isChatItem($0.kind)
        }
        // 历史里已被实时事件覆盖的同一句话（如手机发起的那一轮）不再重复显示。
        let liveTexts = Set(live.map(\.text))
        items = items.filter { !liveTexts.contains($0.text) }
        items.append(contentsOf: live)
        return items
    }

    var pendingMessagesForSelectedThread: [PendingMessage] {
        if showingLocalChat { return [] }
        if isNewConversation {
            return pendingMessages.filter { $0.threadID == nil }
        }
        guard let selectedThreadID else { return [] }
        return pendingMessages.filter { $0.threadID == selectedThreadID }
    }

    var pendingMessagesForLocalChat: [PendingMessage] {
        pendingMessages.filter { $0.threadID == RemoteControlConstants.localChatThreadID }
    }

    var localChatItems: [RemoteDisplayItem] {
        displayItems.filter {
            $0.threadID == RemoteControlConstants.localChatThreadID
                && ($0.kind == .userInput || $0.kind == .localAssistantMessage || $0.kind == .error)
        }
    }

    private static func isChatItem(_ kind: RemoteEventKind) -> Bool {
        switch kind {
        case .userInput, .agentMessageDelta, .turnFailed, .error:
            return true
        default:
            return false
        }
    }

    private func historyItems(for threadID: String) -> [RemoteDisplayItem] {
        (threadHistory[threadID] ?? [])
            .sorted { $0.seq < $1.seq }
            .suffix(30)
            .map { message in
                RemoteDisplayItem(
                    id: message.id,
                    kind: message.role == "user" ? .userInput : .agentMessageDelta,
                    title: message.role == "user" ? "你的指令" : "Codex",
                    text: message.text,
                    sequence: Int64(message.seq),
                    createdAt: message.createdAt,
                    turnID: nil,
                    itemID: message.id.uuidString,
                    sessionID: threadID,
                    threadID: threadID
                )
            }
    }

    var threadFiles: [RemoteFileInfo] {
        guard let selectedThreadID else { return [] }
        return files.filter { $0.threadID == selectedThreadID }
    }

    var systemItems: [RemoteDisplayItem] {
        let errorCutoff = Date().addingTimeInterval(-1_800) // 30 分钟
        return displayItems
            .filter { ($0.threadID ?? "").isEmpty }
            .filter { item in
                // 历史 error/turnFailed 只保留最近 30 分钟，避免旧报错一直挂在首页
                (item.kind != .error && item.kind != .turnFailed) || item.createdAt >= errorCutoff
            }
            .suffix(4) // 只展示最近几条系统状态
    }

    var pendingApproval: RemoteEvent? {
        for request in events.reversed() where request.kind == .approvalRequired {
            let resolved = events.contains { event in
                event.sequence > request.sequence
                    && event.kind == .approvalResolved
                    && event.rpcRequestID == request.rpcRequestID
            }
            if !resolved { return request }
        }
        return nil
    }

    var displayEvents: [RemoteEvent] {
        Array(events.suffix(500))
    }

    var displayItems: [RemoteDisplayItem] {
        var items: [RemoteDisplayItem] = []
        for event in events {
            // “Codex 会话消息”只是历史正文的载体，“历史读取失败/正在修复原会话”是临时诊断，都不直接渲染。
            if event.title == "Codex 会话消息"
                || event.title == "历史读取失败"
                || event.title == "正在修复原会话" { continue }
            if event.kind == .agentMessageDelta,
               let lastIndex = items.indices.last,
               items[lastIndex].kind == .agentMessageDelta,
               items[lastIndex].itemID != nil,
               items[lastIndex].itemID == event.itemID,
               items[lastIndex].turnID == event.turnID {
                let last = items[lastIndex]
                items[lastIndex] = RemoteDisplayItem(
                    id: last.id,
                    kind: last.kind,
                    title: last.title,
                    text: last.text + event.text,
                    sequence: event.sequence,
                    createdAt: last.createdAt,
                    turnID: last.turnID,
                    itemID: last.itemID,
                    sessionID: last.sessionID,
                    threadID: last.threadID
                )
            } else {
                items.append(RemoteDisplayItem(
                    id: event.id,
                    kind: event.kind,
                    title: event.title,
                    text: event.text,
                    sequence: event.sequence,
                    createdAt: event.createdAt,
                    turnID: event.turnID,
                    itemID: event.itemID,
                    sessionID: event.sessionID,
                    threadID: event.threadID
                ))
            }
        }
        return Array(items.suffix(500))
    }

    func start() async {
        pollingTask?.cancel()
        await connectAndBootstrap()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isConnected {
                    await self.refresh()
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    await self.connectAndBootstrap()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func connectAndBootstrap() async {
        let status = await client.connect()
        connectionText = status.text
        appendDiagnostics("connect \(status.text)")
        isConnected = status == .ready
        guard isConnected else { return }
        await refresh()
        if !didRequestProviders {
            didRequestProviders = true
            await sendCommand(type: .listProviders)
            await sendCommand(type: .listModels)
            await sendCommand(type: .listThreads)
        }
    }

    func refresh() async {
        guard isConnected else { return }
        do {
            let fetched = try await client.fetchEvents()
            var added = false
            for event in fetched where !seenEventIDs.contains(event.id) {
                seenEventIDs.insert(event.id)
                events.append(event)
                added = true
                consumeStateEvent(event)
            }
            if added {
                events.sort {
                    if $0.sequence == $1.sequence { return $0.createdAt < $1.createdAt }
                    return $0.sequence < $1.sequence
                }
                if fetched.contains(where: { $0.kind == .fileChange }) {
                    needsFileRefresh = true
                }
            }
            if let text = pendingNewText,
               let sentAt = pendingNewSentAt,
               let match = events.last(where: {
                   $0.kind == .userInput
                       && $0.text == text
                       && $0.threadID != nil
                       && $0.createdAt.timeIntervalSince(sentAt) > -30
               }) {
                if selectedThreadID != match.threadID {
                    selectedThreadID = match.threadID
                    selectedConversationTitle = String(text.prefix(40))
                    needsFileRefresh = true
                    isNewConversation = false
                }
                pendingNewText = nil
                pendingNewSentAt = nil
                isAwaitingResponse = false
            }
            // 已收到真实 userInput 的乐观消息从待发送列表移除（本地聊天同样适用）。
            let confirmedTexts = Set(
                events.compactMap { event -> String? in
                    guard event.kind == .userInput else { return nil }
                    let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
            )
            if !confirmedTexts.isEmpty {
                pendingMessages.removeAll { confirmedTexts.contains($0.text) }
            }
            if needsFileRefresh {
                needsFileRefresh = false
                await refreshFiles()
            }
            saveCacheIfNeeded()
            connectionText = "已连接 Mac"
            errorMessage = nil
        } catch {
            connectionText = "同步暂时中断"
            errorMessage = error.localizedDescription
            print("CLOUDKIT_FETCH_ERROR \(error)")
            appendDiagnostics("fetch_error \(error)")
        }
    }

    func runCloudKitSmokeTest() async {
        let connectionDeadline = Date().addingTimeInterval(45)
        while !isConnected, Date() < connectionDeadline {
            await connectAndBootstrap()
            if !isConnected { try? await Task.sleep(for: .seconds(2)) }
        }
        guard isConnected else {
            print("CLOUDKIT_SMOKE_FAIL connection=\(connectionText)")
            appendDiagnostics("smoke fail connection \(connectionText)")
            return
        }

        let marker = "CLOUDKIT_REMOTE_OK_\(UUID().uuidString.prefix(8))"
        let startedAt = Date().addingTimeInterval(-1)
        await sendCommand(
            type: .prompt,
            text: "只回复 \(marker)，不调用工具。",
            cwd: workingDirectory
        )
        guard errorMessage == nil else {
            print("CLOUDKIT_SMOKE_FAIL submit=\(errorMessage ?? "unknown")")
            appendDiagnostics("smoke fail submit \(errorMessage ?? "unknown")")
            return
        }

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            await refresh()
            let recent = events.filter { $0.createdAt >= startedAt }
            let streamedText = recent
                .filter { $0.kind == .agentMessageDelta }
                .map(\.text)
                .joined()
            if streamedText.contains(marker), recent.contains(where: { $0.kind == .turnCompleted }) {
                print("CLOUDKIT_SMOKE_PASS marker=\(marker)")
                appendDiagnostics("smoke pass marker \(marker)")
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        print("CLOUDKIT_SMOKE_FAIL timeout marker=\(marker) error=\(errorMessage ?? "none")")
        appendDiagnostics("smoke fail timeout marker \(marker) error \(errorMessage ?? "none")")
    }

    func runFileSmokeTest() async {
        let marker = UUID().uuidString.prefix(6)
        let fileName = "barcontrol-\(marker).txt"
        let text = "请在 /tmp 创建文件 \(fileName)，内容为 HELLO_BAR_CONTROL_\(marker)，然后只回复 FILE_DONE_\(marker)，不要调用其他工具。"
        let startedAt = Date().addingTimeInterval(-1)
        await sendCommand(type: .prompt, text: text, cwd: "/tmp")
        guard errorMessage == nil else {
            appendDiagnostics("file smoke submit fail \(errorMessage ?? "unknown")")
            return
        }

        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            await refresh()
            await refreshFiles()
            let recent = events.filter { $0.createdAt >= startedAt }
            let streamed = recent
                .filter { $0.kind == .agentMessageDelta }
                .map(\.text)
                .joined()
            if streamed.contains("FILE_DONE_\(marker)"),
               recent.contains(where: { $0.kind == .turnCompleted }) {
                let matches = files.filter { $0.fileName.contains("barcontrol-\(marker)") }
                appendDiagnostics(
                    "file smoke done marker \(marker) files \(matches.count) names \(matches.map(\.fileName).joined(separator: ","))"
                )
                if let first = matches.first, let url = await downloadFile(first) {
                    let bytes = (try? Data(contentsOf: url).count) ?? -1
                    appendDiagnostics("file smoke downloaded \(url.lastPathComponent) bytes \(bytes)")
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        appendDiagnostics("file smoke timeout marker \(marker)")
    }

    func sendPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        pendingMessages.append(
            PendingMessage(text: text, threadID: selectedThreadID, failed: false, createdAt: Date())
        )
        if selectedThreadID == nil || isNewConversation {
            pendingNewText = text
            pendingNewSentAt = Date()
        }
        isAwaitingResponse = true
        let ok = await sendCommand(
            type: .prompt,
            text: text,
            cwd: workingDirectory,
            threadID: selectedThreadID
        )
        if !ok { markPendingFailed(text) }
    }

    /// 发送到本地模型（首页“本地模型”入口），同样先乐观上屏。
    func sendLocalPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        pendingMessages.append(
            PendingMessage(
                text: text,
                threadID: RemoteControlConstants.localChatThreadID,
                failed: false,
                createdAt: Date()
            )
        )
        let ok = await sendCommand(
            type: .localPrompt,
            text: text,
            threadID: RemoteControlConstants.localChatThreadID
        )
        if !ok { markPendingFailed(text) }
    }

    private func markPendingFailed(_ text: String) {
        if let index = pendingMessages.firstIndex(where: { $0.text == text && !$0.failed }) {
            pendingMessages[index].failed = true
        }
    }

    func openConversation(_ id: String, title: String) {
        isNewConversation = false
        selectedThreadID = id
        selectedConversationTitle = title
        if codexThreads.first(where: { $0.id == id })?.active == true {
            // 正在运行的会话正文不可读（thread/read 会等写者释放），直接显示运行提示/实时消息。
            loadingHistoryThreadID = nil
        } else {
            loadingHistoryThreadID = id
            Task {
                await refreshFiles()
                if isConnected {
                    await sendCommand(type: .loadThreadHistory, threadID: id)
                } else {
                    loadingHistoryThreadID = nil
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if loadingHistoryThreadID == id { loadingHistoryThreadID = nil }
            }
        }
    }

    func closeConversation() {
        selectedThreadID = nil
        isNewConversation = false
        selectedConversationTitle = "远程 Codex"
    }

    func startNewConversation() {
        isNewConversation = true
        selectedThreadID = nil
        selectedConversationTitle = "新会话"
    }

    func refreshFiles() async {
        guard isConnected else { return }
        do {
            files = try await client.fetchFiles()
        } catch {
            appendDiagnostics("files_error \(error)")
        }
    }

    func downloadFile(_ info: RemoteFileInfo) async -> URL? {
        if let cached = downloadedFiles[info.id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let data = try? await client.downloadFile(recordName: info.id) else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarControlFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(info.fileName)
        do {
            try data.write(to: url)
            downloadedFiles[info.id] = url
            return url
        } catch {
            return nil
        }
    }

    func useSpeechTranscript() {
        let transcript = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        prompt = transcript
    }

    func toggleSpeech() async {
        await speech.toggle()
        if !speech.isRecording { useSpeechTranscript() }
    }

    func stopCurrentTurn() async {
        await sendCommand(type: .stop)
    }

    func switchProvider(_ name: String) async {
        await sendCommand(
            type: .switchProvider,
            text: name,
            threadID: selectedThreadID,
            providerID: name
        )
    }

    func switchModel(_ name: String) async {
        await sendCommand(
            type: .switchModel,
            text: name,
            threadID: selectedThreadID,
            modelID: name
        )
    }

    /// 切换当前会话的专属模型（Mac 端只记录该会话覆盖，不修改全局默认）。
    func switchThreadModel(_ name: String) {
        guard let selectedThreadID else { return }
        if let index = codexThreads.firstIndex(where: { $0.id == selectedThreadID }) {
            codexThreads[index].model = name
        }
        threadModels[selectedThreadID] = name
        saveCacheIfNeeded(force: true)
        isSwitchingModel = true
        Task {
            await sendCommand(
                type: .switchModel,
                text: name,
                threadID: selectedThreadID,
                modelID: name
            )
        }
        Task {
            try? await Task.sleep(for: .seconds(12))
            isSwitchingModel = false
        }
    }

    /// 置顶/取消置顶会话（写回 Mac 的 Codex 桌面状态库，两端一致）。
    func togglePin(_ conversation: RemoteConversation) {
        let newValue = !conversation.pinned
        if let index = codexThreads.firstIndex(where: { $0.id == conversation.id }) {
            codexThreads[index].pinned = newValue
        }
        saveCacheIfNeeded(force: true)
        Task {
            await sendCommand(
                type: .setPinned,
                text: newValue ? "1" : "0",
                threadID: conversation.id
            )
        }
    }

    func answerApproval(_ event: RemoteEvent, accepted: Bool) async {
        guard let requestID = event.rpcRequestID else { return }
        await sendCommand(
            type: accepted ? .approve : .decline,
            approvalRequestID: requestID
        )
    }

    func clearLocalTimeline() {
        events.removeAll()
        seenEventIDs.removeAll()
        providerNames.removeAll()
        currentProviderName = nil
        modelNames.removeAll()
        currentModelName = nil
        codexThreads.removeAll()
        threadHistory.removeAll()
        loadingHistoryThreadID = nil
        threadModels.removeAll()
        isAwaitingResponse = false
        isSwitchingModel = false
        pendingMessages.removeAll()
        showingLocalChat = false
        filterProject = nil
        didRequestProviders = false
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    // MARK: - 本地缓存（重启后立即显示上次数据，不等 CloudKit）

    private static var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("barcontrol-cache.json")
    }

    private static func loadCache() -> RemoteCache {
        guard let data = try? Data(contentsOf: cacheURL) else { return RemoteCache() }
        return (try? JSONDecoder().decode(RemoteCache.self, from: data)) ?? RemoteCache()
    }

    private func saveCacheIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastCacheSaveAt) >= 5 else { return }
        lastCacheSaveAt = now
        let cache = RemoteCache(
            events: Array(events.suffix(800)),
            codexThreads: codexThreads,
            threadHistory: threadHistory,
            providerNames: providerNames,
            currentProviderName: currentProviderName,
            modelNames: modelNames,
            currentModelName: currentModelName,
            threadModels: threadModels
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            appendDiagnostics("cache_save_error \(error)")
        }
    }

    @discardableResult
    private func sendCommand(
        type: RemoteCommandType,
        text: String = "",
        cwd: String? = nil,
        threadID: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        approvalRequestID: JSONValue? = nil
    ) async -> Bool {
        guard isConnected else {
            errorMessage = "CloudKit 尚未连接"
            return false
        }
        isSending = true
        defer { isSending = false }
        let command = RemoteCommand(
            sourceDeviceID: Self.deviceID,
            type: type,
            text: text,
            cwd: cwd,
            threadID: threadID,
            providerID: providerID,
            modelID: modelID,
            approvalRequestID: approvalRequestID
        )
        do {
            try await client.submit(command)
            connectionText = "指令已送达 iCloud"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            print("CLOUDKIT_SEND_ERROR \(error)")
            appendDiagnostics("send_error \(error)")
            return false
        }
    }

    private func appendDiagnostics(_ line: String) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("remote-diagnostics.log")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? text.data(using: .utf8)?.write(to: url)
        }
    }

    private func consumeStateEvent(_ event: RemoteEvent) {
        if event.kind == .providerChanged, event.title == "切换成功" {
            if let threadID = event.threadID, !threadID.isEmpty {
                selectedThreadID = threadID
            }
            showSwitchNotice("已切换到 \(event.text)，账号和模型已自动匹配，继续使用原会话")
        }
        if event.title == "原会话已匹配" {
            if let threadID = event.threadID, !threadID.isEmpty {
                selectedThreadID = threadID
            }
            showSwitchNotice(event.text)
        }
        if event.kind == .providerChanged, !event.text.isEmpty {
            currentProviderName = event.text
            if !providerNames.contains(event.text) { providerNames.append(event.text) }
        }
        if event.title == "Codex 供应商" {
            let names = event.text.split(separator: "\n").map { line in
                line.replacingOccurrences(of: "✓ ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if !names.isEmpty { providerNames = names }
            if let currentLine = event.text.split(separator: "\n").first(where: { $0.hasPrefix("✓ ") }) {
                currentProviderName = currentLine.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if event.kind == .modelChanged, !event.text.isEmpty {
            if event.metadata["mode"] == "thread",
               let threadID = event.threadID, !threadID.isEmpty {
                threadModels[threadID] = event.text
                if let index = codexThreads.firstIndex(where: { $0.id == threadID }) {
                    codexThreads[index].model = event.text
                }
                if selectedThreadID == threadID { isSwitchingModel = false }
            } else {
                currentModelName = event.text
            }
            if !modelNames.contains(event.text) { modelNames.append(event.text) }
        }
        if event.title == "已切换新会话",
           let threadID = event.threadID, !threadID.isEmpty {
            selectedThreadID = threadID
            isNewConversation = false
            selectedConversationTitle = "新会话（原会话在桌面端运行）"
            showSwitchNotice(event.text)
            loadingHistoryThreadID = threadID
            Task {
                await sendCommand(type: .listThreads)
                await sendCommand(type: .loadThreadHistory, threadID: threadID)
                loadingHistoryThreadID = nil
            }
        }
        if event.title == "Codex 模型" {
            let names = event.text.split(separator: "\n").map { line in
                line.replacingOccurrences(of: "✓ ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if !names.isEmpty { modelNames = names }
            if let currentLine = event.text.split(separator: "\n").first(where: { $0.hasPrefix("✓ ") }) {
                currentModelName = currentLine.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if event.title == "Codex 会话列表",
           let data = event.text.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            codexThreads = array.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "会话 \(id.prefix(8))"
                let preview = (item["preview"] as? String) ?? ""
                let model = (item["model"] as? String) ?? ""
                let updatedMS = (item["updated_ms"] as? NSNumber)?.doubleValue ?? 0
                let pinned = (item["pinned"] as? NSNumber)?.boolValue ?? false
                let active = (item["active"] as? NSNumber)?.boolValue ?? false
                let cwd = (item["cwd"] as? String) ?? ""
                let projectFolder = (item["projectFolder"] as? String) ?? Self.folderName(from: cwd)
                let threadModel = threadModels[id] ?? model
                return RemoteConversation(
                    id: id,
                    title: String(title.prefix(40)),
                    subtitle: String((preview.isEmpty ? threadModel : preview).prefix(80)),
                    updatedAt: Date(timeIntervalSince1970: updatedMS / 1000),
                    messageCount: 0,
                    pinned: pinned,
                    projectFolder: projectFolder,
                    cwd: cwd,
                    model: threadModel,
                    active: active
                )
            }
            saveCacheIfNeeded(force: true)
        }
        if event.title == "Codex 会话消息",
           let data = event.text.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let threadID = event.threadID, !threadID.isEmpty {
            var messages: [RemoteThreadMessage] = []
            for (index, item) in array.enumerated() {
                guard let role = item["role"] as? String,
                      let text = item["text"] as? String, !text.isEmpty else { continue }
                let seq = (item["seq"] as? NSNumber)?.intValue ?? index
                messages.append(RemoteThreadMessage(role: role, text: text, seq: seq))
            }
            threadHistory[threadID] = Array(messages.suffix(200))
            if loadingHistoryThreadID == threadID { loadingHistoryThreadID = nil }
            saveCacheIfNeeded(force: true)
        }
    }

    private static func folderName(from cwd: String) -> String {
        let trimmed = cwd.split(separator: "/").last.map(String.init) ?? ""
        return trimmed.isEmpty ? cwd : trimmed
    }

    /// 显示一次性提示横幅，10 秒后若未被新提示替换则自动消失。
    private func showSwitchNotice(_ text: String) {
        switchNotice = text
        let current = text
        Task {
            try? await Task.sleep(for: .seconds(10))
            if switchNotice == current { switchNotice = nil }
        }
    }

    private static var deviceID: String {
        if let identifier = UIDevice.current.identifierForVendor?.uuidString {
            return "iphone-\(identifier)"
        }
        return "iphone"
    }
}
