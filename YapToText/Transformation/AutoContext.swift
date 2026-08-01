import Foundation

/// Auto mode: decide how a dictation should be post-processed by reading what was said,
/// where it is going, and how the user asked for it - instead of making them pick a mode first.
///
/// Signals, cheapest first:
///  1. A trailing spoken directive ("... make that formal", "... as a bullet list") is stripped
///     from the text and applied as an explicit formatting instruction.
///  2. A heuristic screen (microseconds) confidently routes the obvious text shapes:
///     "What's up man?" stays as spoken; "Dear Jessica, ... Thank you, Ryleigh" is an email.
///  3. The DESTINATION app breaks ties: dictating into Mail leans email, into Messages leans
///     casual, into an editor leans code, into Notes leans note.
///  4. Only when everything is still ambiguous does the on-device AI get a one-word
///     classification call, so common cases never pay AI latency.
enum AutoContext {
    enum Verdict: String { case email, message, note, code, cleanup }

    // MARK: Destination bias

    /// What the app being dictated into suggests. Only a bias - strong text evidence wins.
    static func destinationBias(bundleID: String?) -> Verdict? {
        guard let id = bundleID?.lowercased() else { return nil }
        let mail = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail",
                    "com.airmailapp", "com.superhuman", "it.bloop.airmail"]
        let chat = ["com.apple.mobilesms", "com.apple.ichat", "com.hnc.discord",
                    "com.tinyspeck.slackmacgap", "net.whatsapp.whatsapp", "org.telegram",
                    "com.facebook.archon", "ru.keepcoder.telegram", "com.microsoft.teams"]
        // Cursor is pinned to its specific bundle prefix, not the bare "com.todesktop" the ToDesktop
        // packager shares with many unrelated Electron apps (which would all get a Code bias).
        let code = ["com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92",
                    "com.jetbrains", "com.sublimetext", "dev.zed.zed", "com.googlecode.iterm2",
                    "com.apple.terminal", "co.zeit.hyper", "com.github.wez.wezterm"]
        let note = ["com.apple.notes", "md.obsidian", "notion.id", "com.agiletortoise.drafts",
                    "com.bear-writer", "net.shinyfrog.bear", "com.evernote"]
        // hasPrefix only: every entry is a reverse-DNS prefix, so `.contains` added no real matches
        // and risked false positives from an unrelated ID that happens to embed one of these strings.
        if mail.contains(where: { id.hasPrefix($0) }) { return .email }
        if chat.contains(where: { id.hasPrefix($0) }) { return .message }
        if code.contains(where: { id.hasPrefix($0) }) { return .code }
        if note.contains(where: { id.hasPrefix($0) }) { return .note }
        return nil
    }

    // MARK: Trailing spoken directives

    /// "…, make that formal" / "as a bullet list please" spoken at the END of a dictation is a
    /// command about the text, not part of it. Returns the text with the directive removed plus
    /// the instruction to hand the AI. Deterministic, no AI cost.
    static func extractDirective(_ text: String) -> (text: String, directive: String)? {
        let patterns: [(regex: String, instruction: String)] = [
            ("make (it|that|this) (more )?formal",        "Rewrite in a formal, professional tone."),
            ("make (it|that|this) (more )?professional",  "Rewrite in a formal, professional tone."),
            ("make (it|that|this) (more )?friendly",      "Rewrite in a warm, friendly tone."),
            ("make (it|that|this) (more )?casual",        "Rewrite in a relaxed, casual tone."),
            ("make (it|that|this) (more )?concise",       "Rewrite as concisely as possible without losing meaning."),
            ("make (it|that|this) shorter",               "Rewrite as concisely as possible without losing meaning."),
            ("(as|make (it|that|this)) (a )?bullet( ed)? ?(point )?list", "Format the content as a bulleted list."),
            ("as an email",                               "Format the content as a complete email."),
            ("as a note",                                 "Format the content as a tidy note."),
            ("as a message",                              "Keep it as a short casual message."),
        ]
        let tail = "( please)?[.!,\\s]*$"
        for p in patterns {
            // Lookbehind for sentence punctuation so ". Make it concise." keeps the period
            // on the sentence it belongs to; commas/spaces before the directive are consumed.
            let full = "(?:(?<=[.!?])\\s+|[,;\\s]+)(and )?" + p.regex + tail
            if let regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                let stripped = String(text[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { return (stripped, p.instruction) }
            }
        }
        return nil
    }

    // MARK: Recipient

    /// The name a letter-shaped dictation opens with ("Dear Jessica," / "Hi Marcus,").
    static func recipient(in text: String) -> String? {
        let pattern = "^(dear|hi|hello|hey)\\s+([A-Za-z][a-zA-Z'-]{1,24})[,.]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 2, let r = Range(match.range(at: 2), in: text) else { return nil }
        let name = String(text[r])
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Heuristic screen

    /// Instant text-shape screen. nil = ambiguous, use the destination bias or the AI.
    static func screen(_ text: String) -> Verdict? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let words = lower.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let count = words.count
        guard count > 0 else { return .message }

        // Email evidence. STRUCTURE (a greeting line or a sign-off) is required - polite
        // body phrases alone ("please let me know", "thank you") show up constantly in
        // casual messages and used to flip them to email, which then got SIGNED. Phrases
        // only add confidence once the text is actually shaped like a letter.
        var structure = 0
        if lower.hasPrefix("dear ") { structure += 2 }
        if (lower.hasPrefix("hi ") || lower.hasPrefix("hello ") || lower.hasPrefix("hey ")),
           lower.prefix(40).contains(",") { structure += 1 }
        for signoff in ["sincerely", "best regards", "kind regards", "warm regards", "regards,",
                        "best wishes", "cheers,"]
            where lower.contains(signoff) { structure += 1 }
        var email = structure
        for tell in ["i am writing to", "i'm writing to", "please find attached", "attached is",
                     "per our conversation", "following up on",
                     "i wanted to reach out", "looking forward to hearing"]
            where lower.contains(tell) { email += 1 }
        if structure >= 1, email >= 2, count >= 12 { return .email }

        // Clearly casual or tiny: keep the words exactly as spoken.
        let casual = ["what's up", "whats up", "hey man", "yo ", "lol", "lmao", "gonna",
                      "wanna", "dude", "bro ", "haha", "omg", "sup "]
        if count <= 6 { return .message }
        if count <= 14, casual.contains(where: { lower.contains($0) }) { return .message }

        // Medium prose with zero email evidence: ordinary cleanup.
        if email == 0, count <= 60 { return .cleanup }
        return nil   // long or mixed-signal text - destination bias or AI decides
    }

    // MARK: Auto-pass instructions

    /// The default treatment for auto-routed dictations: repair the TRANSCRIPT, never the voice.
    /// Fix misheard words, hallucinated fragments, punctuation, capitalization - and nothing else.
    static let conservativeCleanup = """
    You are repairing a speech-to-text transcript. The input is live speech and may contain \
    misheard words, wrong homophones, and hallucinated fragments.
    - Fix ONLY transcription errors: replace clearly misheard words with the intended word from \
    context, and drop fragments that are obviously recognition noise.
    - Fix punctuation and capitalization.
    - KEEP the user's exact wording, tone, slang, and sentence structure. Do not rephrase, \
    formalize, soften, shorten, or expand anything.
    - Never swap a word for a more formal synonym, never tone down blunt or profane language, and \
    never drop a clause they said (including asides like "note to self" or "keep it short").
    - Normalize spoken numbers to digits, but never add a unit or time of day they did not say.
    - Output ONLY the corrected text. Never append notes, explanations, or parenthetical \
    comments about what you did or did not change.
    """

    /// Guard appended to every auto-routed formatting pass (email, note, code): the format may
    /// change, the user's voice may not.
    static let preserveGuard = "Keep the user's own words, tone, and phrasing. Apply the required format and fix transcription errors and punctuation, but never rephrase content or change how formal it sounds."

    // MARK: AI tiebreak

    static let aiPrompt = """
    You are a text classifier. Read the dictated text and answer with EXACTLY one word:
    EMAIL only if it is unmistakably a letter or email with a greeting or sign-off. Polite \
    phrases alone (thanks, please let me know) do NOT make something an email.
    MESSAGE if it is a short casual chat message that should stay as spoken.
    NOTE if it is a personal note, list, or reminder.
    CLEANUP for everything else.
    Answer with one word only. No punctuation, no explanation.
    """

    static func verdict(fromAI reply: String) -> Verdict {
        let r = reply.lowercased()
        if r.contains("email") { return .email }
        if r.contains("message") { return .message }
        if r.contains("note") { return .note }
        return .cleanup
    }
}
