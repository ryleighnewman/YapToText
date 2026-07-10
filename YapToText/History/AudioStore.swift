import Foundation
import AVFoundation

/// Stores optional per-dictation audio recordings in the app data container
/// (Application Support/YapToText/Audio), so they survive updates and are easy to purge.
enum AudioStore {
    static var directory: URL {
        let dir = Persistence.directory.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newFileName() -> String { "\(UUID().uuidString).caf" }

    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    static func exists(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    static func delete(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func totalBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
