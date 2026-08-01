import Foundation
import AVFoundation

/// Incremental transcription state. `finalized` is committed text; `volatile` is the
/// recognizer's current best guess for the tail, which may still change.
struct TranscriptionUpdate: Sendable {
    var volatile: String
    var finalized: String
    var combined: String {
        if volatile.isEmpty { return finalized }
        if finalized.isEmpty { return volatile }
        return finalized + " " + volatile
    }
}

enum TranscriptionError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

/// A swappable speech-to-text backend. Apple's on-device engine is the default;
/// a whisper.cpp backend can be dropped in behind the same contract.
protocol TranscriptionEngine: AnyObject {
    var displayName: String { get }
    /// A short status shown in the panel if this engine will need to LOAD a model before it can
    /// transcribe (e.g. a cold Whisper context). nil = nothing heavy to load (Apple Speech), so the
    /// normal "Transcribing…" label shows. Lets a slow first transcribe read as loading, not stuck.
    var modelLoadingDetail: String? { get }
    func isAvailable() async -> Bool
    /// Ensure the locale model is installed. May download; reports 0...1 progress.
    func prepare(localeIdentifier: String, progress: (@Sendable (Double) -> Void)?) async throws
    /// Start a live session. `onUpdate` is called (off the main thread) as text arrives.
    func beginSession(localeIdentifier: String, onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws
    /// Feed audio. Safe to call from a background queue.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finalize and return the full transcript.
    func endSession() async throws -> String
    /// Abort without producing a result.
    func cancel() async
}

extension TranscriptionEngine {
    /// Default: no heavy model to load (Apple Speech). Whisper overrides this.
    var modelLoadingDetail: String? { nil }
}
