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

struct RemoteConversation: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let updatedAt: Date
    let messageCount: Int
}

@MainActor
final class RemoteViewModel: ObservableObject {
    private enum DefaultsKey {
        static let selectedThreadID = "remote.selectedThreadID.v1"
    }

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
    @Published var prompt = ""
    @Published var workingDirectory = "/Users/mac/Documents/Obsidian Vault"
    @Published var errorMessage: String?
    @Published private(set) var files: [RemoteFileInfo] = []
    @Published var selectedThreadID: String? = UserDefaults.standard.string(
        forKey: DefaultsKey.selectedThreadID
    ) {
        didSet {
            if let selectedThreadID, !selectedThreadID.isEmpty {
                UserDefaults.standard.set(selectedThreadID, forKey: DefaultsKey.selectedThreadID)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.selectedThreadID)
            }
        }
    }
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
            guard let threadID = event.threadID, !threadID.isEmpty else { continue }
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
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var threadDisplayItems: [RemoteDisplayItem] {
        guard let selectedThreadID else { return [] }
        return displayItems.filter { $0.threadID == selectedThreadID }
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
            }
            if needsFileRefresh {
                needsFileRefresh = false
                await refreshFiles()
            }
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
        if selectedThreadID == nil || isNewConversation {
            pendingNewText = text
            pendingNewSentAt = Date()
        }
        await sendCommand(
            type: .prompt,
            text: text,
            cwd: workingDirectory,
            threadID: selectedThreadID
        )
    }

    func openConversation(_ id: String, title: String) {
        isNewConversation = false
        selectedThreadID = id
        selectedConversationTitle = title
        Task { await refreshFiles() }
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
        didRequestProviders = false
    }

    private func sendCommand(
        type: RemoteCommandType,
        text: String = "",
        cwd: String? = nil,
        threadID: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        approvalRequestID: JSONValue? = nil
    ) async {
        guard isConnected else {
            errorMessage = "CloudKit 尚未连接"
            return
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
        } catch {
            errorMessage = error.localizedDescription
            print("CLOUDKIT_SEND_ERROR \(error)")
            appendDiagnostics("send_error \(error)")
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
            switchNotice = "已切换到 \(event.text)，账号和模型已自动匹配，继续使用原会话"
        }
        if event.title == "原会话已匹配" {
            if let threadID = event.threadID, !threadID.isEmpty {
                selectedThreadID = threadID
            }
            switchNotice = event.text
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
            currentModelName = event.text
            if !modelNames.contains(event.text) { modelNames.append(event.text) }
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
                return RemoteConversation(
                    id: id,
                    title: String(title.prefix(40)),
                    subtitle: String((preview.isEmpty ? model : preview).prefix(80)),
                    updatedAt: Date(timeIntervalSince1970: updatedMS / 1000),
                    messageCount: 0
                )
            }
        }
    }

    private static var deviceID: String {
        if let identifier = UIDevice.current.identifierForVendor?.uuidString {
            return "iphone-\(identifier)"
        }
        return "iphone"
    }
}
