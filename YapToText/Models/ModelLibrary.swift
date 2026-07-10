import Foundation
import Observation

/// The model catalog plus live install/selection state. Named "Library" (not "Store") to
/// avoid confusion with ModeStore.
@MainActor
@Observable
final class ModelLibrary {
    let catalog: [ModelInfo]
    let downloads = ModelDownloadManager()

    init(catalog: [ModelInfo] = ModelCatalog.all) {
        self.catalog = catalog
        downloads.refreshInstalled(catalog: catalog)
    }

    var speechModels: [ModelInfo] { catalog.filter { $0.kind == .speech } }
    var languageModels: [ModelInfo] { catalog.filter { $0.kind == .language } }

    func model(id: String) -> ModelInfo? { catalog.first { $0.id == id } }

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
