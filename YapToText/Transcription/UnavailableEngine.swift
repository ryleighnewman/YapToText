import AVFoundation

/// The honest dead-end engine for configurations that cannot transcribe at all - no Whisper
/// model on disk yet (the Homebrew build ships none until one downloads). Every session fails
/// immediately with a message telling the user exactly what to do, instead of a silent no-op.
final class UnavailableEngine: TranscriptionEngine, @unchecked Sendable {
    let displayName = "No speech engine"
    var modelLoadingDetail: String? { nil }
    private let message: String

    init(message: String) { self.message = message }

    func isAvailable() async -> Bool { false }

    func prepare(localeIdentifier: String, progress: (@Sendable (Double) -> Void)?) async throws {
        throw TranscriptionError.unavailable(message)
    }

    func beginSession(localeIdentifier: String, onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        throw TranscriptionError.unavailable(message)
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func endSession() async throws -> String {
        throw TranscriptionError.unavailable(message)
    }

    func cancel() async {}
}
