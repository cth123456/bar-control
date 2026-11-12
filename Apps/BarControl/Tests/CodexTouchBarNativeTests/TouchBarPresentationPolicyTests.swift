import XCTest
@testable import CodexTouchBarNative

final class TouchBarPresentationPolicyTests: XCTestCase {
    func testLaunchAndWakeFollowOnlyThePersistentSwitch() {
        XCTAssertTrue(TouchBarPresentationPolicy.shouldPresentAtLaunch(persistent: true))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldPresentAtLaunch(persistent: false))
        XCTAssertTrue(TouchBarPresentationPolicy.shouldRestoreAfterWake(persistent: true))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldRestoreAfterWake(persistent: false))
    }

    func testSelfHealNeverStealsAnotherAppsTouchBar() {
        XCTAssertTrue(TouchBarPresentationPolicy.shouldSelfHeal(persistent: true, yieldingToApp: false))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldSelfHeal(persistent: true, yieldingToApp: true))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldSelfHeal(persistent: false, yieldingToApp: false))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldSelfHeal(persistent: false, yieldingToApp: true))
    }

    func testNativeModeRepairRequiresOurBarToBeIntendedVisible() {
        XCTAssertTrue(TouchBarPresentationPolicy.shouldRepairNativeMode(mainBarShown: true, yieldingToApp: false))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldRepairNativeMode(mainBarShown: false, yieldingToApp: false))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldRepairNativeMode(mainBarShown: true, yieldingToApp: true))
    }

    func testAutoExpandOnlyWhenTouchBarIsFree() {
        XCTAssertTrue(TouchBarPresentationPolicy.shouldAutoExpand(
            persistent: true, yieldingToApp: false, systemOwnsTouchBar: false
        ))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldAutoExpand(
            persistent: true, yieldingToApp: true, systemOwnsTouchBar: false
        ))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldAutoExpand(
            persistent: true, yieldingToApp: false, systemOwnsTouchBar: true
        ))
        XCTAssertFalse(TouchBarPresentationPolicy.shouldAutoExpand(
            persistent: false, yieldingToApp: false, systemOwnsTouchBar: false
        ))
    }
}
