import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class PowerRunnerDisplayTests: XCTestCase {
    func testTintColorKeepsGreenTealOrangeRedLadder() {
        func name(_ color: NSColor) -> String {
            color == .systemGreen ? "green"
                : color == .systemTeal ? "teal"
                : color == .systemOrange ? "orange"
                : color == .systemRed ? "red"
                : "other"
        }
        // 读取失败时中性灰。
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: nil)), "other")
        // 边界：24.9/25.0、49.9/50.0、74.9/75.0 必须跨档。
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 10)), "green")
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 24.9)), "green")
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 25.0)), "teal")
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 49.9)), "teal")
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 50.0)), "orange")
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 74.9)), "orange")
        XCTAssertEqual(name(PowerRunnerButton.tintColor(for: 75.0)), "red")
    }

    func testAnimationSpeedIsLinearAndCapped() {
        XCTAssertEqual(PowerRunnerButton.framesPerSecond(for: nil), 2)
        XCTAssertEqual(PowerRunnerButton.framesPerSecond(for: 0), 2)
        XCTAssertEqual(PowerRunnerButton.framesPerSecond(for: 6), 3)
        XCTAssertEqual(PowerRunnerButton.framesPerSecond(for: 42), 9)
        XCTAssertEqual(PowerRunnerButton.framesPerSecond(for: 72), 14)
        XCTAssertEqual(PowerRunnerButton.framesPerSecond(for: 100), 14, "封顶 14 fps")
    }

    func testLocalComputerWattsExcludesExternalOutput() {
        let breakdown = SystemMetrics.previewLocalAndExternalBreakdown
        // 预置样例：整机 20.8W，外设 3.1W → 本机 17.7W。
        XCTAssertEqual(breakdown.localComputerWatts ?? -1, 17.7, accuracy: 0.001)
    }
}
