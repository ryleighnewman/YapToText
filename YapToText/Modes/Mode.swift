import Foundation

/// Where a mode's final text goes after transcription (and optional AI cleanup).
enum OutputTarget: String, Codable, CaseIterable, Identifiable {
    case insertAtCursor
    case clipboardOnly
    case sendAndSubmit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .insertAtCursor: return "Insert at cursor"
        case .clipboardOnly: return "Copy to clipboard"
        case .sendAndSubmit: return "Insert and press Return"
        }
    }
}

/// A Mode is a reusable processing profile: a transcription pass plus an optional
/// on-device AI transformation, with its own output target and context settings.
/// Mirrors superwhisper's model, but every mode is free and runs locally.
struct Mode: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var iconSystemName: String
    var summary: String

    /// When true, the raw transcript is rewritten by the Foundation Models LLM
    /// using `instructions` before insertion.
    var usesAI: Bool
    var instructions: String

    /// Optional per-mode locale override (nil = use the global setting).
    var localeIdentifier: String?

    var outputTarget: OutputTarget
    var isBuiltIn: Bool

    // Context blocks injected into the AI stage (only meaningful when usesAI).
    var includeAppContext: Bool
    var includeSelectedText: Bool
    var includeClipboard: Bool

    // Per-mode engine + vocabulary selection. All optional so older saved modes still decode;
    // nil means "use the global default".
    var speechModelID: String?      // transcription model for this mode
    var languageModelID: String?    // cleanup model for this mode
    var dictionaryIDs: [UUID]?      // which dictionaries to apply; nil = all enabled ones
    var isEnabled: Bool?            // appears in the quick switcher / cycle; nil = yes
    var silenceTimeout: Double?     // per-mode auto-stop; nil = the app-wide setting
    var maxRecordingSeconds: Double? // per-mode length cap; nil = the app-wide setting
    var insertionMethod: InsertionMethod? // how text is delivered; nil = the app-wide setting
    var trimTrailingNewlines: Bool? // trim trailing whitespace; nil = the app-wide setting

    /// Whether this mode is engaged (shown in the switcher and cycled through).
    var isEngaged: Bool { isEnabled ?? true }

    init(id: UUID = UUID(),
         name: String,
         iconSystemName: String = "text.bubble",
         summary: String = "",
         usesAI: Bool = false,
         instructions: String = "",
         localeIdentifier: String? = nil,
         outputTarget: OutputTarget = .insertAtCursor,
         isBuiltIn: Bool = false,
         includeAppContext: Bool = false,
         includeSelectedText: Bool = false,
         includeClipboard: Bool = false,
         speechModelID: String? = nil,
         languageModelID: String? = nil,
         dictionaryIDs: [UUID]? = nil,
         isEnabled: Bool? = nil,
         silenceTimeout: Double? = nil,
         maxRecordingSeconds: Double? = nil,
         insertionMethod: InsertionMethod? = nil,
         trimTrailingNewlines: Bool? = nil) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.summary = summary
        self.usesAI = usesAI
        self.instructions = instructions
        self.localeIdentifier = localeIdentifier
        self.outputTarget = outputTarget
        self.isBuiltIn = isBuiltIn
        self.includeAppContext = includeAppContext
        self.includeSelectedText = includeSelectedText
        self.includeClipboard = includeClipboard
        self.speechModelID = speechModelID
        self.languageModelID = languageModelID
        self.dictionaryIDs = dictionaryIDs
        self.isEnabled = isEnabled
        self.silenceTimeout = silenceTimeout
        self.maxRecordingSeconds = maxRecordingSeconds
        self.insertionMethod = insertionMethod
        self.trimTrailingNewlines = trimTrailingNewlines
    }
}
