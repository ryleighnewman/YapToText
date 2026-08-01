import Foundation
import Observation

/// The model catalog plus live install/selection state. Named "Library" (not "Store") to
/// avoid confusion with ModeStore.
@MainActor
@Observable
final class ModelLibrary {
    private(set) var catalog: [ModelInfo]
    let downloads = ModelDownloadManager()
    private let userStore = UserModelStore()

    init(catalog: [ModelInfo] = ModelCatalog.all) {
        var available = catalog
        if #unavailable(macOS 26.0) {
            // No SpeechAnalyzer / Apple Intelligence before macOS 26: hide the Apple entries so
            // nobody can select an engine that cannot exist here. Whisper + GGUF carry everything.
            available.removeAll { $0.runtime == .apple }
        }
        self.catalog = available + userStore.models
        downloads.refreshInstalled(catalog: self.catalog)
    }

    // MARK: User-added models

    var userModels: [ModelInfo] { userStore.models }
    func isUserModel(_ model: ModelInfo) -> Bool { model.id.hasPrefix("user-") }

    /// Validate + import a model file the user picked. Throws UserModelError with a
    /// human-readable message when the file isn't a supported format.
    @discardableResult
    func addUserModel(from url: URL) throws -> ModelInfo {
        let info = try userStore.add(from: url)
        catalog.append(info)
        downloads.refreshInstalled(catalog: catalog)
        return info
    }

    func removeUserModel(_ model: ModelInfo) {
        userStore.remove(model)
        catalog.removeAll { $0.id == model.id }
    }

    var speechModels: [ModelInfo] { catalog.filter { $0.kind == .speech } }
    var languageModels: [ModelInfo] { catalog.filter { $0.kind == .language } }

    func model(id: String) -> ModelInfo? { catalog.first { $0.id == id } }

    /// Pre-macOS-26 fallback: the first Whisper speech model that is actually on disk, so
    /// dictation still works on systems with no SpeechAnalyzer. nil = nothing downloaded yet.
    func catalogFallbackWhisperURL() -> (url: URL, name: String)? {
        for model in speechModels where model.runtime != .apple {
            if let url = downloads.localURL(for: model) { return (url, model.displayName) }
        }
        return nil
    }

    func state(for model: ModelInfo) -> ModelDownloadState {
        model.isBuiltIn ? .installed : (downloads.states[model.id] ?? .notInstalled)
    }

    /// A model can be selected as active only if it's built-in or fully downloaded.
    func isSelectable(_ model: ModelInfo) -> Bool {
        model.isBuiltIn || state(for: model).isInstalled
    }

    func localURL(forID id: String) -> URL? {
        guard let model = model(id: id) else { return nil }
        return downloads.localURL(for: model)
    }
}
