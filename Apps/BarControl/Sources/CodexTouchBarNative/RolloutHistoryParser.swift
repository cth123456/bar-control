import Foundation

/// 直接解析 Codex 会话落地文件（~/.codex/sessions/.../rollout-*.jsonl）提取对话正文。
/// 这是 Codex+ 等第三方会话管理器的主流做法：不依赖 app-server thread/read，
/// 因此不会遇到“活动写者挂起”或“paginated lineage”等问题。
enum RolloutHistoryParser {
    /// 提取用户/助手消息，按文件顺序输出 [{role, text, seq}]，保留最后 maxMessages 条。
    static func extractMessages(from url: URL, maxMessages: Int = 50) -> [JSONValue] {
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
            // A Codex rollout stores every commentary update as an assistant
            // message. History should show the durable final answer; live
            // progress/reasoning already arrives through dedicated events.
            if role == "assistant", payload["phase"] as? String != "final_answer" {
                return
            }
            let text = Self.cleanedText(
                Self.text(from: payload["content"]),
                role: role
            )
            guard !text.isEmpty else { return }
            let timestamp = (
                (payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["create_time"]
                    as? NSNumber
            )?.doubleValue ?? Self.timestamp(from: object["timestamp"] as? String)
            messages.append(.object([
                "role": .string(role),
                "text": .string(String(text.prefix(2400))),
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

    private static func cleanedText(_ value: String, role: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user" else { return text }

        if let marker = text.range(of: "## My request:") {
            text = String(text[marker.upperBound...])
        }
        let injectedBlocks = [
            #"<environment_context>[\s\S]*?</environment_context>"#,
            #"<skills_instructions>[\s\S]*?</skills_instructions>"#,
            #"<turn_aborted>[\s\S]*?</turn_aborted>"#
        ]
        for pattern in injectedBlocks {
            text = text.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        if text.hasPrefix("# AGENTS.md instructions") && !text.contains("## My request:") {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(from value: String?) -> Double {
        guard let value else { return 0 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date.timeIntervalSince1970
        }
        return ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? 0
    }

    private static func text(from content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            let text = block["text"] as? String ?? block["input_text"] as? String
            return text
        }.joined(separator: "\n")
    }
}
