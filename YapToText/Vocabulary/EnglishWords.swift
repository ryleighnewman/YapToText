import Foundation

/// The system's own word list (/usr/share/dict/words, readable from the sandbox), used to
/// keep everyday words out of the dictionary as "mishearings": mapping "alp" to Alpha would
/// rewrite every real "alp". Proper nouns in the list are capitalized, so a lowercase lookup
/// leaves name-like spellings (riley, rylee) available.
enum EnglishWords {
    private static let common: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var set = Set<String>()
        for line in text.split(separator: "\n") where line.first?.isLowercase == true && line.count >= 2 {
            set.insert(String(line))
        }
        return set
    }()
    private static let properNouns: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var set = Set<String>()
        for line in text.split(separator: "\n") where line.first?.isUppercase == true && line.count >= 2 {
            set.insert(String(line).lowercased())
        }
        return set
    }()

    /// A name-like target ("Ryleigh") may take a candidate that is also a name in the list
    /// ("riley": the adjective is obscure, the name is what the recognizer meant).
    static func isCommon(_ word: String, targetIsName: Bool = false) -> Bool {
        let w = word.lowercased()
        if targetIsName, properNouns.contains(w) { return false }
        if common.contains(w) { return true }
        // Plurals and possessives of common words count too.
        if w.hasSuffix("'s"), common.contains(String(w.dropLast(2))) { return true }
        if w.hasSuffix("s"), common.contains(String(w.dropLast())) { return true }
        return false
    }
}
