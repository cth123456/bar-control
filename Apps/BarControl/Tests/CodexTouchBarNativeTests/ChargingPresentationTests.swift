import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class ChargingPresentationTests: XCTestCase {
    func testSystemChargingStatusDoesNotRewriteNetPower() {
        let metrics = SystemMetrics(externalPower: true, adapterLimitWatts: 20,
                                    inputWatts: 18.474, inputVoltage: 9, inputCurrent: 2.1,
                                    systemWatts: 19.157, batteryWatts: -0.683, batteryPercent: 19,
                                    batteryTemperature: nil, memoryPercent: nil, gpuPercent: nil,
                                    usbOutputs: [], batteryIsCharging: true)
        XCTAssertTrue(metrics.showsChargingIndicator)
        XCTAssertEqual(metrics.batterySupplyWatts, 0.683, accuracy: 0.001)
        XCTAssertEqual(metrics.batteryChargeWatts, 0)
    }

    func testRingHasNoChargingBoltAndNumberSlotReservesIt() throws {
        let normal = DuoMenuIcon.image(battery: 100, charging: false, networkSymbol: "wifi", volume: 0.5, percentStyle: .trailing)
        let charging = DuoMenuIcon.image(battery: 100, charging: true, networkSymbol: "wifi", volume: 0.5, percentStyle: .trailing)
        XCTAssertGreaterThan(charging.size.width, normal.size.width)
        func ring(_ image: NSImage) throws -> Data {
            let canvas = NSImage(size: NSSize(width: 29, height: 22))
            canvas.lockFocus()
            image.isTemplate = false
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            canvas.unlockFocus()
            return try XCTUnwrap(canvas.tiffRepresentation)
        }
        XCTAssertEqual(try ring(normal), try ring(charging))
    }

    func testChargeLimitArrowsStepWithinBounds() throws {
        _ = NSApplication.shared
        let view = PowerMenuControlsView()
        view.update(lowPower: true, busy: false, maximum: 90, effective: 90, supported: true)
        view.layoutSubtreeIfNeeded()
        var delta = 0
        view.onStep = { delta = $0 }
        view.limitUp.performClick(nil)
        XCTAssertEqual(delta, 5)
        view.limitDown.performClick(nil)
        XCTAssertEqual(delta, -5)
        view.update(lowPower: true, busy: false, maximum: 80, effective: 80, supported: true)
        XCTAssertFalse(view.limitDown.isEnabled)
        XCTAssertTrue(view.limitUp.isEnabled)
        view.update(lowPower: true, busy: false, maximum: 100, effective: 100, supported: true)
        XCTAssertFalse(view.limitUp.isEnabled)
        XCTAssertTrue(view.limitDown.isEnabled)
        XCTAssertEqual(view.limitDown.frame.midY, view.ecoButton.frame.midY)
        XCTAssertEqual(view.limitUp.frame.midY, view.ecoButton.frame.midY)
    }

    func testRenderRevisedChargingUI() throws {
        _ = NSApplication.shared
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var renderError: Error?
        appearance.performAsCurrentDrawingAppearance {
          do {
            let canvas = NSImage(size: NSSize(width: 480, height: 240))
            canvas.lockFocus()
            NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 480, height: 240).fill()
            func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 12) {
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)])
            }
            label("整机功率", 20, 194, 16)
            let controls = PowerMenuControlsView()
            controls.appearance = appearance
            controls.update(lowPower: true, busy: false, maximum: 90, effective: 90, supported: true)
            controls.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(controls.bitmapImageRepForCachingDisplay(in: controls.bounds))
            controls.cacheDisplay(in: controls.bounds, to: bitmap)
            NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: controls.bounds.size)
                .draw(in: NSRect(x: 230, y: 188, width: 228, height: 28))
            label("菜单栏图标：闪电移到数字后，圆环内保持干净", 20, 146)
            for (i, state) in [(19, true), (100, true), (100, false)].enumerated() {
                let x = CGFloat(24 + i * 151)
                let image = DuoMenuIcon.image(battery: state.0, charging: state.1, networkSymbol: "wifi", volume: 0.5, percentStyle: .trailing)
                image.isTemplate = false
                image.draw(in: NSRect(x: x, y: 67, width: image.size.width * 1.6, height: 35.2))
                label(state.1 ? "\(state.0)% · 充电中" : "100% · 未充电", x, 36, 11)
            }
            label("原生控件渲染 · 示例数据", 20, 10, 10)
            canvas.unlockFocus()
            let bitmapOut = try XCTUnwrap(canvas.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(bitmapOut.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/barcontrol-charging-ui-revised.png"))
          } catch { renderError = error }
        }
        if let renderError { throw renderError }
    }
}
