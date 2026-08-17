import Foundation
import Observation

/// Root object graph. Owns the stores and the dictation controller and is injected into
/// the SwiftUI environment.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let modeStore: ModeStore
    let vocabulary: VocabularyStore
    let commands: CommandStore
    let actions: AIActionStore
    let history: HistoryStore
    let permissions: PermissionsManager
    let models: ModelLibrary
    let controller: DictationController

    /// False when the global shortcut could not be registered (already claimed elsewhere).
    var mainHotkeyActive = true

    /// Set true when a grayed-out mode/AI control is tapped while post-transcription analysis
    /// is OFF. ContentView watches this and shows an explanatory alert that offers to turn the
    /// analysis back on (or take the user to the setting). Any disabled mode control routes its
    /// tap through `requestAnalysisControl()` instead of doing nothing silently.
    var analysisOffPromptVisible = false

    /// Called by a disabled mode/AI control. If analysis is already on, this is a no-op (the
    /// control should be live); otherwise it raises the explanatory prompt.
    func requestAnalysisControl() {
        guard !settings.aiCleanupEnabled else { return }
        analysisOffPromptVisible = true
    }

    init() {
        let settings = AppSettings()
        let modeStore = ModeStore()
        let vocabulary = VocabularyStore()
        let commands = CommandStore()
        let actions = AIActionStore()
        let history = HistoryStore()
        let permissions = PermissionsManager()
        let models = ModelLibrary()
        self.settings = settings
        self.modeStore = modeStore
        self.vocabulary = vocabulary
        self.commands = commands
        self.actions = actions
        self.history = history
        self.permissions = permissions
        self.models = models
        self.controller = DictationController(settings: settings, modeStore: modeStore,
                                              vocabulary: vocabulary, commands: commands, history: history,
                                              permissions: permissions, models: models)
        history.applyRetention(settings.historyRetention)
        permissions.refresh()
    }
}
