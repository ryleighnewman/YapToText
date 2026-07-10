import XCTest
@testable import YapToText

final class VocabularyTests: XCTestCase {
    private func replace(_ from: String, _ to: String, in text: String,
                         caseSensitive: Bool = false, wholeWord: Bool = true) -> String {
        VocabularyStore.applyReplacement(
            Replacement(from: from, to: to, caseSensitive: caseSensitive, wholeWord: wholeWord),
            to: text)
    }

    func testCaseInsensitiveWholeWord() {
        XCTAssertEqual(replace("swift ui", "SwiftUI", in: "I love swift ui and Swift UI"),
                       "I love SwiftUI and SwiftUI")
    }

    func testCaseSensitiveMatchesOnlyExactCase() {
        XCTAssertEqual(replace("cat", "dog", in: "cat CAT Cat", caseSensitive: true), "dog CAT Cat")
    }

    func testWholeWordVersusSubstring() {
        XCTAssertEqual(replace("cat", "dog", in: "category cat", wholeWord: true), "category dog")
        XCTAssertEqual(replace("cat", "dog", in: "category cat", wholeWord: false), "dogegory dog")
    }

    /// Regression for the whole-word boundary bug: terms that end in punctuation must match.
    func testPunctuationTerminatedTermMatches() {
        XCTAssertEqual(replace("C++", "Cpp", in: "I like C++ a lot", wholeWord: true), "I like Cpp a lot")
        XCTAssertEqual(replace(".net", "dotnet", in: "on .net today", wholeWord: true), "on dotnet today")
    }

    func testMetacharactersMatchedLiterally() {
        XCTAssertEqual(replace("a.b", "X", in: "a.b and axb", wholeWord: false), "X and axb")
    }

    func testReplacementTemplateIsLiteral() {
        XCTAssertEqual(replace("x", "$1", in: "x", wholeWord: false), "$1")
    }

    func testEmptyFromIsNoOp() {
        XCTAssertEqual(replace("", "Y", in: "hello", wholeWord: false), "hello")
    }

    func testInstanceApplyRunsAllReplacements() {
        Persistence.overrideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: Persistence.overrideDirectory!)
            Persistence.overrideDirectory = nil
        }
        let store = VocabularyStore()
        store.addReplacement(Replacement(from: "gm", to: "General Motors", caseSensitive: false, wholeWord: true))
        XCTAssertEqual(store.apply(to: "the gm plant"), "the General Motors plant")
    }
}
