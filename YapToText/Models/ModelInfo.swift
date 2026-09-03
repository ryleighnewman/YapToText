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
    var quality: Int          // 1...5, how accurately it hears/writes
    /// 1...5, how fast it runs on Apple Silicon. Independent of accuracy: the quantized
    /// Turbo model is both fast AND accurate, the full large model is neither.
    var speed: Int = 3
    /// The pick for most people in this model's category.
    var recommended: Bool = false
    var downloadURL: URL?     // nil for built-in
    var fileName: String?     // local filename in the Models container
    var runtime: ModelRuntime
    var license: String
    var sha256: String?

    var isBuiltIn: Bool { runtime == .apple }

    // Explicit decoding so fields added AFTER a user's models file was written decode as
    // their defaults. Swift's synthesized Decodable ignores default values and throws
    // keyNotFound - which made every user-models.json written before 1.3.1 (no speed or
    // recommended keys) fail to load, and the store then overwrote it with an empty list.
    // House rule for every persisted struct: new stored properties use decodeIfPresent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        kind = try c.decode(ModelKind.self, forKey: .kind)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        languages = try c.decodeIfPresent(String.self, forKey: .languages) ?? ""
        sizeMB = try c.decodeIfPresent(Double.self, forKey: .sizeMB) ?? 0
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? 3
        speed = try c.decodeIfPresent(Int.self, forKey: .speed) ?? 3
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        downloadURL = try c.decodeIfPresent(URL.self, forKey: .downloadURL)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        runtime = try c.decode(ModelRuntime.self, forKey: .runtime)
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
    }

    init(id: String, displayName: String, provider: String, kind: ModelKind, summary: String,
         languages: String, sizeMB: Double, quality: Int, speed: Int = 3, recommended: Bool = false,
         downloadURL: URL?, fileName: String?, runtime: ModelRuntime, license: String, sha256: String? = nil) {
        self.id = id; self.displayName = displayName; self.provider = provider; self.kind = kind
        self.summary = summary; self.languages = languages; self.sizeMB = sizeMB; self.quality = quality
        self.speed = speed; self.recommended = recommended; self.downloadURL = downloadURL
        self.fileName = fileName; self.runtime = runtime; self.license = license; self.sha256 = sha256
    }

    /// Plain-language ratings shown as chips next to the stars.
    enum Rating { case high, balanced, low
        var accuracyLabel: String {
            switch self { case .high: "High accuracy"; case .balanced: "Good accuracy"; case .low: "Low accuracy" }
        }
        var speedLabel: String {
            switch self { case .high: "High performance"; case .balanced: "Good performance"; case .low: "Low performance" }
        }
    }
    private static func rating(_ v: Int) -> Rating { v >= 4 ? .high : (v <= 2 ? .low : .balanced) }
    var accuracyRating: Rating { Self.rating(quality) }
    var speedRating: Rating { Self.rating(speed) }
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
