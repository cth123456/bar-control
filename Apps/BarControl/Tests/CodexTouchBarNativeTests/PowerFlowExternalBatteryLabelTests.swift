import AppKit
import XCTest
@testable import CodexTouchBarNative

final class PowerFlowExternalBatteryLabelTests: XCTestCase {
    @MainActor
    func testIPadPercentageAndUnknownState() {
        for percent in [0, 18, 80, 100] {
            XCTAssertEqual(FrostedPowerFlowView.endpointBatteryText(for: "iPad", batteryPercent: percent), "\(percent)%")
        }
        for percent: Int? in [nil, -1, 101] {
            XCTAssertNil(FrostedPowerFlowView.endpointBatteryText(for: "iPad", batteryPercent: percent))
        }
        XCTAssertNil(FrostedPowerFlowView.endpointBatteryText(for: "GPU", batteryPercent: 80))
        XCTAssertNil(FrostedPowerFlowView.endpointBatteryText(for: "iPhone", batteryPercent: 80))
    }

    @MainActor
    func testRenderIPadPercentageInBothAppearances() throws {
        _ = NSApplication.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = FrostedPowerFlowView()
            view.appearance = NSAppearance(named: appearance)
            view.metrics = .preview
            view.frame.size = view.intrinsicContentSize
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-ipad-percent-\(name).png"))
        }
    }
    @MainActor
    func testDeviceSymbolsFollowConnectedDevice() {
        XCTAssertEqual(FrostedPowerFlowView.resolvedDeviceSymbol(for: "iPad"), "ipad.gen2")
        XCTAssertEqual(FrostedPowerFlowView.resolvedDeviceSymbol(for: "iPhone"), "iphone.gen3")
        XCTAssertEqual(FrostedPowerFlowView.resolvedDeviceSymbol(for: "USB-C 显示器"), "display")
        XCTAssertEqual(FrostedPowerFlowView.resolvedDeviceSymbol(for: "未知设备"), "ellipsis")
        XCTAssertGreaterThan(FrostedPowerFlowView.deviceSymbolCandidates(for: "iPad").count, 1)
    }
}
