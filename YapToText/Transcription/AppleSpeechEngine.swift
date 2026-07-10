import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text using macOS 26's SpeechAnalyzer + SpeechTranscriber.
/// Streaming, uncapped duration, models managed by the OS via AssetInventory.
///
/// append() is called from AudioRecorder's background queue while endSession()/cancel()
/// tear the session down from the caller's context, so the shared input fields are guarded
/// by `lock`. The recognized-text fields are only touched by the results Task and read
/// after it drains, so they need no lock.
final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    let displayName = "Apple Speech (on-device)"

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?

    private var finalizedText = ""
    private var volatileText = ""
    private var onUpdate: (@Sendable (TranscriptionUpdate) -> Void)?

    func isAvailable() async -> Bool {
        !(await SpeechTranscriber.supportedLocales).isEmpty
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    private func makeTranscriber(_ localeIdentifier: String) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: localeIdentifier),
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    func prepare(localeIdentifier: String, progress: (@Sendable (Double) -> Void)?) async throws {
        let transcriber = makeTranscriber(localeIdentifier)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress?(0.05)
            try await request.downloadAndInstall()
            progress?(1.0)
        } else {
            progress?(1.0)
        }
    }

    func beginSession(localeIdentifier: String,
                      onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        self.onUpdate = onUpdate
        finalizedText = ""
        volatileText = ""

        let transcriber = makeTranscriber(localeIdentifier)
        self.transcriber = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        self.analyzerFormat = format
        self.inputContinuation = continuation
        lock.unlock()

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += (self.finalizedText.isEmpty ? "" : " ") + text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    self.onUpdate?(TranscriptionUpdate(volatile: self.volatileText, finalized: self.finalizedText))
                }
            } catch {
                // Expected on normal teardown (endSession/cancel finish the stream); not an
                // error worth surfacing to the user.
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let continuation = inputContinuation, let target = analyzerFormat else {
            lock.unlock(); return
        }
        if buffer.format == target {
            lock.unlock()
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        let converter = self.converter
        lock.unlock()

        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func endSession() async throws -> String {
        finishInput()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        resultsTask = nil
        let text = finalizedText.isEmpty ? volatileText : finalizedText
        reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        finishInput()
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        reset()
    }

    /// Finish + clear the input continuation under the lock. Kept as a synchronous helper so
    /// the lock is never held across an await in the async teardown methods.
    private func finishInput() {
        lock.lock()
        inputContinuation?.finish()
        inputContinuation = nil
        lock.unlock()
    }

    private func reset() {
        lock.lock()
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        converter = nil
        converterInputFormat = nil
        inputContinuation = nil
        onUpdate = nil
        lock.unlock()
    }
}
