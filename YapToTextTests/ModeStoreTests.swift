import XCTest
@testable import YapToText

final class ModeStoreTests: XCTestCase {
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

    func testFirstRunSeedsBuiltInsAndPersists() {
        let store = ModeStore()
        XCTAssertEqual(store.modes.map(\.id), BuiltInModes.all.map(\.id))
        // Seeding is written to disk immediately, so a second launch reads the same list.
        let onDisk = Persistence.load([Mode].self, from: "modes.json")
        XCTAssertEqual(onDisk?.map(\.id), BuiltInModes.all.map(\.id))
    }

    func testEditedBuiltInSurvivesReloadInCanonicalOrder() {
        var edited = BuiltInModes.clean
        edited.name = "My Clean"
        let custom = Mode(name: "Custom A")
        // Saved order is scrambled on purpose: custom first, edited built-in second.
        Persistence.save([custom, edited], to: "modes.json")

        let store = ModeStore()
        // Built-ins come back in canonical order with the edit preserved; customs follow.
        XCTAssertEqual(store.builtInModes.map(\.id), BuiltInModes.all.map(\.id))
        XCTAssertEqual(store.mode(withID: BuiltInModes.clean.id)?.name, "My Clean")
        XCTAssertEqual(store.customModes.map(\.id), [custom.id])
        XCTAssertEqual(store.modes.last?.id, custom.id)
    }

    func testUpdatePersistsAcrossInstances() {
        let store = ModeStore()
        var raw = store.mode(withID: BuiltInModes.rawTranscriptionID)!
        raw.name = "Verbatim"
        store.update(raw)

        let reloaded = ModeStore()
        XCTAssertEqual(reloaded.mode(withID: BuiltInModes.rawTranscriptionID)?.name, "Verbatim")
    }

    func testDeleteResetsBuiltInButRemovesCustom() {
        let store = ModeStore()
        var clean = store.mode(withID: BuiltInModes.clean.id)!
        clean.name = "Edited"
        store.update(clean)

        store.delete(clean)   // built-in: resets instead of removing
        XCTAssertEqual(store.mode(withID: BuiltInModes.clean.id)?.name, BuiltInModes.clean.name)

        let custom = Mode(name: "Scratch")
        store.addCustomMode(custom)
        store.delete(custom)  // custom: actually removed
        XCTAssertNil(store.mode(withID: custom.id))
    }

    func testDuplicateMakesEditableCopy() {
        let store = ModeStore()
        let copy = store.duplicate(BuiltInModes.email)
        XCTAssertNotEqual(copy.id, BuiltInModes.email.id)
        XCTAssertEqual(copy.name, BuiltInModes.email.name + " Copy")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNotNil(store.mode(withID: copy.id))
    }

    func testRestoreBuiltInsResetsEditsAndKeepsCustoms() {
        let store = ModeStore()
        var note = store.mode(withID: BuiltInModes.note.id)!
        note.instructions = "changed"
        store.update(note)
        let custom = Mode(name: "Keep Me")
        store.addCustomMode(custom)

        store.restoreBuiltIns()
        XCTAssertEqual(store.mode(withID: BuiltInModes.note.id)?.instructions, BuiltInModes.note.instructions)
        XCTAssertEqual(store.builtInModes.map(\.id), BuiltInModes.all.map(\.id))
        XCTAssertNotNil(store.mode(withID: custom.id))
    }

    func testResolvedModePrecedence() {
        let store = ModeStore()
        let custom = Mode(name: "Slack Mode")
        store.addCustomMode(custom)

        // Per-app override wins over the active mode.
        let overridden = store.resolvedMode(activeID: BuiltInModes.rawTranscriptionID,
                                            appBundleID: "com.slack.Slack",
                                            overrides: ["com.slack.Slack": custom.id])
        XCTAssertEqual(overridden.id, custom.id)

        // No override: the active mode.
        let active = store.resolvedMode(activeID: BuiltInModes.email.id, appBundleID: "com.apple.mail", overrides: [:])
        XCTAssertEqual(active.id, BuiltInModes.email.id)

        // Unknown active id: falls back to the first mode rather than crashing.
        let fallback = store.resolvedMode(activeID: UUID(), appBundleID: nil, overrides: [:])
        XCTAssertEqual(fallback.id, store.modes.first?.id)
    }

    func testResolvedModeFallsBackWhenOverrideModeDeleted() {
        let store = ModeStore()
        // A per-app override that points at a mode that no longer exists (the user deleted it)
        // must fall back to the active mode, not return an empty/garbage mode.
        let dangling = ["com.apple.mail": UUID()]
        let resolved = store.resolvedMode(activeID: BuiltInModes.clean.id,
                                          appBundleID: "com.apple.mail",
                                          overrides: dangling)
        XCTAssertEqual(resolved.id, BuiltInModes.clean.id)
    }
}
