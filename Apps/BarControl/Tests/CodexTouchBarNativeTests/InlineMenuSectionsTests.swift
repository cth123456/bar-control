import AppKit
import XCTest
@testable import CodexTouchBarNative

final class InlineMenuSectionsTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    func testMenuRowsUseIntegratedPanelWithoutPerRowCards() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu)
        let item = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        var opened = false
        sections.append(item, id: "services", summary: "4/7 运行中", opensWindow: { opened = true })
        let header = try XCTUnwrap(item.view)
        header.frame.size.width = 550
        header.layoutSubtreeIfNeeded()
        // 用类名字符串判断，避免旧 SDK（CI 的 macOS 15 runner）没有 NSGlassEffectView 符号而编译失败。
        XCTAssertFalse(descendants(header).contains {
            String(describing: type(of: $0)) == "NSGlassEffectView"
        })
        XCTAssertTrue(descendants(header).compactMap { $0 as? NSVisualEffectView }.isEmpty)
        let button = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        XCTAssertTrue(opened)
        XCTAssertTrue(descendants(header).contains { ($0 as? NSTextField)?.stringValue == "服务" })
    }

    @MainActor
    func testExpandedPowerAndSupplierSummaryResize() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu, expanded: ["systemMonitor"])
        let power = NSMenuItem(title: "功率", action: nil, keyEquivalent: "")
        power.submenu = NSMenu()
        let detail = NSMenuItem(title: "详细功率", action: nil, keyEquivalent: "")
        power.submenu?.addItem(detail)
        sections.append(power, id: "systemMonitor", summary: "20 W")
        XCTAssertFalse(detail.isHidden)
        let initialHeight = try XCTUnwrap(power.view).frame.height
        sections.updateSummary("A $1.00\nB ¥2.00", for: "systemMonitor")
        XCTAssertEqual(power.view?.frame.height, initialHeight)
        sections.toggle("systemMonitor")
        XCTAssertTrue(detail.isHidden)
        let twoLineHeight = try XCTUnwrap(power.view).frame.height
        sections.toggle("systemMonitor")
        XCTAssertEqual(power.view?.frame.height, 32)
        sections.toggle("systemMonitor")
        XCTAssertEqual(power.view?.frame.height, twoLineHeight)
    }

    @MainActor
    func testNestedSectionsExpandDownwardAndPreserveActions() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu)
        let root = NSMenuItem(title: "模块", action: nil, keyEquivalent: "")
        let child = NSMenuItem(title: "选项", action: nil, keyEquivalent: "")
        let action = NSMenuItem(title: "执行", action: #selector(NSObject.description), keyEquivalent: "")
        let target = NSObject()
        action.target = target
        let checkbox = NSButton(checkboxWithTitle: "开关", target: nil, action: nil)
        let checkItem = NSMenuItem()
        checkItem.view = checkbox
        child.submenu = NSMenu()
        child.submenu?.addItem(action)
        child.submenu?.addItem(checkItem)
        root.submenu = NSMenu()
        root.submenu?.addItem(child)

        sections.append(root, id: "root", summary: "摘要")
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })
        XCTAssertEqual(menu.items.filter { !$0.isHidden }.count, 1)
        sections.toggle("root")
        XCTAssertEqual(menu.items.filter { !$0.isHidden }.count, 2)
        sections.toggle("root.0")
        XCTAssertEqual(menu.items.filter { !$0.isHidden }.count, 4)
        XCTAssertTrue(action.target === target)
        XCTAssertEqual(action.action, #selector(NSObject.description))
        XCTAssertTrue(checkItem.view === checkbox)
        sections.toggle("root")
        XCTAssertEqual(menu.items.filter { !$0.isHidden }.count, 1)
        sections.toggle("root")
        XCTAssertFalse(action.isHidden)
        XCTAssertEqual(sections.expanded, ["root", "root.0"])
    }

    @MainActor
    func testCachedServicesCanBeReadWithoutWaitingForProbes() {
        let started = Date()
        for _ in 0..<100 {
            XCTAssertEqual(ServiceMonitor.cachedSnapshot.states.count, ServiceMonitor.services().count)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }

    @MainActor
    func testWindowRowKeepsCompactSummaryAndRunsWithoutExpanding() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let sections = InlineMenuSections(menu: menu)
        let item = NSMenuItem(title: "整机功率", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        item.submenu?.addItem(NSMenuItem(title: "旧的向下展开项", action: nil, keyEquivalent: ""))
        var opened = 0
        sections.append(item, id: "power", summary: "整机 22.5 W · 内存 67%", badges: [
            .init(title: "整机", value: "22.5 W", symbol: "bolt.fill", tone: .orange)
        ], opensWindow: { opened += 1 })
        let header = try XCTUnwrap(item.view)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(header.frame.height, 38)
        let button = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(menu.items.allSatisfy { !$0.isHidden })
    }
}
