import XCTest
@testable import YapToText

final class AIActionStoreTests: XCTestCase {
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

    func testDefaultsSeeded() {
        let store = AIActionStore()
        XCTAssertFalse(store.actions.isEmpty)
        XCTAssertTrue(store.actions.contains { $0.name == "Improve Writing" })
        XCTAssertTrue(store.actions.allSatisfy { !$0.instructions.isEmpty })
    }

    func testAddUpdateDelete() {
        let store = AIActionStore()
        let added = store.add()
        XCTAssertNotNil(store.action(withID: added.id))

        var edited = added
        edited.name = "Shout"
        edited.instructions = "UPPERCASE IT"
        store.update(edited)
        XCTAssertEqual(store.action(withID: added.id)?.name, "Shout")
        XCTAssertEqual(store.action(withID: added.id)?.instructions, "UPPERCASE IT")

        store.delete(added)
        XCTAssertNil(store.action(withID: added.id))
    }

    func testPersistenceRoundTrip() {
        let store = AIActionStore()
        let added = store.add()
        var edited = added
        edited.name = "Custom One"
        store.update(edited)
        store.flush()   // writes are debounced

        let reloaded = AIActionStore()
        XCTAssertTrue(reloaded.actions.contains { $0.name == "Custom One" })
    }

    func testRestoreDefaults() {
        let store = AIActionStore()
        store.actions.forEach { store.delete($0) }
        XCTAssertTrue(store.actions.isEmpty)
        store.restoreDefaults()
        XCTAssertEqual(store.actions.map(\.name), AIActionStore.defaults.map(\.name))
    }
}
