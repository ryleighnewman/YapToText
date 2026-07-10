import Foundation
import Observation

/// Owns the user's AI actions (the things you can run on selected text). Ships a useful set of
/// defaults; every one is editable and you can add your own. Writes are debounced so editing an
/// action's instructions doesn't hit the disk on every keystroke.
@Observable
final class AIActionStore {
    private(set) var actions: [AIAction]

    @ObservationIgnored private static let fileName = "aiactions.json"
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    struct Snapshot: Codable { var actions: [AIAction] }

    init() {
        if let snap = Persistence.load(Snapshot.self, from: AIActionStore.fileName), !snap.actions.isEmpty {
            actions = snap.actions
        } else {
            actions = AIActionStore.defaults
        }
    }

    func action(withID id: UUID) -> AIAction? { actions.first { $0.id == id } }

    // MARK: Mutations

    @discardableResult
    func add() -> AIAction {
        let action = AIAction(name: "New Action", iconSystemName: "wand.and.stars", instructions: "")
        actions.append(action)
        save()
        return action
    }

    func update(_ action: AIAction) {
        guard let i = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[i] = action
        save()
    }

    func delete(_ action: AIAction) {
        actions.removeAll { $0.id == action.id }
        save()
    }

    func restoreDefaults() {
        actions = AIActionStore.defaults
        save()
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Persistence.save(Snapshot(actions: actions), to: AIActionStore.fileName)
    }

    // MARK: Defaults

    static let defaults: [AIAction] = [
        AIAction(name: "Improve Writing", iconSystemName: "sparkles",
                 instructions: "Improve the writing: fix grammar, spelling, and clarity while preserving the meaning, tone, and language. Output only the improved text, with no preamble or quotes.",
                 isBuiltIn: true),
        AIAction(name: "Fix Grammar & Spelling", iconSystemName: "checkmark.circle",
                 instructions: "Correct grammar, spelling, and punctuation only. Do not change wording, tone, or meaning. Output only the corrected text.",
                 isBuiltIn: true),
        AIAction(name: "Make Concise", iconSystemName: "scissors",
                 instructions: "Rewrite to be as concise as possible without losing meaning. Output only the shortened text.",
                 isBuiltIn: true),
        AIAction(name: "Make Formal", iconSystemName: "briefcase",
                 instructions: "Rewrite in a professional, formal tone while keeping the meaning and language. Output only the rewritten text.",
                 isBuiltIn: true),
        AIAction(name: "Make Friendly", iconSystemName: "face.smiling",
                 instructions: "Rewrite in a warm, friendly, casual tone while keeping the meaning and language. Output only the rewritten text.",
                 isBuiltIn: true),
        AIAction(name: "Summarize", iconSystemName: "text.line.first.and.arrowtriangle.forward",
                 instructions: "Summarize the text into its key points. Output only the summary.",
                 isBuiltIn: true),
        AIAction(name: "Bullet Points", iconSystemName: "list.bullet",
                 instructions: "Rewrite the text as a clear bulleted list of its key points. Output only the list.",
                 isBuiltIn: true),
        AIAction(name: "Translate to English", iconSystemName: "globe",
                 instructions: "Translate the text into English. Output only the translation. If it is already English, lightly correct it.",
                 isBuiltIn: true),
    ]
}
