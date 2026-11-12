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

struct UsagePoint: Codable, Sendable {
    let timestamp: Double
    let primary: Double
    let secondary: Double?
}

struct UsageAccount: Codable, Sendable {
    let key: String
    let clientID: String
    let clientLabel: String
    let accountLabel: String
    let providerLabel: String
    let isCurrent: Bool
    let showByDefault: Bool?
    let iconID: String?
    let isOfficial: Bool
    let metricKind: String
    let remainingBalance: Double?
    let balanceUnit: String?
    let remainingPercent: Double?
    let secondaryRemainingPercent: Double?
    var primaryWindowLabel: String? = nil
    var secondaryWindowLabel: String? = nil
    var primaryResetAt: Double? = nil
    var secondaryResetAt: Double? = nil
    let todayCost: Double
    let monthCost: Double
    let todayRequests: Int
    let todayTokens: Int
    let cacheHitPercent: Double?
    let successPercent: Double?
    let modelLabel: String
    let metricsScope: String
    let chartTitle: String
    let chartUnit: String
    let latestAt: Double
    let history: [UsagePoint]

    enum CodingKeys: String, CodingKey {
        case key
        case clientID = "client_id"
        case clientLabel = "client_label"
        case accountLabel = "account_label"
        case providerLabel = "provider_label"
        case isCurrent = "is_current"
        case showByDefault = "show_by_default"
        case iconID = "icon_id"
        case isOfficial = "is_official"
        case metricKind = "metric_kind"
        case remainingBalance = "remaining_balance"
        case balanceUnit = "balance_unit"
        case remainingPercent = "remaining_percent"
        case secondaryRemainingPercent = "secondary_remaining_percent"
        case primaryWindowLabel = "primary_window_label"
        case secondaryWindowLabel = "secondary_window_label"
        case primaryResetAt = "primary_reset_at"
        case secondaryResetAt = "secondary_reset_at"
        case todayCost = "today_cost"
        case monthCost = "month_cost"
        case todayRequests = "today_requests"
        case todayTokens = "today_tokens"
        case cacheHitPercent = "cache_hit_percent"
        case successPercent = "success_percent"
        case modelLabel = "model_label"
        case metricsScope = "metrics_scope"
        case chartTitle = "chart_title"
        case chartUnit = "chart_unit"
        case latestAt = "latest_at"
        case history
    }
}

struct CodexSnapshot: Codable, Sendable {
    let label: String
    let state: String
    let activeCount: Int
    let activeThreads: [ActiveThread]
    let limits: RateLimits?
    let platforms: [PlatformUsage]?
    var accounts: [UsageAccount]? = nil

    enum CodingKeys: String, CodingKey {
        case label, state, limits, platforms, accounts
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

    init(helperURL: URL) {
        self.helperURL = helperURL
    }

    init() {
        let manager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("codex_touchbar.py"),
            manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexTouchBar/codex_touchbar.py")
        ].compactMap { $0 }
        helperURL = candidates.first { manager.isReadableFile(atPath: $0.path) }
    }

    func fetch(timeout: TimeInterval = 20) async -> CodexSnapshot {
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
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                defer { watchdog.cancel() }
                // Drain stdout while the helper runs: quota histories can exceed
                // the pipe buffer, blocking both writer and waitUntilExit().
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return .loading }
                return (try? JSONDecoder().decode(CodexSnapshot.self, from: data)) ?? .loading
            } catch {
                return .loading
            }
        }.value
    }
}
