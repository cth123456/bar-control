import XCTest
@testable import CodexTouchBarNative

final class ExternalBatteryPolicyTests: XCTestCase {
    func testLowestBatteryDecidesPriority() {
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 80, deviceBattery: 90, macLow: 30, deviceLow: 30), .keep)
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 29, deviceBattery: 90, macLow: 30, deviceLow: 30), .charging)
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 80, deviceBattery: 29, macLow: 30, deviceLow: 30), .discharging)
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 10, deviceBattery: 10, macLow: 30, deviceLow: 30), .bothLow)
    }

    func testUnknownReadingsNeverTrigger() {
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: nil, deviceBattery: 10, macLow: 30, deviceLow: 30), .discharging)
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 10, deviceBattery: nil, macLow: 30, deviceLow: 30), .charging)
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: nil, deviceBattery: nil, macLow: 30, deviceLow: 30), .keep)
    }

    func testThresholdsAreConfigurable() {
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 35, deviceBattery: 35, macLow: 40, deviceLow: 40), .bothLow)
        XCTAssertEqual(PowerFlowPolicy.lowBatteryPriority(
            macBattery: 35, deviceBattery: 35, macLow: 30, deviceLow: 30), .keep)
    }
}
