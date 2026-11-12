import CoreGraphics
import XCTest
@testable import CodexTouchBarNative

final class KeyboardLockTests: XCTestCase {
    func testPresentationFollowsLockStateAndPermission() {
        let locked = KeyboardLockPolicy.presentation(locked: true)
        XCTAssertEqual(locked.title, "键盘已锁定")
        XCTAssertEqual(locked.symbol, "lock.fill")
        XCTAssertTrue(locked.locked)
        XCTAssertFalse(locked.permissionMissing)

        let unlocked = KeyboardLockPolicy.presentation(locked: false)
        XCTAssertEqual(unlocked.title, "键盘可输入")
        XCTAssertEqual(unlocked.symbol, "lock.open.fill")
        XCTAssertFalse(unlocked.locked)

        let missing = KeyboardLockPolicy.presentation(locked: true, permissionGranted: false)
        XCTAssertEqual(missing.title, "键盘未授权")
        XCTAssertEqual(missing.symbol, "lock.slash.fill")
        XCTAssertTrue(missing.permissionMissing)
        XCTAssertFalse(missing.locked)
    }

    func testAutoUnlockOnlyOnBatteryToPowerTransition() {
        XCTAssertTrue(KeyboardLockPolicy.shouldAutoUnlock(
            wasOnExternalPower: false, isOnExternalPower: true, locked: true, automationEnabled: true
        ))
        XCTAssertFalse(KeyboardLockPolicy.shouldAutoUnlock(
            wasOnExternalPower: false, isOnExternalPower: true, locked: false, automationEnabled: true
        ))
        XCTAssertFalse(KeyboardLockPolicy.shouldAutoUnlock(
            wasOnExternalPower: false, isOnExternalPower: true, locked: true, automationEnabled: false
        ))
        XCTAssertFalse(KeyboardLockPolicy.shouldAutoUnlock(
            wasOnExternalPower: true, isOnExternalPower: true, locked: true, automationEnabled: true
        ))
        XCTAssertFalse(KeyboardLockPolicy.shouldAutoUnlock(
            wasOnExternalPower: false, isOnExternalPower: false, locked: true, automationEnabled: true
        ))
    }

    func testSuppressorSwallowsOnlyHardwareKeyboardEventsWhileLocked() throws {
        let suppressor = KeyboardLockSuppressor()
        let keyEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        suppressor.setLocked(false)
        XCTAssertNotNil(suppressor.handle(type: .keyDown, event: keyEvent))
        XCTAssertFalse(suppressor.isSuppressing)

        suppressor.setLocked(true)
        XCTAssertTrue(suppressor.isSuppressing)
        XCTAssertNil(suppressor.handle(type: .keyDown, event: keyEvent))
        XCTAssertNil(suppressor.handle(type: .keyUp, event: keyEvent))
        XCTAssertNil(suppressor.handle(type: .flagsChanged, event: keyEvent))

        // 鼠标事件必须放行，否则用户无法用状态栏菜单解锁。
        XCTAssertNotNil(suppressor.handle(type: .leftMouseDown, event: keyEvent))
        XCTAssertNotNil(suppressor.handle(type: .scrollWheel, event: keyEvent))

        suppressor.setLocked(false)
        XCTAssertNotNil(suppressor.handle(type: .keyDown, event: keyEvent))
    }
}
