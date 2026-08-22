import Foundation

struct ActiveThread: Codable, Sendable {
    let id: String?
    let title: String
    let cwd: String
}

struct LimitWindow: Codable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    var remainingPercent: Double? {
        usedPercent.map { max(0, min(100, 100 - $0)) }
    }

    var shortLabel: String {
        guard let minutes = windowMinutes else { return "额度" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080 * 7)d" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct RateLimits: Codable, Sendable {
    let primary: LimitWindow?
    let secondary: LimitWindow?

    var ordered: [LimitWindow] {
        [primary, secondary].compactMap { $0 }
    }
}

struct PlatformUsage: Codable, Sendable {
    let id: String
    let label: String
    let provider: String
    let todayCost: Double
    let monthCost: Double
    let todayRequests: Int
    let todayTokens: Int
    let dailyLimit: Double?
    let monthlyLimit: Double?
    let latestAt: Double
    let remainingBalance: Double?
    let balanceUnit: String?

    enum CodingKeys: String, CodingKey {
        case id, label, provider
        case todayCost = "today_cost"
        case monthCost = "month_cost"
        case todayRequests = "today_requests"
        case todayTokens = "today_tokens"
        case dailyLimit = "daily_limit"
        case monthlyLimit = "monthly_limit"
        case latestAt = "latest_at"
        case remainingBalance = "remaining_balance"
        case balanceUnit = "balance_unit"
    }
}

struct CodexSnapshot: Codable, Sendable {
    let label: String
    let state: String
    let activeCount: Int
    let activeThreads: [ActiveThread]
    let limits: RateLimits?
    let platforms: [PlatformUsage]?

    enum CodingKeys: String, CodingKey {
        case label, state, limits, platforms
        case activeCount = "active_count"
        case activeThreads = "active_threads"
    }

    static let loading = CodexSnapshot(
        label: "正在读取 Codex",
        state: "idle",
        activeCount: 0,
        activeThreads: [],
        limits: nil,
        platforms: nil
    )
}

struct CodexStatusClient: Sendable {
    let helperURL: URL?

    init() {
        let manager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("codex_touchbar.py"),
            manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexTouchBar/codex_touchbar.py")
        ].compactMap { $0 }
        helperURL = candidates.first { manager.isReadableFile(atPath: $0.path) }
    }

    func fetch() async -> CodexSnapshot {
        guard let helperURL else { return .loading }
        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [helperURL.path, "status", "--json"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return .loading }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return (try? JSONDecoder().decode(CodexSnapshot.self, from: data)) ?? .loading
            } catch {
                return .loading
            }
        }.value
    }
}
