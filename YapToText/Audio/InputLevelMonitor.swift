import AVFoundation
import SwiftUI

/// Live microphone meter for Settings - its own AVAudioEngine tap that publishes the current
/// input level (post-boost). Kept deliberately low-impact: it runs ONLY while the audio settings
/// section is on screen AND the app is active, throttles its updates, and its level is observed
/// in isolation (see `LiveInputMeter`) so it never re-renders the surrounding glass cards.
///
/// History: a previous version left this engine running while the app was idle and published
/// ~40x/sec, which re-rendered the whole glass settings view and crashed Apple's Liquid Glass
/// (DesignLibrary) during a render transaction. Hence the suspend/resume + throttle + isolation.
final class InputLevelMonitor: ObservableObject, @unchecked Sendable {
    /// Shared instance: only one meter tap exists, and dictation stops it before recording so the
    /// two AVAudioEngines never fight over the microphone (which yields a silent recording).
    static let shared = InputLevelMonitor()

    @Published var level: Float = 0
    /// Live signal-to-noise ratio in dB (speech above the room's own floor), measured on the RAW
    /// pre-gain signal so it reflects true capture quality, not how hard auto-gain is pushing.
    /// nil until enough audio has been seen to judge. Drives the mic-health readout in Settings.
    @Published var snrDB: Float? = nil
    /// Manual boost to preview on the meter; set from the slider.
    var gain: Float = 1.0
    /// Preview auto-gain on the meter too, so it matches what dictation will actually hear.
    var autoAmplify: Bool = false

    /// Rebuilt on every start: an engine that survives an input-device change reports a
    /// STALE cached format, and installing a tap with it raises an uncatchable NSException.
    /// A fresh engine re-queries the hardware, so its format is right by construction.
    private var engine = AVAudioEngine()
    /// The user's Input source pick (nil = system default), so the meter measures the SAME
    /// microphone dictation will use instead of always showing the system default.
    var deviceUID: String?
    private var running = false        // the tap/engine is actually live
    private var wantsRunning = false   // the meter is wanted (settings card visible)
    private var agcGain: Float = 1.0
    private var lastPublish: CFTimeInterval = 0
    // SNR tracking (raw RMS): the floor chases the quiet minimum, the peak follows recent speech.
    private var noiseFloorRMS: Float = 0
    private var speechPeakRMS: Float = 0
    private var snrFrames = 0

    /// The settings meter appeared: run the tap.
    func start() { wantsRunning = true; startEngine() }
    /// The settings meter disappeared: fully stop.
    func stop() { wantsRunning = false; stopEngine() }
    /// App went to the background: drop the mic tap so NO audio thread runs while idle - but
    /// remember we want it back when the app returns.
    func suspend() { stopEngine() }
    func resume() { if wantsRunning { startEngine() } }
    /// The Input source changed: rebuild on the new device if the meter is on screen.
    func restart() { stopEngine(); if wantsRunning { startEngine() } }

    private func startEngine() {
        guard !running else { return }
        engine = AVAudioEngine()   // fresh: never trust a node that outlived a route change
        let input = engine.inputNode
        // Route to the chosen device BEFORE reading the format (engine is not running yet).
        if let uid = deviceUID, let device = AudioInputDevices.device(forUID: uid), let unit = input.audioUnit {
            var deviceID = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)   // a bus can hold exactly one tap; double-install aborts the app
        agcGain = 1.0
        lastPublish = 0
        noiseFloorRMS = 0; speechPeakRMS = 0; snrFrames = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let raw = AudioRecorder.rawRMS(buffer)
            // SNR from the RAW signal: floor chases the quiet minimum (fast down, slow up so a
            // breath can't ratchet it), peak follows recent speech energy with a gentle decay.
            if raw.isFinite, raw > 0 {
                if self.snrFrames == 0 { self.noiseFloorRMS = raw; self.speechPeakRMS = raw }
                self.noiseFloorRMS += (raw - self.noiseFloorRMS) * (raw < self.noiseFloorRMS ? 0.25 : 0.002)
                self.speechPeakRMS = max(raw, self.speechPeakRMS * 0.995)
                self.snrFrames += 1
            }
            var g = self.gain
            if self.autoAmplify {
                if raw > 0.004 {
                    let desired = min(12, max(1, 0.09 / raw))
                    let rate: Float = desired > self.agcGain ? 0.2 : 0.03
                    self.agcGain += (desired - self.agcGain) * rate
                }
                g *= self.agcGain
            }
            let lvl = AudioRecorder.normalize(raw * g)
            // Throttle to ~20 Hz: a meter doesn't need 40+ publishes/sec, and that churn on the
            // glass settings view is what crashed Liquid Glass.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastPublish > 0.05 else { return }
            self.lastPublish = now
            // Only report SNR once the floor has settled AND some speech-level energy was seen,
            // so a silent room doesn't read as a huge or zero ratio.
            let ready = self.snrFrames > 40 && self.speechPeakRMS > max(0.006, self.noiseFloorRMS * 2)
            let snr: Float? = ready ? 20 * log10(max(self.speechPeakRMS, 1e-6) / max(self.noiseFloorRMS, 1e-6)) : nil
            DispatchQueue.main.async { [weak self] in
                self?.level = lvl
                if let snr { self?.snrDB = min(60, max(0, snr)) }
            }
        }
        engine.prepare()
        do { try engine.start(); running = true }
        catch {
            // The tap was installed above; leaving it on a stopped engine meant the next
            // start() double-installed on the same bus and the app aborted.
            input.removeTap(onBus: 0)
            running = false
        }
    }

    private func stopEngine() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        DispatchQueue.main.async { [weak self] in self?.level = 0; self?.snrDB = nil }
    }
}

