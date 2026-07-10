import XCTest
@testable import YapToText

/// The AI-cleanup output sanitizer: a small on-device model sometimes echoes prompt
/// scaffolding (tags, "Sure, here's..." preambles, wrapping quotes) - these must never reach
/// the user's cursor. Pure string logic, so testable without Apple Intelligence.
final class TransformSanitizeTests: XCTestCase {
    private func clean(_ s: String) -> String { FoundationModelsTransformer.sanitize(s) }

    func testStripsEchoedTags() {
        XCTAssertEqual(clean("<output>Hello world.</output>"), "Hello world.")
        XCTAssertEqual(clean("<input>Hello world.</input>"), "Hello world.")
        XCTAssertEqual(clean("Hello <output>there</output>."), "Hello there.")
    }

    func testStripsLeadingPreambleLine() {
        XCTAssertEqual(clean("Sure, here's the rewritten text:\nHello world."), "Hello world.")
        XCTAssertEqual(clean("Here is the cleaned version:\n\nHello world."), "Hello world.")
        XCTAssertEqual(clean("Certainly! Here you go:\nHello world."), "Hello world.")
    }

    func testStripsWrappingQuotes() {
        XCTAssertEqual(clean("\"Hello world.\""), "Hello world.")
        XCTAssertEqual(clean("\u{201C}Hello world.\u{201D}"), "Hello world.")
    }

    func testDoesNotOverStripLegitimateText() {
        // Real dictation that happens to start with these words (no colon+newline) is untouched.
        XCTAssertEqual(clean("Here's the plan for tomorrow."), "Here's the plan for tomorrow.")
        XCTAssertEqual(clean("Sure sounds good to me."), "Sure sounds good to me.")
        // An internal quote (not wrapping the whole thing) stays put.
        XCTAssertEqual(clean("She said \"hi\" to me."), "She said \"hi\" to me.")
        XCTAssertEqual(clean("Plain sentence."), "Plain sentence.")
    }
}
