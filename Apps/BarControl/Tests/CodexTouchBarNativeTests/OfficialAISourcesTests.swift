import XCTest
@testable import CodexTouchBarNative

final class OfficialAISourcesTests: XCTestCase {
    private func jwt(payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let body = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(body).sig"
    }

    func testChatGPTPlanFromIDToken() {
        let token = jwt(payload: ["https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]])
        XCTAssertEqual(OfficialAISources.chatGPTPlan(fromIDToken: token), "Plus")
        let pro = jwt(payload: ["https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]])
        XCTAssertEqual(OfficialAISources.chatGPTPlan(fromIDToken: pro), "Pro")
        XCTAssertNil(OfficialAISources.chatGPTPlan(fromIDToken: "not-a-jwt"))
    }

    func testClaudePlanFromCredentials() throws {
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["subscriptionType": "max"]])
        XCTAssertEqual(OfficialAISources.claudePlan(fromCredentials: data), "Max")
        let pro = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["subscriptionType": "pro"]])
        XCTAssertEqual(OfficialAISources.claudePlan(fromCredentials: pro), "Pro")
        XCTAssertEqual(OfficialAISources.claudePlan(fromCredentials: Data("{}".utf8)), "已登录")
    }

    func testSummaryLineOnlyWhenAccountsExist() {
        XCTAssertNil(OfficialAISources.summaryLine(accounts: []))
        let line = OfficialAISources.summaryLine(accounts: [
            .init(name: "ChatGPT", plan: "Plus", detail: "Codex CLI 登录"),
            .init(name: "Claude", plan: "Max", detail: "Claude Code 登录")
        ])
        XCTAssertEqual(line, "ChatGPT Plus · Claude Max")
    }

    func testDetectDoesNotShowSecrets() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let token = jwt(payload: ["https://api.openai.com/auth": ["chatgpt_plan_type": "plus"], "email": "person@example.invalid"])
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": token, "access_token": "secret"]])
        try auth.write(to: tmp.appendingPathComponent(".codex/auth.json"))
        let accounts = OfficialAISources.detect(home: tmp)
        XCTAssertEqual(accounts.first?.plan, "Plus")
        XCTAssertFalse(accounts.map(\.detail).joined().contains("secret"))
        XCTAssertFalse(accounts.map(\.detail).joined().contains("person@"))
    }
}
