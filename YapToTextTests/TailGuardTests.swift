import XCTest
@testable import YapToText

final class TailGuardTests: XCTestCase {
    let raw = "The meeting moved to Thursday at ten in the morning. Please bring the printed deck and the budget figures. We also need the vendor contract signed before Friday."

    func testMissingFinalSentenceIsCaught() {
        let cut = "The meeting moved to Thursday at ten in the morning. Please bring the printed deck and the budget figures."
        XCTAssertTrue(CleanupGuards.dropsTail(raw: raw, output: cut))
    }

    func testCompleteOutputPasses() {
        XCTAssertFalse(CleanupGuards.dropsTail(raw: raw, output: raw))
        let fixed = "The meeting moved to Thursday at 10 in the morning. Please bring the printed deck and the budget figures. We also need the vendor contract signed before Friday."
        XCTAssertFalse(CleanupGuards.dropsTail(raw: raw, output: fixed))
    }

    func testShortNotesAreLeftAlone() {
        XCTAssertFalse(CleanupGuards.dropsTail(raw: "Call me back. Thanks a lot.", output: "Call me back."))
    }

    func testWindowPiecesStayWithinOneWhisperWindow() {
        let rate = 16_000
        // 70 s of tone with 300 ms silences every 20 s, so every cut can land in a pause.
        var audio = [Float](repeating: 0, count: 70 * rate)
        for i in 0..<audio.count { audio[i] = 0.3 * sinf(Float(i) * 0.05) }
        for mark in stride(from: 20, to: 70, by: 20) {
            for i in (mark * rate)..<(mark * rate + rate * 3 / 10) { audio[i] = 0 }
        }
        let pieces = WhisperEngine.windowPieces(audio)
        XCTAssertGreaterThanOrEqual(pieces.count, 3)
        XCTAssertEqual(pieces.first?.lowerBound, 0)
        XCTAssertEqual(pieces.last?.upperBound, audio.count)
        for (a, b) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 30 * rate)
            XCTAssertGreaterThanOrEqual(piece.count, rate)
        }
        // Short audio is a single piece, untouched.
        XCTAssertEqual(WhisperEngine.windowPieces(Array(audio[0..<(25 * rate)])), [0..<(25 * rate)])
    }
}
