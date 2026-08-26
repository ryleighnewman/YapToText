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
    // INCREMENTAL COMMIT: long dictations are transcribed WHILE the user talks. Once the
    // uncommitted audio passes ~24s, a background task cuts it at a silence near 18s and
    // transcribes that piece through the identical per-segment pipeline; endSession then
    // only pays for the tail. Guarded by `lock`; whisper inference itself is serialized
    // by `inferenceLock` (the preview, the commits, and the final pass share one context).
    private var committedPieces: [String] = []
    private var committedCount: Int = 0
    private var commitTask: Task<Void, Never>?
    // Commit ONLY in segmentation territory: measured on real dictations, cutting
    // normal-length clips into small pieces cost 14% text divergence (whisper loses
    // cross-piece context), so short and mid clips keep their single pass untouched.
    // Past the 240s threshold the clip gets cut at 120s boundaries REGARDLESS - doing
    // those pieces during the recording adds no new seams, it only prepays the wait.
    private static let commitTriggerSeconds: Double = 140
    private static let commitCutTarget: Double = 120
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var language = "auto"
    private var cancelled = false

    /// Live transcription preview: whisper.cpp has no native streaming, so when enabled we
    /// periodically run inference over the (recent) accumulated audio and publish the partial
    /// text. Costs extra compute while recording; toggleable in Settings.
    var livePreview = false
    /// A Whisper initial-prompt biasing the decoder toward the user's own vocabulary (names,
    /// jargon, brand casings), built by the controller from the active dictionaries. Set before
    /// a session; passed into every decode pass so the model hears these words in the FIRST place.
    var promptBias: String?
    private var previewTask: Task<Void, Never>?
    /// Retained from beginSession so a long, segmented transcription can publish each
    /// finished segment as it lands instead of going silent for minutes.
    private var sessionUpdate: (@Sendable (TranscriptionUpdate) -> Void)?
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

    /// Shown while the whisper context for this model isn't resident yet - loading the .bin into RAM
    /// takes a few seconds on the first transcribe (or the first after a cooldown eviction), during
    /// which the app looked stuck on "Transcribing…". nil once the model is warm.
    var modelLoadingDetail: String? {
        guard let path = modelURL?.path, Self.cachedPath != path else { return nil }
        return "Loading the speech model…"
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
        sessionUpdate = onUpdate
        // whisper wants an ISO 639-1 code; anything unparseable falls back to auto-detect.
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "auto"
        language = code.count == 2 ? code : "auto"
        lock.unlock()

        // Load the model context NOW, in the background, while the user is still speaking -
        // the ~1.5GB cold load then overlaps the dictation instead of stalling the stop button
        // ("running very slow when I hit transcribe"). No-op when already cached.
        if let warmPath = modelURL?.path {
            Task.detached(priority: .userInitiated) {
                _ = try? WhisperEngine.sharedContext(for: warmPath)
            }
        }

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
                let bias = self.promptBias
                self.lock.unlock()
                guard !stop else { return }
                // Only re-run once at least ~0.6s of new audio arrived and there's enough to say.
                guard count > Int(WhisperEngine.sampleRate), count - lastCount > Int(WhisperEngine.sampleRate * 0.6) else { continue }
                lastCount = count
                // Skip silent windows entirely: no hallucinated pleasantries in the preview,
                // and no wasted inference while the user is just holding the key.
                let previewAnalysis = SpeechEnhancer.analyze(window, sampleRate: WhisperEngine.sampleRate)
                let previewQuietReal = previewAnalysis.speechLevel >= max(0.003, previewAnalysis.noiseFloor * 3)
                    && previewAnalysis.activeSeconds >= 0.4
                guard WhisperEngine.peakWindowRMS(window) >= WhisperEngine.silenceRMS || previewQuietReal else { continue }
                let conditionedWindow = SpeechEnhancer.enhance(window, analysis: previewAnalysis).audio
                guard let partial = try? WhisperEngine.transcribe(modelPath: path, audio: conditionedWindow,
                                                                  language: lang, allowBeam: false, initialPrompt: bias,
                                                                  isCancelled: { Task.isCancelled }),
                      !partial.isEmpty, !Task.isCancelled, !WhisperEngine.isSilenceHallucination(partial),
                      !WhisperEngine.isNonSpeechAnnotation(partial) else { continue }
                let prefix = windowStart > 0 ? "\u{2026}" : ""
                onUpdate(TranscriptionUpdate(volatile: prefix + partial, finalized: ""))
            }
        }
    }

    func append(_ rawBuffer: AVAudioPCMBuffer) {
        // Multi-channel mics (the M4 mic array presents as 3ch non-interleaved) BREAK
        // AVAudioConverter's channel mapping: it "succeeds" while writing pure zeros, which
        // silently starved the transcriber (caught live: real audio in, convertedPeak=0.00000).
        // Never hand it multi-channel input: take channel 0 into a mono buffer ourselves first.
        let buffer = WhisperEngine.monoChannel0(rawBuffer) ?? rawBuffer
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
              let channel = converted.floatChannelData else {
            // A silently-failing converter starves endSession (0 samples -> instant empty
            // transcript), so the failure must be visible in the trace.
            yapdiag("whisper append: conversion FAILED status=\(status.rawValue) err=\(conversionError?.localizedDescription ?? "nil") from=\(buffer.format)")
            return
        }

        let frames = Int(converted.frameLength)
        lock.lock()
        let logThis = samples.count < 8000   // first ~0.5s of the session only
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
        maybeStartCommit()
        lock.unlock()
        if logThis {
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(channel[0][i])) }
            yapdiag(String(format: "whisper append: in=%d out=%d convertedPeak=%.5f", Int(buffer.frameLength), frames, peak))
        }
    }

    /// Reduce a multi-channel float buffer to mono by copying channel 0 (the array's primary
    /// mic). Returns nil when the buffer is already mono (or not float PCM) - caller keeps it.
    static func monoChannel0(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1,
              let src = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: buffer.format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData else { return nil }
        mono.frameLength = buffer.frameLength
        memcpy(dst[0], src[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        return mono
    }

    /// Called (with `lock` HELD) whenever samples grow: starts one background commit
    /// when enough uncommitted audio has piled up. The commit itself copies its slice
    /// under the lock and releases it before inference.
    private func maybeStartCommit() {
        guard commitTask == nil, modelIsOnDisk, let modelURL else { return }
        let uncommitted = samples.count - committedCount
        guard Double(uncommitted) > WhisperEngine.sampleRate * Self.commitTriggerSeconds else { return }
        let lang = language
        commitTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.commitOnePiece(modelURL: modelURL, lang: lang)
        }
    }

    private func commitOnePiece(modelURL: URL, lang: String) async {
        lock.lock()
        let base = committedCount
        let region = Array(samples[base...])
        let stop = cancelled
        lock.unlock()
        defer { lock.lock(); commitTask = nil; lock.unlock() }
        guard !stop else { return }
        // Cut at a silence near the target; if the region has no usable cut (one
        // unbroken stretch of speech), skip - the next append re-arms the trigger.
        let bounds = Self.segmentBounds(region, sampleRate: WhisperEngine.sampleRate,
                                        target: Self.commitCutTarget)
        guard bounds.count >= 2, let first = bounds.first else {
            yapdiag("commit: no silence cut in region; deferring")
            return
        }
        let piece = Array(region[first])
        do {
            let text = try await transcribeOneShot(piece, modelURL: modelURL, lang: lang)
            lock.lock()
            if !cancelled {
                if !text.isEmpty { committedPieces.append(text) }
                committedCount = base + first.upperBound
            }
            lock.unlock()
            yapdiag(String(format: "commit: %.1fs piece -> %d chars (%.1fs committed total)",
                           Double(piece.count) / WhisperEngine.sampleRate, text.count,
                           Double(base + first.upperBound) / WhisperEngine.sampleRate))
        } catch {
            yapdiag("commit: piece failed (\(error)); tail pass will cover it")
        }
    }

    func endSession() async throws -> String {
        previewTask?.cancel()
        _ = await previewTask?.value   // wait out any in-flight preview inference
        previewTask = nil
        // A commit mid-flight finishes first: its piece then counts as committed and the
        // tail below shrinks accordingly. Serialization with the tail pass is by design -
        // they never overlap.
        lock.lock(); let pending = commitTask; lock.unlock()
        _ = await pending?.value
        lock.lock()
        var audio = Array(samples[committedCount...])
        let committed = committedPieces
        let lang = language
        samples.removeAll()
        committedPieces.removeAll()
        committedCount = 0
        converter = nil
        converterInputFormat = nil
        lock.unlock()

        guard let modelURL, modelIsOnDisk else { throw unavailableError() }
        let peakDiag = Self.peakWindowRMS(audio)
        yapdiag(String(format: "whisper endSession: samples=%d (%.2fs) peak=%.4f gates: min=%.4f",
                       audio.count, Double(audio.count) / Double(WhisperEngine.sampleRate), peakDiag, Self.silenceRMS))
        guard audio.count > Int(WhisperEngine.sampleRate / 2) else {
            return committed.joined(separator: " ")   // < 0.5s tail: whatever was committed IS the dictation
        }

        // LONG SESSIONS ARE SEGMENTED. Every conditioning stage below allocates a full
        // copy of the clip, and whisper's cost climbs with length, so a runaway session
        // (a stop that never fired) used to end in half a gigabyte of live float arrays
        // and a beam search over half an hour of audio - the app froze, then died with
        // the recording orphaned. Past the threshold the clip is cut at SILENCE and each
        // piece runs through the identical pipeline, one at a time, so peak memory is
        // bounded by the segment length no matter how long the recording ran.
        // Below the threshold nothing changes: same single pass, same tuning.
        let tail: String
        if audio.count > Int(WhisperEngine.sampleRate * Self.segmentThreshold) {
            tail = try await transcribeSegmented(audio, modelURL: modelURL, lang: lang)
        } else {
            tail = try await transcribeOneShot(audio, modelURL: modelURL, lang: lang)
        }
        return (committed + (tail.isEmpty ? [] : [tail])).joined(separator: " ")
    }

    /// Longer than this (seconds) and the clip is cut into pieces. Chosen so a normal
    /// dictation, however generous, never segments.
    private static let segmentThreshold: Double = 240
    /// Target length of each piece. The real cut lands at the nearest silence.
    private static let segmentTarget: Double = 120

    /// The full single-pass pipeline: conditioning, inference, the rescue passes, and the
    /// hallucination guards. Unchanged from when it was inline in endSession.
    private func transcribeOneShot(_ input: [Float], modelURL: URL, lang: String) async throws -> String {
        var audio = input
        let peakDiag = Self.peakWindowRMS(audio)
        let originalCount = audio.count
        // Speech conditioning: measure where the SPEECH sits vs the room's own floor.
        var analysis = SpeechEnhancer.analyze(audio, sampleRate: WhisperEngine.sampleRate)
        // Energy gate: if the whole clip never reached speech-level energy, nothing was said -
        // don't even run the model (whisper WILL invent "Thank you." from silence of any length).
        // WHISPER-AWARE: genuinely quiet speech (whispering) can sit below the absolute gate
        // while still rising clearly above the mic's measured floor - that passes too.
        let peak = peakDiag
        let quietButReal = analysis.speechLevel >= max(0.003, analysis.noiseFloor * 3)
            && analysis.activeSeconds >= 0.4
        guard peak >= Self.silenceRMS || quietButReal else { return "" }
        // STATIONARY-NOISE REMOVAL, gated on measured SNR: below 15dB (a machine running
        // near the mic) the hum's spectral fingerprint is subtracted before anything
        // else. Clean audio never enters this path, so the healthy case is untouched.
        let sIn = Double(max(analysis.speechLevel, 1e-6))
        let fIn = Double(max(analysis.noiseFloor, 1e-6))
        let snrIn: Double = 20 * log10(sIn / fIn)
        // 14dB, not 15: at the boundary the subtraction costs whisper its punctuation
        // cues for no accuracy gain (borderline clips already transcribe correctly).
        if snrIn < 14 {
            audio = SpeechEnhancer.denoiseStationary(audio)
            analysis = SpeechEnhancer.analyze(audio, sampleRate: WhisperEngine.sampleRate)
            let sOut = Double(max(analysis.speechLevel, 1e-6))
            let fOut = Double(max(analysis.noiseFloor, 1e-6))
            let snrOut: Double = 20 * log10(sOut / fOut)
            yapdiag(String(format: "denoise: stationary subtraction %.1fdB -> %.1fdB", snrIn, snrOut))
        }
        // Lift quiet speech to the level the model expects (no-op on healthy audio).
        var (conditioned, gain) = SpeechEnhancer.enhance(audio, analysis: analysis)
        // ENDPOINTING: collapse dead-air stretches longer than 3s down to a natural pause.
        // Long silences are where whisper drifts (hallucinated pleasantries, lost sentence
        // boundaries); short pauses are kept intact - they carry the punctuation cues.
        let beforeSilenceTrim = conditioned.count
        conditioned = SpeechEnhancer.compressSilences(conditioned, analysis: analysis,
                                                      sampleRate: WhisperEngine.sampleRate)
        if conditioned.count != beforeSilenceTrim {
            yapdiag(String(format: "endpointing: compressed %.1fs of dead air (%.1fs -> %.1fs)",
                           Double(beforeSilenceTrim - conditioned.count) / WhisperEngine.sampleRate,
                           Double(beforeSilenceTrim) / WhisperEngine.sampleRate,
                           Double(conditioned.count) / WhisperEngine.sampleRate))
        }
        audio = conditioned
        if gain > 1 {
            yapdiag(String(format: "speech enhance: gain=%.2fx speech=%.4f floor=%.4f active=%.1fs",
                           gain, analysis.speechLevel, analysis.noiseFloor, analysis.activeSeconds))
        }
        // whisper.cpp is least stable on very short clips; pad quiet tails so inference always
        // sees a comfortable minimum of audio.
        let minSamples = Int(WhisperEngine.sampleRate * 1.2)
        if audio.count < minSamples {
            audio.append(contentsOf: [Float](repeating: 0, count: minSamples - audio.count))
        }

        let path = modelURL.path
        let bias = promptBias   // vocabulary priming, captured for the detached decode closures
        let isCancelled: () -> Bool = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.cancelled
        }

        // Inference is CPU/GPU-heavy; keep it off the cooperative pool's main lanes.
        // NOTE: dual-pass arbitration (decode raw AND denoised, pick by whisper's mean
        // token probability) was built and MEASURED here on 13 real noisy clips: the
        // confidence signal chose confidently-wrong raw decodes over correct denoised
        // ones ("Fasting their" beat the correct reading at p 0.605 vs 0.506), a net
        // quality LOSS plus a doubled decode. Confidence is not truth in noise. Removed;
        // transcribeScored remains for future work with a better arbitration signal.
        var text = try await Task.detached(priority: .userInitiated) { [audio] in
            try WhisperEngine.transcribe(modelPath: path, audio: audio, language: lang, initialPrompt: bias, isCancelled: isCancelled)
        }.value
        // NOT-FULLY-HEARD detection: the mic recorded clearly active speech for N seconds but
        // the transcript's word count doesn't plausibly cover it (or came back empty). One
        // rescue pass with a stronger lift - whichever result covers more speech wins.
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        if !isCancelled(), SpeechEnhancer.coverageLooksShort(words: words, activeSeconds: analysis.activeSeconds)
            || (text.isEmpty && analysis.activeSeconds >= 0.6) {
            let (rescued, rescueGain) = SpeechEnhancer.enhance(conditioned, analysis:
                SpeechEnhancer.analyze(conditioned, sampleRate: WhisperEngine.sampleRate), boost: 1.6)
            if rescueGain > 1.05 {
                yapdiag(String(format: "speech rescue: words=%d active=%.1fs extraGain=%.2fx",
                               words, analysis.activeSeconds, rescueGain))
                // GREEDY on purpose: this is a speculative second opinion that is only
                // ADOPTED if it recovers more words. Beam-5 here would double its cost for
                // a pass that usually loses - the accuracy comes from the main pass; this
                // one's value is the extra gain lift, not the decoder.
                let second = (try? await Task.detached(priority: .userInitiated) { [rescued] in
                    try WhisperEngine.transcribe(modelPath: path, audio: rescued, language: lang, allowBeam: false, initialPrompt: bias, isCancelled: isCancelled)
                }.value) ?? ""
                let secondWords = second.split { $0.isWhitespace || $0.isNewline }.count
                if secondWords > words, !Self.isSilenceHallucination(second) {
                    yapdiag("speech rescue: adopted second pass (\(secondWords) vs \(words) words)")
                    text = second
                }
            }
        }
        // Second layer: on short presses OR low-confidence audio (breath, rustle - above the
        // silence gate but below solid speech), discard whisper's stock silence pleasantries.
        // Quiet-but-real speech is judged by its measured level, not the absolute gate.
        // RATE RESCUE: machine-gun dictation makes whisper fuse or drop words. When the
        // envelope reads fast (approximate 40ms-peak metric), try the SAME audio gently
        // time-stretched toward natural pacing - and adopt that pass only when it
        // actually recovers more words, so a wrong fast-guess costs nothing but time.
        let envRate = SpeechEnhancer.fastRate(conditioned, sampleRate: WhisperEngine.sampleRate)
        let wordsNow = text.split { $0.isWhitespace || $0.isNewline }.count
        // Threshold 6.3: measured TTS baselines sit at 6.5-6.7 regardless of speed (the
        // 40ms envelope saturates), while relaxed human speech reads well below.
        // SPEED: a fast talker trips envRate > 6.3 on EVERY dictation, so this pass used to
        // fire every time and cost a whole extra transcription (~0.3s) that almost never won.
        // Gate it on the main pass ALSO looking short on coverage - i.e. only when there is
        // actual evidence the fast speech fused or dropped words. When the main pass already
        // produced a plausible word count (the common case), skip the pass entirely. The
        // adoption gate still means a wrong nomination only costs time, never a worse result.
        let fastAndShort = envRate > 6.3 && analysis.activeSeconds >= 1.5
            && SpeechEnhancer.coverageLooksShort(words: wordsNow, activeSeconds: analysis.activeSeconds)
        if !isCancelled(), fastAndShort {
            let slowed = SpeechEnhancer.stretch(conditioned, factor: 1.22)
            yapdiag(String(format: "rate: fast envelope (%.1f peaks/s) - trying a 1.22x-stretched pass", envRate))
            // GREEDY: a speculative candidate (adopted only if it recovers more words). The
            // time-stretch is what helps fast speech, not the beam - keep it cheap.
            let second = (try? await Task.detached(priority: .userInitiated) { [slowed] in
                try WhisperEngine.transcribe(modelPath: path, audio: slowed, language: lang, allowBeam: false, initialPrompt: bias, isCancelled: isCancelled)
            }.value) ?? ""
            let secondWords = second.split { $0.isWhitespace || $0.isNewline }.count
            if secondWords > wordsNow, !Self.isSilenceHallucination(second), !Self.isNonSpeechAnnotation(second) {
                yapdiag("rate: adopted stretched pass (\(secondWords) vs \(wordsNow) words)")
                text = second
            }
        }
        // Whisper narrating non-speech ("(background noise)", "[BLANK_AUDIO]", a lone
        // period) is never dictation - discarded unconditionally, however loud or long
        // the clip. A session with no words in it must insert NOTHING.
        if Self.isNonSpeechAnnotation(text) { return "" }
        // Inline audio captions INSIDE otherwise-real speech ("take notes *sad music* on
        // this") survive the whole-output check above, so they are excised span by span.
        text = Self.stripInlineAudioCaptions(text)
        // A LOUD room with no clear speech activity is as hallucination-prone as
        // silence: the pleasantry filter applies there too, not just to quiet clips.
        let lowConfidence = (peak < Self.confidentSpeechRMS || analysis.activeSeconds < 0.4)
            && !(quietButReal && analysis.activeSeconds >= 1.0)
        if originalCount < Int(WhisperEngine.sampleRate * 1.2) || lowConfidence,
           Self.isSilenceHallucination(text) {
            return ""
        }
        // The decoder chanting at noise: the SAME short sentence three or more times and
        // nothing else. Real emphasis is dictated inside one sentence ("no no no"), not
        // as punctuated clones - so the identical-loop case discards unconditionally.
        let segments = text
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if segments.count >= 3, Set(segments).count == 1,
           segments[0].split(separator: " ").count <= 5 {
            yapdiag("silence guard: identical repetition loop discarded (\(text.prefix(40)))")
            return ""
        }
        // Two alternating short phrases still counts when the mic measured no real speech.
        if analysis.activeSeconds < 0.4, Self.isRepetitionLoop(text) {
            yapdiag("silence guard: repetition loop from inactive audio discarded (\(text.prefix(40)))")
            return ""
        }
        return text
    }

    /// Cut a long recording into pieces at natural silences and run each through the SAME
    /// one-shot pipeline, joining the results. Memory stays bounded by one segment, each
    /// piece gets conditioning measured against ITS OWN room (which is more correct over
    /// half an hour than one global measurement), and the user sees text arrive as it goes
    /// instead of staring at a spinner.
    private func transcribeSegmented(_ audio: [Float], modelURL: URL, lang: String) async throws -> String {
        let bounds = Self.segmentBounds(audio, sampleRate: WhisperEngine.sampleRate,
                                        target: Self.segmentTarget)
        yapdiag(String(format: "segmented: %.1fs split into %d pieces at silence",
                       Double(audio.count) / WhisperEngine.sampleRate, bounds.count))
        var pieces: [String] = []
        for (index, range) in bounds.enumerated() {
            lock.lock(); let stop = cancelled; lock.unlock()
            if stop { break }
            // One segment alive at a time: the slice is copied here and released at the end
            // of the iteration, so peak memory never scales with the recording's length.
            let piece = Array(audio[range])
            let text = try await transcribeOneShot(piece, modelURL: modelURL, lang: lang)
            if !text.isEmpty { pieces.append(text) }
            yapdiag(String(format: "segmented: piece %d/%d -> %d chars",
                           index + 1, bounds.count, text.count))
            // Publish progress: the finished text so far, so a long transcription visibly
            // advances rather than looking hung.
            if !pieces.isEmpty, let publish = sessionUpdate {
                let soFar = pieces.joined(separator: " ")
                publish(TranscriptionUpdate(volatile: "", finalized: soFar))
            }
        }
        return pieces.joined(separator: " ")
    }

    /// Choose segment boundaries that land in silence. Walks 100 ms RMS windows, and for
    /// each target boundary picks the quietest window within a generous search radius, so
    /// a cut never lands mid-word. Falls back to the exact target when a stretch of speech
    /// genuinely runs that long.
    static func segmentBounds(_ audio: [Float], sampleRate: Double,
                              target: Double) -> [Range<Int>] {
        let window = max(1, Int(sampleRate / 10))            // 100 ms
        var rms: [Float] = []
        rms.reserveCapacity(audio.count / window + 1)
        var start = 0
        while start < audio.count {
            let end = min(start + window, audio.count)
            var sum: Float = 0
            for i in start..<end { sum += audio[i] * audio[i] }
            rms.append(sqrt(sum / Float(end - start)))
            start = end
        }
        guard !rms.isEmpty else { return [0..<audio.count] }

        let targetWindows = max(1, Int(target * 10))          // target in 100 ms units
        let searchRadius = max(1, targetWindows / 4)          // +/- 25% to find a quiet spot
        var bounds: [Range<Int>] = []
        var cursor = 0                                        // in samples
        while cursor < audio.count {
            let targetSample = cursor + targetWindows * window
            if targetSample >= audio.count - window {         // last piece: take the rest
                bounds.append(cursor..<audio.count)
                break
            }
            let targetIndex = targetSample / window
            let lo = max(cursor / window + 1, targetIndex - searchRadius)
            let hi = min(rms.count - 1, targetIndex + searchRadius)
            var cutIndex = targetIndex
            if lo < hi {
                var quietest = Float.greatestFiniteMagnitude
                for i in lo...hi where rms[i] < quietest {
                    quietest = rms[i]
                    cutIndex = i
                }
            }
            let cut = min(audio.count, max(cursor + window, cutIndex * window))
            bounds.append(cursor..<cut)
            cursor = cut
        }
        return bounds.filter { !$0.isEmpty }
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

    /// Whisper's other noise signature: a short phrase LOOPED ("The Christ. The Christ.
    /// The Christ.") - the decoder latching onto nothing and repeating itself. Only ever
    /// applied to clips with no measured speech activity, so a real "no, no, no" can't
    /// be caught by it.
    static func isRepetitionLoop(_ text: String) -> Bool {
        let segments = text
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard segments.count >= 3 else { return false }
        let unique = Set(segments)
        // Nearly everything is the same short phrase over and over.
        return unique.count <= 2
            && segments.allSatisfy { $0.split(separator: " ").count <= 5 }
            && Double(unique.count) / Double(segments.count) <= 0.5
    }

    /// Output that can NEVER be dictation, regardless of how loud or long the clip was:
    /// whisper narrating non-speech instead of transcribing it. "(background noise)",
    /// "[BLANK_AUDIO]", "♪ ♪", a lone period - nothing a user said produces these, so
    /// they are always discarded rather than pasted into someone's document.
    /// Words whisper uses when it captions AUDIO instead of transcribing SPEECH. A span
    /// wrapped in (…) […] *…* or ♪…♪ whose words include one of these is a caption, never
    /// dictation ("*sad music*", "(applause)", "[soft piano]") - nobody dictates in brackets.
    static let audioCaptionWords: Set<String> = [
        "music", "applause", "laughter", "laughs", "noise", "silence", "inaudible",
        "static", "typing", "wind", "breathing", "coughing", "coughs", "sighs", "sigh",
        "chuckles", "clapping", "cheering", "singing", "humming", "piano", "beeping",
        "ringing", "barking", "blank_audio", "blankaudio", "speaking", "mumbling",
    ]

    /// Remove bracketed audio captions embedded inside real speech. Only short spans
    /// (<= 4 words) containing a caption word are removed - "(see the attached file)"
    /// style genuine asides survive untouched.
    static func stripInlineAudioCaptions(_ text: String) -> String {
        var out = text
        for (open, close) in [("(", ")"), ("[", "]"), ("*", "*"), ("\u{266A}", "\u{266A}")] {
            var search = out.startIndex
            while let a = out.range(of: open, range: search..<out.endIndex),
                  let b = out.range(of: close, range: a.upperBound..<out.endIndex) {
                let inner = String(out[a.upperBound..<b.lowerBound]).lowercased()
                let words = inner.split { !$0.isLetter && $0 != "_" }.map(String.init)
                if !words.isEmpty, words.count <= 4,
                   words.contains(where: { audioCaptionWords.contains($0) }) {
                    out.removeSubrange(a.lowerBound..<b.upperBound)
                    search = a.lowerBound
                } else {
                    search = b.upperBound
                }
            }
        }
        // Collapse the seams the removals leave behind.
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNonSpeechAnnotation(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        // Strip every (...) [...] *...* ♪...♪ group; if nothing but punctuation/space
        // remains, the whole output was annotations.
        for (open, close) in [("(", ")"), ("[", "]"), ("*", "*")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        t = t.replacingOccurrences(of: "\u{266A}", with: "")   // ♪
        let residue = t.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0)
            && !CharacterSet.whitespacesAndNewlines.contains($0)
            && !CharacterSet.symbols.contains($0) }
        if residue.isEmpty { return true }
        // Bare annotation phrases some models emit without brackets.
        let bare = String(String.UnicodeScalarView(residue)).lowercased()
        return ["blankaudio", "backgroundnoise", "silence", "inaudible", "music",
                "applause", "laughter", "noise", "static", "keyboardclacking", "typing",
                "wind", "breathing", "coughing"].contains(bare)
    }

    func cancel() async {
        previewTask?.cancel()
        _ = await previewTask?.value
        previewTask = nil
        lock.lock()
        cancelled = true
        samples.removeAll()
        committedPieces.removeAll()
        committedCount = 0
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

    /// Load the model into RAM ahead of need (launch, user activity after a cooldown
    /// eviction) so no dictation ever pays the multi-second cold-load at stop time. Also runs
    /// ONE throwaway inference on a short silent buffer: the first whisper_full JIT-compiles
    /// the Metal kernels (a large slice of the cold cost), so warming only the context still
    /// left the first REAL dictation paying the shader compile. This makes the first dictation
    /// fully warm - model loaded AND kernels built.
    static func warmContext(at path: String) {
        Task.detached(priority: .utility) {
            guard (try? WhisperEngine.sharedContext(for: path)) != nil else { return }
            let silence = [Float](repeating: 0, count: Int(sampleRate * 1.2))
            _ = try? WhisperEngine.transcribe(modelPath: path, audio: silence, language: "en",
                                              allowBeam: false, isCancelled: { false })
        }
    }

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
        // Flash attention: same math, fused kernels - a large Metal speedup for free.
        contextParams.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath, contextParams) else {
            throw TranscriptionError.unavailable("The model file couldn't be loaded. Try re-downloading it on the AI Models page.")
        }
        cachedContext = context
        cachedPath = modelPath
        return context
    }

    /// Cheap clip-level SNR estimate: speech level (92nd percentile of 100ms RMS windows)
    /// over noise floor (15th percentile), in dB. Same percentile scheme SpeechEnhancer
    /// uses, kept self-contained so the decode choice needs no plumbing.
    private static func quickSNR(_ audio: [Float]) -> Double {
        let window = 1600   // 100ms at 16kHz
        guard audio.count >= window * 4 else { return 100 }
        var rms: [Float] = []
        rms.reserveCapacity(audio.count / window + 1)
        var start = 0
        while start < audio.count {
            let end = min(start + window, audio.count)
            var sum: Float = 0
            for i in start..<end { sum += audio[i] * audio[i] }
            rms.append(sqrt(sum / Float(end - start)))
            start = end
        }
        let sorted = rms.sorted()
        func pct(_ p: Double) -> Float { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let floorLevel = max(pct(0.15), 1e-6)
        let speech = max(pct(0.92), 1e-6)
        return 20 * log10(Double(speech / floorLevel))
    }

    private static func transcribe(modelPath: String, audio: [Float], language: String,
                                   allowBeam: Bool = true, initialPrompt: String? = nil,
                                   isCancelled: @escaping () -> Bool) throws -> String {
        try transcribeScored(modelPath: modelPath, audio: audio, language: language,
                             allowBeam: allowBeam, initialPrompt: initialPrompt,
                             isCancelled: isCancelled).text
    }

    /// Like transcribe, but also reports whisper's OWN mean per-token probability - the
    /// model's confidence in what it wrote. Used to arbitrate between the raw and the
    /// denoised decode of a noisy clip: whichever reading the model believed more, wins.
    private static func transcribeScored(modelPath: String, audio: [Float], language: String,
                                         allowBeam: Bool = true, initialPrompt: String? = nil,
                                         isCancelled: @escaping () -> Bool) throws -> (text: String, confidence: Double) {
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        let context = try sharedContext(for: modelPath)

        // ADAPTIVE DECODING: greedy is fine on clean speech, but in heavy background
        // noise it commits to one token path and silently drops words - a real dictation
        // lost the "isn't" in "the app isn't able to understand me" (6dB SNR room noise;
        // beam search recovered it). Beam-5 costs a few times more compute, so it only
        // engages when the clip actually measures noisy - turbo transcribes 17s in ~0.4s,
        // leaving plenty of headroom. Live PREVIEW passes never beam (allowBeam false):
        // provisional text repainted every 1.5s doesn't justify 5x compute while the CPU
        // is already recording, and in a noisy room every preview pass was beaming.
        let snrDB = allowBeam ? Self.quickSNR(audio) : 100
        // Clipping counts as degradation too - and it RAISES the measured SNR, so a
        // clipped shout in a loud room sails past the SNR gate looking pristine while
        // whisper reads square waves ("Detailed." from a full sentence).
        var clipped = 0
        if allowBeam { for s in audio where abs(s) > 0.985 { clipped += 1 } }
        let clippedFrac = Double(clipped) / Double(max(1, audio.count))
        // Gate at 18 dB, not 12. Real-world microphone dictation (built-in mics, ordinary
        // rooms, fans) measures 12-16 dB SNR here - captured logs from a live user showed
        // EVERY normal dictation landing in that band and running greedy, dropping words,
        // while only the rare sub-12 clip got the beam rescue. Clean studio speech is
        // 25-40 dB, so an 18 dB gate still leaves genuinely-clean audio on fast greedy and
        // moves the common noisy case onto beam-5. Beam is a superset search of greedy, so
        // this only ever helps accuracy; the cost is compute, and turbo has headroom to spare.
        let noisy = allowBeam && (snrDB < 18 || clippedFrac > 0.001)
        // NOTE: beam-3-always for quantized models was tried here and measured on 60 real
        // dictations: no accuracy gain over adaptive greedy/beam-5 (7.0% vs 6.5% divergence
        // from the fp16 reference), so it was removed. Adaptive decoding stands.
        var params = whisper_full_default_params(noisy ? WHISPER_SAMPLING_BEAM_SEARCH
                                                       : WHISPER_SAMPLING_GREEDY)
        if noisy { params.beam_search.beam_size = 5 }
        // NOTE: audio_ctx reduction (encoding less than the full 30s window) was tried
        // here and REVERTED: it roughly doubled short-clip speed on synthetic benchmarks
        // but produced fragmented word salad on real microphone speech within minutes of
        // shipping ("you're a key's, you're a big, you're a bag"). The encoder wants its
        // full window; the model was trained that way. Do not re-add without an accuracy
        // harness over real recorded speech.
        yapdiag("whisper: snr=\(String(format: "%.1f", snrDB))dB clip=\(String(format: "%.2f", clippedFrac * 100))% decode=\(noisy ? "beam5" : "greedy")")
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

        // VOCABULARY PRIMING: bias the decoder toward the user's own words (see promptBias).
        // strdup because params.initial_prompt is a borrowed C pointer that must outlive the
        // whisper_full call; freed after. Empty/nil prompt leaves the decoder unbiased.
        let promptCString: UnsafeMutablePointer<CChar>? = (initialPrompt?.isEmpty == false) ? strdup(initialPrompt!) : nil
        defer { if let promptCString { free(promptCString) } }
        if let promptCString { params.initial_prompt = UnsafePointer(promptCString) }

        let status = audio.withUnsafeBufferPointer { pointer in
            whisper_full(context, params, pointer.baseAddress, Int32(pointer.count))
        }
        guard status == 0 else {
            throw TranscriptionError.unavailable("Transcription failed (whisper error \(status)). Try again or switch models.")
        }
        if isCancelled() { return ("", 0) }

        var text = ""
        var pSum = 0.0
        var pCount = 0
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
            for t in 0..<whisper_full_n_tokens(context, i) {
                pSum += Double(whisper_full_get_token_p(context, i, t))
                pCount += 1
            }
        }
        let confidence = pCount > 0 ? pSum / Double(pCount) : 0
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), confidence)
    }
}
