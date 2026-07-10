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
    /// Manual boost to preview on the meter; set from the slider.
    var gain: Float = 1.0
    /// Preview auto-gain on the meter too, so it matches what dictation will actually hear.
    var autoAmplify: Bool = false

    private let engine = AVAudioEngine()
    private var running = false        // the tap/engine is actually live
    private var wantsRunning = false   // the meter is wanted (settings card visible)
    private var agcGain: Float = 1.0
    private var lastPublish: CFTimeInterval = 0

    /// The settings meter appeared: run the tap.
    func start() { wantsRunning = true; startEngine() }
    /// The settings meter disappeared: fully stop.
    func stop() { wantsRunning = false; stopEngine() }
    /// App went to the background: drop the mic tap so NO audio thread runs while idle - but
    /// remember we want it back when the app returns.
    func suspend() { stopEngine() }
    func resume() { if wantsRunning { startEngine() } }

    private func startEngine() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        agcGain = 1.0
        lastPublish = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let raw = AudioRecorder.rawRMS(buffer)
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
            DispatchQueue.main.async { [weak self] in self?.level = lvl }
        }
        engine.prepare()
        do { try engine.start(); running = true } catch { running = false }
    }

    private func stopEngine() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        DispatchQueue.main.async { [weak self] in self?.level = 0 }
    }
}

/// Observes the shared monitor in ISOLATION, so incoming level updates re-render only this meter
/// bar - not the surrounding glass settings cards. This is the render-scope fix for the Liquid
/// Glass crash.
struct LiveInputMeter: View {
    @ObservedObject private var monitor = InputLevelMonitor.shared
    var body: some View { InputMeter(level: monitor.level) }
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
