import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .number(let value): return Int64(value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

enum RemoteEventKind: String, Codable, CaseIterable, Sendable {
    case connection
    case userInput
    case transcript
    case localIntent
    case actionStarted
    case actionProgress
    case providerChanged
    case agentMessageDelta
    case planDelta
    case reasoningSummaryDelta
    case commandOutputDelta
    case fileChange
    case toolActivity
    case approvalRequired
    case approvalResolved
    case turnStarted
    case turnCompleted
    case turnFailed
    case modelChanged
    case localAssistantMessage
    case warning
    case error
}

struct RemoteEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: String
    let sequence: Int64
    let createdAt: Date
    let kind: RemoteEventKind
    let title: String
    let text: String
    let threadID: String?
    let turnID: String?
    let itemID: String?
    let rpcRequestID: JSONValue?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        sessionID: String,
        sequence: Int64,
        createdAt: Date = Date(),
        kind: RemoteEventKind,
        title: String = "",
        text: String = "",
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String? = nil,
        rpcRequestID: JSONValue? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.text = text
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.rpcRequestID = rpcRequestID
        self.metadata = metadata
    }

    var isTerminal: Bool {
        kind == .turnCompleted || kind == .turnFailed || kind == .error
    }
}

enum RemoteCommandType: String, Codable, CaseIterable, Sendable {
    case prompt
    case localPrompt
    case steer
    case stop
    case approve
    case decline
    case switchProvider
    case switchModel
    case listProviders
    case listModels
    case listThreads
    case setPinned
    case loadThreadHistory
    case healthCheck
}

struct RemoteCommand: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceDeviceID: String
    let type: RemoteCommandType
    let text: String
    let cwd: String?
    let threadID: String?
    let providerID: String?
    let modelID: String?
    let approvalRequestID: JSONValue?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceDeviceID: String,
        type: RemoteCommandType,
        text: String = "",
        cwd: String? = nil,
        threadID: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        approvalRequestID: JSONValue? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceDeviceID = sourceDeviceID
        self.type = type
        self.text = text
        self.cwd = cwd
        self.threadID = threadID
        self.providerID = providerID
        self.modelID = modelID
        self.approvalRequestID = approvalRequestID
    }
}

struct RemoteProviderSummary: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: String?
    let isCurrent: Bool
}

struct RemoteModelSummary: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isCurrent: Bool
}

struct LocalIntent: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case prompt
        case steer
        case stop
        case switchProvider
        case listProviders
        case status
        case unknown
    }

    let action: Action
    let prompt: String?
    let providerName: String?
    let confidence: Double
    let explanation: String

    static func directPrompt(_ text: String) -> LocalIntent {
        LocalIntent(
            action: .prompt,
            prompt: text,
            providerName: nil,
            confidence: 1,
            explanation: "作为 Codex 指令发送"
        )
    }
}

enum RemoteControlConstants {
    static var cloudContainerIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "BarControlCloudKitContainerIdentifier") as? String ?? ""
    }
    static let localChatThreadID = "local-chat"
    static let commandRecordType = "RemoteCommand"
    static let eventRecordType = "RemoteEvent"
    static let fileRecordType = "RemoteFile"
    static let commandSubscriptionID = "bar-control-remote-commands-v1"
    static let eventSubscriptionID = "bar-control-remote-events-v1"
    #if os(macOS)
    static let defaultWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .path
    #else
    static let defaultWorkingDirectory = ""
    #endif
}
