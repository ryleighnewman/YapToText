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

/// A mishear the user has corrected by voice ("replace X with Y") - tracked so a REPEATED
/// correction can be offered as a permanent dictionary entry (which then primes Whisper).
struct LearnedCorrection: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var from: String
    var to: String
    var count: Int = 1
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
    /// Repeated voice corrections, counted. When one hits the threshold it becomes a suggestion.
    private(set) var learned: [LearnedCorrection] = []
    /// A correction the user has made enough times to be worth making permanent. The UI watches
    /// this and offers "add it to your dictionary?" - transient, never persisted.
    var pendingSuggestion: LearnedCorrection?

    @ObservationIgnored private static let fileName = "vocabulary.json"
    @ObservationIgnored private static let suggestThreshold = 2

    struct Snapshot: Codable {
        var dictionaries: [VocabDictionary]
        /// One-shot migration marker: v2 added the multi-word "mac os" fixes to EXISTING
        /// installs (starters only seed brand-new ones).
        var migratedMacOSFix: Bool? = nil
        /// v3 added the app's own name: the recognizers hear "YapToText" as "yep to text".
        var migratedYapFix: Bool? = nil
        var learned: [LearnedCorrection]? = nil
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
    ] + yapToTextFixes

    /// The app's own name, as the speech models actually hear it. Visible in the dictionary
    /// so it can be edited; `brandNormalizer` below catches the long tail of spellings.
    static let yapToTextFixes: [Replacement] = [
        Replacement(from: "yap to text", to: "YapToText"),
        Replacement(from: "yep to text", to: "YapToText"),
        Replacement(from: "yep, to text", to: "YapToText"),
        Replacement(from: "yup to text", to: "YapToText"),
        Replacement(from: "yap two text", to: "YapToText"),
        Replacement(from: "yep two texts", to: "YapToText"),
        Replacement(from: "yep, two texts", to: "YapToText"),
        Replacement(from: "bit to text", to: "YapToText"),
        Replacement(from: "yap the text", to: "YapToText"),
        Replacement(from: "yaptotext", to: "YapToText"),
        Replacement(from: "yap-to-text", to: "YapToText"),
    ]

    /// Every remaining way to mishear the name, in one pass: a yap-like first word, a
    /// to-like middle (which the middle is REQUIRED, so "yep, text me later" is safe), a
    /// text-like ending, with or without spaces ("yapToText", "Yep, ToText", "Yeah, P2Text",
    /// "yeah, put to text"). "yet to text" and "app to text" are real phrases ("I have yet to
    /// text him", "tell the app to text me") and stay out on purpose; so does "yeah to text".
    static let brandNormalizer: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(?:yap|yapp|yep|yup|imp|yip),?\s*(?:to|two|2|the|ta|put\s+to|p\s*2)\s*(?:texts?|tex|tax|test|tech|txt)\b|\bbit,?\s+(?:to|two|2|ta)\s+(?:texts?|tex|tax|txt)\b|\byeah,?\s*(?:p\s*2\s*(?:texts?|tex)|put\s+to\s+(?:texts?|tex)|totext)\b|\byap-to-text\b"#,
        options: [.caseInsensitive])

    init() {
        if let snap = Persistence.load(Snapshot.self, from: VocabularyStore.fileName), !snap.dictionaries.isEmpty {
            dictionaries = snap.dictionaries
            learned = snap.learned ?? []
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
        // v3 migration for EXISTING installs: the app's own name, once, skipping anything the
        // user already covers; a deliberate delete stays deleted after this stamp.
        let yapMigrated = Persistence.load(Snapshot.self, from: VocabularyStore.fileName)?.migratedYapFix ?? false
        if !yapMigrated, !dictionaries.isEmpty {
            let covered = Set(dictionaries.flatMap { $0.replacements.map { $0.from.lowercased() } })
            for fix in VocabularyStore.yapToTextFixes where !covered.contains(fix.from.lowercased()) {
                dictionaries[0].replacements.append(fix)
            }
            save()
        }
    }

    func apply(to text: String) -> String {
        apply(to: text, dictionaryIDs: nil)
    }

    /// A Whisper INITIAL-PROMPT built from the user's own vocabulary - the exact spellings the
    /// model should hear (names, jargon, brand casings). Priming the decoder with these makes it
    /// recognize the words in the FIRST place, instead of the post-hoc `apply` substitution only
    /// catching a mishear AFTER it happened ("grade the chips" for "gray the chips"). The same
    /// dictionary selection as `apply` (mode-pinned list, else all enabled). Returns nil when
    /// there's nothing worth priming. Length-capped well under Whisper's ~224-token prompt budget.
    func primingPrompt(dictionaryIDs: [UUID]?) -> String? {
        let selected: [VocabDictionary]
        if let dictionaryIDs {
            let idSet = Set(dictionaryIDs)
            selected = dictionaries.filter { idSet.contains($0.id) }
        } else {
            selected = dictionaries.filter { $0.enabled }
        }
        var seen = Set<String>()
        var terms: [String] = []
        for dict in selected {
            for r in dict.replacements {
                let term = r.to.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empties, single chars, and long phrases (those aren't vocabulary the
                // decoder needs primed - they're reformattings the substitution handles).
                guard term.count >= 2, term.count <= 40 else { continue }
                if seen.insert(term.lowercased()).inserted { terms.append(term) }
            }
        }
        guard !terms.isEmpty else { return nil }
        var kept: [String] = []
        var budget = 0
        for t in terms {
            if budget + t.count + 2 > 200 { break }   // ~200 chars stays safely inside the window
            kept.append(t); budget += t.count + 2
        }
        // A glossary framing is the established way to bias Whisper toward specific words.
        return "Glossary: " + kept.joined(separator: ", ") + "."
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
        return VocabularyStore.normalizeBrand(in: result)
    }

    /// The app's own name, however it was heard.
    static func normalizeBrand(in text: String) -> String {
        guard let re = brandNormalizer else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "YapToText")
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
        Persistence.save(Snapshot(dictionaries: dictionaries, migratedMacOSFix: true, migratedYapFix: true, learned: learned),
                         to: VocabularyStore.fileName)
    }

    // MARK: - Learning from corrections

    /// Record a voice correction ("replace X with Y"). When the SAME mishear is corrected enough
    /// times, `pendingSuggestion` is raised so the UI can offer to make it permanent - which, once
    /// accepted, both fixes it automatically AND primes Whisper to hear it right next time.
    func noteCorrection(from rawFrom: String, to rawTo: String) {
        let from = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = rawTo.trimmingCharacters(in: .whitespacesAndNewlines)
        // Learn only word-level fixes (not sentence rewrites), a real change, sane lengths.
        guard from.count >= 2, from.count <= 40, !to.isEmpty, to.count <= 40,
              from.lowercased() != to.lowercased(),
              from.split(separator: " ").count <= 3 else { return }
        let key = from.lowercased()
        // Already covered by a substitution? Nothing to learn.
        if dictionaries.contains(where: { $0.replacements.contains { $0.from.lowercased() == key } }) { return }
        if let i = learned.firstIndex(where: { $0.from.lowercased() == key }) {
            learned[i].count += 1
            learned[i].to = to   // remember the most recent target
            if learned[i].count >= VocabularyStore.suggestThreshold { pendingSuggestion = learned[i] }
        } else {
            learned.append(LearnedCorrection(from: from, to: to))
        }
        save()
    }

    /// Accept the pending suggestion: add it as a permanent substitution in a "Learned" dictionary.
    func acceptSuggestion() {
        guard let s = pendingSuggestion else { return }
        let replacement = Replacement(from: s.from, to: s.to)
        if let i = dictionaries.firstIndex(where: { $0.name == "Learned" }) {
            dictionaries[i].replacements.append(replacement)
        } else {
            dictionaries.append(VocabDictionary(name: "Learned", enabled: true, replacements: [replacement]))
        }
        learned.removeAll { $0.from.lowercased() == s.from.lowercased() }
        pendingSuggestion = nil
        save()
    }

    /// Dismiss the suggestion and stop counting this pair, so it never nags again.
    func dismissSuggestion() {
        if let s = pendingSuggestion { learned.removeAll { $0.from.lowercased() == s.from.lowercased() } }
        pendingSuggestion = nil
        save()
    }
}
