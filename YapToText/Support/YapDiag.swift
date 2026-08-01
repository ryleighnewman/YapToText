import Foundation

/// Debug-only stderr tracer for diagnosing the live dictation pipeline. Compiles to a
/// no-op in Release: several call sites log user speech content (transcript text,
/// quick-edit instructions, dictionary words), which must NEVER reach the system log
/// on a user's machine - the app's whole promise is on-device privacy.
@inline(__always)
func yapdiag(_ message: @autoclosure () -> String) {
    #if DEBUG
    FileHandle.standardError.write(Data("[yapdiag] \(message())\n".utf8))
    #endif
}
