import Foundation
import XCTest
@testable import CodexTouchBarNative

final class CodexStatusClientTests: XCTestCase {
    func testLargeSnapshotsKeepRefreshingThroughCompletionAndIdle() async throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: helper) }
        let client = CodexStatusClient(helperURL: helper)
        for (state, count) in [("running", 1), ("completed", 0), ("idle", 0)] {
            try writeHelper(helper, state: state, count: count)
            let snapshot = await client.fetch(timeout: 5)
            XCTAssertEqual(snapshot.state, state)
            XCTAssertEqual(snapshot.activeCount, count)
            // Far larger than the macOS pipe buffer: wait-before-read deadlocks.
            XCTAssertEqual(snapshot.label.count, 512 * 1024)
        }
    }

    func testTimeoutAllowsTheNextRefreshToSucceed() async throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: helper) }
        try "import time\ntime.sleep(30)\n".write(to: helper, atomically: true, encoding: .utf8)
        let client = CodexStatusClient(helperURL: helper)
        let started = Date()
        let timedOut = await client.fetch(timeout: 0.3)
        XCTAssertEqual(timedOut.label, CodexSnapshot.loading.label)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try writeHelper(helper, state: "idle", count: 0)
        let recovered = await client.fetch(timeout: 5)
        XCTAssertEqual(recovered.state, "idle")
    }

    private func writeHelper(_ url: URL, state: String, count: Int) throws {
        let script = """
        import json
        print(json.dumps({"label": "x" * (512 * 1024), "state": "\(state)",
                          "active_count": \(count), "active_threads": [],
                          "limits": None, "platforms": [], "accounts": []}))
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
    }
}
