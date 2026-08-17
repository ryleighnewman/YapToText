import Foundation
import AVFoundation
import AudioToolbox

/// Captures microphone audio with AVAudioEngine. Audio buffers are deep-copied and
/// handed to a serial queue so any format conversion happens OFF the real-time render
/// thread (converting on the render thread is a documented crash).
final class AudioRecorder: @unchecked Sendable {
    /// Recreated per session (see start()): reusing ONE AVAudioEngine for the app's lifetime lets
    /// a wedged CoreAudio output-node/HAL state persist between sessions - after a force-kill of an
    /// audio-active instance, engine.start() then fails -10875 on kAUInitialize(outputNode) or hangs.
    /// A brand-new engine always has a clean graph.
    private var engine = AVAudioEngine()

    /// ROUTE KEEP-ALIVE. The always-hot guarantee dies silently whenever the system stops
    /// the engine behind our back: sleep/wake, display sleep, screen lock, a Bluetooth
    /// headset joining or leaving, or a default-device change all halt AVAudioEngine (or
    /// change its configuration) without any call of ours - the route then sits COLD until
    /// the next dictation, whose first 1-3s of audio the waking hardware never delivers.
    /// Cure: watch for configuration changes AND run a heartbeat that revives the engine
    /// whenever it is found stopped while we believe it should be hot.
    private var keepAlive: Timer?
    /// True while start()/arm() is mutating the engine on its detached task. The main
    /// thread's keep-alive/idle machinery must keep its hands off during that window -
    /// concurrent AVAudioEngine mutation is the -10849/segfault class of race.
    private let armLock = NSLock()
    private var _armInFlight = false
    private var armInFlight: Bool {
        get { armLock.lock(); defer { armLock.unlock() }; return _armInFlight }
        set { armLock.lock(); _armInFlight = newValue; armLock.unlock() }
    }
    func installKeepAlive() {
        guard keepAlive == nil else { return }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            // Config changes land mid-transition; give the route a beat to settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard let self else { return }
                if self.isRunning {
                    // MID-SESSION device change (headset died, default input switched):
                    // the engine halts silently and the rest of the dictation would be
                    // lost while the UI still says "Listening". Rebuild the route in
                    // place and keep capturing - the session's callbacks are still
                    // plugged in, so audio resumes into the SAME transcription.
                    self.rebuildRouteMidSession()
                } else {
                    self.reviveIfCold("config change")
                }
            }
        }
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.reviveIfCold("heartbeat")
        }
        timer.tolerance = 2.0   // coalesce wakeups; exact timing is irrelevant here
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }
    /// A device change killed the route while a session is LIVE: bring capture back on
    /// the new device without ending the session. The resident tap is reinstalled at the
    /// new device's format; the whisper/apple engines convert per-buffer, so the session
    /// continues seamlessly. A gap of ~1s of audio (the transition) is the only loss.
    private func rebuildRouteMidSession() {
        guard isRunning, !armInFlight else { return }
        if engine.isRunning { engine.stop() }
        invalidateResidentTap()
        // ALWAYS a fresh engine. Reusing the old engine's input node after a route change
        // crashed in the field (1.2 (7), SIGABRT in installTap): the node reports a STALE
        // cached format that passes the >0 guards while the hardware underneath already
        // runs at the new device's rate, and the mismatched tap install raises an
        // NSException Swift cannot catch. A fresh engine re-queries the hardware, so its
        // reported format is consistent with reality by construction.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            yapdiag("recorder: mid-session device change - NO input available")
            return
        }
        ensureResidentTap(format, on: input)
        engine.prepare()
        do {
            try engine.start()
            yapdiag("recorder: mid-session route rebuilt fresh (\(Int(format.sampleRate))Hz) - capture continues")
        } catch {
            yapdiag("recorder: mid-session rebuild failed (\(error))")
        }
    }

    private func reviveIfCold(_ why: String) {
        guard !isRunning, !prewarmActive, !armInFlight, !engine.isRunning else { return }
        // Keep-warm off (or its standby window expired) and nobody at the keyboard: a cold
        // route is the DESIRED state (mic released, indicator off). Reviving here silently
        // defeated the setting.
        guard (keepWarm && !warmStandbyExpired) || activityHoldActive else { return }
        engine.prepare()
        do {
            try engine.start()
            yapdiag("recorder: revived cold route (\(why)) - instant capture restored")
        } catch {
            // A wedged graph never recovers by restarting - rebuild fresh, exactly like start()'s fallback.
            engine.stop()
            engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 { ensureResidentTap(format, on: input) }
            engine.prepare()
            try? engine.start()
            yapdiag("recorder: revive rebuilt a fresh engine (\(why)) - start ok: \(engine.isRunning)")
        }
    }

    private let processingQueue = DispatchQueue(label: "com.ryleighnewman.YapToText.audio-processing")
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?

    /// THE RESIDENT TAP. An idle AVAudioEngine with no tap does NOT pull from the mic -
    /// CoreAudio suspends the input stream, and the next tap install pays a ~0.4s hardware
    /// wake during which the route delivers near-silence (proven by the head-profile
    /// forensics: first 4 windows 0.01-0.03 RMS, then 0.50 - the missing first words).
    /// So ONE tap is installed permanently; sessions just plug their callbacks in and out.
    /// The tap pulls continuously, so the stream never suspends and the first pressed
    /// millisecond is real audio.
    private let sessionLock = NSLock()
    private var sessionLevelCB: ((Float) -> Void)?
    private var sessionBufferCB: ((AVAudioPCMBuffer) -> Void)?
    private var probeCB: ((Float) -> Void)?
    private var residentFormat: AVAudioFormat?
    private var residentEngineID: ObjectIdentifier?
    /// PRE-ROLL: the freshest ~0.5s of idle audio, continuously refreshed by the resident
    /// tap. A dictation prepends it, so speech that began a breath BEFORE the press is
    /// still in the recording - the press reaches back in time.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollLastAppend = Date.distantPast

    /// Toggling voice processing REBUILDS the input route - the installed tap dies with
    /// the old route while our tracking still says "installed", so every later session
    /// captured nothing (the "second and third dictation record nothing" bug). Every VP
    /// toggle must invalidate the tracking so the next ensure genuinely reinstalls.
    private func invalidateResidentTap() {
        residentFormat = nil
        residentEngineID = nil
        // The ring holds buffers in the OLD route's format (and possibly from before a
        // stall) - never let them leak into the next session's prepend.
        sessionLock.lock(); preRoll.removeAll(); preRollLastAppend = .distantPast; sessionLock.unlock()
    }

    private func ensureResidentTap(_ format: AVAudioFormat, on input: AVAudioInputNode) {
        if residentFormat == format, residentEngineID == ObjectIdentifier(engine) { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.residentTap(buffer)
        }
        residentFormat = format
        residentEngineID = ObjectIdentifier(engine)
        yapdiag("recorder: resident tap installed (\(Int(format.sampleRate))Hz) - input pulls continuously")
    }

    private func residentTap(_ buffer: AVAudioPCMBuffer) {
        sessionLock.lock()
        let levelCB = sessionLevelCB
        let bufferCB = sessionBufferCB
        let probe = probeCB
        let file = audioFile
        sessionLock.unlock()
        if let probe { probe(AudioRecorder.rawRMS(buffer)) }
        guard let levelCB, let bufferCB else {
            // Idle: the pull itself keeps the stream alive; the ring keeps the last ~0.5s
            // so the next press can reach back to speech that started before it.
            if let copy = buffer.deepCopy() {
                sessionLock.lock()
                preRoll.append(copy)
                preRollLastAppend = Date()
                let cap = Int(0.5 * buffer.format.sampleRate / Double(max(1, buffer.frameLength))) + 1
                while preRoll.count > cap { preRoll.removeFirst() }
                sessionLock.unlock()
            }
            return
        }
        if isPaused {
            DispatchQueue.main.async { levelCB(0) }
            return   // drop the buffer: no transcription, no file write while paused
        }
        if bufferCount == 0 {
            let latency = Date().timeIntervalSince(startedAt)
            yapdiag(String(format: "recorder: FIRST buffer after %.0f ms", latency * 1000))
        }
        bufferCount += 1
        let raw = AudioRecorder.rawRMS(buffer)
        if raw > 0.0005, !sawLiveAudio { sawLiveAudio = true }
        let peak = AudioRecorder.rawPeak(buffer)
        let gain = effectiveGain(rawRMS: raw, rawPeak: peak)   // manual * AGC, peak-guarded
        // The visualizer hears what the TRANSCRIBER hears - full gain, AGC included. The
        // old "voice's real dynamics" purity (manual boost only) left quiet mics with a
        // near-dead wave: raw RMS of 0.005 amplified 10x for the pipeline still drew as
        // 0.005 on screen, so the app was visibly ignoring speech it recorded perfectly.
        let level = AudioRecorder.normalize(raw * gain)
        DispatchQueue.main.async { levelCB(level) }
        guard let copy = buffer.deepCopy() else { return }
        if bufferCount <= 3 {
            yapdiag(String(format: "tap[%d]: raw=%.5f gain=%.2f fmt=%@",
                           bufferCount, raw, gain,
                           "\(buffer.format.sampleRate)Hz ch\(buffer.format.channelCount)"))
        }
        let spectrumCB = onSpectrum
        let analyzer = self.analyzer
        processingQueue.async {
            AudioRecorder.applyGain(copy, gain)   // amplify what the transcriber receives
            // Spectrum AFTER the gain: the wave's bands must dance to the amplified
            // signal the pipeline actually uses, not the whisper-quiet raw capture.
            if let spectrumCB, let ch = copy.floatChannelData {
                let bands = analyzer.analyze(ch[0], count: Int(copy.frameLength))
                DispatchQueue.main.async { spectrumCB(bands) }
            }
            bufferCB(copy)
            if let file { try? file.write(from: copy) }
        }
    }
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
    /// Apple's voice-processing IO on the input: on-device noise suppression + echo cancellation
    /// (the FaceTime pipeline). Set before start(). Changes the input route's format, which is
    /// fine - the tap reads the format AFTER this is applied.
    var reduceNoise: Bool = false
    /// Apple's AUVoiceIO is PERMANENTLY off. Every engage/release of it rebuilds the
    /// system output route around the voice unit, which audibly wrecks other apps'
    /// playback for seconds (choppy bap-bap output at dictation start, stutter/echo
    /// while parked at idle) - and measured against the real pipeline it bought nothing:
    /// whisper's accuracy in loud rooms is carried by the app's own conditioning
    /// (peak-guarded capture, speech enhancement, beam decoding), and media is paused
    /// during dictation anyway so there is no speaker echo to cancel. `reduceNoise`
    /// (the user's "Reduce background noise" setting) now rides the software pipeline
    /// alone; nothing may ever call setVoiceProcessingEnabled(true).
    private static let voiceProcessingPermitted = false
    private var agcGain: Float = 1.0
    private let maxAutoGain: Float = 12.0
    private let maxTotalGain: Float = 40.0
    /// Running peak of the RAW input (fast attack, slow decay). The AGC's RMS target is
    /// blind to crest factor: in loud background noise the noise dominates the RMS, the
    /// AGC settles on a big gain, and the USER'S louder speech peaks then slam into the
    /// ±1 clamp - hard digital clipping that turned whole sentences into one-word
    /// transcripts. The gain is capped so the recent peak lands at ~0.85, never the rail.
    private var rawPeakTracker: Float = 0
    private var bufferCount = 0   // diagnostic: how many mic buffers the tap actually received
    private var startedAt = Date()   // diagnostic: measures time-to-first-buffer (cold-route dead window)
    /// True once the tap has seen a buffer with REAL signal (not the all-zero buffers a cold or
    /// dead input route delivers). The controller polls this to catch a session whose route came
    /// up dead - buffers flowing, every sample zero - and rebuild the engine before the user
    /// loses a whole dictation to silence. Written on the audio thread, read from the main actor.
    private let liveLock = NSLock()
    private var _sawLiveAudio = false
    private(set) var sawLiveAudio: Bool {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _sawLiveAudio }
        set { liveLock.lock(); _sawLiveAudio = newValue; liveLock.unlock() }
    }

    /// Set by the dead-route watchdog: the LAST session's route came up dead, so the next
    /// session should skip straight to a fresh engine instead of burning 2s rediscovering it.
    var startFreshNextSession = false

    /// Wait until the route proves it's alive (a non-zero buffer) or the timeout passes.
    func waitUntilLive(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sawLiveAudio { return true }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return sawLiveAudio
    }

    /// FFT frequency bands of the live audio, for the visualizer. Set before start().
    var onSpectrum: (([Float]) -> Void)?
    /// UID of the input device to capture from (the user's Input source pick). nil = system
    /// default. Set before start(); applied to the engine's input unit each session.
    var preferredDeviceUID: String?
    private let analyzer = SpectrumAnalyzer()

    /// Gain to apply to this buffer: the manual boost, times an AGC factor that eases quiet
    /// speech up toward a comfortable level (fast to rise, slow to fall, held during near-silence
    /// so background hiss isn't amplified). Runs on the audio thread only.
    private func effectiveGain(rawRMS: Float, rawPeak: Float) -> Float {
        // Track the recent true peak: jump up instantly, bleed off slowly (~2% per buffer,
        // a few seconds at typical buffer rates) so one shout guards the next one.
        rawPeakTracker = max(rawPeak, rawPeakTracker * 0.98)
        var gain = inputGain
        if autoAmplify {
            let target: Float = 0.09        // ~ -21 dB, a comfortable speech RMS
            let noiseFloor: Float = 0.004   // below this it's silence/hiss - don't chase it
            if rawRMS > noiseFloor {
                // Chase the target from the POST-manual-gain level, not the raw one. The AGC
                // multiplying blindly on top of a high manual boost drove speech into the ±1
                // hard clip (verified: manual gain 9x -> distorted audio -> garbage transcripts),
                // so with a big manual boost the AGC must ease OFF (below 1) rather than pile on.
                let amplified = rawRMS * max(inputGain, 0.01)
                let desired = min(maxAutoGain, max(0.05, target / amplified))
                let rate: Float = desired > agcGain ? 0.2 : 0.03   // quick attack, gentle release
                agcGain += (desired - agcGain) * rate
            }
            gain *= agcGain
        }
        gain = min(gain, maxTotalGain)
        // PEAK GUARD: whatever the RMS chase wants, the loudest recent sample must land
        // at ~0.85 after gain, not the rail. (Headroom, not a limiter - the soft knee in
        // applyGain catches the stragglers this running estimate hasn't seen yet.)
        if rawPeakTracker > 0.001 {
            gain = min(gain, 0.85 / rawPeakTracker)
        }
        return max(gain, 0.05)
    }

    /// Voice processing (the FaceTime pipeline) DUCKS all other system audio by default -
    /// with the warm-held engine, that muted the user's music/videos even while NOT
    /// dictating ("audio refuses to play or is very muted"). Tell it to never duck.
    private static func disableOtherAudioDucking(_ input: AVAudioInputNode) {
        guard input.isVoiceProcessingEnabled else { return }
        if #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                     duckingLevel: .min)
        }
    }

    /// First AVAudioEngine session after launch can capture pure silence while CoreAudio warms
    /// the input route (observed: a full first dictation of all-zero levels -> empty transcript).
    /// Spin the engine briefly at launch so the route is hot before the first real recording.
    private var prewarmActive = false

    /// Fully release the audio route once the user has been idle for a while: stop the
    /// engine AND tear down the voice-processing unit. An initialized AUVoiceIO - even on
    /// a paused engine - keeps macOS in system-wide "voice chat" mode: output is processed
    /// and Bluetooth falls back to the low-quality voice codec, which quietly degraded ALL
    /// system audio the entire time the app was open. Cold restarts stay instant (plain
    /// start, 1-6ms; VP rejoins via the post-session prewarm), so idle costs nothing.
    private var idlePowerDown: DispatchWorkItem?
    private func scheduleIdlePowerDown(after seconds: TimeInterval = 20) {
        idlePowerDown?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRunning else { return }   // a live session owns the route; stop() reschedules
            // Busy in a transient state (prewarm confirming, engine mutation mid-flight):
            // DO NOT bail silently - a bailed power-down left VP parked on the system
            // output indefinitely (stuttering, echoing playback at idle). Try again soon.
            guard !self.prewarmActive, !self.armInFlight else {
                self.scheduleIdlePowerDown(after: 3)
                return
            }
            // If warmth is still wanted (activity hold / keep-warm standby), the engine
            // comes right back up - but VP-FREE: a warm plain route gives the same instant
            // start without holding the whole system in degraded voice mode. With keep-warm
            // OFF and no activity hold, the route is fully released: tap out, engine
            // stopped, and the mic indicator turns off. That is what the setting promises.
            let wantWarm = (self.keepWarm && !self.warmStandbyExpired) || self.activityHoldActive
            if self.engine.isRunning { self.engine.stop() }
            let input = self.engine.inputNode
            if input.isVoiceProcessingEnabled {
                try? input.setVoiceProcessingEnabled(false)
                self.invalidateResidentTap()   // the toggle rebuilt the route; the tap died with it
                yapdiag("recorder: idle power-down - voice processing released, system audio back to full quality")
            }
            if wantWarm {
                let format = input.outputFormat(forBus: 0)
                if format.sampleRate > 0, format.channelCount > 0 { self.ensureResidentTap(format, on: input) }
                self.engine.prepare()
                try? self.engine.start()
                yapdiag("recorder: route re-warmed VP-free")
            } else {
                input.removeTap(onBus: 0)
                self.invalidateResidentTap()
                yapdiag("recorder: route fully released - microphone indicator off")
            }
        }
        idlePowerDown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func prewarmRoute(withVoiceProcessing: Bool = false) {
        guard !isRunning, !prewarmActive else { return }
        idlePowerDown?.cancel()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        // AUVoiceIO is permanently off (voiceProcessingPermitted): every warmth path is
        // PLAIN. The parameter survives for call-site compatibility but can never engage.
        let wantVP = withVoiceProcessing && reduceNoise && Self.voiceProcessingPermitted
        if input.isVoiceProcessingEnabled != wantVP {
            if engine.isRunning { engine.stop() }
            try? input.setVoiceProcessingEnabled(wantVP)
            invalidateResidentTap()   // route rebuilt - the tap must be reinstalled
        }
        if wantVP { Self.disableOtherAudioDucking(input) }
        prewarmActive = true
        let started = Date()
        // Spin until the hardware PROVES it's awake (first non-silent buffer), not for a fixed
        // interval: a cold route can deliver zeroed buffers for over a second, and a timed 0.7s
        // spin of zeros warmed nothing - the first real dictation then recorded pure silence.
        var confirmedWarm = false
        ensureResidentTap(format, on: input)
        sessionLock.lock()
        probeCB = { [weak self] rms in
            guard !confirmedWarm, rms > 0.0005 else { return }
            confirmedWarm = true
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            yapdiag("mic prewarm: route confirmed live after \(ms)ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.endPrewarm() }
        }
        sessionLock.unlock()
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
        sessionLock.lock(); probeCB = nil; sessionLock.unlock()   // the RESIDENT tap stays
        // VP's idle grace is SHORT. While AUVoiceIO is resident the whole system runs in
        // voice mode, and on macOS 26.x that audibly degrades other apps' playback
        // (stutter, doubled/echoing output) - not just a slight muffle. 6s still covers
        // the rapid back-to-back redictation the prewarm exists for; after that the
        // route stays warm but PLAIN, which starts just as instantly.
        var grace: TimeInterval = engine.inputNode.isVoiceProcessingEnabled ? 6 : 20
        if !keepWarm, !activityHoldActive { grace = 2 }   // default: prewarm ends, mic lets go
        if keepWarm {
            // Leave the engine RUNNING: the whole point of prewarm is a hot route, and
            // stopping here made the FIRST dictation after launch cold again ("recordings
            // must start instantaneously" - so the route is warm from launch onward).
            scheduleWarmShutdown()
            scheduleIdlePowerDown(after: grace)   // VP released after the grace; route re-warms VP-free
        } else if activityHoldActive {
            scheduleIdlePowerDown(after: grace)   // same: activity warmth continues, but VP-free
            // Activity-driven warmth: the user is at the keyboard, so keep the route hot;
            // the activity timer (holdWarmForActivity) powers it down once they go idle.
        } else {
            // Engine stays RUNNING: a cold route loses the first words of the next
            // dictation (zeroed buffers while the hardware wakes). Only VP is released.
            scheduleIdlePowerDown(after: grace)
        }
    }

    // MARK: Activity-driven warmth (keep-warm OFF, instant starts anyway)

    /// While the user is actively typing/clicking, keep the input route hot for a short
    /// window so the next dictation starts instantly - and power it down once they go
    /// idle, so the mic indicator never stays on while they're away. This is the middle
    /// ground between "always warm" (indicator always on) and "always cold" (first words
    /// delayed by the hardware wake-up).
    private var activityStop: DispatchWorkItem?
    private var activityHoldActive = false
    func holdWarmForActivity(seconds: TimeInterval = 25) {
        guard !isRunning else { return }
        activityHoldActive = true
        activityStop?.cancel()
        if !engine.isRunning { prewarmRoute() }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRunning, !self.prewarmActive else { return }
            self.activityHoldActive = false
            self.scheduleIdlePowerDown()   // keep-warm on: stays hot; off: fully releases the mic
        }
        activityStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void,
               writeTo url: URL? = nil,
               forceFreshEngine: Bool = false) throws {
        armInFlight = true
        defer { armInFlight = false }
        idlePowerDown?.cancel()
        endPrewarm()   // a real session takes over the engine; drop the warm-up tap first
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        // CARRY the converged AGC across sessions instead of resetting to 1.0: the room,
        // mic, and voice don't change between dictations, but a fresh ramp meant the first
        // ~2s of every session were under-amplified while the gain climbed - the waveform
        // moved, yet whisper got those first words several dB quieter and dropped them.
        // ACROSS LAUNCHES TOO: the very first dictation of every app run started at 1.0
        // and spent seconds climbing to ~10x on this mic - the muted first-ever waveform.
        // The last converged gain is remembered and restored, clamped conservatively.
        if agcGain <= 1.01 {
            let saved = UserDefaults.standard.double(forKey: "agc.lastGain")
            if saved > 1 { agcGain = Float(min(saved, Double(maxAutoGain) * 0.75)) }
        }
        agcGain = min(max(agcGain, 1.0), maxAutoGain * 0.75)
        analyzer.resetNoiseFloor()   // re-learn the room's background per session
        sawLiveAudio = false

        // Attempt 1 REUSES the existing engine - crucial, because prewarm warmed THIS engine's mic
        // route, and a fresh engine would start cold and record silence. Only if arming fails
        // (e.g. the -10875 output-node wedge seen after a force-kill of an audio-active instance),
        // or the caller detected a DEAD route (buffers of pure zeros) and asked for a rebuild,
        // do we recreate: a brand-new engine sidesteps a stale CoreAudio graph.
        warmShutdown?.cancel()   // a new session claims the standby engine
        var lastError: Error?
        let fresh = forceFreshEngine || startFreshNextSession
        startFreshNextSession = false
        for attempt in 1...2 {
            if attempt == 2 || fresh {
                retireEngine()
                if attempt == 1 { yapdiag("recorder: fresh engine requested (dead route rebuild)") }
                else { yapdiag("recorder: arm failed once, retrying on a fresh engine") }
            }
            do {
                try arm(url: url, onBuffer: onBuffer, onLevel: onLevel)
                isRunning = true
                return
            } catch {
                lastError = error
                yapdiag("recorder: engine.start attempt \(attempt) failed (\(error))")
            }
        }
        throw lastError ?? TranscriptionError.unavailable("The microphone couldn't start.")
    }

    /// Replace the engine with a brand-new one, tearing the old one down in the safe order.
    /// The tap MUST come off before stop/reset/dealloc: deallocating an AVAudioEngine with a
    /// live input tap crashed the app mid-retry (caught live after a -10875 arm failure).
    private func retireEngine() {
        let old = engine
        old.inputNode.removeTap(onBus: 0)
        old.stop()
        old.reset()
        engine = AVAudioEngine()
        // Give the old engine's teardown a beat off the hot path before its final release.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { _ = old }
    }

    /// Configure the current `engine`'s input, install the tap, and start it. Throws on any
    /// audio failure so start() can retry on a fresh engine.
    private func arm(url: URL?,
                     onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
                     onLevel: @escaping (Float) -> Void) throws {
        let armStart = Date()
        func armMark(_ what: String) {
            yapdiag(String(format: "arm timing: %@ +%.0f ms", what, Date().timeIntervalSince(armStart) * 1000))
        }
        let input = engine.inputNode
        // Noise reduction: toggle Apple's voice-processing IO BEFORE device routing and format
        // reads (it rebuilds the input route). Failing to enable it (some aggregate/virtual
        // devices refuse) degrades silently to the plain mic - never blocks recording.
        Self.disableOtherAudioDucking(input)
        // AUVoiceIO is permanently off (see voiceProcessingPermitted). The only VP work
        // left on the session path is CLEANUP: if some earlier state left it engaged,
        // shed it - turning VP off is quick, but never on a running engine (-10849).
        if input.isVoiceProcessingEnabled {
            if engine.isRunning { engine.stop() }
            do { try input.setVoiceProcessingEnabled(false) }
            catch { yapdiag("recorder: voice processing disable failed (\(error)) - continuing") }
            invalidateResidentTap()   // route rebuilt - the tap must be reinstalled
            armMark("voiceProcessing -> off")
        }
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
        armMark("device routing")
        let format = input.outputFormat(forBus: 0)
        armMark("format read")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw TranscriptionError.unavailable("No microphone input is available.")
        }

        if let url {
            let f = try? AVAudioFile(forWriting: url, settings: format.settings)
            sessionLock.lock(); audioFile = f; sessionLock.unlock()
        }

        // Plug this session's callbacks into the RESIDENT tap - no tap churn. Removing and
        // re-installing the tap per session suspended the input stream between sessions,
        // costing the first ~0.4s of the next dictation to hardware wake.
        sessionLock.lock()
        // Hand the pre-roll to the transcriber FIRST (same serial queue the live buffers
        // use, enqueued under the lock, so ordering is airtight: pre-roll, then session).
        let roll = preRoll
        preRoll = []
        // Stale ring = the engine sat stopped (failed revive, sleep) - prepending it
        // would transcribe OLD room audio. Only fresh, format-matched audio counts.
        let ringFresh = Date().timeIntervalSince(preRollLastAppend) < 1.0
        if !roll.isEmpty, ringFresh, roll.allSatisfy({ $0.format == format }) {
            let rollGain = max(1, inputGain)
            let file = audioFile
            let ms = Int(Double(roll.count) * Double(roll[0].frameLength) / format.sampleRate * 1000)
            processingQueue.async {
                for b in roll {
                    AudioRecorder.applyGain(b, rollGain)
                    onBuffer(b)
                    if let file { try? file.write(from: b) }   // crash recovery covers it too
                }
            }
            yapdiag("recorder: prepended \(roll.count) pre-roll buffers (~\(ms)ms of pre-press audio)")
        }
        sessionLevelCB = onLevel
        sessionBufferCB = onBuffer
        probeCB = nil
        sessionLock.unlock()
        ensureResidentTap(format, on: input)
        armMark("installTap")
        bufferCount = 0
        startedAt = Date()
        engine.prepare()
        armMark("engine.prepare")
        try engine.start()
        armMark("engine.start DONE")
    }

    /// Hot-mic standby: after a session ends, keep the engine (and the hardware input route)
    /// RUNNING instead of stopping it. A cold route delivers zeroed buffers for the first
    /// 1-2s of the next session - exactly the "it skips my first words" complaint - and the
    /// only real cure is to never let it go cold. The route is released after 5 idle minutes
    /// so the mic indicator doesn't stay on forever.
    var keepWarm = true
    /// User-tunable standby duration (Settings > Microphone slider).
    var warmSeconds: Double = 300
    private var warmShutdown: DispatchWorkItem?

    /// Set when the keep-warm standby window has run out: the NEXT idle power-down fully
    /// releases the mic instead of re-warming, honoring the "stay warm for N minutes"
    /// slider. Cleared whenever warmth is legitimately re-established.
    private var warmStandbyExpired = false
    private func scheduleWarmShutdown() {
        warmStandbyExpired = false
        warmShutdown?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRunning, !self.prewarmActive else { return }
            yapdiag("recorder: warm standby expired - releasing the route")
            self.warmStandbyExpired = true
            self.scheduleIdlePowerDown(after: 1)
        }
        warmShutdown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(30, warmSeconds), execute: item)
    }

    /// Set when a session had to start WITHOUT voice processing (instant start beats a
    /// 1-2s VP init). stop() then re-warms the route with VP enabled, off the hot path.
    private var needsVoiceProcessingPrewarm = false
    /// Set when media playback resumed after a session: audio quality outranks having VP
    /// pre-armed, so the pending VP prewarm for THIS session stands down.
    private var vpPrewarmSuppressed = false

    /// Release voice processing RIGHT NOW (idle only) and suppress this session's pending
    /// VP prewarm. Called just before resuming the user's media: playback must come back
    /// at full quality, not into system voice mode. Warmth is preserved VP-free.
    func releaseVoiceProcessingNow() {
        guard !isRunning else { return }
        vpPrewarmSuppressed = true
        idlePowerDown?.cancel()
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled || prewarmActive else { return }
        prewarmActive = false
        input.removeTap(onBus: 0)
        let wantWarm = (keepWarm && !warmStandbyExpired) || activityHoldActive   // keep-warm off/expired = the mic actually lets go
        if engine.isRunning { engine.stop() }
        if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
            invalidateResidentTap()   // route rebuilt - the tap must be reinstalled
            yapdiag("recorder: VP released before media resume - playback comes back clean")
        }
        if wantWarm {
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 { ensureResidentTap(format, on: input) }
            engine.prepare(); try? engine.start()
        }
    }

    func stop() {
        guard isRunning else { return }
        yapdiag("recorder.stop: captured \(bufferCount) buffers")
        sessionLock.lock()
        sessionLevelCB = nil
        sessionBufferCB = nil
        sessionLock.unlock()   // the RESIDENT tap stays installed - the stream keeps pulling
        // Remember the converged gain for the NEXT LAUNCH's first dictation.
        if agcGain > 1.01 { UserDefaults.standard.set(Double(agcGain), forKey: "agc.lastGain") }
        if keepWarm {
            scheduleWarmShutdown()   // engine stays running: next session has zero cold-route skip
            scheduleIdlePowerDown()  // ...but VP is still released after the grace (restarts VP-free)
        } else {
            // Keep-warm OFF (the default): the mic lets go right after the dictation ends.
            // One second of grace covers instant re-dictation taps without holding the
            // route (or the orange indicator) a moment longer than promised.
            scheduleIdlePowerDown(after: 1)
        }
        if needsVoiceProcessingPrewarm, reduceNoise, Self.voiceProcessingPermitted {
            needsVoiceProcessingPrewarm = false
            vpPrewarmSuppressed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, !self.isRunning, !self.vpPrewarmSuppressed else { return }
                yapdiag("recorder: post-session prewarm to bring voice processing back")
                self.prewarmRoute(withVoiceProcessing: true)   // applies VP before spinning the engine
            }
        }
        isRunning = false
        isPaused = false
        // Deliberately NOT clearing onBuffer/onLevel here: the tap runs on a real-time audio
        // thread and reads those closures, so mutating them from the main thread while a buffer
        // is in flight is a data race that corrupts the heap. They're simply replaced on the
        // next start(), which only happens after the tap is fully removed.
        // Close THIS session's file after its queued writes drain - by VALUE, so a
        // back-to-back dictation that already installed a NEW file can never have it
        // nulled by the old session's deferred close (that silently produced empty
        // crash-recovery/saved-audio files on rapid re-triggers).
        sessionLock.lock()
        let closing = audioFile
        audioFile = nil
        sessionLock.unlock()
        processingQueue.async {
            _ = closing   // retained until every queued write lands, then released
        }
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

    /// Highest absolute sample of the first channel, before any gain (peak-guard input).
    static func rawPeak(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let data = buffer.floatChannelData {
            let p = data[0]
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(p[i])) }
            return peak
        } else if let data = buffer.int16ChannelData {
            let p = data[0]
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(Float(p[i]))) }
            return peak / Float(Int16.max)
        } else if let data = buffer.int32ChannelData {
            let p = data[0]
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(Float(p[i]))) }
            return peak / Float(Int32.max)
        }
        return 0
    }

    /// Multiply every sample by `gain`, through a SOFT KNEE instead of a hard clamp: linear
    /// below 0.85, smooth tanh compression above, asymptotically bounded under 1.0. A hard
    /// min/max clamp turned loud-voice-over-loud-noise sessions into square-wave distortion
    /// whisper couldn't read ("Detailed." from a full sentence). Same knee constants as
    /// SpeechEnhancer's limiter. Runs off the render thread (on the processing queue).
    static func applyGain(_ buffer: AVAudioPCMBuffer, _ gain: Float) {
        guard gain != 1.0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let knee: Float = 0.85
        let span: Float = 0.14
        @inline(__always) func soft(_ y: Float) -> Float {
            let a = abs(y)
            return a <= knee ? y : (y < 0 ? -1 : 1) * (knee + tanh((a - knee) / 0.3) * span)
        }
        if let data = buffer.floatChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames { p[i] = soft(p[i] * gain) }
            }
        } else if let data = buffer.int16ChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames {
                    let v = soft(Float(p[i]) / Float(Int16.max) * gain)
                    p[i] = Int16(v * Float(Int16.max))
                }
            }
        } else if let data = buffer.int32ChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frames {
                    let v = soft(Float(p[i]) / Float(Int32.max) * gain)
                    p[i] = Int32(v * Float(Int32.max))
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
