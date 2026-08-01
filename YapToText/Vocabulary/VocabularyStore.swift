import Foundation
import Observation

/// A single find-and-replace applied to transcripts (fixes names, casing, homophones).
struct Replacement: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var from: String
    var to: String
    var caseSensitive: Bool = false
    var wholeWord: Bool = true
}

/// A named, toggleable set of substitutions. Users can keep several (e.g. "Work", "Medical").
struct VocabDictionary: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var enabled: Bool = true
    var replacements: [Replacement] = []
}

/// Owns the user's vocabulary dictionaries. `apply(to:)` runs every enabled dictionary's
/// substitutions over a transcript, in order.
@Observable
final class VocabularyStore {
    private(set) var dictionaries: [VocabDictionary]

    @ObservationIgnored private static let fileName = "vocabulary.json"

    struct Snapshot: Codable {
        var dictionaries: [VocabDictionary]
        /// One-shot migration marker: v2 added the multi-word "mac os" fixes to EXISTING
        /// installs (starters only seed brand-new ones).
        var migratedMacOSFix: Bool? = nil
    }
    private struct LegacySnapshot: Codable { var replacements: [Replacement]; var vocabularyHints: [String]? }

    /// Starter substitutions every user actually benefits from: brand casings the speech models
    /// reliably lowercase. Seeded ONLY when the user has no replacements of their own, so app
    /// updates can never disturb an existing library.
    static let starterReplacements: [Replacement] = [
        Replacement(from: "iphone", to: "iPhone"),
        Replacement(from: "ipad", to: "iPad"),
        Replacement(from: "imac", to: "iMac"),
        Replacement(from: "airpods", to: "AirPods"),
        Replacement(from: "macos", to: "macOS"),
        Replacement(from: "mac os", to: "macOS"),   // recognizers say it as two words
        Replacement(from: "mac o s", to: "macOS"),
        Replacement(from: "youtube", to: "YouTube"),
        Replacement(from: "wifi", to: "Wi-Fi"),
    ]

    init() {
        if let snap = Persistence.load(Snapshot.self, from: VocabularyStore.fileName), !snap.dictionaries.isEmpty {
            dictionaries = snap.dictionaries
        } else if let legacy = Persistence.load(LegacySnapshot.self, from: VocabularyStore.fileName) {
            // Migrate the old flat replacement list into a default dictionary.
            dictionaries = [VocabDictionary(name: "General", enabled: true, replacements: legacy.replacements)]
        } else {
            // True first run: start with the useful examples, which double as a demonstration
            // of what dictionaries are for.
            dictionaries = [VocabDictionary(name: "General", enabled: true,
                                            replacements: VocabularyStore.starterReplacements)]
        }
        // An install that has NEVER added a replacement gets the starters too (they lose
        // nothing); anyone with even one replacement of their own is left completely alone.
        if dictionaries.allSatisfy({ $0.replacements.isEmpty }), !dictionaries.isEmpty {
            dictionaries[0].replacements = VocabularyStore.starterReplacements
            save()
        }
        // v2 migration for EXISTING installs: the recognizer says "Mac OS" as two words, which
        // the one-word "macos" starter never matched. Add the multi-word forms once, only where
        // nothing already covers them; the marker keeps a user's deliberate delete deleted.
        let migrated = Persistence.load(Snapshot.self, from: VocabularyStore.fileName)?.migratedMacOSFix ?? false
        if !migrated, !dictionaries.isEmpty {
            let covered = Set(dictionaries.flatMap { $0.replacements.map { $0.from.lowercased() } })
            for fix in [Replacement(from: "mac os", to: "macOS"), Replacement(from: "mac o s", to: "macOS")]
            where !covered.contains(fix.from) {
                dictionaries[0].replacements.append(fix)
            }
            save()
        }
    }

    func apply(to text: String) -> String {
        apply(to: text, dictionaryIDs: nil)
    }

    /// Apply substitutions. When `dictionaryIDs` is nil, every enabled dictionary runs (the
    /// global default). When a mode supplies its own list, exactly those dictionaries run
    /// (whether or not they're globally enabled), so a mode can pin its own vocabulary.
    func apply(to text: String, dictionaryIDs: [UUID]?) -> String {
        let selected: [VocabDictionary]
        if let dictionaryIDs {
            let idSet = Set(dictionaryIDs)
            selected = dictionaries.filter { idSet.contains($0.id) }
        } else {
            selected = dictionaries.filter { $0.enabled }
        }
        var result = text
        for dict in selected {
            for r in dict.replacements where !r.from.isEmpty {
                result = VocabularyStore.applyReplacement(r, to: result)
            }
        }
        return result
    }

