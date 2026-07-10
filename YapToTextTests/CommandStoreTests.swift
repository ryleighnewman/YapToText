import XCTest
@testable import YapToText

final class CommandStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Persistence.overrideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        if let dir = Persistence.overrideDirectory { try? FileManager.default.removeItem(at: dir) }
        Persistence.overrideDirectory = nil
        super.tearDown()
    }

    func testPunctuationAttachesWithoutLeadingSpace() {
        let store = CommandStore()
        XCTAssertEqual(store.apply(to: "hello exclamation point"), "hello!")
        XCTAssertEqual(store.apply(to: "wait comma then go"), "wait, then go")
        XCTAssertEqual(store.apply(to: "really question mark"), "really?")
    }

    func testNewLineAndParagraph() {
        let store = CommandStore()
        XCTAssertEqual(store.apply(to: "line one new line line two"), "line one\nline two")
        XCTAssertEqual(store.apply(to: "para one new paragraph para two"), "para one\n\npara two")
    }

    func testEmojiInsertion() {
        let store = CommandStore()
        XCTAssertEqual(store.apply(to: "great work fire emoji"), "great work 🔥")
        XCTAssertEqual(store.apply(to: "nice thumbs up emoji"), "nice 👍")
    }

    func testWholeWordBoundaryDoesNotFireInsideWords() {
        let store = CommandStore()
        // "period" must not trigger inside "periodic".
        XCTAssertEqual(store.apply(to: "the periodic table"), "the periodic table")
    }

    func testMasterDisableLeavesTextUntouched() {
        let store = CommandStore()
        store.isEnabled = false
        XCTAssertEqual(store.apply(to: "hello exclamation point"), "hello exclamation point")
    }

    func testDisablingOneCommandStopsIt() {
        let store = CommandStore()
        guard let period = store.commands.first(where: { $0.triggers.contains("period") }) else {
            return XCTFail("missing default")
        }
        store.setEnabled(period, false)
        XCTAssertEqual(store.apply(to: "the end period"), "the end period")
    }

    func testMultipleTriggersForOneCommand() {
        let store = CommandStore()
        // The "!" command ships with several phrases; each maps to the same symbol.
        XCTAssertEqual(store.apply(to: "wow bang"), "wow!")
        XCTAssertEqual(store.apply(to: "wow exclamation"), "wow!")
        XCTAssertEqual(store.apply(to: "wow exclamation point"), "wow!")
    }

    func testCustomTriggerIsHonored() {
        let store = CommandStore()
        guard var bang = store.commands.first(where: { $0.triggers.contains("exclamation point") }) else {
            return XCTFail("missing default")
        }
        bang.triggers = ["exclamation"]
        store.update(bang)
        XCTAssertEqual(store.apply(to: "wow exclamation"), "wow!")
    }

    func testRequireInsertPrefix() {
        let store = CommandStore()
        store.requireInsertPrefix = true
        // Bare trigger no longer fires...
        XCTAssertEqual(store.apply(to: "the meeting period"), "the meeting period")
        // ...but "insert <trigger>" does, swallowing the space so it attaches.
        XCTAssertEqual(store.apply(to: "done insert period"), "done.")
        XCTAssertEqual(store.apply(to: "great insert fire emoji"), "great 🔥")
    }

    func testSnippetTokensExpand() {
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(CommandStore.expandTokens("{date}").contains(String(year)))
        XCTAssertNotEqual(CommandStore.expandTokens("{time}"), "{time}")
        XCTAssertEqual(CommandStore.expandTokens("plain"), "plain")
    }

    func testSnippetDefaultsFire() {
        let store = CommandStore()
        let year = String(Calendar.current.component(.year, from: Date()))
        XCTAssertTrue(store.apply(to: "today's date").contains(year))
        XCTAssertTrue(store.apply(to: "shrug face").contains("ツ"))
    }

    func testMigrationFromSingleTriggerJSON() throws {
        // Old data used a single "trigger" string; it must decode into triggers = [that].
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","trigger":"yo","output":"👋","category":"emoji","enabled":true}"#
        let command = try JSONDecoder().decode(SpokenCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command.triggers, ["yo"])
        XCTAssertEqual(command.output, "👋")
    }

    func testNoCommandFiredLeavesSpacingAlone() {
        let store = CommandStore()
        // Nothing matches here, so the spacing-tidy pass must not run and collapse the spaces.
        XCTAssertEqual(store.apply(to: "a  b"), "a  b")
    }

    func testDoesNotTouchDictatedPunctuationElsewhere() {
        let store = CommandStore()
        // A command firing must not collapse an unrelated spelled-out decimal ("3 . 14").
        XCTAssertEqual(store.apply(to: "the value is 3 . 14 exclamation point"), "the value is 3 . 14!")
    }

    func testPersistenceRoundTrip() {
        let store = CommandStore()
        store.isEnabled = false
        let added = store.add(category: .emoji)
        var edited = added
        edited.triggers = ["shrug emoji"]
        edited.output = "🤷"
        store.update(edited)
        store.flush()   // writes are debounced; force it out before reloading

        let reloaded = CommandStore()
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertTrue(reloaded.commands.contains { $0.triggers.contains("shrug emoji") && $0.output == "🤷" })
    }

    func testRestoreDefaultsForCategoryOnly() {
        let store = CommandStore()
        // Mangle a punctuation command and add an emoji one.
        if let period = store.commands.first(where: { $0.triggers.contains("period") }) {
            store.delete(period)
        }
        let customEmoji = store.add(category: .emoji)
        store.restoreDefaults(for: .punctuation)

        XCTAssertTrue(store.commands.contains { $0.triggers.contains("period") })   // punctuation restored
        XCTAssertTrue(store.commands.contains { $0.id == customEmoji.id })          // emoji untouched
    }
}
