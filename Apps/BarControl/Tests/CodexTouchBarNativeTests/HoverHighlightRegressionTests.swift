import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class HoverHighlightRegressionTests: XCTestCase {
    private func enterEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: NSPoint(x: 20, y: 20), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
            trackingNumber: 0, userData: nil
        ))
    }

    func testSettingsRowsDoNotAccumulateHoverWithoutExitEvents() throws {
        let rows = (0..<3).map { index in
            WindowActionRow(frame: NSRect(x: 0, y: 0, width: 400, height: 50),
                            title: "设置 \(index)", subtitle: "说明", symbol: "gearshape",
                            target: nil, action: #selector(NSObject.description))
        }
        for row in rows {
            row.updateLayer()
            let initial = row.layer?.backgroundColor
            row.mouseEntered(with: try enterEvent())
            // 模拟滚动/布局重建追踪区域，没有发送 mouseExited。
            row.updateTrackingAreas()
            row.updateLayer()
            XCTAssertEqual(row.layer?.backgroundColor, initial)
        }
    }

    func testSidebarKeepsOnlyExplicitSelection() throws {
        let selected = SidebarItemButton(title: "选中", target: nil, action: nil)
        let other = SidebarItemButton(title: "其它", target: nil, action: nil)
        selected.isSelected = true
        other.isSelected = false
        let original = other.layer?.backgroundColor
        other.mouseEntered(with: try enterEvent())
        other.updateTrackingAreas()
        XCTAssertTrue(selected.isSelected)
        XCTAssertFalse(other.isSelected)
        XCTAssertEqual(other.layer?.backgroundColor, original)
    }

    func testMenuRowIgnoresStaleEnterAfterTrackingAreaRebuild() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu)
        let item = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        sections.append(item, id: "services", summary: "运行中", opensWindow: {})
        let row = try XCTUnwrap(item.view)
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.bitmapData)
            return Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let initial = try pixels()
        row.mouseEntered(with: try enterEvent())
        row.updateTrackingAreas()
        XCTAssertFalse(item.isHighlighted)
        XCTAssertEqual(try pixels(), initial, "旧进入事件不能让非当前菜单项保留高亮")
    }
}
