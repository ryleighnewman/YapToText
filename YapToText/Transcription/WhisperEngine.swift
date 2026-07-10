import Foundation
import AVFoundation
import whisper

/// Downloaded-model backend using whisper.cpp (via its Swift package). Audio is converted to
/// 16 kHz mono float as it arrives and buffered; the model runs once at endSession, which is
/// how whisper.cpp works best. Live partials aren't produced, so the panel shows "Listening…"
/// until you stop. Everything runs on device.
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    let displayName: String
    private let modelURL: URL?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var language = "auto"
    private var cancelled = false

    /// Live transcription preview: whisper.cpp has no native streaming, so when enabled we
    /// periodically run inference over the (recent) accumulated audio and publish the partial
    /// text. Costs extra compute while recording; toggleable in Settings.
    var livePreview = false
    private var previewTask: Task<Void, Never>?
    /// Serializes ALL whisper_full calls (preview vs final) - the shared context is not
    /// re-entrant, and endSession must never run while a preview pass is mid-inference.
    private static let inferenceLock = NSLock()

    private static let sampleRate: Double = 16_000
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: sampleRate,
                                                    channels: 1, interleaved: false)!

    init(modelURL: URL?, modelName: String) {
        self.modelURL = modelURL
        self.displayName = modelName
    }

    private var modelIsOnDisk: Bool {
        guard let modelURL else { return false }
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    func isAvailable() async -> Bool { modelIsOnDisk }

    private func unavailableError() -> TranscriptionError {
        .unavailable("'\(displayName)' isn't downloaded yet. Download it on the AI Models page, or switch to Apple Speech.")
    }

    func prepare(localeIdentifier: String, progress: (@Sendable (Double) -> Void)?) async throws {
        guard modelIsOnDisk else { throw unavailableError() }
        progress?(1.0)
    }

    func beginSession(localeIdentifier: String,
                      onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        guard modelIsOnDisk else { throw unavailableError() }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        cancelled = false
        // whisper wants an ISO 639-1 code; anything unparseable falls back to auto-detect.
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "auto"
        language = code.count == 2 ? code : "auto"
        lock.unlock()

        guard livePreview, let path = modelURL?.path else { return }
        // Preview loop: every ~1.5s transcribe the last <=12s of audio and publish the partial.
        previewTask = Task.detached(priority: .utility) { [weak self] in
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.lock.lock()
                let stop = self.cancelled
                let count = self.samples.count
                let windowStart = max(0, count - Int(WhisperEngine.sampleRate * 12))
                let window = stop ? [] : Array(self.samples[windowStart...])
                let lang = self.language
                self.lock.unlock()
                guard !stop else { return }
                // Only re-run once at least ~0.6s of new audio arrived and there's enough to say.
                guard count > Int(WhisperEngine.sampleRate), count - lastCount > Int(WhisperEngine.sampleRate * 0.6) else { continue }
                lastCount = count
                // Skip silent windows entirely: no hallucinated pleasantries in the preview,
                // and no wasted inference while the user is just holding the key.
                guard WhisperEngine.peakWindowRMS(window) >= WhisperEngine.silenceRMS else { continue }
                guard let partial = try? WhisperEngine.transcribe(modelPath: path, audio: window,
                                                                  language: lang, isCancelled: { Task.isCancelled }),
                      !partial.isEmpty, !Task.isCancelled, !WhisperEngine.isSilenceHallucination(partial) else { continue }
                let prefix = windowStart > 0 ? "\u{2026}" : ""
                onUpdate(TranscriptionUpdate(volatile: prefix + partial, finalized: ""))
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: WhisperEngine.targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { lock.unlock(); return }
        lock.unlock()

        let ratio = WhisperEngine.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: WhisperEngine.targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil,
              let channel = converted.floatChannelData else { return }

        let frames = Int(converted.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
        lock.unlock()
    }

    func endSession() async throws -> String {
        previewTask?.cancel()
        _ = await previewTask?.value   // wait out any in-flight preview inference
        previewTask = nil
        lock.lock()
        var audio = samples
        let lang = language
        samples.removeAll()
        converter = nil
        converterInputFormat = nil
        lock.unlock()

        guard let modelURL, modelIsOnDisk else { throw unavailableError() }
        guard audio.count > Int(WhisperEngine.sampleRate / 2) else { return "" }   // < 0.5s: nothing said
        let originalCount = audio.count
        // Energy gate: if the whole clip never reached speech-level energy, nothing was said -
        // don't even run the model (whisper WILL invent "Thank you." from silence of any length).
        let peak = Self.peakWindowRMS(audio)
        guard peak >= Self.silenceRMS else { return "" }
        // whisper.cpp is least stable on very short clips; pad quiet tails so inference always
        // sees a comfortable minimum of audio.
        let minSamples = Int(WhisperEngine.sampleRate * 1.2)
        if audio.count < minSamples {
            audio.append(contentsOf: [Float](repeating: 0, count: minSamples - audio.count))
        }

        let path = modelURL.path
        let isCancelled: () -> Bool = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.cancelled
        }

        // Inference is CPU/GPU-heavy; keep it off the cooperative pool's main lanes.
        let text = try await Task.detached(priority: .userInitiated) {
            try WhisperEngine.transcribe(modelPath: path, audio: audio, language: lang, isCancelled: isCancelled)
        }.value
        // Second layer: on short presses OR low-confidence audio (breath, rustle - above the
        // silence gate but below solid speech), discard whisper's stock silence pleasantries.
        if originalCount < Int(WhisperEngine.sampleRate * 1.2) || peak < Self.confidentSpeechRMS,
           Self.isSilenceHallucination(text) {
            return ""
        }
        return text
    }

    /// Below this the clip is treated as silence outright; below `confidentSpeechRMS` it can
    /// still transcribe, but hallucination phrases are filtered regardless of duration.
    static let silenceRMS: Float = 0.006
    static let confidentSpeechRMS: Float = 0.02

    /// The loudest 100 ms window in the clip - a cheap "did anyone actually speak?" measure
    /// that ignores how LONG the silence lasted (a 3-second silent hold has a quiet peak too).
    static func peakWindowRMS(_ audio: [Float]) -> Float {
        let window = Int(sampleRate / 10)   // 100 ms
        guard !audio.isEmpty else { return 0 }
        var peak: Float = 0
        var start = 0
        while start < audio.count {
            let end = min(start + window, audio.count)
            var sum: Float = 0
            for i in start..<end { sum += audio[i] * audio[i] }
            peak = max(peak, sqrt(sum / Float(end - start)))
            start = end
        }
        return peak
    }

    /// Stock phrases whisper invents from silence/noise (well documented upstream).
    static func isSilenceHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        return ["thank you", "thanks", "thank you very much", "thanks for watching",
                "thank you for watching", "you", "bye", ""].contains(normalized)
    }

    func cancel() async {
        previewTask?.cancel()
        _ = await previewTask?.value
        previewTask = nil
        lock.lock()
        cancelled = true
        samples.removeAll()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    // MARK: whisper.cpp

    /// The loaded model is cached across dictations - reloading a 1.6GB model from disk on
    /// every stop() made short dictations feel like nothing was happening. Guarded by a lock;
    /// swapped out (and the old one freed) when the user picks a different model.
    private static let contextLock = NSLock()
    nonisolated(unsafe) private static var cachedContext: OpaquePointer?
    nonisolated(unsafe) private static var cachedPath: String?

    /// Drop the cached model context (memory pressure). Takes the inference lock first, so it
    /// can never free the context out from under a running whisper_full.
    static func evictCachedContext() {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        contextLock.lock(); defer { contextLock.unlock() }
        if let context = cachedContext { whisper_free(context) }
        cachedContext = nil
        cachedPath = nil
    }

    private static func sharedContext(for modelPath: String) throws -> OpaquePointer {
        contextLock.lock()
        defer { contextLock.unlock() }
        if let context = cachedContext, cachedPath == modelPath { return context }
        if let old = cachedContext { whisper_free(old) }
        cachedContext = nil
        cachedPath = nil
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        guard let context = whisper_init_from_file_with_params(modelPath, contextParams) else {
            throw TranscriptionError.unavailable("The model file couldn't be loaded. Try re-downloading it on the AI Models page.")
        }
        cachedContext = context
        cachedPath = modelPath
        return context
    }

    private static func transcribe(modelPath: String, audio: [Float], language: String,
                                   isCancelled: @escaping () -> Bool) throws -> String {
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        let context = try sharedContext(for: modelPath)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.no_timestamps = true
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let langCString = strdup(language)
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)

        let status = audio.withUnsafeBufferPointer { pointer in
            whisper_full(context, params, pointer.baseAddress, Int32(pointer.count))
        }
        guard status == 0 else {
            throw TranscriptionError.unavailable("Transcription failed (whisper error \(status)). Try again or switch models.")
        }
        if isCancelled() { return "" }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
