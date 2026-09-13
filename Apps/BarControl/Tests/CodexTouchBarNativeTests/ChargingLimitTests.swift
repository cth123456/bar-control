import XCTest
@testable import CodexTouchBarNative

final class ChargingLimitTests: XCTestCase {
    func testChargingPolicyAllowsFullCharge() {
        XCTAssertEqual(
            PowerFlowPolicy.charging.chargingLimitDecision(
                macBatteryPercent: 80,
                externalBatteryPercent: 10
            ),
            .allowFullCharge
        )
    }

    func testDischargingPolicyHoldsAtMinimum() {
        XCTAssertEqual(
            PowerFlowPolicy.discharging.chargingLimitDecision(
                macBatteryPercent: 90,
                externalBatteryPercent: 90
            ),
            .hold(percent: 80)
        )
    }

    func testBalancedHoldsWhenBothDevicesAreHealthy() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 80,
                externalBatteryPercent: 65
            ),
            .hold(percent: 80)
        )
    }

    func testBalancedChargesWhenMacIsBelowTwentyPercent() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 19,
                externalBatteryPercent: 80
            ),
            .allowFullCharge
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 19,
                externalBatteryPercent: 19
            ),
            .allowFullCharge
        )
    }

    func testBalancedHoldsWhenExternalBatteryIsLowButUnreadable() {
        // Below 80% the firmware charges regardless, so the hold value does
        // not need to change when the external device cannot be read.
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 19,
                externalBatteryPercent: nil
            ),
            .allowFullCharge
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 80,
                externalBatteryPercent: nil
            ),
            .hold(percent: 80)
        )
    }

    func testDecisionLimitPercentMatchesConstants() {
        XCTAssertEqual(ChargingLimitDecision.allowFullCharge.limitPercent, 100)
        XCTAssertEqual(ChargingLimitDecision.hold(percent: 80).limitPercent, 80)
    }

    @MainActor
    func testControllerReadsSnapshotWithoutCrashing() {
        let controller = ChargingLimitController.shared
        controller.refreshSnapshot()
        let summary = controller.summaryText
        XCTAssertFalse(summary.isEmpty)
        if !controller.snapshot.isSupported {
            XCTAssertEqual(summary, "不支持控制")
        }
    }
}
