import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class MenuPairStylePreviewTests: XCTestCase {
    func testRenderPairStyleProposal() throws {
        _ = NSApplication.shared
        let scale: CGFloat = 2
        let width: CGFloat = 390
        let height: CGFloat = 190
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {}
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color == .labelColor ? NSColor.white : color])
        }
        func icon(_ name: String, _ x: CGFloat, _ y: CGFloat) {
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) else { return }
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus()
            symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.controlAccentColor.setFill()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: x, y: y, width: 15, height: 15))
        }
        func rightAligned(_ s: String, _ right: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color == .labelColor ? NSColor.white : color]
            let w = (s as NSString).size(withAttributes: attrs).width
            (s as NSString).draw(at: NSPoint(x: right - w, y: y), withAttributes: attrs)
        }

        var y = height - 30
        icon("server.rack", 17, y - 7)
        text("服务", 39, y - 10, 12.5, .semibold, .white)
        func pill(_ t: String, right: CGFloat, _ color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: color]
            let w = (t as NSString).size(withAttributes: attrs).width + 14
            let rect = NSRect(x: right - w, y: y - 21, width: w, height: 18)
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            (t as NSString).draw(at: NSPoint(x: rect.minX + 7, y: y - 18), withAttributes: attrs)
        }
        pill("常驻 4/4", right: width - 17, .systemGreen)
        pill("定时 0/3", right: width - 101, NSColor.white.withAlphaComponent(0.7))
        y -= 30
        icon("ipad.and.iphone", 17, y - 7)
        text("随航与通用控制", 39, y - 10, 12.5, .semibold, .white)
        pill("iPad 已连接", right: width - 17, .systemGreen)
        y -= 30

        func badge(_ text: String, right: CGFloat, y: CGFloat, color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: color]
            let w = (text as NSString).size(withAttributes: attrs).width + 14
            let rect = NSRect(x: right - w, y: y - 6, width: w, height: 18)
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            (text as NSString).draw(at: NSPoint(x: rect.minX + 7, y: y - 3), withAttributes: attrs)
        }
        // Proposal A: badges, matching 服务 / 随航 rows.
        let halfA = width / 2
        icon("doc.on.clipboard", 17, y - 7)
        text("剪贴板", 39, y - 10, 12.5, .semibold, .white)
        badge("1 条", right: halfA - 14, y: y - 6, color: NSColor.white.withAlphaComponent(0.75))
        NSColor.separatorColor.setFill()
        NSRect(x: halfA, y: y - 24, width: 1, height: 20).fill()
        icon("lock.open", halfA + 14, y - 7)
        text("键盘锁", halfA + 36, y - 10, 12.5, .semibold, .white)
        badge("已解锁", right: width - 17, y: y - 6, color: .systemGreen)
        y -= 34
        text("方案 B：纯文字（上一版）", 17, y - 8, 10, .regular, NSColor.white.withAlphaComponent(0.45))
        y -= 22
        // Proposal: two halves, same metrics as the rows above.
        let half = width / 2
        icon("doc.on.clipboard", 17, y - 7)
        text("剪贴板", 39, y - 10, 12.5, .semibold, .white)
        rightAligned("1 条", half - 16, y - 9, 11, NSColor.white.withAlphaComponent(0.62))
        NSColor.separatorColor.setFill()
        NSRect(x: half, y: y - 24, width: 1, height: 20).fill()
        icon("lock.open", half + 14, y - 7)
        text("键盘锁", half + 36, y - 10, 12.5, .semibold, .white)
        rightAligned("已解锁", width - 17, y - 9, 11, NSColor.white.withAlphaComponent(0.62))
        y -= 34

        text("对比：当前样式", 17, y - 8, 10, .regular, NSColor.white.withAlphaComponent(0.45))
        y -= 22
        icon("doc.on.clipboard", 17, y - 7)
        text("剪贴板  ·  1 条", 39, y - 8, 12.5, .semibold, .white)
        NSColor.separatorColor.setFill()
        NSRect(x: half, y: y - 24, width: 1, height: 20).fill()
        icon("lock.open", half + 14, y - 7)
        text("键盘锁  ·  已解锁", half + 36, y - 8, 12.5, .semibold, .white)

        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-pair-style-proposal.png"))
        _ = scale
    }
}
