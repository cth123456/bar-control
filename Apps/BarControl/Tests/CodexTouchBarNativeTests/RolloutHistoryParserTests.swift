import Foundation
import XCTest
@testable import CodexTouchBarNative

final class RolloutHistoryParserTests: XCTestCase {
    func testKeepsUserMessagesAndFinalAnswersOnly() throws {
        let records: [[String: Any]] = [
            message(
                role: "user",
                text: "<environment_context><cwd>/tmp</cwd></environment_context>",
                createdAt: 100
            ),
            message(
                role: "user",
                text: "# Attached document\nIgnore this\n\n## My request:\n修复手机同步",
                createdAt: 101
            ),
            message(
                role: "assistant",
                text: "正在检查日志",
                phase: "commentary",
                createdAt: 102
            ),
            message(
                role: "assistant",
                text: "同步已经修复",
                phase: "final_answer",
                createdAt: 103
            )
        ]
        let data = try records.map {
            try JSONSerialization.data(withJSONObject: $0)
        }.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-parser-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = RolloutHistoryParser.extractMessages(from: url)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"]?.stringValue, "user")
        XCTAssertEqual(messages[0]["text"]?.stringValue, "修复手机同步")
        XCTAssertEqual(messages[0]["ts"]?.int64Value, 101)
        XCTAssertEqual(messages[1]["role"]?.stringValue, "assistant")
        XCTAssertEqual(messages[1]["text"]?.stringValue, "同步已经修复")
        XCTAssertEqual(messages[1]["ts"]?.int64Value, 103)
    }

    private func message(
        role: String,
        text: String,
        phase: String? = nil,
        createdAt: Double
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "message",
            "role": role,
            "content": [[
                "type": role == "user" ? "input_text" : "output_text",
                "text": text
            ]],
            "internal_chat_message_metadata_passthrough": [
                "create_time": createdAt
            ]
        ]
        if let phase { payload["phase"] = phase }
        return [
            "type": "response_item",
            "payload": payload
        ]
    }
}
