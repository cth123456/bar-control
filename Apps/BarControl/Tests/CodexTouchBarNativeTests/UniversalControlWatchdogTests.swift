import XCTest
@testable import CodexTouchBarNative

final class UniversalControlWatchdogTests: XCTestCase {
    func testAutomaticRecoveryIsDisabled() {
        XCTAssertFalse(UniversalControlWatchdog.automaticRecoveryEnabled)
    }

    func testClassifiesDiagnosticEvents() {
        XCTAssertEqual(
            UniversalControlWatchdog.event(in: "FocusMove pointer=true keyFocus=false device=4647167F source=7E947D87"),
            .remotePointerFocus
        )
        XCTAssertEqual(
            UniversalControlWatchdog.event(in: "[com.apple.universalcontrol:LINK] IDS 4647167F: Device Lost SF <BLE WiFiP2P>"),
            .deviceLost
        )
        XCTAssertEqual(
            UniversalControlWatchdog.event(in: "[com.apple.universalcontrol:SYNC] IDS 4647167F: Device Unavailable"),
            .deviceLost
        )
        XCTAssertEqual(
            UniversalControlWatchdog.event(in: "Pointer target is another device which has transitioned to unavailable"),
            .deviceLost
        )
        XCTAssertEqual(
            UniversalControlWatchdog.event(in: "Selected circle: [4647167F,7E947D87]"),
            .connectedCircle
        )
        XCTAssertNil(UniversalControlWatchdog.event(in: "Selected circle: [7E947D87]"))
    }
}
