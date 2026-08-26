import Foundation

/// 直接解析 Codex 会话落地文件（~/.codex/sessions/.../rollout-*.jsonl）提取对话正文。
/// 这是 Codex+ 等第三方会话管理器的主流做法：不依赖 app-server thread/read，
/// 因此不会遇到“活动写者挂起”或“paginated lineage”等问题。
enum RolloutHistoryParser {
    /// 提取用户/助手消息，按文件顺序输出 [{role, text, seq}]，保留最后 maxMessages 条。
    static func extractMessages(from url: URL, maxMessages: Int = 150) -> [JSONValue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var messages: [JSONValue] = []
        var seq = 0
        data.split(separator: 0x0A).forEach { lineData in
            guard
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                object["type"] as? String == "response_item",
                let payload = object["payload"] as? [String: Any],
                payload["type"] as? String == "message",
                let role = payload["role"] as? String,
                role == "user" || role == "assistant"
            else { return }
            let text = Self.text(from: payload["content"])
            guard !text.isEmpty else { return }
            let timestamp = (object["timestamp"] as? String)
                .flatMap { ISO8601DateFormatter().date(from: $0) }
                .map { $0.timeIntervalSince1970 } ?? 0
            messages.append(.object([
                "role": .string(role),
                "text": .string(String(text.prefix(4000))),
                "seq": .number(Double(seq)),
                "ts": .number(timestamp)
            ]))
            seq += 1
            if messages.count > maxMessages {
                messages.removeFirst(messages.count - maxMessages)
            }
        }
        return messages
    }

    private static func text(from content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            let text = block["text"] as? String ?? block["input_text"] as? String
            return text
        }.joined(separator: "\n")
    }
}
