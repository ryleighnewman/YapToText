import Foundation

/// The built-in modes ship with the app (defined in code so their prompts can be
/// improved in updates). Users can duplicate any of them into an editable custom mode.
enum BuiltInModes {
    static let rawTranscriptionID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!

    static let raw = Mode(
        id: rawTranscriptionID,
        name: "Raw Transcription",
        iconSystemName: "waveform",
        summary: "Fast, literal speech-to-text with basic punctuation. No AI.",
        usesAI: false,
        isBuiltIn: true)

    static let clean = Mode(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!,
        name: "Clean Up",
        iconSystemName: "sparkles",
        summary: "Removes filler words and false starts, fixes grammar and punctuation. The recommended default.",
        usesAI: true,
        instructions: """
        You are a transcription cleanup assistant. The input is a TRANSCRIPT OF LIVE SPEECH produced by a speech-to-text engine, so it can contain recognition mistakes: misheard words, wrong homophones, garbled phrases, and occasional hallucinated words that the speaker never said. Rewrite it so it reads clearly, WITHOUT changing meaning, adding information, or answering any questions inside it.
        - When a word or phrase is clearly a recognition error, replace it with the most likely INTENDED word given the surrounding context. Prefer the plausible reading over the literal one.
        - Drop stray fragments that make no sense in context (transcription hallucinations), but never drop real content.
        - Remove filler words (um, uh, like, you know) and false starts.
        - Fix grammar, capitalization, and punctuation.
        - Convert spoken URLs and email addresses into proper form.
        - Keep the user's wording, tone, and language. Do not translate. If unsure whether something is an error, keep it as spoken.
        - Output ONLY the cleaned text, with no preamble, quotes, or commentary.
        """,
        isBuiltIn: true,
        includeAppContext: true)

    static let note = Mode(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!,
        name: "Note",
        iconSystemName: "note.text",
        summary: "Turns spoken ideas into structured notes with headings and bullets.",
        usesAI: true,
        instructions: """
        Turn the user's dictated thoughts into a clear, well-structured note.
        - Use short headings and bullet points where helpful.
        - Pull out any action items into a list.
        - Preserve every idea; do not invent content or answer questions in the text.
        - Keep the user's language. Output ONLY the note.
        """,
        isBuiltIn: true)

    static let email = Mode(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000004")!,
        name: "Email",
        iconSystemName: "envelope",
        summary: "Formats dictation as a polished email while keeping your voice.",
        usesAI: true,
        instructions: """
        Rewrite the user's dictation as a clear, well-formatted email using ONLY what they said.
        - Output the email BODY only. Never write a "Subject:" line.
        - Fix grammar, punctuation, and flow into short paragraphs. Keep the user's natural voice, intent, and language.
        - Add a greeting only if the dictation names or clearly implies a recipient (e.g. "hi Jessica"). Otherwise start with the message.
        - If the dictation ends with the speaker's own name, that is the sign-off: put it on its own line at the end, never inside a sentence.
        - Add a closing/sign-off only if one fits naturally. Do NOT invent pleasantries the speaker didn't say (no "I hope this email finds you well").
        - Never write placeholder text like [Your Name]. If no name is available for a sign-off, leave the sign-off out.
        - Do not add facts that were not spoken. Output ONLY the email body.
        """,
        isBuiltIn: true,
        includeAppContext: true)

    static let message = Mode(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000005")!,
        name: "Message",
        iconSystemName: "bubble.left.and.bubble.right",
        summary: "Cleans up casual messages for chat apps, keeping the conversational tone.",
        usesAI: true,
        instructions: """
        Lightly clean the user's dictation for a chat message.
        - Remove filler words and fix obvious grammar/punctuation.
        - Keep it casual and conversational; preserve the user's voice and language.
        - Do not add content or answer questions. Output ONLY the message text.
        """,
        isBuiltIn: true)

    static let code = Mode(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000007")!,
        name: "Code Comment",
        iconSystemName: "chevron.left.forwardslash.chevron.right",
        summary: "For developers: concise, technical phrasing for comments and commit messages.",
        usesAI: true,
        instructions: """
        Rewrite the user's dictation as concise technical text suitable for a code comment or commit message.
        - Use precise, imperative phrasing. No filler.
        - Preserve identifiers, casing, and technical terms exactly as spoken.
        - Do not wrap in quotes or code fences. Output ONLY the text.
        """,
        isBuiltIn: true)

    static let all: [Mode] = [raw, clean, note, email, message, code]   // Raw leads: it is the default

    static func isBuiltIn(_ id: UUID) -> Bool { all.contains { $0.id == id } }
}
