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
