import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class MenuCompactPreviewTests: XCTestCase {
    func testRenderMenuRowComponents() throws {
        _ = NSApplication.shared
        let width: CGFloat = 430
        let controls = PowerMenuControlsView()
        controls.update(lowPower: true, busy: false, maximum: 90, effective: 90, supported: true)
        let yieldRow = ApplicationYieldMenuRow(width: width)
        yieldRow.update(name: "Codex", enabled: true)
        let pair = ClipboardKeyboardMenuRow(width: width, clipboard: true, keyboard: true)
        pair.update(count: 1, keyboard: KeyboardLockPolicy.presentation(locked: false))
        let views = [controls, yieldRow, pair]
        let height = views.reduce(CGFloat(0)) { $0 + $1.frame.height + 10 } + 20
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        var y: CGFloat = 10
        for view in views {
            view.frame = NSRect(x: 0, y: y, width: width, height: view.frame.height)
            canvas.addSubview(view)
            y += view.frame.height + 10
        }
        canvas.layoutSubtreeIfNeeded()
        for view in views { view.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-menu-rows.png"))
    }
}
