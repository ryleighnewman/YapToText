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
        guard let idx = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[idx] = mode
        save()
    }

    func addCustomMode(_ mode: Mode) {
        var m = mode
        m.isBuiltIn = false
        modes.append(m)
        save()
    }

    /// Delete a custom mode. Built-in modes are reset to their default instead of removed, so a
    /// core mode can never be lost by accident (use restoreBuiltIns to bring one back).
    func delete(_ mode: Mode) {
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
