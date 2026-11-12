import AppKit
import XCTest
@testable import CodexTouchBarNative

final class QuotaInteractionTests: XCTestCase {
    @MainActor
    func testDraggingBrowsesBothDirectionsWithoutOpeningAnAccount() throws {
        let quota = QuotaView(width: 180)
        quota.update(with: nil, accounts: accounts())
        let scroll = try XCTUnwrap(quota.subviews.first as? NSScrollView)
        let input = try XCTUnwrap(quota.subviews.last as? QuotaInteractionView)
        var opened = 0
        quota.onOpenUsage = { _ in opened += 1 }
        XCTAssertTrue(input.allowedTouchTypes.contains(.direct))

        input.beginInteraction(at: NSPoint(x: 100, y: 15))
        input.moveInteraction(to: NSPoint(x: 30, y: 15))
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 70, accuracy: 0.1)
        let firstCard = scroll.documentView?.subviews.first
        quota.update(with: nil, accounts: accounts())
        XCTAssertTrue(firstCard === scroll.documentView?.subviews.first)
        input.endInteraction(at: NSPoint(x: 30, y: 15))
        XCTAssertEqual(opened, 0)

        input.beginInteraction(at: NSPoint(x: 60, y: 15))
        input.moveInteraction(to: NSPoint(x: 150, y: 15))
        input.endInteraction(at: NSPoint(x: 150, y: 15))
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 0.1)
        input.beginInteraction(at: NSPoint(x: 60, y: 15))
        input.endInteraction(at: NSPoint(x: 60, y: 15))
        XCTAssertEqual(opened, 1)

        input.beginInteraction(at: NSPoint(x: 60, y: 15))
        input.cancelInteraction()
        XCTAssertFalse(input.isInteracting)
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testNarrowTouchBarGetsAScrollableViewport() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let container = FixedTouchBarContainer(width: 730)
        window.contentView = container
        let quota = QuotaView(width: 549)
        quota.frame.origin.x = 160
        container.addSubview(quota)
        quota.update(with: nil, accounts: accounts())
        quota.layout()
        let scroll = try XCTUnwrap(quota.subviews.first as? NSScrollView)
        let input = try XCTUnwrap(quota.subviews.last as? QuotaInteractionView)
        XCTAssertEqual(scroll.frame.width, 232, accuracy: 0.1)
        XCTAssertEqual(input.frame, scroll.frame)
        input.beginInteraction(at: NSPoint(x: 100, y: 15))
        input.moveInteraction(to: NSPoint(x: 20, y: 15))
        input.endInteraction(at: NSPoint(x: 20, y: 15))
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 80, accuracy: 0.1)
    }

    private func accounts() -> [UsageAccount] {
        (0..<4).map { index in
            UsageAccount(
                key: "quota-test-\(index)", clientID: "quota-test", clientLabel: "Test",
                accountLabel: "Account \(index)", providerLabel: "API", isCurrent: true,
                showByDefault: true, iconID: nil, isOfficial: false, metricKind: "balance",
                remainingBalance: 10, balanceUnit: "USD", remainingPercent: nil,
                secondaryRemainingPercent: nil, todayCost: 0, monthCost: 0,
                todayRequests: 0, todayTokens: 0, cacheHitPercent: nil, successPercent: nil,
                modelLabel: "", metricsScope: "Test", chartTitle: "Test", chartUnit: "USD",
                latestAt: 0, history: []
            )
        }
    }
}
