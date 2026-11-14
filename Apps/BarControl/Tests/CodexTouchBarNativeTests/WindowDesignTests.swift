import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class WindowDesignTests: XCTestCase {
    @MainActor
    func testSharedWindowComponentsRenderInBothAppearances() throws {
        _ = NSApplication.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let page = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
            page.appearance = NSAppearance(named: appearance)
            page.wantsLayer = true
            page.layer?.backgroundColor = WindowDesign.background(for: page.effectiveAppearance).cgColor
            let header = WindowDesign.header(title: "服务", subtitle: "4/4 运行中 · 常驻与定时任务",
                                             symbol: "server.rack", accent: .systemGreen)
            header.frame = NSRect(x: 24, y: 24, width: 512, height: 48)
            page.addSubview(header)
            let card = WindowDesign.card(frame: NSRect(x: 24, y: 94, width: 512, height: 54),
                                         tint: .systemGreen)
            page.addSubview(card)
            let title = NSTextField(labelWithString: "Global Agent Memory")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.frame = NSRect(x: 38, y: 9, width: 300, height: 18)
            card.addSubview(title)
            let role = NSTextField(labelWithString: "Codex / Obsidian 持久记忆服务")
            role.font = .systemFont(ofSize: 11)
            role.textColor = .secondaryLabelColor
            role.frame = NSRect(x: 38, y: 29, width: 330, height: 15)
            card.addSubview(role)
            let pill = WindowDesign.statusPill(text: "运行中", color: .systemGreen, width: 58)
            pill.frame.origin = NSPoint(x: 372, y: 17)
            card.addSubview(pill)
            let action = WindowActionRow(frame: NSRect(x: 24, y: 158, width: 512, height: 50),
                                         title: "自定义 Touch Bar 组件…",
                                         subtitle: "排序、宽度、图标与文字",
                                         symbol: "slider.horizontal.3", target: nil, action: #selector(NSObject.description))
            page.addSubview(action)
            let titleInAction = try XCTUnwrap(action.subviews.compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "自定义 Touch Bar 组件…" })
            let subtitleInAction = try XCTUnwrap(action.subviews.compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "排序、宽度、图标与文字" })
            page.layoutSubtreeIfNeeded()
            XCTAssertLessThan(titleInAction.frame.minY, subtitleInAction.frame.minY)
            let bitmap = try XCTUnwrap(page.bitmapImageRepForCachingDisplay(in: page.bounds))
            page.effectiveAppearance.performAsCurrentDrawingAppearance {
                page.cacheDisplay(in: page.bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-window-design-\(name).png"))
            XCTAssertTrue(card.bounds.contains(pill.frame))
        }
    }
}
