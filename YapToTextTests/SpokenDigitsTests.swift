import XCTest
@testable import YapToText

final class SpokenDigitsTests: XCTestCase {
    func testSpokenCodeBecomesDigits() {
        XCTAssertEqual(SpokenDigits.collapse("One, three, five, seven, two, one."), "135721")
        XCTAssertEqual(SpokenDigits.collapse("four two zero six"), "4206")
        XCTAssertEqual(SpokenDigits.collapse("Nine, oh, three, one, two."), "90312")
        XCTAssertEqual(SpokenDigits.collapse("one two three four five six seven eight"), "12345678")
    }

    func testMixedWordsAndNumeralsStillCollapse() {
        // Whisper often writes some of the digits as numerals.
        XCTAssertEqual(SpokenDigits.collapse("One, 3, 5, seven, 2, 1."), "135721")
        XCTAssertEqual(SpokenDigits.collapse("seven 1 1 four"), "7114")
    }

    func testNumeralsAloneCollapseToo() {
        // What Whisper actually wrote for three codes spoken digit by digit (2026-10-21).
        XCTAssertEqual(SpokenDigits.collapse("804-949."), "804949")
        XCTAssertEqual(SpokenDigits.collapse("1, 2, 3, 5, 4, 7, 3, 1."), "12354731")
        XCTAssertEqual(SpokenDigits.collapse("848128."), "848128")
        XCTAssertEqual(SpokenDigits.collapse("135721"), "135721")
    }

    func testMultipliers() {
        XCTAssertEqual(SpokenDigits.collapse("double five, three, nine"), "5539")
        XCTAssertEqual(SpokenDigits.collapse("triple seven one"), "7771")
        XCTAssertNil(SpokenDigits.collapse("double double five one"))
        XCTAssertNil(SpokenDigits.collapse("five double"))
    }

    func testProseIsLeftAlone() {
        XCTAssertNil(SpokenDigits.collapse("I have two cats and three dogs."))
        XCTAssertNil(SpokenDigits.collapse("Call me at two."))
        XCTAssertNil(SpokenDigits.collapse("one two"))                 // too short to be a code
        XCTAssertNil(SpokenDigits.collapse("12"))
        XCTAssertNil(SpokenDigits.collapse("one two three and four"))
        XCTAssertNil(SpokenDigits.collapse(""))
        XCTAssertNil(SpokenDigits.collapse("Thank you."))
    }
}
