import XCTest
@testable import YapToText

@MainActor
final class HistoryStoreTests: XCTestCase {
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

    private func record(_ text: String) -> DictationRecord {
        DictationRecord(date: Date(), rawText: text, finalText: text, modeName: "Raw",
                        durationSeconds: 1, appName: "App", appBundleID: nil,
                        localeIdentifier: "en_US", usedAI: false)
    }

    func testRetentionLast100KeepsNewest() {
        let store = HistoryStore()
        store.applyRetention(.last100)
        for i in 0..<150 { store.add(record("t\(i)")) }
        XCTAssertEqual(store.records.count, 100)
        XCTAssertEqual(store.records.first?.finalText, "t149")
    }

    func testRetentionOffDropsAdds() {
        let store = HistoryStore()
        store.applyRetention(.off)
        store.add(record("x"))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testSessionOnlyKeepsInMemoryButNotOnDisk() {
        let store = HistoryStore()
        store.applyRetention(.sessionOnly)
        store.add(record("x"))
        XCTAssertEqual(store.records.count, 1)
        // sessionOnly leaves nothing meaningful on disk (an empty array) for the next launch.
        XCTAssertTrue((Persistence.load([DictationRecord].self, from: "history.json") ?? []).isEmpty)
    }

    func testSearch() {
        let store = HistoryStore()
        store.add(record("Hello world"))
        store.add(record("Goodbye"))
        XCTAssertEqual(store.search("hello").count, 1)
        XCTAssertEqual(store.search("").count, 2)
    }

    func testTotalWords() {
        let store = HistoryStore()
        store.add(record("a b c"))
        store.add(record("one two"))
        XCTAssertEqual(store.totalWords, 5)
    }
}
