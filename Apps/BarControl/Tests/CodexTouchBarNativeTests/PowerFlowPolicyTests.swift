import XCTest
@testable import CodexTouchBarNative

final class PowerFlowPolicyTests: XCTestCase {
    func testBalancedStaysBalancedWhenBothDevicesAreAtLeastTwentyPercent() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 20, externalBatteryPercent: 20),
            .balanced
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 80, externalBatteryPercent: 65),
            .balanced
        )
    }

    func testBalancedPrioritizesChargingWhenMacIsBelowTwentyPercent() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 19, externalBatteryPercent: 80),
            .charging
        )
    }

    func testBalancedPrioritizesDischargingWhenExternalDeviceIsBelowTwentyPercent() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 80, externalBatteryPercent: 19),
            .discharging
        )
    }

    func testBalancedPrioritizesChargingWhenBothDevicesAreBelowTwentyPercent() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 19, externalBatteryPercent: 19),
            .charging
        )
    }

    func testManualPoliciesIgnoreBatteryThresholds() {
        XCTAssertEqual(
            PowerFlowPolicy.charging.resolved(macBatteryPercent: 80, externalBatteryPercent: 10),
            .charging
        )
        XCTAssertEqual(
            PowerFlowPolicy.discharging.resolved(macBatteryPercent: 10, externalBatteryPercent: 80),
            .discharging
        )
    }

    func testBalancedStaysBalancedWhenExternalBatteryIsUnavailable() {
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 10, externalBatteryPercent: nil),
            .charging
        )
        XCTAssertEqual(
            PowerFlowPolicy.balanced.resolved(macBatteryPercent: 80, externalBatteryPercent: nil),
            .balanced
        )
    }
}
