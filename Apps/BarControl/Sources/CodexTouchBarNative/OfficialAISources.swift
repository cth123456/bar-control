import Foundation

/// 本机官方 AI 客户端（Codex / Claude / Gemini / Copilot）的登录信息。
/// 只读本地凭据文件，不联网、不显示邮箱或令牌；用于在没有中转服务时
/// 至少告诉用户「装了哪些官方订阅」，而不是一片“暂无数据”。
struct OfficialAIAccount: Equatable, Sendable {
    let name: String
    let plan: String
    let detail: String
}

enum OfficialAISources {
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [OfficialAIAccount] {
        var result: [OfficialAIAccount] = []
        let fm = FileManager.default

        let codexAuth = home.appendingPathComponent(".codex/auth.json")
        if let data = try? Data(contentsOf: codexAuth),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String,
           let plan = chatGPTPlan(fromIDToken: idToken) {
            result.append(OfficialAIAccount(name: "ChatGPT", plan: plan, detail: "Codex CLI 登录"))
        }

        let claudeCreds = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: claudeCreds),
           let plan = claudePlan(fromCredentials: data) {
            result.append(OfficialAIAccount(name: "Claude", plan: plan, detail: "Claude Code 登录"))
        }

        if fm.fileExists(atPath: home.appendingPathComponent(".gemini/oauth_creds.json").path) {
            result.append(OfficialAIAccount(name: "Gemini", plan: "已登录", detail: "Gemini CLI"))
        }
        if fm.fileExists(atPath: home.appendingPathComponent(".config/github-copilot/hosts.json").path)
            || fm.fileExists(atPath: home.appendingPathComponent(".copilot/config.json").path) {
            result.append(OfficialAIAccount(name: "GitHub Copilot", plan: "已登录", detail: "Copilot 客户端"))
        }
        return result
    }

    /// id_token 的载荷里带 chatgpt_plan_type，本地解码即可，不需要联网。
    static func chatGPTPlan(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        let raw = (auth?["chatgpt_plan_type"] as? String) ?? (json["chatgpt_plan_type"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    static func claudePlan(fromCredentials data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = json["claudeAiOauth"] as? [String: Any] ?? json
        let raw = (oauth["subscriptionType"] as? String)
            ?? (oauth["rateLimitTier"] as? String)
            ?? ""
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "": return "已登录"
        default: return raw.capitalized
        }
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    /// 菜单摘要回退文案：没有中转余额时列出官方订阅。
    static func summaryLine(accounts: [OfficialAIAccount]) -> String? {
        guard !accounts.isEmpty else { return nil }
        return accounts.map { "\($0.name) \($0.plan)" }.joined(separator: " · ")
    }
}
