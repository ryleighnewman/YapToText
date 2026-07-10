import Foundation

/// Lightweight always-on stderr tracer for diagnosing the live dictation pipeline. Prefixed
/// so it can be grepped out of the runtime log. Temporary: remove once the no-output issue
/// is resolved.
@inline(__always)
func yapdiag(_ message: @autoclosure () -> String) {
    FileHandle.standardError.write(Data("[yapdiag] \(message())\n".utf8))
}
