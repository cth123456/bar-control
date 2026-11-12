import AppKit
import XCTest
@testable import CodexTouchBarNative

@MainActor
final class DuoMenuIconTests: XCTestCase {
    func testVolumeDotBoundariesAndUnavailableValue() {
        XCTAssertEqual(DuoMenuIcon.illuminatedDots(volume: nil), 0)
        XCTAssertEqual(DuoMenuIcon.illuminatedDots(volume: .nan), 0)
        XCTAssertEqual(DuoMenuIcon.illuminatedDots(volume: 0), 0)
        XCTAssertEqual(DuoMenuIcon.illuminatedDots(volume: 0.25), 1)
        XCTAssertEqual(DuoMenuIcon.illuminatedDots(volume: 0.5), 2)
        XCTAssertEqual(DuoMenuIcon.illuminatedDots(volume: 1), 4)
    }
    func testThreeDigitPercentWidensInsteadOfOverlapping() {
        let two = DuoMenuIcon.image(battery: 99, charging: true, networkSymbol: "wifi", volume: 0.5, percentStyle: .trailing)
        let three = DuoMenuIcon.image(battery: 100, charging: true, networkSymbol: "wifi", volume: 0.5, percentStyle: .trailing)
        XCTAssertGreaterThan(three.size.width, two.size.width)
        XCTAssertGreaterThanOrEqual(three.size.width, 30 + 24)
    }

    func testTemplateRendersAtMenuBarSize() throws {
        for symbol in ["wifi", "cable.connector", "network.slash"] {
            let image = DuoMenuIcon.image(battery: 78, charging: true, networkSymbol: symbol, volume: 0.5)
            XCTAssertEqual(image.size, NSSize(width: 39, height: 22))
            XCTAssertTrue(image.isTemplate)
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }
}
