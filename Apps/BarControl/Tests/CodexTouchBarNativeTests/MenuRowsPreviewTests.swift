import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class MenuRowsPreviewTests: XCTestCase {
    func testRenderMenuRowsInAWindow() throws {
        let width: CGFloat = 390
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)

        let pair = ClipboardKeyboardMenuRow(width: width, clipboard: true, keyboard: true)
        pair.update(count: 1, keyboard: KeyboardLockPolicy.presentation(locked: false))

        let panel = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        let power = PowerMenuSectionView(width: width, panel: panel)
        power.controls.update(lowPower: true, busy: false, maximum: 90, effective: 90, supported: true)
        let rows: [NSView] = [power, pair]
        var y: CGFloat = 300 - rows.reduce(CGFloat(0)) { $0 + $1.frame.height }
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: row.frame.height)
            host.addSubview(row)
            y += row.frame.height + 8
        }
        host.layoutSubtreeIfNeeded()
        rows.forEach { $0.layoutSubtreeIfNeeded() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-pair-row-real.png"))
    }
}
