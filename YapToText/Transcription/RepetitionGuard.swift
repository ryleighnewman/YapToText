import Foundation

/// Whisper's decoder loop, caught at the block level. The single-sentence guard in
/// WhisperEngine catches "A. A. A."; a long dictation on a poor input looped a two-sentence
/// block instead ("A. B. A. B. A. B. Um, A. B."), which that guard let through, and the
/// cleanup model then copied the loop forty more times (Oct 3 2026, 311 s, Clean Up).
/// Blocks of two or three sentences repeated three or more times in a row collapse to the
/// first copy. Leading fillers ("um," "uh,") are ignored when comparing, and the first
/// copy keeps its own text. No dependencies, so it is tested headlessly.
enum RepetitionGuard {
    static let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "mm", "like", "so", "and", "okay", "ok"]

    /// Split keeping each terminator with its sentence, so the join is lossless.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) || ch == "\n" { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The comparable words of a sentence: lowercased, punctuation gone, leading fillers dropped.
    static func key(_ s: String) -> [String] {
        var w = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        while let first = w.first, fillers.contains(first), w.count > 1 { w.removeFirst() }
        return w
    }

    /// Collapse repeated blocks of 2 or 3 sentences. Returns the text and how many sentences went.
    static func collapseBlocks(_ text: String) -> (text: String, removed: Int) {
        var sents = sentences(text)
        guard sents.count >= 6 else { return (text, 0) }
        var removed = 0
        for length in [3, 2] {
            var keys = sents.map(key)
            var out: [String] = []
            var i = 0
            while i < sents.count {
                guard i + length <= sents.count, keys[i..<(i + length)].allSatisfy({ !$0.isEmpty }) else {
                    out.append(sents[i]); i += 1; continue
                }
                let block = Array(keys[i..<(i + length)])
                var j = i + length
                var copies = 1
                while j + length <= sents.count, Array(keys[j..<(j + length)]) == block { j += length; copies += 1 }
                if copies >= 3 {
                    out.append(contentsOf: sents[i..<(i + length)])
                    removed += (copies - 1) * length
                    i = j
                } else {
                    out.append(sents[i]); i += 1
                }
            }
            sents = out
            keys = sents.map(key)
            _ = keys
        }
        return (removed > 0 ? sents.joined() : text, removed)
    }
}
