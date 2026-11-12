import XCTest
@testable import CodexTouchBarNative

final class TouchBarBrightnessPolicyTests: XCTestCase {
    func testPhysicalBrightnessFloorAndIdleTransitionRespectQuantization() {
        XCTAssertTrue(TouchBarBrightnessPolicy.shouldAdjust(current: 0, target: 1, targetChanged: false))
        XCTAssertFalse(TouchBarBrightnessPolicy.shouldAdjust(current: 0.991, target: 1, targetChanged: false))
        XCTAssertTrue(TouchBarBrightnessPolicy.shouldAdjust(current: 0.991, target: 0.8, targetChanged: true))
        XCTAssertFalse(TouchBarBrightnessPolicy.shouldAdjust(current: 0.991, target: 0.8, targetChanged: false))
        XCTAssertFalse(TouchBarBrightnessPolicy.shouldAdjust(current: -1, target: 1, targetChanged: true))
        XCTAssertFalse(TouchBarBrightnessPolicy.shouldAdjust(current: .nan, target: 1, targetChanged: true))
        XCTAssertFalse(TouchBarBrightnessPolicy.shouldAdjust(current: 0, target: 1.1, targetChanged: true))
    }

    func testTypingAndMouseUsePreventDimmingWithoutTouchingAModule() {
        XCTAssertFalse(TouchBarBrightnessPolicy.isIdle(touchBarIdle: 300, macIdle: 0.1, delay: 15))
        XCTAssertFalse(TouchBarBrightnessPolicy.isIdle(touchBarIdle: 300, macIdle: 14.9, delay: 15))
        XCTAssertTrue(TouchBarBrightnessPolicy.isIdle(touchBarIdle: 300, macIdle: 15, delay: 15))
    }

    func testTouchBarDetailsAndScrollingKeepItBrightWhileMacInputIsIdle() {
        XCTAssertFalse(TouchBarBrightnessPolicy.isIdle(touchBarIdle: 0, macIdle: 300, delay: 15))
        XCTAssertTrue(TouchBarBrightnessPolicy.isIdle(touchBarIdle: 15, macIdle: 300, delay: 15))
        XCTAssertTrue(TouchBarBrightnessPolicy.isIdle(touchBarIdle: 30, macIdle: .infinity, delay: 15))
    }
}
