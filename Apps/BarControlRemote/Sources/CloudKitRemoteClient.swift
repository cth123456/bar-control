@preconcurrency import CloudKit
import Foundation

struct RemoteFileInfo: Identifiable, Equatable, Sendable {
    let id: String
    let threadID: String
    let turnID: String
    let sessionID: String
    let fileName: String
    let filePath: String
    let size: Int64
    let mimeType: String
    let createdAt: Date
}

actor CloudKitRemoteClient {
    enum ClientStatus: Equatable, Sendable {
        case connecting
        case ready
        case unavailable(String)

        var text: String {
            switch self {
            case .connecting: return "正在连接 Mac"
            case .ready: return "CloudKit 已连接"
            case .unavailable(let message): return message
            }
        }
    }

    private var container: CKContainer?
    private var database: CKDatabase?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var status: ClientStatus = .connecting

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func connect() async -> ClientStatus {
        guard Self.hasCloudKitEntitlement() else {
            status = .unavailable("当前安装包未包含 CloudKit 权限")
            return status
        }

        var lastError: Error?
        for attempt in 0..<5 {
            do {
                let container = container
                    ?? CKContainer(identifier: RemoteControlConstants.cloudContainerIdentifier)
                self.container = container
                database = container.privateCloudDatabase
                let account = try await container.accountStatus()
                guard account == .available else {
                    status = .unavailable(Self.accountStatusText(account))
                    return status
                }

                // Foreground polling is the source of truth. A push
                // subscription improves latency but must not block startup.
                do {
                    try await installEventSubscription()
                } catch {
                    print("CLOUDKIT_SUBSCRIPTION_WARNING \(error.localizedDescription)")
                }
                status = .ready
                return status
            } catch {
                lastError = error
                guard attempt < 4, Self.isRetryable(error) else { break }
                try? await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        status = .unavailable(Self.errorText(lastError))
        return status
    }

    func currentStatus() -> ClientStatus { status }

    func submit(_ command: RemoteCommand) async throws {
        guard status == .ready, let database else {
            throw NSError(
                domain: "BarControlRemote.CloudKit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: status.text]
            )
        }
        let recordID = CKRecord.ID(recordName: "command-\(command.id.uuidString.lowercased())")
        let record = CKRecord(recordType: RemoteControlConstants.commandRecordType, recordID: recordID)
        record["payload"] = try encoder.encode(command) as CKRecordValue
        record["createdAt"] = command.createdAt as CKRecordValue
        record["sourceDeviceID"] = command.sourceDeviceID as CKRecordValue
        do {
            _ = try await database.save(record)
        } catch {
            print("CLOUDKIT_SUBMIT_ERROR \(error)")
            throw error
        }
    }

    func fetchEvents() async throws -> [RemoteEvent] {
        guard status == .ready, let database else { return [] }
        let query = CKQuery(
            recordType: RemoteControlConstants.eventRecordType,
            predicate: NSPredicate(
                format: "createdAt >= %@",
                argumentArray: [Date(timeIntervalSince1970: 0)]
            )
        )
        var collected: [RemoteEvent] = []
        let first: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
        do {
            first = try await database.records(
                matching: query,
                desiredKeys: ["payload", "createdAt", "sequence", "sessionID"],
                resultsLimit: 200
            )
        } catch let error as CKError where error.code == .unknownItem {
            // A fresh development container has no RemoteEvent record type
            // until the Mac relay saves its first event. Treat it as empty.
            print("CLOUDKIT_FETCH_EMPTY unknownItem")
            return []
        }
        collected.append(contentsOf: decode(first.matchResults))
        var cursor = first.queryCursor
        var pageCount = 1
        while let current = cursor, pageCount < 20 {
            let page = try await database.records(
                continuingMatchFrom: current,
                desiredKeys: ["payload", "createdAt", "sequence", "sessionID"],
                resultsLimit: 200
            )
            collected.append(contentsOf: decode(page.matchResults))
            cursor = page.queryCursor
            pageCount += 1
        }
        return collected.sorted {
            if $0.sequence == $1.sequence { return $0.createdAt < $1.createdAt }
            return $0.sequence < $1.sequence
        }
    }

    func fetchFiles() async throws -> [RemoteFileInfo] {
        guard status == .ready, let database else { return [] }
        let query = CKQuery(
            recordType: RemoteControlConstants.fileRecordType,
            predicate: NSPredicate(
                format: "createdAt >= %@",
                argumentArray: [Date(timeIntervalSince1970: 0)]
            )
        )
        let keys = [
            "threadID", "turnID", "sessionID", "fileName",
            "filePath", "size", "mimeType", "createdAt"
        ]
        var collected: [RemoteFileInfo] = []
        do {
            let first = try await database.records(
                matching: query,
                desiredKeys: keys,
                resultsLimit: 200
            )
            collected.append(contentsOf: Self.decodeFiles(first.matchResults))
            var cursor = first.queryCursor
            while let current = cursor {
                let page = try await database.records(
                    continuingMatchFrom: current,
                    desiredKeys: keys,
                    resultsLimit: 200
                )
                collected.append(contentsOf: Self.decodeFiles(page.matchResults))
                cursor = page.queryCursor
            }
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
        return collected
    }

    func downloadFile(recordName: String) async throws -> Data {
        guard let database else {
            throw NSError(
                domain: "BarControlRemote.CloudKit",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "CloudKit 尚未连接"]
            )
        }
        let record = try await database.record(for: CKRecord.ID(recordName: recordName))
        guard let asset = record["content"] as? CKAsset,
              let fileURL = asset.fileURL
        else {
            throw NSError(
                domain: "BarControlRemote.CloudKit",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "文件内容缺失"]
            )
        }
        return try Data(contentsOf: fileURL)
    }

    private func decode(
        _ results: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) -> [RemoteEvent] {
        results.compactMap { _, result in
            guard
                let record = try? result.get(),
                let payload = record["payload"] as? Data
            else { return nil }
            return try? decoder.decode(RemoteEvent.self, from: payload)
        }
    }

    private static func decodeFiles(
        _ results: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) -> [RemoteFileInfo] {
        results.compactMap { _, result in
            guard
                let record = try? result.get(),
                let fileName = record["fileName"] as? String
            else { return nil }
            return RemoteFileInfo(
                id: record.recordID.recordName,
                threadID: record["threadID"] as? String ?? "",
                turnID: record["turnID"] as? String ?? "",
                sessionID: record["sessionID"] as? String ?? "",
                fileName: fileName,
                filePath: record["filePath"] as? String ?? "",
                size: (record["size"] as? NSNumber)?.int64Value ?? 0,
                mimeType: record["mimeType"] as? String ?? "application/octet-stream",
                createdAt: record["createdAt"] as? Date ?? Date()
            )
        }
    }

    private func installEventSubscription() async throws {
        guard let database else { return }
        let subscription = CKQuerySubscription(
            recordType: RemoteControlConstants.eventRecordType,
            predicate: NSPredicate(
                format: "createdAt >= %@",
                argumentArray: [Date(timeIntervalSince1970: 0)]
            ),
            subscriptionID: RemoteControlConstants.eventSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
        } catch let error as CKError where error.code == .unknownItem {
            // A fresh development container has no RemoteEvent record type
            // until the Mac saves its first event. Foreground polling still
            // works, and the subscription can be installed on a later launch.
            return
        } catch let error as CKError where error.localizedDescription.localizedCaseInsensitiveContains("already") {
            return
        }
    }

    private static func accountStatusText(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "iCloud 可用"
        case .noAccount: return "请先在 iPhone 登录 iCloud"
        case .restricted: return "iCloud 账户受限"
        case .couldNotDetermine: return "无法确认 iCloud 状态"
        case .temporarilyUnavailable: return "iCloud 暂时不可用"
        @unknown default: return "iCloud 状态未知"
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return [
            .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy
        ].contains(cloudError.code)
    }

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "CloudKit 连接失败" }
        if let cloudError = error as? CKError, cloudError.code == .networkUnavailable {
            return "CloudKit 网络不可用，请检查 Wi-Fi、蜂窝网络或代理"
        }
        return error.localizedDescription
    }

    private static func hasCloudKitEntitlement() -> Bool {
        #if targetEnvironment(simulator)
        // An unsigned simulator build is used for UI validation. Calling
        // CKContainer without entitlements is a process-terminating trap.
        return false
        #else
        // A physical-device build cannot be installed unless Xcode has signed
        // it with the entitlements declared by BarControlRemote.entitlements.
        return true
        #endif
    }
}