    static func applyReplacement(_ r: Replacement, to text: String) -> String {
        let options: NSRegularExpression.Options = r.caseSensitive ? [] : [.caseInsensitive]
        // Multi-word phrases match across any run of whitespace, so "as per say" catches the
        // spoken phrase however the recognizer spaced it - several heard words can collapse
        // into one replacement.
        let escaped = r.from.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        let pattern: String
        if r.wholeWord {
            func isWordChar(_ c: Character?) -> Bool {
                guard let c else { return false }
                return c.isLetter || c.isNumber || c == "_"
            }
            let lead = isWordChar(r.from.first) ? "\\b" : ""
            let trail = isWordChar(r.from.last) ? "\\b" : ""
            pattern = lead + escaped + trail
        } else {
            pattern = escaped
        }
        guard let regex = cachedRegex(pattern, caseSensitive: r.caseSensitive, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: r.to)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Compiled-regex cache keyed on (pattern, case-sensitivity). Both the pattern and the options
    /// derive entirely from the immutable fields of a Replacement, so an entry is always valid for
    /// its key and needs no invalidation. Removes redundant ICU compiles (applyReplacement runs
    /// ~2x per AI dictation, scaling with dictionary size) from the main-actor path.
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()
    private static func cachedRegex(_ pattern: String, caseSensitive: Bool,
                                    options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = (caseSensitive ? "1\u{0}" : "0\u{0}") + pattern
        regexCacheLock.lock(); defer { regexCacheLock.unlock() }
        if let hit = regexCache[key] { return hit }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache[key] = compiled
        return compiled
    }

    // MARK: Dictionaries

    @discardableResult
    func addDictionary(name: String) -> VocabDictionary {
        let dict = VocabDictionary(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Dictionary" : name)
        dictionaries.append(dict)
        save()
        return dict
    }

    func rename(_ dict: VocabDictionary, to name: String) {
        guard let i = index(of: dict) else { return }
        dictionaries[i].name = name
        save()
    }

    func setEnabled(_ dict: VocabDictionary, _ enabled: Bool) {
        guard let i = index(of: dict) else { return }
        dictionaries[i].enabled = enabled
        save()
    }

    func deleteDictionary(_ dict: VocabDictionary) {
        dictionaries.removeAll { $0.id == dict.id }
        if dictionaries.isEmpty { dictionaries = [VocabDictionary(name: "General")] }
        save()
    }

    // MARK: Replacements

    func addReplacement(_ r: Replacement, to dictID: UUID) {
        guard let i = dictionaries.firstIndex(where: { $0.id == dictID }) else { return }
        dictionaries[i].replacements.append(r)
        save()
    }

    /// Edit an existing substitution in place, keyed by its stable ID.
    func updateReplacement(_ r: Replacement, in dictID: UUID) {
        guard let d = dictionaries.firstIndex(where: { $0.id == dictID }),
              let i = dictionaries[d].replacements.firstIndex(where: { $0.id == r.id }) else { return }
        dictionaries[d].replacements[i] = r
        save()
    }

    /// Insert a copy of `r` right below it - handy for building families of similar fixes.
    func duplicateReplacement(_ r: Replacement, in dictID: UUID) {
        guard let d = dictionaries.firstIndex(where: { $0.id == dictID }),
              let i = dictionaries[d].replacements.firstIndex(where: { $0.id == r.id }) else { return }
        var copy = r
        copy.id = UUID()
        dictionaries[d].replacements.insert(copy, at: i + 1)
        save()
    }

    /// Reorder by drag: move the dragged replacement so it sits before `targetID`.
    /// Order matters - substitutions run top to bottom.
    func moveReplacement(id: UUID, before targetID: UUID, in dictID: UUID) {
        guard id != targetID,
              let d = dictionaries.firstIndex(where: { $0.id == dictID }),
              let from = dictionaries[d].replacements.firstIndex(where: { $0.id == id }) else { return }
        let item = dictionaries[d].replacements.remove(at: from)
        if let to = dictionaries[d].replacements.firstIndex(where: { $0.id == targetID }) {
            dictionaries[d].replacements.insert(item, at: to)
        } else {
            dictionaries[d].replacements.insert(item, at: from)
        }
        save()
    }

    func deleteReplacement(_ r: Replacement, in dictID: UUID) {
        guard let i = dictionaries.firstIndex(where: { $0.id == dictID }) else { return }
        dictionaries[i].replacements.removeAll { $0.id == r.id }
        save()
    }

    /// Convenience: add to the first dictionary (used for quick adds and by tests).
    func addReplacement(_ r: Replacement) {
        if dictionaries.isEmpty { dictionaries = [VocabDictionary(name: "General")] }
        dictionaries[0].replacements.append(r)
        save()
    }

    private func index(of dict: VocabDictionary) -> Int? {
        dictionaries.firstIndex { $0.id == dict.id }
    }

    private func save() {
        // The migration marker is stamped on EVERY save, so the mac-os fix runs exactly once
        // per install and a deliberate user delete stays deleted.
        Persistence.save(Snapshot(dictionaries: dictionaries, migratedMacOSFix: true),
                         to: VocabularyStore.fileName)
    }
}
