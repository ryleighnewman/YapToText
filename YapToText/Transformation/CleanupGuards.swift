import Foundation

/// Checks on the cleanup model's output for the modes that must PRESERVE what was said
/// (Clean Up, and Auto's conservative repair). A small model on a long, looping transcript
/// copied the loop about forty times, garbled the end, and stopped mid-sentence at its
/// token limit (Oct 3 2026); the growth guard of 3x let 1,132 words through for 465 in.
/// No dependencies, so these are tested headlessly.
enum CleanupGuards {
    /// A preserving mode fixes and trims; it never grows the text past this.
    static func growsTooMuch(inWords: Int, outWords: Int) -> Bool {
        inWords >= 8 && Double(outWords) > Double(inWords) * 1.3 + 20
    }

    /// A sentence of four or more words that the output repeats more often than the raw
    /// text did is the model looping, whatever the word counts say.
    static func repeatsMoreThanInput(raw: String, output: String) -> Bool {
        func counts(_ text: String) -> [[String]: Int] {
            var c: [[String]: Int] = [:]
            for s in RepetitionGuard.sentences(text) {
                let k = RepetitionGuard.key(s)
                if k.count >= 4 { c[k, default: 0] += 1 }
            }
            return c
        }
        let rawC = counts(raw), outC = counts(output)
        return outC.contains { k, n in n > max(1, rawC[k] ?? 0) }
    }

    /// The end of the dictation is missing from the output: the model stopped short and left
    /// the last section out (a long passage came back without its final part, reported Oct 21
    /// 2026). The content words of the final sentence (the final two when the last one is
    /// short) are looked for anywhere in the output; fewer than half present means the end
    /// was dropped. Spelling fixes to a word or two still pass.
    static func dropsTail(raw: String, output: String) -> Bool {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        guard rawWords >= 12 else { return false }
        var tail: [String] = []
        for s in RepetitionGuard.sentences(raw).reversed() {
            tail = RepetitionGuard.key(s).filter { $0.count >= 4 } + tail
            if tail.count >= 3 { break }
        }
        guard tail.count >= 3 else { return false }
        let outWords = Set(output.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let found = tail.filter { outWords.contains($0) }.count
        return found * 2 < tail.count
    }

    /// The raw transcript ended a sentence and the output does not: the model ran out of
    /// tokens or stopped mid-sentence. Only for long outputs, where that is what it means.
    static func endsMidSentence(raw: String, output: String) -> Bool {
        let rawEnd = raw.trimmingCharacters(in: .whitespacesAndNewlines).last
        let outEnd = output.trimmingCharacters(in: .whitespacesAndNewlines).last
        guard let rawEnd, let outEnd else { return false }
        let terminators = ".!?…\"')]"
        let outWords = output.split(whereSeparator: \.isWhitespace).count
        return outWords >= 40 && terminators.contains(rawEnd) && !terminators.contains(outEnd)
    }
}
