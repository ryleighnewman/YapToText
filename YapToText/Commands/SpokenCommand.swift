import Foundation

/// The two kinds of spoken insert commands. Punctuation turns spoken names into symbols
/// ("exclamation point" -> "!"); Emoji turns spoken names into emoji ("fire emoji" -> 🔥).
/// They are kept as separate categories because they read and edit differently.
enum CommandCategory: String, Codable, CaseIterable, Identifiable {
    case punctuation
    case emoji
    case snippet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .punctuation: return "Punctuation"
        case .emoji: return "Emoji"
        case .snippet: return "Snippets"
        }
    }
    var icon: String {
        switch self {
        case .punctuation: return "exclamationmark.bubble"
        case .emoji: return "face.smiling"
        case .snippet: return "text.quote"
        }
    }
    /// Placeholder shown in the trigger field.
    var triggerPlaceholder: String {
        switch self {
        case .punctuation: return "exclamation point, exclamation, bang"
        case .emoji: return "fire emoji, flame emoji"
        case .snippet: return "my work email"
        }
    }
}

/// One spoken insert command: when ANY of its `triggers` is heard, it is replaced with `output`.
/// Multiple triggers let several spoken phrases map to the same symbol ("exclamation point" and
/// "exclamation" and "bang" all give "!").
struct SpokenCommand: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var triggers: [String]
    var output: String
    var category: CommandCategory
    var enabled: Bool = true

    init(id: UUID = UUID(), triggers: [String], output: String, category: CommandCategory, enabled: Bool = true) {
        self.id = id
        self.triggers = triggers
        self.output = output
        self.category = category
        self.enabled = enabled
    }

    /// Convenience for single-trigger commands.
    init(id: UUID = UUID(), trigger: String, output: String, category: CommandCategory, enabled: Bool = true) {
        self.init(id: id, triggers: [trigger], output: output, category: category, enabled: enabled)
    }

    // Custom coding so older saved data (a single `trigger` string) migrates to `triggers`.
    private enum CodingKeys: String, CodingKey { case id, triggers, trigger, output, category, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let list = try c.decodeIfPresent([String].self, forKey: .triggers) {
            triggers = list
        } else if let single = try c.decodeIfPresent(String.self, forKey: .trigger) {
            triggers = [single]
        } else {
            triggers = []
        }
        output = try c.decode(String.self, forKey: .output)
        category = try c.decode(CommandCategory.self, forKey: .category)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(output, forKey: .output)
        try c.encode(category, forKey: .category)
        try c.encode(enabled, forKey: .enabled)
    }
}
