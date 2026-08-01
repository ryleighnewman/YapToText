import Foundation
import Observation

/// Owns the full mode catalog as one editable, persisted list. The built-in modes are seeded
/// into the store on first run and are then fully editable and saved just like custom modes;
/// `BuiltInModes` only supplies the factory defaults for "Reset to default" / "Restore".
@Observable
final class ModeStore {
    private(set) var modes: [Mode]

    @ObservationIgnored private static let fileName = "modes.json"

    init() {
        if let loaded = Persistence.load([Mode].self, from: ModeStore.fileName) {
            // Keep the user's edits (reuse each loaded built-in where present), but always list the
            // built-ins in canonical order, then customs in saved order. A new built-in shipped in
            // an app update slots into its canonical position instead of jumping to the top.
            let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let orderedBuiltIns = BuiltInModes.all.map { byID[$0.id] ?? $0 }
            let customs = loaded.filter { !BuiltInModes.isBuiltIn($0.id) }
            modes = orderedBuiltIns + customs
        } else {
            modes = BuiltInModes.all
        }
        save()
    }

    var allModes: [Mode] { modes }

    /// Drag reorder from the modes list. Digits renumber automatically (they follow order).
    func moveModes(fromOffsets source: IndexSet, toOffset destination: Int) {
        rememberForUndo()
        modes.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Reorder: move a mode one step up or down in the master list. The switcher digits
    /// (1-9) follow this order, so moving a mode automatically renumbers everything.
    func move(_ mode: Mode, up: Bool) {
        guard let i = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        let j = up ? i - 1 : i + 1
        guard modes.indices.contains(j) else { return }
        rememberForUndo()
        modes.swapAt(i, j)
        save()
    }

    // MARK: Undo (single-step, whole-list snapshots)

    /// The last few states of the mode list; any edit (rename, prompt change, reorder,
    /// delete) can be stepped back with Undo Mode Change.
    private var undoStack: [[Mode]] = []

    func rememberForUndo() {
        undoStack.append(modes)
        if undoStack.count > 25 { undoStack.removeFirst() }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undoLastChange() {
        guard let previous = undoStack.popLast() else { return }
        modes = previous
        save()
    }
    var builtInModes: [Mode] { modes.filter { BuiltInModes.isBuiltIn($0.id) } }
    var customModes: [Mode] { modes.filter { !BuiltInModes.isBuiltIn($0.id) } }

    func mode(withID id: UUID) -> Mode? { modes.first { $0.id == id } }

    /// Resolve the mode to use, honoring per-app overrides when present.
    func resolvedMode(activeID: UUID, appBundleID: String?, overrides: [String: UUID]) -> Mode {
        if let bundleID = appBundleID, let overrideID = overrides[bundleID], let m = mode(withID: overrideID) {
            return m
        }
        return mode(withID: activeID) ?? modes.first ?? BuiltInModes.raw
    }

    // MARK: Mutations (any mode, built-in or custom)

    func update(_ mode: Mode) {
        guard let idx = modes.firstIndex(where: { $0.id == mode.id }) else {
            // First edit of a virtual mode (Auto): adopt it into the store so the change persists.
            rememberForUndo()
            modes.insert(mode, at: 0)
            save()
            return
        }
        // Draft edits stream in per keystroke; snapshot only when a NEW edit burst begins
        // (>2s since the last), so Undo steps back a whole edit, not one character.
        if Date().timeIntervalSince(lastEditAt) > 2 { rememberForUndo() }
        lastEditAt = Date()
        modes[idx] = mode
        save()
    }
    private var lastEditAt = Date.distantPast

    func addCustomMode(_ mode: Mode) {
        var m = mode
        m.isBuiltIn = false
        modes.append(m)
        save()
    }

    /// Delete a custom mode. Built-in modes are reset to their default instead of removed, so a
    /// core mode can never be lost by accident (use restoreBuiltIns to bring one back).
    func delete(_ mode: Mode) {
        rememberForUndo()
        if BuiltInModes.isBuiltIn(mode.id) {
            resetToDefault(mode)
        } else {
            modes.removeAll { $0.id == mode.id }
            save()
        }
    }

    @discardableResult
    func duplicate(_ mode: Mode) -> Mode {
        var copy = mode
        copy.id = UUID()
        copy.name = mode.name + " Copy"
        copy.isBuiltIn = false
        modes.append(copy)
        save()
        return copy
    }

    /// Reset a built-in mode back to its shipped default.
    func resetToDefault(_ mode: Mode) {
        guard let def = BuiltInModes.all.first(where: { $0.id == mode.id }),
              let idx = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[idx] = def
        save()
    }

    /// Reset all built-ins to their defaults and re-add any that were removed.
    func restoreBuiltIns() {
        var insertIndex = 0
        for def in BuiltInModes.all {
            if let idx = modes.firstIndex(where: { $0.id == def.id }) {
                modes[idx] = def
                insertIndex = idx + 1
            } else {
                modes.insert(def, at: min(insertIndex, modes.count))
                insertIndex += 1
            }
        }
        save()
    }

    private func save() {
        Persistence.save(modes, to: ModeStore.fileName)
    }
}
