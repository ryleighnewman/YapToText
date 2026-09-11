import Foundation

/// Literal replacements never need the model. "Change this to named" on a selected "different"
/// went to the edit model and came back as "Different Name" (2026-09-16 17:26): a small model
/// reading a one-word swap as a naming task. When the instruction is explicitly "change /
/// replace / swap / switch … to / with X" and X is a plain word or short phrase, the answer is X,
/// with the selection's own capitalisation and trailing punctuation carried over.
///
/// Anything that names a STYLE, FORMAT, TENSE, or LANGUAGE ("change this to a question", "to
/// Spanish", "to bullet points", "to past tense") is a rewrite and still goes to the model.
enum ReplaceEdit {
    /// Words that mark a rewrite rather than a literal replacement.
    private static let rewriteWords: Set<String> = [
        "question", "questions", "statement", "list", "bullet", "bullets", "points", "heading", "title",
        "sentence", "sentences", "paragraph", "paragraphs", "tense", "past", "present", "future", "plural",
        "singular", "formal", "informal", "casual", "polite", "friendly", "professional", "shorter",
        "longer", "simpler", "simple", "clearer", "concise", "brief", "summary", "bold", "italic",
        "uppercase", "lowercase", "capitalized", "capitalised", "caps", "quote", "code", "email",
        "message", "note", "spanish", "french", "german", "italian", "portuguese", "japanese", "chinese",
        "korean", "english", "dutch", "russian", "arabic", "hindi", "language", "words", "synonym",
        "opposite", "number", "numbers", "digits", "percentage", "date", "time",
    ]

    /// The literal text to put in place of `selection`, or nil when this is not a literal swap.
    static func apply(instruction: String, to selection: String) -> String? {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(?:please\s+)?(?:can you\s+|could you\s+)?(?:change|replace|swap|switch|rename)\s+(?:this|that|it|this word|that word|the word|this one|the selection)?\s*(?:to|with|for|into)\s+(.+?)[.!?]*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
              let r = Range(m.range(at: 1), in: trimmed) else { return nil }
        var replacement = String(trimmed[r]).trimmingCharacters(in: .whitespaces)
        // "to say X" / "to the word X" / "to X instead"
        for prefix in ["say ", "the word ", "the phrase ", "just "] where replacement.lowercased().hasPrefix(prefix) {
            replacement = String(replacement.dropFirst(prefix.count))
        }
        if replacement.lowercased().hasSuffix(" instead") { replacement = String(replacement.dropLast(" instead".count)) }
        replacement = replacement.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}'\u{2018}\u{2019} "))
        let words = replacement.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !words.isEmpty, words.count <= 6, !words.contains(where: { rewriteWords.contains($0) }) else { return nil }
        // Only a short selection is a literal swap; a sentence "changed to X" is a rewrite.
        let selWords = selection.split { $0.isWhitespace }.count
        guard selWords >= 1, selWords <= 4 else { return nil }
        // Carry the selection's shape: leading capital, ALL CAPS, and trailing punctuation.
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = sel.filter { $0.isLetter }
        var out = replacement
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }), letters.count > 1 {
            out = out.uppercased()
        } else if let first = letters.first, first.isUppercase, out.first?.isLowercase == true {
            out = out.prefix(1).uppercased() + out.dropFirst()
        }
        if let last = sel.last, ".,;:!?".contains(last), !(out.last.map { ".,;:!?".contains($0) } ?? false) {
            out.append(last)
        }
        return out
    }
}
