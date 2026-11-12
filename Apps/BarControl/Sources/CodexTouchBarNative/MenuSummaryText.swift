import Foundation

enum MenuSummaryText {
    static func suppliers(accounts: [UsageAccount], platforms: [PlatformUsage] = []) -> String {
        let rows = supplierBadges(accounts: accounts, platforms: platforms).map { "\($0.title) \($0.value)" }
        if rows.isEmpty, let official = OfficialAISources.summaryLine(accounts: OfficialAISources.detect()) {
            return "本机官方订阅：\(official)"
        }
        return rows.isEmpty ? "暂无供应商数据" : rows.joined(separator: "\n")
    }

    static func supplierBadges(accounts: [UsageAccount], platforms: [PlatformUsage] = []) -> [MenuSummaryBadge] {
        var rows: [MenuSummaryBadge] = []
        var seen: Set<String> = []
        for account in accounts {
            let name = supplierName(account)
            let value = remaining(balance: account.remainingBalance, unit: account.balanceUnit,
                                  percent: account.remainingPercent)
            let row = "\(name) \(value)"
            // 同一个供应商的钱包可能被多个客户端重复引用，不重复列出，也不累加余额。
            if seen.insert(row).inserted {
                let low = account.remainingBalance.map { $0 < 0 }
                    ?? account.remainingPercent.map { $0 < 20 } ?? false
                rows.append(MenuSummaryBadge(
                    title: name, value: value, symbol: "creditcard", tone: low ? .orange : .blue,
                    progress: account.remainingBalance == nil ? account.remainingPercent.map { $0 / 100 } : nil,
                    iconID: account.iconID, clientID: account.clientID,
                    action: account.clientID == "magpie" ? .openUsage(account.key) : .openAIDetails
                ))
            }
        }
        if accounts.isEmpty {
            for platform in platforms {
                let row = "\(platform.provider) \(remaining(balance: platform.remainingBalance, unit: platform.balanceUnit, percent: nil))"
                if seen.insert(row).inserted {
                    rows.append(MenuSummaryBadge(title: platform.provider,
                                                  value: remaining(balance: platform.remainingBalance, unit: platform.balanceUnit, percent: nil),
                                                  symbol: "creditcard", clientID: platform.id))
                }
            }
        }
        return rows
    }

    private static func supplierName(_ account: UsageAccount) -> String {
        let name = account.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = account.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("·"), let prefix = name.components(separatedBy: "·").first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            let plans = ["plus", "pro", "free", "team", "enterprise", "max"]
            return plans.contains(provider.lowercased()) ? "\(prefix) \(provider.capitalized)" : prefix
        }
        if ["", "当前账户", "当前账号", "API"].contains(name) || name.contains("@") {
            return provider.isEmpty ? account.clientLabel : provider
        }
        return name
    }

    static func sidecar(state: String, message: String, connectedDevices: [String]?) -> String {
        if state == "connecting" { return "随航连接中…" }
        guard let connectedDevices else {
            return state == "failure" ? message : "正在读取随航状态…"
        }
        if !connectedDevices.isEmpty { return "已连接 · " + connectedDevices.joined(separator: "、") }
        return state == "failure" ? "未连接 · \(message)" : "随航未连接"
    }

    private static func remaining(balance: Double?, unit: String?, percent: Double?) -> String {
        if let balance { return usageMoney(balance, unit: unit) }
        if let percent { return String(format: "余 %.0f%%", percent) }
        return "余额未读取"
    }
}
