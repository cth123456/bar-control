import Foundation

actor RemoteEventStore {
    private struct State: Codable {
        var nextSequence: Int64
        var processedCommandIDs: [UUID]
    }

    private let directoryURL: URL
    private let eventLogURL: URL
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: State
    private var cachedEvents: [RemoteEvent]
    private var continuations: [UUID: AsyncStream<RemoteEvent>.Continuation] = [:]

    init(baseDirectory: URL? = nil) {
        let manager = FileManager.default
        let directory = baseDirectory ?? manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BarControlRemote", isDirectory: true)
        directoryURL = directory
        eventLogURL = directory.appendingPathComponent("events.jsonl")
        stateURL = directory.appendingPathComponent("state.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder

        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        if
            let data = try? Data(contentsOf: stateURL),
            let saved = try? decoder.decode(State.self, from: data)
        {
            state = saved
        } else {
            state = State(nextSequence: 1, processedCommandIDs: [])
        }

        cachedEvents = Self.loadEvents(from: eventLogURL, decoder: decoder)
        if let last = cachedEvents.last, state.nextSequence <= last.sequence {
            state.nextSequence = last.sequence + 1
        }
    }

    func append(
        sessionID: String,
        kind: RemoteEventKind,
        title: String = "",
        text: String = "",
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String? = nil,
        rpcRequestID: JSONValue? = nil,
        metadata: [String: String] = [:]
    ) throws -> RemoteEvent {
        let event = RemoteEvent(
            sessionID: sessionID,
            sequence: state.nextSequence,
            kind: kind,
            title: title,
            text: text,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            rpcRequestID: rpcRequestID,
            metadata: metadata
        )
        state.nextSequence += 1
        let data = try encoder.encode(event)
        try appendLine(data, to: eventLogURL)
        cachedEvents.append(event)
        if cachedEvents.count > 2_000 {
            cachedEvents.removeFirst(cachedEvents.count - 2_000)
        }
        try persistState()
        for continuation in continuations.values {
            continuation.yield(event)
        }
        return event
    }

    func events(sessionID: String? = nil, after sequence: Int64 = 0, limit: Int = 500) -> [RemoteEvent] {
        let filtered = cachedEvents.filter { event in
            event.sequence > sequence && (sessionID == nil || event.sessionID == sessionID)
        }
        return Array(filtered.suffix(max(1, limit)))
    }

    func stream() -> AsyncStream<RemoteEvent> {
        let identifier = UUID()
        return AsyncStream { continuation in
            continuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(identifier) }
            }
        }
    }

    func hasProcessed(commandID: UUID) -> Bool {
        state.processedCommandIDs.contains(commandID)
    }

    func markProcessed(commandID: UUID) throws {
        guard !state.processedCommandIDs.contains(commandID) else { return }
        state.processedCommandIDs.append(commandID)
        if state.processedCommandIDs.count > 1_000 {
            state.processedCommandIDs.removeFirst(state.processedCommandIDs.count - 1_000)
        }
        try persistState()
    }

    func clearHistory() throws {
        cachedEvents.removeAll()
        state.nextSequence = 1
        try Data().write(to: eventLogURL, options: .atomic)
        try persistState()
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    private func persistState() throws {
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.synchronize()
    }

    private static func loadEvents(from url: URL, decoder: JSONDecoder) -> [RemoteEvent] {
        guard
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").suffix(2_000).compactMap { line in
            try? decoder.decode(RemoteEvent.self, from: Data(line.utf8))
        }
    }
}
