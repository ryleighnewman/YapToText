import Foundation

/// Tiny JSON-file store under ~/Library/Application Support/YapToText/.
/// Everything the user owns (modes, vocabulary, history) lives here as
/// human-readable JSON so it can be inspected, backed up, or edited by hand.
enum Persistence {
    /// Tests point this at a temporary folder so they never read or write real user data.
    static var overrideDirectory: URL?

    static var directory: URL {
        let dir: URL
        if let overrideDirectory {
            dir = overrideDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = base.appendingPathComponent("YapToText", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic])
    }
}
