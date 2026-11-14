import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class PowerFlowPanelLayoutTests: XCTestCase {
    @MainActor
    func testRemovedPolicyControlLeavesNoOverlappingFooterRows() throws {
        _ = NSApplication.shared
        let panel = PowerFlowPanelView()
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.metrics = .preview
        panel.interfaceSpecs = .preview
        panel.frame = NSRect(origin: .zero, size: panel.intrinsicContentSize)
        panel.layoutSubtreeIfNeeded()

        let labels = descendants(of: panel).compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
        let source = try XCTUnwrap(labels.first { $0.stringValue.hasPrefix("来源") })
        // 系统充电上限只在已启用时才有文字；该测试不依赖本机当前电源状态。
        let limit = labels.first { $0.stringValue.hasPrefix("系统充电上限") }
        let chips = descendants(of: panel).compactMap { $0 as? NSVisualEffectView }
            .filter { abs($0.frame.height - 26) < 0.5 && $0.frame.width > 20 && $0.frame.minY < 90 }
        XCTAssertFalse(chips.isEmpty)

        let policyRows = descendants(of: panel).filter {
            !$0.isHidden && String(describing: type(of: $0)) == "PowerPolicySelector"
        }
        let controllerLabels = descendants(of: panel).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue.contains("优先充电") || $0.stringValue.contains("负载均衡") || $0.stringValue.contains("优先放电") }
        XCTAssertTrue(policyRows.isEmpty)
        XCTAssertTrue(controllerLabels.isEmpty)
        for chip in chips {
            XCTAssertFalse(source.frame.intersects(chip.frame), "来源文字与功率卡片重叠：\(chip.frame)")
            if let limit {
                XCTAssertFalse(limit.frame.intersects(chip.frame), "充电上限文字与功率卡片重叠：\(chip.frame)")
            }
        }
        // "来源" and "系统充电上限" occupy two independent columns on the same row.
        if let limit {
            XCTAssertLessThanOrEqual(source.frame.maxX, limit.frame.minX)
        }

        let canvas = NSView(frame: panel.bounds)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        canvas.appearance = NSAppearance(named: .darkAqua)
        canvas.addSubview(panel)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/barcontrol-power-panel-footer.png"))
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
