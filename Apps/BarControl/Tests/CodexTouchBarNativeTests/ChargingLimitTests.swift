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

    func testDischargingStopsChargingAtCurrentLevel() {
        // 优先放电 = 保持适配器供电、停止给电池充电：上限压到当前电量。
        XCTAssertEqual(
            PowerFlowPolicy.discharging.chargingLimitDecision(
                macBatteryPercent: 92,
                externalBatteryPercent: 90
            ),
            .hold(percent: 92)
        )
        // 低于固件下限时只能保持 80%。
        XCTAssertEqual(
            PowerFlowPolicy.discharging.chargingLimitDecision(
                macBatteryPercent: 55,
                externalBatteryPercent: 90
            ),
            .hold(percent: 80)
        )
    }

    func testSailingKeepsBatteryInsideBand() {
        // 达到上限：停在上限不再充。
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 91, externalBatteryPercent: 60, balancedLower: 80, balancedUpper: 90
            ),
            .hold(percent: 90)
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 90, externalBatteryPercent: 60, balancedLower: 80, balancedUpper: 90
            ),
            .hold(percent: 90)
        )
        // 掉到下限：放到上限重新充。
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 80, externalBatteryPercent: 60, balancedLower: 80, balancedUpper: 90
            ),
            .hold(percent: 90)
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 79, externalBatteryPercent: 60, balancedLower: 80, balancedUpper: 90
            ),
            .hold(percent: 90)
        )
        // 区间中间：压到下限，保持不充。
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 85, externalBatteryPercent: 60, balancedLower: 80, balancedUpper: 90
            ),
            .hold(percent: 80)
        )
    }

    func testBalancedHoldsAtConfigurableTarget() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 95, externalBatteryPercent: 65, balancedLower: 80, balancedUpper: 85
            ),
            .hold(percent: 85)
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 95, externalBatteryPercent: 65, balancedLower: 85, balancedUpper: 90
            ),
            .hold(percent: 90)
        )
        // 低于固件下限的配置被钳到 80：此时 95% 已在上限之上，停在上限。
        XCTAssertEqual(
            PowerFlowPolicy.balanced.chargingLimitDecision(
                macBatteryPercent: 95, externalBatteryPercent: 65, balancedLower: 60, balancedUpper: 90
            ),
            .hold(percent: 90)
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
                externalBatteryPercent: nil,
                balancedLower: 80, balancedUpper: 85
            ),
            .hold(percent: 85)
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
