import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class WindowActionRowInteractionTests: XCTestCase {
    private final class Target: NSObject {
        var fired = false
        @objc func fire() { fired = true }
    }

    func testClicksOnLabelsReachTheRowAndFireTheAction() {
        let target = Target()
        let row = WindowActionRow(
            frame: NSRect(x: 0, y: 0, width: 400, height: 50),
            title: "在触控栏常驻显示模块",
            subtitle: "启动、唤醒后自动恢复模块栏",
            symbol: "pin.circle",
            value: "关",
            target: target,
            action: #selector(Target.fire)
        )
        row.layoutSubtreeIfNeeded()

        // 标题文字、副标题、右侧状态文字的位置都必须命中行本身，而不是标签。
        for point in [NSPoint(x: 60, y: 20), NSPoint(x: 70, y: 34), NSPoint(x: 370, y: 25)] {
            XCTAssertTrue(row.hitTest(point) === row, "point \(point) should hit the row")
        }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        XCTAssertNotNil(event)
        row.mouseDown(with: event!)
        XCTAssertTrue(target.fired)
    }
}
