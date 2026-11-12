import XCTest
@testable import CodexTouchBarNative

final class MainComponentSlotTests: XCTestCase {
    func testSavedOrderAndIntentionalGapsArePreservedExactly() {
        let saved = ["sidecar", "aiCoding", "", "clipboard", "systemMonitor", ""]
        let resolved = MainComponent.resolveSavedSlots(saved)
        XCTAssertFalse(resolved.fallback)
        XCTAssertEqual(resolved.slots.map { $0?.rawValue ?? "" }, saved)
        XCTAssertEqual(resolved.slots.compactMap { $0 }, [.sidecar, .aiCoding, .clipboard, .systemMonitor])
    }

    func testSavedLayoutIsNotReorderedWhenShortOrContainsUnknownValues() {
        let resolved = MainComponent.resolveSavedSlots(["clipboard", "removedModule", "aiCoding"])
        XCTAssertFalse(resolved.fallback)
        XCTAssertEqual(resolved.slots.map { $0?.rawValue ?? "" },
                       ["clipboard", "", "aiCoding", "", "", ""])
    }

    func testOnlyCompletelyEmptyLayoutUsesNonPersistentFallback() {
        let resolved = MainComponent.resolveSavedSlots(["", "unknown", "", "", "", ""])
        XCTAssertTrue(resolved.fallback)
        XCTAssertFalse(resolved.slots.isEmpty)
    }

    func testDecodedLayoutNeverPadsWithDefaultModules() {
        let slots = MainComponent.decodeStoredSlots(["", "", "systemMonitor", "", "", ""])
        XCTAssertEqual(slots.compactMap { $0 }, [.systemMonitor])
        XCTAssertEqual(slots.count, MainComponent.slotCount)
    }
}
