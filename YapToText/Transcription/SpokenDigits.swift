import Foundation

/// A dictation that is nothing but digits, spoken one at a time, is a code: a verification
/// code, a PIN, a phone extension. Whisper writes it out as prose ("One, three, five, seven,
/// two, one.") and the words then land in the field as words. Such a dictation becomes the
/// bare digits, with nothing else in it, so it goes into an authentication field cleanly.
///
/// Strict on purpose: the WHOLE utterance has to be digits, at least four of them, and
/// nothing else survives except separators. Whisper writes a spoken code as words
/// ("one, three, five"), as numerals ("1, 3, 5"), grouped ("804-949") or run together
/// ("848128."); every one of those becomes the bare digits. "I have two cats" is prose;
/// "two" alone is a word; "double five" and "triple seven" are the only multipliers.
enum SpokenDigits {
    private static let words: [String: Character] = [
        "zero": "0", "oh": "0", "o": "0", "nought": "0", "naught": "0",
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]
    private static let multipliers: [String: Int] = ["double": 2, "triple": 3]
    static let minimumDigits = 4

    /// The digits of a spoken code, or nil when the text is anything else.
    static func collapse(_ text: String) -> String? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "[,.;:!?\\-\u{2013}\u{2014}\\n\\r\\t]", with: " ", options: .regularExpression)
        let tokens = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var digits = ""
        var pendingMultiplier = 1
        for token in tokens {
            if let m = multipliers[token] {
                guard pendingMultiplier == 1 else { return nil }   // "double double" is not a code
                pendingMultiplier = m
                continue
            }
            if let d = words[token] {
                digits += String(repeating: d, count: pendingMultiplier)
            } else if token.allSatisfy(\.isNumber), token.unicodeScalars.allSatisfy({ $0.isASCII }) {
                guard pendingMultiplier == 1 else { return nil }   // "double 55" is not spoken
                digits += token
            } else {
                return nil
            }
            pendingMultiplier = 1
        }
        guard pendingMultiplier == 1, digits.count >= minimumDigits else { return nil }
        return digits
    }
}
