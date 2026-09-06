import Foundation

/// Debug-only tracer for diagnosing the live dictation pipeline. Compiles to a no-op in
/// Release: several call sites log user speech content (transcript text, quick-edit
/// instructions, dictionary words), which must NEVER reach the system log on a user's
/// machine - the app's whole promise is on-device privacy.
///
/// Debug builds write to stderr AND to Library/Logs/yapdiag.log inside the container, so a
/// copy launched from Finder (stderr discarded) still leaves a trail to read after a
/// misbehaving dictation. The file is truncated once it passes 8 MB.
@inline(__always)
func yapdiag(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = "[yapdiag] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    YapDiagFile.append(line)
    #endif
}

#if DEBUG
enum YapDiagFile {
    private static let queue = DispatchQueue(label: "yapdiag.file")
    private static let url: URL? = {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("yapdiag.log")
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func append(_ line: String) {
        guard let url else { return }
        let stamped = stamp.string(from: Date()) + " " + line
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
               size > 8_000_000 {
                try? Data().write(to: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close()
            } else {
                try? Data(stamped.utf8).write(to: url)
            }
        }
    }
}
#endif
