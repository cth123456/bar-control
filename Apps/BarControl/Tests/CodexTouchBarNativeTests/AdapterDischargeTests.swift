import XCTest
@testable import CodexTouchBarNative

@MainActor
final class AdapterDischargeTests: XCTestCase {
    func testKeepCutOnlyForDischargingPolicy() {
        XCTAssertTrue(
            AdapterDischargeController.shouldKeepCut(
                policy: .discharging,
                macBatteryPercent: 80
            )
        )
        XCTAssertFalse(
            AdapterDischargeController.shouldKeepCut(
                policy: .balanced,
                macBatteryPercent: 80
            )
        )
        XCTAssertFalse(
            AdapterDischargeController.shouldKeepCut(
                policy: .charging,
                macBatteryPercent: 80
            )
        )
    }

    func testKeepCutStopsBelowTwentyPercent() {
        XCTAssertFalse(
            AdapterDischargeController.shouldKeepCut(
                policy: .discharging,
                macBatteryPercent: 19
            )
        )
        XCTAssertTrue(
            AdapterDischargeController.shouldKeepCut(
                policy: .discharging,
                macBatteryPercent: 20
            )
        )
        // Unknown battery stays permissive: the metrics loop restores as
        // soon as a real low reading arrives.
        XCTAssertTrue(
            AdapterDischargeController.shouldKeepCut(
                policy: .discharging,
                macBatteryPercent: nil
            )
        )
    }

    func testHelperPathIsAbsolute() {
        XCTAssertTrue(AdapterDischargeController.helperPath.hasPrefix("/Library/"))
    }
}
