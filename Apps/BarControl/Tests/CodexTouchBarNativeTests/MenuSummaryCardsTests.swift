import AppKit
import XCTest
@testable import CodexTouchBarNative

final class MenuSummaryCardsTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    func testCardHeaderButtonExpandsDetailsAndRestoresCardsWhenCollapsed() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu)
        let root = NSMenuItem(title: "剪贴板", action: nil, keyEquivalent: "")
        root.submenu = NSMenu()
        let detail = NSMenuItem(title: "打开历史", action: nil, keyEquivalent: "")
        root.submenu?.addItem(detail)
        sections.append(root, id: "clipboard", summary: "8 条历史", badges: [
            .init(title: "历史", value: "8 条", symbol: "doc.on.clipboard")
        ])
        let header = try XCTUnwrap(root.view)
        let originalHeight = header.frame.height
        let button = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        XCTAssertTrue(sections.expanded.contains("clipboard"))
        XCTAssertFalse(detail.isHidden)
        XCTAssertLessThan(header.frame.height, originalHeight)
        XCTAssertTrue(header.subviews.compactMap { $0 as? MenuSummaryBadgeView }.allSatisfy(\.isHidden))
        button.performClick(nil)
        XCTAssertTrue(detail.isHidden)
        XCTAssertEqual(header.frame.height, originalHeight)
    }

    @MainActor
    func testCollapsedBadgeRunsItsActionWithoutExpandingTheSection() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu)
        let root = NSMenuItem(title: "剪贴板", action: nil, keyEquivalent: "")
        root.submenu = NSMenu()
        let detail = NSMenuItem(title: "打开历史", action: nil, keyEquivalent: "")
        root.submenu?.addItem(detail)
        var performed: MenuSummaryAction?
        sections.onBadgeAction = { performed = $0 }
        sections.append(root, id: "clipboard", summary: "8 条历史", badges: [
            .init(title: "", value: "8 条", symbol: "doc.on.clipboard", action: .openClipboard)
        ])
        let header = try XCTUnwrap(root.view)
        let badge = try XCTUnwrap(descendants(of: header).compactMap { $0 as? MenuSummaryBadgeView }.first)
        let point = badge.convert(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: header)
        let hit = try XCTUnwrap(header.hitTest(point))
        XCTAssertTrue(hit === badge || hit.isDescendant(of: badge))
        badge.performPress()
        XCTAssertEqual(performed, .openClipboard)
        XCTAssertTrue(detail.isHidden)
        XCTAssertFalse(sections.expanded.contains("clipboard"))

        let overflowed = NSMenuItem(title: "AI coding", action: nil, keyEquivalent: "")
        overflowed.submenu = NSMenu()
        sections.append(overflowed, id: "ai", summary: "供应商", badges: (0..<5).map {
            .init(title: "供应商 \($0)", value: "40%", symbol: "creditcard", clientID: "codex")
        })
        let overflow = try XCTUnwrap(overflowed.view.map(descendants)
            .flatMap { $0.compactMap { $0 as? MenuSummaryOverflowView } }?.first)
        overflow.mouseDown(with: NSEvent())
        XCTAssertTrue(sections.expanded.contains("ai"))
    }

    @MainActor
    func testNativeCardsFitAndRenderInLightAndDarkAppearance() throws {
        _ = NSApplication.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let menu = NSMenu()
            let sections = InlineMenuSections(menu: menu)
            let examples: [(String, String, [MenuSummaryBadge])] = [
                ("整机功率", "bolt.fill", [
                    .init(title: "整机", value: "22.5 W", symbol: "bolt.fill", tone: .orange),
                    .init(title: "内存", value: "67%", symbol: "memorychip", tone: .purple)
                ]),
                ("服务", "server.rack", [
                    .init(title: "常驻", value: "3/4 运行", symbol: "server.rack", tone: .green),
                    .init(title: "定时", value: "1/3 运行", symbol: "clock", tone: .green)
                ]),
                ("随航与通用控制", "ipad.and.iphone", [
                    .init(title: "CTHPAD", value: "● 已连接", symbol: "ipad.landscape", tone: .green)
                ]),
                ("AI coding", "curlybraces.square.fill", [
                    .init(title: "Codex Plus", value: "余 40%", symbol: "creditcard", progress: 0.4, clientID: "codex"),
                    .init(title: "Codex Free", value: "余 64%", symbol: "creditcard", progress: 0.64, clientID: "codex"),
                    .init(title: "WorkBuddy Free", value: "credits 1414", symbol: "creditcard", clientID: "workbuddy"),
                    .init(title: "ZCode", value: "余 100%", symbol: "creditcard", progress: 1, clientID: "zcode")
                ]),
                ("剪贴板", "doc.on.clipboard", [
                    .init(title: "", value: "8 条 · 记录中", symbol: "doc.on.clipboard", tone: .green)
                ]),
                ("Touch Bar 设置", "slider.horizontal.3", [
                    .init(title: "外观", value: "跟随系统", symbol: "circle.lefthalf.filled", tone: .purple),
                    .init(title: "Touch Bar", value: "自定义", symbol: "slider.horizontal.3")
                ])
            ]
            var headers: [(NSView, Int, String)] = []
            var totalHeight: CGFloat = 12
            for (index, example) in examples.enumerated() {
                let item = NSMenuItem(title: example.0, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: example.1, accessibilityDescription: nil)
                item.submenu = NSMenu()
                sections.append(item, id: "\(index)", summary: "示例数据", badges: example.2)
                let view = try XCTUnwrap(item.view)
                item.view = nil
                totalHeight += view.frame.height + 5
                headers.append((view, example.2.count, example.0))
            }
            let canvas = SummaryPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 390, height: totalHeight))
            let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = canvas
            defer { window.orderOut(nil) }
            var y: CGFloat = 8
            for (view, count, titleText) in headers {
                view.autoresizingMask = []
                canvas.addSubview(view)
                view.frame = NSRect(x: 0, y: y, width: 390, height: view.frame.height)
                view.layoutSubtreeIfNeeded()
                let cards = descendants(of: view).compactMap { $0 as? MenuSummaryBadgeView }
                XCTAssertEqual(cards.count, count)
                let title = descendants(of: view).compactMap { $0 as? NSTextField }
                    .first { $0.stringValue.replacingOccurrences(of: "\n", with: "") == titleText }
                if let title {
                    XCTAssertFalse(title.stringValue.isEmpty)
                }
                let visible = cards.filter { !$0.isHidden }
                for card in visible {
                    XCTAssertEqual(card.frame.height, MenuSummaryBadgeView.height)
                    XCTAssertLessThanOrEqual(card.frame.width, 150)
                    XCTAssertTrue(card.superview?.bounds.contains(card.frame) == true)
                }
                for first in visible.indices {
                    for second in visible.indices where second > first {
                        XCTAssertFalse(visible[first].frame.intersects(visible[second].frame))
                    }
                }
                let overflow = descendants(of: view).compactMap { $0 as? MenuSummaryOverflowView }.first
                XCTAssertEqual(overflow != nil, cards.contains(where: \.isHidden))
                y += view.frame.height + 5
            }
            canvas.layoutSubtreeIfNeeded()
            for index in 1..<headers.count {
                XCTAssertGreaterThanOrEqual(headers[index].0.frame.minY, headers[index - 1].0.frame.maxY)
            }
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-summary-cards-\(name).png"))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class SummaryPreviewCanvas: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
