import XCTest
@testable import YapToText

final class DictionaryTests: XCTestCase {
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

    func testFreshStoreStartsWithGeneralDictionary() {
        let store = VocabularyStore()
        XCTAssertEqual(store.dictionaries.map(\.name), ["General"])
        XCTAssertTrue(store.dictionaries[0].enabled)
    }

    func testDisabledDictionaryIsSkipped() {
        let store = VocabularyStore()
        let dict = store.addDictionary(name: "Work")
        store.addReplacement(Replacement(from: "gm", to: "General Motors"), to: dict.id)

        XCTAssertEqual(store.apply(to: "the gm plant"), "the General Motors plant")
        store.setEnabled(dict, false)
        XCTAssertEqual(store.apply(to: "the gm plant"), "the gm plant")
    }

    func testMultipleEnabledDictionariesAllApply() {
        let store = VocabularyStore()
        store.addReplacement(Replacement(from: "swift ui", to: "SwiftUI"))   // goes to General
        let medical = store.addDictionary(name: "Medical")
        store.addReplacement(Replacement(from: "otc", to: "over-the-counter"), to: medical.id)

        XCTAssertEqual(store.apply(to: "swift ui and otc meds"), "SwiftUI and over-the-counter meds")
    }

    func testDeletingLastDictionaryRecreatesGeneral() {
        let store = VocabularyStore()
        store.deleteDictionary(store.dictionaries[0])
        XCTAssertEqual(store.dictionaries.map(\.name), ["General"])
    }

    func testRenamePersistsAcrossInstances() {
        let store = VocabularyStore()
        store.rename(store.dictionaries[0], to: "Names")
        XCTAssertEqual(VocabularyStore().dictionaries.first?.name, "Names")
    }

    func testLegacyFlatFormatMigratesIntoGeneral() {
        // The pre-dictionaries format: a flat replacement list plus hints.
        struct Legacy: Codable {
            var replacements: [Replacement]
            var vocabularyHints: [String]
        }
        let legacy = Legacy(replacements: [Replacement(from: "yap", to: "YapToText")],
                            vocabularyHints: ["YapToText"])
        Persistence.save(legacy, to: "vocabulary.json")

        let store = VocabularyStore()
        XCTAssertEqual(store.dictionaries.count, 1)
        XCTAssertEqual(store.dictionaries[0].name, "General")
        XCTAssertEqual(store.apply(to: "open yap now"), "open YapToText now")
    }
}

@MainActor
final class HistoryPruneTests: XCTestCase {
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

    private func record(_ text: String, daysAgo: Int) -> DictationRecord {
        DictationRecord(date: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
                        rawText: text, finalText: text, modeName: "Raw",
                        durationSeconds: 1, appName: nil, appBundleID: nil,
                        localeIdentifier: "en_US", usedAI: false)
    }

    func testPruneOlderThanRemovesOnlyStaleRecords() {
        let store = HistoryStore()
        store.add(record("fresh", daysAgo: 1))
        store.add(record("stale", daysAgo: 45))
        store.add(record("ancient", daysAgo: 400))

        let removed = store.pruneOlderThan(days: 30)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.records.map(\.finalText), ["fresh"])
    }

    func testPruneZeroDaysIsOff() {
        let store = HistoryStore()
        store.add(record("old", daysAgo: 900))
        XCTAssertEqual(store.pruneOlderThan(days: 0), 0)
        XCTAssertEqual(store.records.count, 1)
    }

    func testUpdateReplacesRecordInPlace() {
        let store = HistoryStore()
        store.add(record("first draft", daysAgo: 0))
        var updated = store.records[0]
        updated.finalText = "regenerated"
        store.update(updated)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].finalText, "regenerated")
        XCTAssertEqual(store.records[0].id, updated.id)
    }
}
