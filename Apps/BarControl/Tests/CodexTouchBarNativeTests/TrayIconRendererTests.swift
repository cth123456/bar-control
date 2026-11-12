import AppKit
import XCTest
@testable import CodexTouchBarNative

final class TrayIconRendererTests: XCTestCase {
    @MainActor
    func testRenderedIconIsAnIndependentBitmapWithVisiblePixels() throws {
        let source = NSImage(size: NSSize(width: 36, height: 36))
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 32, height: 32), xRadius: 8, yRadius: 8).fill()
        source.unlockFocus()

        let image = try XCTUnwrap(TrayIconRenderer.render(source: source, side: 20))
        XCTAssertEqual(image.size, NSSize(width: 20, height: 20))
        XCTAssertTrue(image.isTemplate)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        var opaque = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                opaque += 1
            }
        }
        XCTAssertGreaterThan(opaque, 100, "固定区图标不能是空位图")
    }

    func testMissingSourceDoesNotCrash() {
        XCTAssertNil(TrayIconRenderer.render(source: nil))
    }
}
