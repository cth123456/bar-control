import AppKit
import XCTest
@testable import CodexTouchBarNative

/// 仅用于生成“菜单栏三合一图标”百分比样式对比图（写入 /tmp，供人工挑选）。
@MainActor
final class DuoIconPreviewTests: XCTestCase {
    func testRenderPercentVariants() throws {
        let variants: [(String, NSImage)] = [
            ("无数字", DuoMenuIcon.previewImage(battery: 64, charging: false, networkSymbol: "wifi", volume: 0.6, style: .none)),
            ("数字在右侧", DuoMenuIcon.previewImage(battery: 64, charging: false, networkSymbol: "wifi", volume: 0.6, style: .trailing)),
            ("数字在圆环内 v2", DuoMenuIcon.previewImage(battery: 64, charging: false, networkSymbol: "wifi", volume: 0.6, style: .inside))
        ]
        let scale: CGFloat = 6
        let cellW: CGFloat = 300, cellH: CGFloat = 200
        let canvas = NSImage(size: NSSize(width: cellW * CGFloat(variants.count), height: cellH))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.50, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        for (index, variant) in variants.enumerated() {
            let originX = CGFloat(index) * cellW
            let icon = variant.1
            let w = icon.size.width * scale
            let h = icon.size.height * scale
            icon.draw(in: NSRect(x: originX + (cellW - w) / 2, y: 46, width: w, height: h))
            let label = NSAttributedString(string: variant.0, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85)
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: originX + (cellW - size.width) / 2, y: 8))
        }
        canvas.unlockFocus()
        let rep = try XCTUnwrap(canvas.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-duo-percent-variants.png"))
    }
}
