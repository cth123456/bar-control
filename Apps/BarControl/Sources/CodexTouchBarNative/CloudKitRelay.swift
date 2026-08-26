@preconcurrency import CloudKit
import Foundation
import Security

enum RelayFileLog {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarControlRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("relay.log")
    }()

    static func append(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}

actor CloudKitRelay {
    enum RelayStatus: Equatable, Sendable {
        case stopped
        case connecting
        case ready
        case retrying(String)
        case unavailable(String)

        var label: String {
            switch self {
            case .stopped: return "未启动"
            case .connecting: return "正在连接 iCloud"
            case .ready: return "CloudKit 已连接"
            case .retrying(let message): return "iCloud 重试中 · \(message)"
            case .unavailable(let message): return "仅本机 · \(message)"
            }
        }
    }

    private var container: CKContainer?
    private var database: CKDatabase?
    private let eventStore: RemoteEventStore
    private var status: RelayStatus = .stopped
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingEvents: [RemoteEvent] = []
    private var commandHandler: (@Sendable (RemoteCommand) async -> Void)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(eventStore: RemoteEventStore) {
        self.eventStore = eventStore
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func currentStatus() -> RelayStatus { status }

    func start(commandHandler: @escaping @Sendable (RemoteCommand) async -> Void) async {
        guard eventTask == nil else { return }
        self.commandHandler = commandHandler
        status = .connecting
        RelayFileLog.append("start: connecting")

        guard Self.hasCloudKitEntitlement() else {
            status = .unavailable("当前签名未包含 CloudKit 权限")
            RelayFileLog.append("start: no CloudKit entitlement")
            startLocalEventForwarding()
            return
        }

        do {
            let container = CKContainer(identifier: RemoteControlConstants.cloudContainerIdentifier)
            self.container = container
            database = container.privateCloudDatabase
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .unavailable(Self.accountStatusLabel(accountStatus))
                RelayFileLog.append("start: account unavailable \(accountStatus.rawValue)")
                startLocalEventForwarding()
                return
            }
            status = .ready
            RelayFileLog.append("start: ready")
        } catch {
            status = .unavailable(error.localizedDescription)
            RelayFileLog.append("start: error \(error)")
        }

        startLocalEventForwarding()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchCommands()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        pollTask?.cancel()
        flushTask?.cancel()
        eventTask = nil
        pollTask = nil
        flushTask = nil
        commandHandler = nil
        pendingEvents.removeAll()
        status = .stopped
    }

    func notificationDidArrive() async {
        await fetchCommands()
    }

    func uploadFiles(paths: [String], event: RemoteEvent) async {
        guard canRelay, let database else { return }
        let manager = FileManager.default
        for path in paths.prefix(20) {
            let url = URL(fileURLWithPath: path)
            guard manager.fileExists(atPath: path),
                  let attributes = try? manager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int,
                  size > 0, size <= 25_000_000,
                  let fileName = url.lastPathComponent.removingPercentEncoding,
                  !fileName.isEmpty
            else {
                RelayFileLog.append("file: skip \(path)")
                continue
            }

            let safeName = fileName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let recordName = "file-\(event.sessionID)-\(event.turnID ?? "x")-\(safeName)"
            let recordID = CKRecord.ID(recordName: recordName)
            let record = CKRecord(recordType: RemoteControlConstants.fileRecordType, recordID: recordID)
            record["threadID"] = event.threadID ?? ""
            record["turnID"] = event.turnID ?? ""
            record["sessionID"] = event.sessionID
            record["fileName"] = fileName
            record["filePath"] = path
            record["size"] = NSNumber(value: size)
            record["mimeType"] = Self.mimeType(forPath: path)
            record["createdAt"] = event.createdAt as CKRecordValue
            record["content"] = CKAsset(fileURL: url)

            do {
                _ = try await database.save(record)
                RelayFileLog.append("file: uploaded \(fileName) (\(size) bytes)")
            } catch {
                RelayFileLog.append("file: upload error \(path) \(error)")
            }
        }
    }

    private func startLocalEventForwarding() {
        eventTask = Task { [weak self, eventStore] in
            let stream = await eventStore.stream()
            for await event in stream {
                await self?.enqueue(event)
            }
        }
    }

    private func enqueue(_ event: RemoteEvent) {
        guard canRelay else { return }
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            await self?.flushEvents()
        }
    }

    private func flushEvents() async {
        flushTask = nil
        guard canRelay, let database, !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)

        do {
            let records = try events.map(makeEventRecord)
            _ = try await database.modifyRecords(saving: records, deleting: [])
            status = .ready
            RelayFileLog.append("flush: saved \(records.count) events")
        } catch {
            pendingEvents.insert(contentsOf: events, at: 0)
            if pendingEvents.count > 500 {
                pendingEvents.removeFirst(pendingEvents.count - 500)
            }
            status = .retrying(error.localizedDescription)
            RelayFileLog.append("flush: error \(error)")
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.flushEvents()
            }
        }
    }

    private func fetchCommands() async {
        guard canRelay, let database, let commandHandler else { return }
        do {
            let query = CKQuery(
                recordType: RemoteControlConstants.commandRecordType,
                predicate: NSPredicate(
                    format: "createdAt >= %@",
                    argumentArray: [Date(timeIntervalSince1970: 0)]
                )
            )
            let result = try await database.records(
                matching: query,
                desiredKeys: ["payload", "createdAt"],
                resultsLimit: 100
            )
            var commands: [(CKRecord.ID, RemoteCommand)] = []
            for (recordID, recordResult) in result.matchResults {
                guard
                    let record = try? recordResult.get(),
                    let payload = record["payload"] as? Data,
                    let command = try? decoder.decode(RemoteCommand.self, from: payload)
                else { continue }
                commands.append((recordID, command))
            }
            commands.sort { $0.1.createdAt < $1.1.createdAt }
            if !commands.isEmpty {
                RelayFileLog.append("poll: found \(commands.count) commands")
            }

            var consumedRecordIDs: [CKRecord.ID] = []
            for (recordID, command) in commands {
                if await eventStore.hasProcessed(commandID: command.id) {
                    consumedRecordIDs.append(recordID)
                    continue
                }
                await commandHandler(command)
                try? await eventStore.markProcessed(commandID: command.id)
                consumedRecordIDs.append(recordID)
                RelayFileLog.append("poll: processed \(command.type.rawValue) id=\(command.id.uuidString)")
            }
            if !consumedRecordIDs.isEmpty {
                _ = try await database.modifyRecords(saving: [], deleting: consumedRecordIDs)
            }
            status = .ready
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                RelayFileLog.append("poll: unknownItem")
                return
            }
            status = .retrying(error.localizedDescription)
            RelayFileLog.append("poll: error \(error)")
        }
    }

    private func makeEventRecord(_ event: RemoteEvent) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: "event-\(event.id.uuidString.lowercased())")
        let record = CKRecord(recordType: RemoteControlConstants.eventRecordType, recordID: recordID)
        record["payload"] = try encoder.encode(event) as CKRecordValue
        record["createdAt"] = event.createdAt as CKRecordValue
        record["sequence"] = NSNumber(value: event.sequence)
        record["sessionID"] = event.sessionID as CKRecordValue
        return record
    }

    private static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "txt", "log": return "text/plain"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "swift": return "text/x-swift"
        case "py": return "text/x-python"
        case "js", "mjs", "cjs": return "text/javascript"
        case "ts": return "text/typescript"
        case "jsx": return "text/jsx"
        case "tsx": return "text/tsx"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private static func accountStatusLabel(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "可用"
        case .noAccount: return "未登录 iCloud"
        case .restricted: return "iCloud 受限"
        case .couldNotDetermine: return "无法确定 iCloud 状态"
        case .temporarilyUnavailable: return "iCloud 暂时不可用"
        @unknown default: return "iCloud 状态未知"
        }
    }

    private var canRelay: Bool {
        switch status {
        case .ready, .retrying: return true
        case .stopped, .connecting, .unavailable: return false
        }
    }

    private static func hasCloudKitEntitlement() -> Bool {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let services = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
            ) as? [String],
            services.contains("CloudKit"),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
            ) as? [String]
        else { return false }
        return value.contains(RemoteControlConstants.cloudContainerIdentifier)
    }
}
