import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class PowerAppUsageViewTests: XCTestCase {
    func testHelperExecutableMapsToOuterApp() {
        let path = "/Applications/Example.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/helper"
        XCTAssertEqual(PowerAppUsageView.appURL(executablePath: path)?.path, "/Applications/Example.app")
        XCTAssertNil(PowerAppUsageView.appURL(executablePath: "/usr/libexec/powerd"))
    }

    func testListKeepsTopThreeNamesIconsAndEstimatesReadable() {
        let list = PowerAppUsageView(frame: NSRect(x: 0, y: 0, width: 350, height: 88))
        list.update(samples: [
            .init(name: "A", billedWatts: 1.2),
            .init(name: "B", billedWatts: 2.8),
            .init(name: "C", billedWatts: 1.4),
            .init(name: "D", billedWatts: 0.1),
            .init(name: "invalid", billedWatts: .nan)
        ], ignoreThrottle: true)
        list.layoutSubtreeIfNeeded()
        let labels = list.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        let names = labels.filter { ["A", "B", "C", "D"].contains($0.stringValue) }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(names.map(\.stringValue), ["B", "C", "A"])
        let icons = list.subviews.compactMap { $0 as? NSImageView }.filter { !$0.isHidden }
        XCTAssertEqual(icons.count, 3)
        for icon in icons { XCTAssertNotNil(icon.image); XCTAssertEqual(icon.frame.width, 16) }
        for name in names {
            XCTAssertLessThanOrEqual(name.frame.maxX, 278)
            XCTAssertLessThanOrEqual(name.frame.maxY, list.bounds.height)
        }
        XCTAssertEqual(labels.filter { $0.stringValue.hasPrefix("≈") }.count, 3)
        // 衰减需要几帧才会真正移除（防抖动设计），连续低值后才清空。
        for _ in 0..<10 { list.update(samples: [], ignoreThrottle: true) } // 0.10 W 退出阈值下 2.8 W 需约 7 帧衰减才退出
        XCTAssertTrue(list.subviews.compactMap { $0 as? NSImageView }.allSatisfy(\.isHidden))
    }
    func testThrottledUpdateDoesNotResetDisplayClock() {
        let list = PowerAppUsageView(frame: NSRect(x: 0, y: 0, width: 350, height: 88))
        list.lastDisplayAt = .distantPast
        list.update(samples: [.init(name: "A", billedWatts: 2.0)], ignoreThrottle: false)
        let stamp = list.lastDisplayAt
        XCTAssertNotEqual(stamp, .distantPast)
        // 立刻再喂一次应被节流，且不能刷新时间戳——否则 2 秒周期喂数永远过不了 5 秒节流。
        list.update(samples: [.init(name: "B", billedWatts: 3.0)], ignoreThrottle: false)
        XCTAssertEqual(list.lastDisplayAt, stamp)
    }
    func testHighPowerThresholdRunsAfterAggregation() {
        let list = PowerAppUsageView(frame: NSRect(x: 0, y: 0, width: 350, height: 88))
        list.update(samples: [
            .init(name: "below", billedWatts: 0.19),
            .init(name: "boundary", billedWatts: 0.20),
            .init(name: "above", billedWatts: 0.21),
            .init(name: "combined", billedWatts: 0.12),
            .init(name: "combined", billedWatts: 0.12)
        ], ignoreThrottle: true)
        list.layoutSubtreeIfNeeded()
        let visible = list.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        XCTAssertTrue(visible.contains("above"))
        XCTAssertTrue(visible.contains("combined"), "Aggregate before filtering")
        XCTAssertFalse(visible.contains("below"))
        XCTAssertFalse(visible.contains("boundary"), "Strictly over the enter threshold")
        for _ in 0..<6 { list.update(samples: [.init(name: "low", billedWatts: 0.02)], ignoreThrottle: true) }
        XCTAssertTrue(list.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue == "暂无高功耗应用"
        })
    }

    func testListHeightTracksActualRowsAndCollapsesAfterFiltering() {
        let list = PowerAppUsageView(frame: NSRect(x: 0, y: 0, width: 350, height: 88))
        for count in 0...3 {
            list.update(samples: (0..<count).map { .init(name: "app\($0)", billedWatts: 2) }, ignoreThrottle: true)
            let expected: CGFloat = count == 0 ? 20 : 20 + CGFloat(count) * 22
            XCTAssertEqual(list.contentHeight, expected)
            list.setFrameSize(NSSize(width: 350, height: list.contentHeight))
            list.layoutSubtreeIfNeeded()
            for view in list.subviews where !view.isHidden {
                XCTAssertGreaterThanOrEqual(view.frame.minY, 0)
                XCTAssertLessThanOrEqual(view.frame.maxY, expected)
            }
        }
        for _ in 0..<6 { list.update(samples: [.init(name: "low", billedWatts: 0.02)], ignoreThrottle: true) }
        XCTAssertEqual(list.contentHeight, 20, "No reserved rows after high-power samples disappear")
    }

    func testBoundaryJitterDoesNotFlicker() {
        let list = PowerAppUsageView(frame: NSRect(x: 0, y: 0, width: 350, height: 88))
        func visibleNames() -> [String] {
            list.subviews.compactMap { $0 as? NSTextField }
                .filter { !$0.isHidden }
                .map(\.stringValue)
                .filter { $0 != "高功耗应用" && !$0.hasPrefix("≈") }
        }
        // 先让它稳定进入列表。
        for watts in [0.6, 0.5, 0.45, 0.4] {
            list.update(samples: [.init(name: "Browser", billedWatts: watts)], ignoreThrottle: true)
        }
        list.layoutSubtreeIfNeeded()
        XCTAssertTrue(visibleNames().contains("Browser"))
        // 在 1 W 上下抖动：平滑 + 迟滞保证 Browser 不会立刻消失。
        for watts in [0.22, 0.12, 0.21, 0.11, 0.20, 0.15, 0.23] {
            list.update(samples: [.init(name: "Browser", billedWatts: watts)], ignoreThrottle: true)
            XCTAssertTrue(list.testHookTrackedNames.contains("Browser"), "browser vanished from smoothing at \(watts) W")
        }
        // 持续低于退出阈值后才会消失。
        for _ in 0..<12 { list.update(samples: [.init(name: "Browser", billedWatts: 0.02)], ignoreThrottle: true) }
        XCTAssertFalse(visibleNames().contains("Browser"), "持续低功耗后应退出列表")
    }

    func testEmptySamplingFrameKeepsPreviousRowsInsteadOfBlinking() {
        let list = PowerAppUsageView(frame: NSRect(x: 0, y: 0, width: 350, height: 88))
        for _ in 0..<4 { list.update(samples: [.init(name: "Editor", billedWatts: 2.0)], ignoreThrottle: true) }
        XCTAssertTrue(list.subviews.compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "Editor" })
        // 单帧空采样（增量未就绪）不应把列表清空成“正在采样…”。
        list.update(samples: [])
        let visible = list.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        XCTAssertTrue(visible.contains("Editor"))
        XCTAssertFalse(visible.contains("正在采样…"))
    }

}
