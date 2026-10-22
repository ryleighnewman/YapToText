import XCTest
@testable import YapToText

final class LoopGuardTests: XCTestCase {
    func testTwoSentenceBlockLoopCollapses() {
        let block = "Tap the Mac to check the sensor. Then open the calibration page. "
        let text = block + block + block + "Um, " + block + "Finally, save the preset."
        let (out, removed) = RepetitionGuard.collapseBlocks(text)
        XCTAssertEqual(removed, 6)
        XCTAssertEqual(out, block + "Finally, save the preset.")
    }

    func testThreeSentenceBlockLoopCollapses() {
        let block = "First we scan. Then we map it. Then we test the row. "
        let text = block + block + block + "Done."
        let (out, removed) = RepetitionGuard.collapseBlocks(text)
        XCTAssertEqual(removed, 6)
        XCTAssertEqual(out, block + "Done.")
    }

    func testTwoCopiesAreRealSpeech() {
        let block = "No. Not that one. "
        let text = block + block + "The other one, please. Thanks a lot. Really."
        let (out, removed) = RepetitionGuard.collapseBlocks(text)
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(out, text)
    }

    func testCleanupGrowthLimit() {
        XCTAssertFalse(CleanupGuards.growsTooMuch(inWords: 465, outWords: 500))
        XCTAssertTrue(CleanupGuards.growsTooMuch(inWords: 465, outWords: 1132))
        XCTAssertFalse(CleanupGuards.growsTooMuch(inWords: 5, outWords: 40))   // short notes may be shaped
    }

    func testCleanupRepeatGuard() {
        let raw = "The meeting moved to Thursday at ten. Can you send the deck before then?"
        let looped = "The meeting moved to Thursday at ten. The meeting moved to Thursday at ten. Can you send the deck before then?"
        XCTAssertTrue(CleanupGuards.repeatsMoreThanInput(raw: raw, output: looped))
        XCTAssertFalse(CleanupGuards.repeatsMoreThanInput(raw: raw, output: raw))
        let rawLoop = "Tap the Mac to check it. Tap the Mac to check it."
        XCTAssertFalse(CleanupGuards.repeatsMoreThanInput(raw: rawLoop, output: rawLoop))
    }

    func testCleanupMidSentenceEnd() {
        let raw = String(repeating: "Here is a sentence that ends properly. ", count: 12)
        let cut = String(repeating: "Here is a sentence that ends properly. ", count: 11) + "Here is a sentence that"
        XCTAssertTrue(CleanupGuards.endsMidSentence(raw: raw, output: cut))
        XCTAssertFalse(CleanupGuards.endsMidSentence(raw: raw, output: raw))
        XCTAssertFalse(CleanupGuards.endsMidSentence(raw: "Short note", output: "Short note"))
    }
}
