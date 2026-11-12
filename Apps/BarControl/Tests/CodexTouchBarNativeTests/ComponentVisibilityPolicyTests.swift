import XCTest
@testable import CodexTouchBarNative

final class ComponentVisibilityPolicyTests: XCTestCase {
    func testHidingClearsEverySlotOfThatModule() {
        let slots: [MainComponent?] = [.sidecar, .aiCoding, nil, .clipboard, .keyboardLock, .systemMonitor]
        let next = ComponentVisibilityPolicy.applying(to: slots, component: .aiCoding, show: false)
        XCTAssertFalse(next.contains(.aiCoding))
        XCTAssertEqual(next[1], nil)
        XCTAssertEqual(next[0], .sidecar)
        XCTAssertEqual(next[3], .clipboard)
    }

    func testShowingFillsFirstEmptySlot() {
        let slots: [MainComponent?] = [.sidecar, nil, nil, .clipboard, .keyboardLock, .systemMonitor]
        let next = ComponentVisibilityPolicy.applying(to: slots, component: .aiCoding, show: true)
        XCTAssertEqual(next[1], .aiCoding)
        XCTAssertEqual(next[2], nil)
    }

    func testShowingWhenFullReplacesLastSlot() {
        let slots: [MainComponent?] = [.sidecar, .aiCoding, .clipboard, .keyboardLock, .systemMonitor, .systemMonitor]
        let next = ComponentVisibilityPolicy.applying(to: slots, component: .aiCoding, show: true)
        XCTAssertEqual(next.filter { $0 == .aiCoding }.count, 1, "已存在时不能重复插入")
        let full: [MainComponent?] = [.sidecar, .clipboard, .keyboardLock, .systemMonitor, .sidecar, .clipboard]
        let replaced = ComponentVisibilityPolicy.applying(to: full, component: .aiCoding, show: true)
        XCTAssertEqual(replaced[replaced.count - 1], .aiCoding)
    }

    func testIdempotentWhenAlreadyVisible() {
        let slots: [MainComponent?] = [.aiCoding, nil, nil, nil, nil, nil]
        XCTAssertEqual(ComponentVisibilityPolicy.applying(to: slots, component: .aiCoding, show: true), slots)
    }
}
