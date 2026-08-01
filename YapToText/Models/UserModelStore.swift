import Foundation

/// Models the user brings themselves: any whisper.cpp GGML speech model or llama.cpp GGUF
/// cleanup model, added from disk. Entries persist as JSON next to the other user data; the
/// files are copied into the same Models container the downloaded catalog models use, so
/// selection, cooldown, and eviction treat them identically.
enum UserModelError: LocalizedError {
    case unreadable
    case unrecognizedFormat
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That file couldn't be read."
        case .unrecognizedFormat:
            return "That file isn't a supported model. Speech models are whisper.cpp GGML .bin files; cleanup models are llama.cpp GGUF files."
        case .copyFailed(let reason):
            return "The model couldn't be copied: \(reason)"
        }
    }
}

@MainActor
final class UserModelStore {
    private static let fileName = "user-models.json"

    private(set) var models: [ModelInfo]

    init() {
        models = Persistence.load([ModelInfo].self, from: Self.fileName) ?? []
        // Drop entries whose file was deleted out from under us (e.g. via Show in Finder).
        models.removeAll { info in
            guard let name = info.fileName else { return true }
            return !FileManager.default.fileExists(atPath: Persistence.modelsDirectory.appendingPathComponent(name).path)
        }
        save()
    }

    private func save() { Persistence.save(models, to: Self.fileName) }

    /// Validate, copy into the Models container, and register a user-picked model file.
    /// The kind is inferred from the file's magic bytes, so there's nothing to configure:
    /// GGUF -> cleanup (llama.cpp), whisper GGML -> speech. Anything else is rejected
    /// up front instead of failing mysteriously at load time.
    func add(from source: URL) throws -> ModelInfo {
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

        guard let handle = try? FileHandle(forReadingFrom: source),
              let magic = try? handle.read(upToCount: 4), magic.count == 4 else {
            throw UserModelError.unreadable
        }
        try? handle.close()

        let kind: ModelKind
        let runtime: ModelRuntime
        if magic == Data("GGUF".utf8) {
            kind = .language; runtime = .llamaCpp
        } else if magic == Data([0x6C, 0x6D, 0x67, 0x67]) || magic == Data("ggml".utf8) {
            // whisper.cpp GGML magic 0x67676d6c, stored little-endian on disk ("lmgg").
            kind = .speech; runtime = .whisperCpp
        } else {
            throw UserModelError.unrecognizedFormat
        }

        // Copy into the Models container under a collision-safe name.
        let dir = Persistence.modelsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fileName = source.lastPathComponent
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path) {
            let stem = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            fileName = "\(stem)-\(Int(Date().timeIntervalSince1970))" + (ext.isEmpty ? "" : ".\(ext)")
        }
        do {
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(fileName))
        } catch {
            throw UserModelError.copyFailed(error.localizedDescription)
        }

        let sizeMB = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(fileName).path)[.size] as? Int64)
            .map { Double($0) / 1_048_576 } ?? 0
        let display = (source.lastPathComponent as NSString).deletingPathExtension
        let info = ModelInfo(id: "user-\(UUID().uuidString)",
                             displayName: display,
                             provider: "Your model",
                             kind: kind,
                             summary: kind == .speech
                                ? "Your own whisper.cpp speech model."
                                : "Your own GGUF cleanup model. If it fails to load, its architecture isn't supported by the built-in engine.",
                             languages: "\u{2014}", sizeMB: sizeMB, quality: 3,
                             downloadURL: nil, fileName: fileName,
                             runtime: runtime, license: "User provided")
        models.append(info)
        save()
        return info
    }

    /// Remove a user model and its copied file.
    func remove(_ info: ModelInfo) {
        models.removeAll { $0.id == info.id }
        if let name = info.fileName {
            try? FileManager.default.removeItem(at: Persistence.modelsDirectory.appendingPathComponent(name))
        }
        save()
    }
}
