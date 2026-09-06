import Foundation

/// Spoken case changes handled without the model: "capitalize this", "all caps", "make it
/// lowercase", "title case", "capitalize the last letter", "uppercase the first word". A
/// small model told to preserve words tends to leave text that already starts with a capital
/// untouched (or explains why it will not), so these run deterministically and instantly.
/// Returns nil when the instruction says anything beyond a case change, so the model gets it.
enum CaseEdit {
    enum Op { case upper, lower, capitalize }
    enum Target { case whole, eachWord, firstLetter, lastLetter, firstWord, lastWord, lastLetterOfEachWord, firstLetterOfEachWord }

    static func parse(_ instruction: String) -> (Op, Target)? {
        let words = instruction.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .map(String.init)
        guard !words.isEmpty else { return nil }
        let set = Set(words)
        let filler: Set<String> = [
            "please", "make", "put", "turn", "change", "this", "it", "that", "these", "those", "both",
            "of", "the", "sentence", "sentences", "word", "words", "text", "selection", "selected",
            "all", "everything", "in", "to", "into", "letters", "letter", "whole", "entire", "thing",
            "phrase", "line", "paragraph", "and", "a", "an", "on", "up", "case", "capital", "capitals",
            "caps", "first", "last", "final", "each", "every", "title", "upper", "lower", "uppercase",
            "lowercase", "capitalize", "capitalise", "capitalized", "capitalised", "small", "them", "so",
            "is", "are", "should", "be", "with", "as", "one", "ones", "here", "there", "now", "only",
            "character", "characters", "beginning", "end", "ending", "start", "big", "little",
        ]
        guard set.isSubset(of: filler) else { return nil }
        let has = { (w: String) in set.contains(w) }

        let op: Op
        if has("uppercase") || has("caps") || has("capitals") || (has("upper") && has("case"))
            || (has("capital") && (has("letters") || has("letter"))) || has("big") { op = .upper }
        else if has("lowercase") || (has("lower") && has("case")) || (has("small") && has("letters")) || has("little") { op = .lower }
        else if has("capitalize") || has("capitalise") || has("capitalized") || has("capitalised") { op = .capitalize }
        else if has("title") && has("case") { return (.capitalize, .eachWord) }
        else if has("sentence") && has("case") { return (.capitalize, .firstLetter) }
        else { return nil }

        let letter = has("letter") || has("letters") || has("character") || has("characters")
        let word = has("word") || has("words")
        let each = has("each") || has("every") || (has("all") && word)
        let first = has("first") || has("beginning") || has("start")
        let last = has("last") || has("final") || has("end") || has("ending")
        let target: Target
        if last && letter { target = each ? .lastLetterOfEachWord : .lastLetter }
        else if first && letter { target = each ? .firstLetterOfEachWord : .firstLetter }
        else if last && word { target = .lastWord }
        else if first && word { target = .firstWord }
        else if each && word { target = .eachWord }
        else if has("title") && has("case") { target = .eachWord }
        else if has("sentence") && has("case") { target = .firstLetter }
        else { target = .whole }
        return (op, target)
    }

    /// The edited text, or nil when the instruction is not a plain case change.
    static func apply(instruction: String, to text: String) -> String? {
        guard let (op, target) = parse(instruction) else { return nil }
        switch target {
        case .whole:
            switch op {
            case .upper: return text.uppercased()
            case .lower: return text.lowercased()
            case .capitalize:
                // Escalate so the request always changes something visible: sentence starts,
                // then every word, then every letter.
                let s = sentenceCase(text); if s != text { return s }
                let t = titleCase(text); if t != text { return t }
                return text.uppercased()
            }
        case .eachWord:
            switch op {
            case .upper: return text.uppercased()
            case .lower: return text.lowercased()
            case .capitalize: return titleCase(text)
            }
        case .firstLetter:
            return op == .lower ? mapSentenceStarts(text, { $0.lowercased() }) : sentenceCase(text)
        case .firstLetterOfEachWord:
            return op == .lower ? mapWordStarts(text, { $0.lowercased() }) : titleCase(text)
        case .lastLetter:
            return mapLetter(text, at: lastLetterIndex(text), op)
        case .lastLetterOfEachWord:
            return mapWordEnds(text, { op == .lower ? $0.lowercased() : $0.uppercased() })
        case .firstWord, .lastWord:
            guard let range = target == .firstWord ? firstWordRange(text) : lastWordRange(text) else { return text }
            let word = String(text[range])
            let edited: String
            switch op {
            case .upper: edited = word.uppercased()
            case .lower: edited = word.lowercased()
            case .capitalize: edited = word.prefix(1).uppercased() + word.dropFirst()
            }
            return text.replacingCharacters(in: range, with: edited)
        }
    }

    // MARK: Helpers

    static func sentenceCase(_ text: String) -> String { mapSentenceStarts(text, { $0.uppercased() }) }
    static func titleCase(_ text: String) -> String { mapWordStarts(text, { $0.uppercased() }) }

    private static func mapSentenceStarts(_ text: String, _ f: (String) -> String) -> String {
        var out = ""; out.reserveCapacity(text.count)
        var atStart = true
        for ch in text {
            if atStart, ch.isLetter { out.append(contentsOf: f(String(ch))); atStart = false; continue }
            out.append(ch)
            if ".!?".contains(ch) || ch.isNewline { atStart = true }
            else if !ch.isWhitespace, !"\"'\u{201C}\u{2018}([".contains(ch) { atStart = false }
        }
        return out
    }

    private static func mapWordStarts(_ text: String, _ f: (String) -> String) -> String {
        var out = ""; out.reserveCapacity(text.count)
        var atWordStart = true
        for ch in text {
            if atWordStart, ch.isLetter { out.append(contentsOf: f(String(ch))); atWordStart = false; continue }
            out.append(ch)
            atWordStart = ch.isWhitespace || "-/(\"\u{201C}".contains(ch)
        }
        return out
    }

    private static func mapWordEnds(_ text: String, _ f: (String) -> String) -> String {
        var chars = Array(text)
        for i in chars.indices where chars[i].isLetter {
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if next == nil || !(next!.isLetter || next! == "'") {
                chars.replaceSubrange(i...i, with: Array(f(String(chars[i]))))
            }
        }
        return String(chars)
    }

    private static func lastLetterIndex(_ text: String) -> String.Index? {
        text.lastIndex(where: { $0.isLetter })
    }

    private static func mapLetter(_ text: String, at index: String.Index?, _ op: Op) -> String {
        guard let index else { return text }
        let ch = String(text[index])
        let edited = op == .lower ? ch.lowercased() : ch.uppercased()
        return text.replacingCharacters(in: index...index, with: edited)
    }

    private static func firstWordRange(_ text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let end = text[start...].firstIndex(where: { !($0.isLetter || $0.isNumber || $0 == "'") }) ?? text.endIndex
        return start..<end
    }

    private static func lastWordRange(_ text: String) -> Range<String.Index>? {
        guard let last = text.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
        var start = last
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev].isLetter || text[prev].isNumber || text[prev] == "'" { start = prev } else { break }
        }
        return start..<text.index(after: last)
    }
}
