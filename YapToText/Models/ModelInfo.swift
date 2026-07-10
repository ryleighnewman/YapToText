import Foundation

enum ModelKind: String, Codable, CaseIterable {
    case speech      // speech-to-text
    case language    // LLM for the optional cleanup/transform stage
}

enum ModelRuntime: String, Codable {
    case apple           // built-in Apple frameworks (no download)
    case whisperCpp      // whisper.cpp GGML/GGUF single-file
    case llamaCpp        // llama.cpp GGUF single-file
    case mlx             // Apple MLX (multi-file repo)
}

/// A model the user can choose. Built-in Apple engines have no download; everything else
/// is a single downloadable file stored in the app's data container.
struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var provider: String
    var kind: ModelKind
    var summary: String
    var languages: String
    var sizeMB: Double
    var quality: Int          // 1...5
    var downloadURL: URL?     // nil for built-in
    var fileName: String?     // local filename in the Models container
    var runtime: ModelRuntime
    var license: String
    var sha256: String?

    var isBuiltIn: Bool { runtime == .apple }
    var sizeDescription: String {
        if sizeMB <= 0 { return "Built-in" }
        if sizeMB >= 1024 { return String(format: "%.1f GB", sizeMB / 1024) }
        return String(format: "%.0f MB", sizeMB)
    }
}

enum ModelDownloadState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }
    var isDownloading: Bool { if case .downloading = self { return true }; return false }
}
