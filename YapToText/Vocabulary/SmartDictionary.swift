import Foundation

/// Smart dictionary: learns recurring fixes from the user's own history. When the pipeline
/// (AI cleanup or an existing substitution) keeps re-casing the same word the recognizer
/// heard - "iphone" coming out as "iPhone" three separate times - that's a correction worth
/// making permanent, so it's offered as a one-click vocabulary suggestion. Everything runs
/// on the local history file; nothing is sent anywhere.
enum SmartDictionary {
    struct Suggestion: Identifiable, Equatable {
        var id: String { from.lowercased() + "|" + to }
        var from: String
        var to: String
        var count: Int
    }

    private struct DismissedFile: Codable { var keys: [String] }
    private static let fileName = "smart-dictionary.json"

    static func loadDismissed() -> Set<String> {
        Set(Persistence.load(DismissedFile.self, from: fileName)?.keys ?? [])
    }

    static func dismiss(_ suggestion: Suggestion) {
        var keys = loadDismissed()
        keys.insert(suggestion.id)
        Persistence.save(DismissedFile(keys: Array(keys)), to: fileName)
    }

    /// Scan recent history for words whose casing the pipeline changed, count how often each
    /// exact fix recurred, and return the fixes seen at least `threshold` times that aren't
    /// already covered by a replacement and weren't dismissed.
    static func suggestions(history: [DictationRecord],
                            vocabulary: VocabularyStore,
                            threshold: Int = 3,
                            maxRecords: Int = 400) -> [Suggestion] {
        let dismissed = loadDismissed()
        // Every "heard" form already handled by the user's dictionaries, so we never re-suggest.
        let covered = Set(vocabulary.dictionaries.flatMap { $0.replacements.map { $0.from.lowercased() } })

        var counts: [String: (from: String, to: String, count: Int)] = [:]
        for record in history.prefix(maxRecords) where record.rawText != record.finalText {
            let rawWords = words(in: record.rawText)
            let finalWords = words(in: record.finalText)
            // Raw forms the recognizer produced, keyed by lowercase.
            var rawByLower: [String: String] = [:]
            for w in rawWords { rawByLower[w.lowercased()] = w }
            let finalExact = Set(finalWords)
            for f in Set(finalWords) {
                guard f.count >= 3 else { continue }
                let lower = f.lowercased()
                guard let heard = rawByLower[lower], heard != f,
                      !finalExact.contains(heard)   // the raw casing also survived: ambiguous, skip
                else { continue }
                let key = lower + "|" + f
                var entry = counts[key] ?? (from: heard, to: f, count: 0)
                entry.count += 1
                counts[key] = entry
            }
        }
        return counts.values
            .filter { $0.count >= threshold }
            .filter { !covered.contains($0.from.lowercased()) }
            .map { Suggestion(from: $0.from.lowercased(), to: $0.to, count: $0.count) }
            .filter { !dismissed.contains($0.id) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { $0 }
    }

    private static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
    }
}
