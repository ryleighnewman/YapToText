import Foundation
import AVFoundation
import AudioToolbox

/// Captures microphone audio with AVAudioEngine. Audio buffers are deep-copied and
/// handed to a serial queue so any format conversion happens OFF the real-time render
/// thread (converting on the render thread is a documented crash).
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.ryleighnewman.YapToText.audio-processing")
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    /// Optional destination for saving the raw recording. Touched only on processingQueue.
    private var audioFile: AVAudioFile?
    private(set) var isRunning = false

    /// When paused, the tap keeps running (so resume is instant) but buffers are dropped:
    /// nothing is fed to the transcriber or written to the audio file, and the meter reads
    /// zero. Read/written from both the audio thread and the main actor, so guarded by a lock.
    private let pauseLock = NSLock()
    private var _paused = false
    var isPaused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }

    /// Manual input boost (1.0 = off) and automatic gain control for quiet speech. Set before
    /// start(); safe to nudge live from the UI. `agcGain` is touched only on the audio thread.
    var inputGain: Float = 1.0
    var autoAmplify: Bool = false
    private var agcGain: Float = 1.0
    private let maxAutoGain: Float = 12.0
    private let maxTotalGain: Float = 40.0
    private var bufferCount = 0   // diagnostic: how many mic buffers the tap actually received
    private var startedAt = Date()   // diagnostic: measures time-to-first-buffer (cold-route dead window)

    /// FFT frequency bands of the live audio, for the visualizer. Set before start().
    var onSpectrum: (([Float]) -> Void)?
    /// UID of the input device to capture from (the user's Input source pick). nil = system
    /// default. Set before start(); applied to the engine's input unit each session.
    var preferredDeviceUID: String?
    private let analyzer = SpectrumAnalyzer()

    /// Gain to apply to this buffer: the manual boost, times an AGC factor that eases quiet
    /// speech up toward a comfortable level (fast to rise, slow to fall, held during near-silence
    /// so background hiss isn't amplified). Runs on the audio thread only.
    private func effectiveGain(rawRMS: Float) -> Float {
        var gain = inputGain
        if autoAmplify {
            let target: Float = 0.09        // ~ -21 dB, a comfortable speech RMS
            let noiseFloor: Float = 0.004   // below this it's silence/hiss - don't chase it
            if rawRMS > noiseFloor {
                let desired = min(maxAutoGain, max(1.0, target / rawRMS))
                let rate: Float = desired > agcGain ? 0.2 : 0.03   // quick attack, gentle release
                agcGain += (desired - agcGain) * rate
            }
            gain *= agcGain
        }
        return min(gain, maxTotalGain)
    }

    /// First AVAudioEngine session after launch can capture pure silence while CoreAudio warms
    /// the input route (observed: a full first dictation of all-zero levels -> empty transcript).
    /// Spin the engine briefly at launch so the route is hot before the first real recording.
    private var prewarmActive = false
    func prewarmRoute() {
        guard !isRunning, !prewarmActive else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        prewarmActive = true
        let started = Date()
        // Spin until the hardware PROVES it's awake (first non-silent buffer), not for a fixed
        // interval: a cold route can deliver zeroed buffers for over a second, and a timed 0.7s
        // spin of zeros warmed nothing - the first real dictation then recorded pure silence.
        var confirmedWarm = false
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard !confirmedWarm, let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var peak: Float = 0
            for i in stride(from: 0, to: n, by: 16) { peak = max(peak, abs(data[i])) }
            if peak > 0.0005 {
                confirmedWarm = true
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                yapdiag("mic prewarm: route confirmed live after \(ms)ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.endPrewarm() }
            }
        }
        engine.prepare()
        try? engine.start()
        // Cap: if no live audio in 4s (muted hardware mic, no ambient signal), stop anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.prewarmActive else { return }
            if !confirmedWarm { yapdiag("mic prewarm: no live signal within 4s, stopping") }
            self.endPrewarm()
        }
    }

    private func endPrewarm() {
        guard prewarmActive else { return }
        prewarmActive = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void,
               writeTo url: URL? = nil) throws {
        endPrewarm()   // a real session takes over the engine; drop the warm-up tap first
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        agcGain = 1.0   // fresh AGC ramp per session
        analyzer.resetNoiseFloor()   // re-learn the room's background per session

        let input = engine.inputNode
        // Route to the user's chosen input device BEFORE reading the format, so the tap and the
        // saved file use the selected mic's native format. Falls back silently to the system
        // default if the device went away (unplugged headset).
        if let uid = preferredDeviceUID, let device = AudioInputDevices.device(forUID: uid),
           let unit = input.audioUnit {
            var deviceID = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw TranscriptionError.unavailable("No microphone input is available.")
        }

        if let url {
            audioFile = try? AVAudioFile(forWriting: url, settings: format.settings)
        }

        // 2048 frames ≈ 23 level updates/sec at 48kHz - smooth enough for a live waveform
        // without burdening the transcription engines.
        let levelCB = onLevel
        let bufferCB = onBuffer
        let spectrumCB = onSpectrum
        let analyzer = self.analyzer
        let file = audioFile
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if self.isPaused {
                DispatchQueue.main.async { levelCB(0) }
                return   // drop the buffer: no transcription, no file write while paused
            }
            if self.bufferCount == 0 {
                let latency = Date().timeIntervalSince(self.startedAt)
                yapdiag(String(format: "recorder: FIRST buffer after %.0f ms", latency * 1000))
            }
            self.bufferCount += 1
            let raw = AudioRecorder.rawRMS(buffer)
            let gain = self.effectiveGain(rawRMS: raw)          // manual * AGC, for the transcriber
            // The visualizer must show the VOICE'S real dynamics, so it uses only the uniform
            // manual boost - NOT the AGC, which deliberately flattens loudness toward a target and
            // would make the wave a constant-height animation instead of reacting to your voice.
            let level = AudioRecorder.normalize(raw * self.inputGain)
            DispatchQueue.main.async { levelCB(level) }   // capture the closure, not self
            guard let copy = buffer.deepCopy() else { return }
            self.processingQueue.async {
                // Frequency spectrum from the RAW (pre-gain) audio, so the wave reacts to the
                // actual pitch/energy of the voice. Runs off the render thread.
                if let spectrumCB, let ch = copy.floatChannelData {
                    let bands = analyzer.analyze(ch[0], count: Int(copy.frameLength))
                    DispatchQueue.main.async { spectrumCB(bands) }
                }
                AudioRecorder.applyGain(copy, gain)   // amplify what the transcriber receives
                bufferCB(copy)
                if let file { try? file.write(from: copy) }
            }
        }

        bufferCount = 0
        startedAt = Date()
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        yapdiag("recorder.stop: captured \(bufferCount) buffers")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        isPaused = false
        // Deliberately NOT clearing onBuffer/onLevel here: the tap runs on a real-time audio
        // thread and reads those closures, so mutating them from the main thread while a buffer
        // is in flight is a data race that corrupts the heap. They're simply replaced on the
        // next start(), which only happens after the tap is fully removed.
        // Close the file after any queued writes have drained.
        processingQueue.async { self.audioFile = nil }
    }

    /// Raw linear RMS of the first channel (0…~1), before any gain.
    static func rawRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sumSquares: Float = 0
        if let data = buffer.floatChannelData {
            let channel = data[0]
            for i in 0..<frames { let s = channel[i]; sumSquares += s * s }
        } else if let data = buffer.int16ChannelData {
            let channel = data[0]
            for i in 0..<frames { let s = Float(channel[i]) / Float(Int16.max); sumSquares += s * s }
        } else {
            return 0
        }
        let ms = sumSquares / Float(frames)
        // One NaN/Inf sample would make sumSquares non-finite; don't let it escape as the level.
        return ms.isFinite ? sqrt(max(0, ms)) : 0
    }

    /// Map a linear RMS into a 0…1 meter range (roughly -50 dB…0 dB).
    static func normalize(_ rms: Float) -> Float {
        // Swift's min/max do NOT clamp NaN - a NaN rms would pass straight through the clamp and
        // downstream into a CGFloat the renderer misreads as a pointer. Reject non-finite explicitly.
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let v = (db + 50) / 50
        return v.isFinite ? min(max(v, 0), 1) : 0
    }

    /// RMS level mapped to a 0…1 meter range. Retained for callers that want it in one step.
    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float { normalize(rawRMS(buffer)) }

    /// Multiply every sample by `gain`, clamping to the format's range so a boost can't wrap or
    /// distort past full scale. Runs off the render thread (on the processing queue).
    static func applyGain(_ buffer: AVAudioPCMBuffer, _ gain: Float) {
        guard gain != 1.0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let data = buffer.floatChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames { p[i] = min(1, max(-1, p[i] * gain)) }
            }
        } else if let data = buffer.int16ChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames {
                    let v = Float(p[i]) * gain
                    p[i] = Int16(min(Float(Int16.max), max(Float(Int16.min), v)))
                }
            }
        } else if let data = buffer.int32ChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames {
                    let v = Float(p[i]) * gain
                    p[i] = Int32(min(Float(Int32.max), max(Float(Int32.min), v)))
                }
            }
        }
    }
}

extension AVAudioPCMBuffer {
    /// A standalone copy safe to use after the tap callback returns.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size) }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size) }
        } else {
            return nil
        }
        return copy
    }
}