/// A plain-language verdict on how clean the microphone signal is, from the measured SNR.
/// Thresholds are grounded in real capture: clean studio speech is 25-40 dB, a typical laptop
/// mic in an ordinary room lands ~12-18 dB, and below ~12 dB Whisper starts dropping words.
enum MicHealth {
    case unknown, excellent, good, fair, poor

    static func from(snrDB: Float?) -> MicHealth {
        guard let s = snrDB else { return .unknown }
        switch s {
        case 25...: return .excellent
        case 18..<25: return .good
        case 12..<18: return .fair
        default: return .poor
        }
    }

    var label: String {
        switch self {
        case .unknown: return "Listening…"
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Needs attention"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .excellent, .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        }
    }

    /// Honest, specific guidance - what's happening and what to do about it.
    var advice: String {
        switch self {
        case .unknown:
            return "Say a few words so the app can measure how clearly it hears you."
        case .excellent:
            return "Your mic is heard clearly, well above the room noise. Transcription will be at its best."
        case .good:
            return "A clean signal. The occasional word may slip in a noisy moment, but accuracy will be strong."
        case .fair:
            return "There's noticeable background noise relative to your voice. A headset or getting closer to the mic would raise accuracy the most. If you're in a call app (Teams, Zoom), it may be holding the mic and lowering your level."
        case .poor:
            return "Your voice is close to the room noise, which is the biggest limit on accuracy. Move closer to the mic or use a headset, quiet fans or nearby noise, and quit call apps (Teams, Zoom) that may be ducking your input."
        }
    }
}

/// Observes the shared monitor in ISOLATION, so incoming level updates re-render only this meter
/// bar - not the surrounding glass settings cards. This is the render-scope fix for the Liquid
/// Glass crash.
struct LiveInputMeter: View {
    @ObservedObject private var monitor = InputLevelMonitor.shared
    var body: some View { InputMeter(level: monitor.level) }
}

/// Live mic-health verdict, isolated the same way as the meter so its updates never re-render the
/// surrounding glass cards. Shows a colored badge, the measured SNR, and plain-language guidance.
struct MicHealthReadout: View {
    @ObservedObject private var monitor = InputLevelMonitor.shared
    var body: some View {
        let health = MicHealth.from(snrDB: monitor.snrDB)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(health.color).frame(width: 7, height: 7)
                Text(health.label).font(.caption.weight(.semibold)).foregroundStyle(health.color)
                if let snr = monitor.snrDB {
                    Text(String(format: "· %.0f dB signal-to-noise", snr))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(health.advice).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A segmented input-level meter styled like macOS Sound settings: green rising into yellow, then
/// red near the top so the user can see when a boost is pushing into clipping.
struct InputMeter: View {
    var level: Float
    var segments: Int = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let threshold = Float(i) / Float(segments)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(level > threshold ? color(for: i) : Color.secondary.opacity(0.15))
                    .frame(height: 12)
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(for index: Int) -> Color {
        let fraction = Double(index) / Double(segments)
        if fraction > 0.88 { return .red }
        if fraction > 0.65 { return .yellow }
        return .green
    }
}
