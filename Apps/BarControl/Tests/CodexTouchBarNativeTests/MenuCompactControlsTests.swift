import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class MenuCompactControlsTests: XCTestCase {
    func testPairedActionsAreIndependentAndDoNotOverlap() {
        let row = ClipboardKeyboardMenuRow(width: 390, clipboard: true, keyboard: true)
        row.update(count: 12, keyboard: KeyboardLockPolicy.presentation(locked: false))
        row.layoutSubtreeIfNeeded()
        var clipboard = 0, keyboard = 0
        row.onClipboard = { clipboard += 1 }
        row.onKeyboard = { keyboard += 1 }
        row.clipboardButton.performClick(nil)
        XCTAssertEqual(clipboard, 1)
        XCTAssertEqual(keyboard, 0)
        row.keyboardButton.performClick(nil)
        XCTAssertEqual(keyboard, 1)
        XCTAssertFalse(row.clipboardButton.frame.intersects(row.keyboardButton.frame))
        XCTAssertEqual(row.frame.height, 30)
        XCTAssertTrue(row.bounds.contains(row.keyboardButton.frame))
        let single = ClipboardKeyboardMenuRow(width: 390, clipboard: false, keyboard: true)
        single.layoutSubtreeIfNeeded()
        XCTAssertTrue(single.clipboardButton.isHidden)
        XCTAssertEqual(single.keyboardButton.frame.width, 390)
    }

    func testPowerHeaderControlsStayClickableAndSeparated() throws {
        _ = NSApplication.shared
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 210))
        let section = PowerMenuSectionView(width: 430, panel: panel)
        section.controls.update(lowPower: false, busy: false, maximum: 90, effective: 90, supported: true)
        section.frame = NSRect(x: 0, y: 0, width: 430, height: 250)
        section.layoutSubtreeIfNeeded()
        section.controls.layoutSubtreeIfNeeded()
        XCTAssertEqual(section.frame.height, 250)
        XCTAssertGreaterThanOrEqual(section.controls.frame.minX, section.titleLabel.frame.maxX + 8)
        XCTAssertTrue(section.bounds.contains(section.controls.frame))
        XCTAssertTrue(section.controls.bounds.contains(section.controls.ecoButton.frame))
        XCTAssertTrue(section.controls.ecoButton.isEnabled)
        XCTAssertTrue(section.controls.limitUp.isEnabled)
        var toggled = false
        section.controls.onEco = { toggled = true }
        section.controls.ecoButton.performClick(nil)
        XCTAssertTrue(toggled)
    }

    func testMaximumIsRespectedByEveryPolicy() {
        XCTAssertEqual(ChargingLimitConstants.effectiveLimit(policyLimit: 100, maximum: 90), 90)
        XCTAssertEqual(ChargingLimitConstants.effectiveLimit(policyLimit: 80, maximum: 95), 80)
        XCTAssertEqual(ChargingLimitConstants.effectiveLimit(policyLimit: 100, maximum: 100), 100)
        XCTAssertEqual(ChargingLimitConstants.effectiveLimit(policyLimit: 90, maximum: -1), 80)
    }

    func testLowPowerCommandOnlyUsesFixedAllowedValues() {
        XCTAssertEqual(LowPowerModeCommand.script(enabled: true),
                       "do shell script \"/usr/bin/pmset -a lowpowermode 1\" with administrator privileges")
        XCTAssertEqual(LowPowerModeCommand.script(enabled: false),
                       "do shell script \"/usr/bin/pmset -a lowpowermode 0\" with administrator privileges")
    }

    func testPowerRowDispatchesClicksFromTheItemView() throws {
        _ = NSApplication.shared
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 10))
        let section = PowerMenuSectionView(width: 430, panel: panel)
        section.frame = NSRect(x: 0, y: 0, width: 430, height: 50)
        section.layout(width: 430)
        var eco = 0
        var limit = 0
        section.onEcoTap = { eco += 1 }
        section.onLimitStep = { _ in limit += 1 }
        func click(_ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            section.mouseDown(with: event)
        }
        let ecoPoint = NSPoint(x: section.controls.frame.minX + 20, y: 20)
        let limitPoint = NSPoint(x: section.controls.frame.minX + section.controls.limitUp.frame.midX, y: 20)
        try click(ecoPoint)
        XCTAssertEqual(eco, 1)
        XCTAssertEqual(limit, 0)
        try click(limitPoint)
        XCTAssertEqual(limit, 1)
        XCTAssertTrue(section.hitTest(ecoPoint) === section)
        XCTAssertTrue(section.hitTest(limitPoint) === section)
    }

    func testQuitRowMatchesMenuStyleAndDispatches() throws {
        _ = NSApplication.shared
        let row = MenuCommandRow(width: 390, title: "退出 Bar Control", symbol: "power")
        var fired = 0
        row.onPress = { fired += 1 }
        let inside = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 60, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: inside)
        XCTAssertEqual(fired, 1)
        let outside = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 60, y: 99), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: outside)
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(row.frame.height, 30)
    }
}
