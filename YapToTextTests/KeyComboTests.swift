import XCTest
@testable import YapToText

final class KeyComboTests: XCTestCase {
    func testDefaultDisplayString() {
        XCTAssertEqual(KeyCombo.default.displayString, "⌃⌥Space")
    }

    func testGlyphOrderIsStableRegardlessOfOrValueOrder() {
        let combo = KeyCombo(keyCode: 0,
                             modifiers: KeyCombo.cmd | KeyCombo.shift | KeyCombo.option | KeyCombo.control)
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘A")
    }

    func testKeyNames() {
        XCTAssertEqual(KeyCombo.keyName(for: 0), "A")
        XCTAssertEqual(KeyCombo.keyName(for: 36), "Return")
        XCTAssertEqual(KeyCombo.keyName(for: 49), "Space")
        XCTAssertEqual(KeyCombo.keyName(for: 999), "Key 999")
    }

    func testJSONRoundTrip() throws {
        let combo = KeyCombo(keyCode: 49, modifiers: KeyCombo.control | KeyCombo.option)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
    }
}
