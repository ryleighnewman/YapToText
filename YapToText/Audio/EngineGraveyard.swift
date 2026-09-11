import AVFoundation

/// Where retired AVAudioEngines go instead of being released.
///
/// Releasing an AVAudioEngine is not safe while CoreAudio is delivering a device change.
/// `stop()` and `reset()` leave the IO unit's HAL property listener registered; only dealloc
/// removes it. A device change (a headset joining or leaving, sleep/wake, the default input
/// switching) posts a burst of property notifications over several seconds, and each one is
/// dispatched to the IO unit's own queue. If the engine is deallocated on the main thread
/// while one of those blocks is in flight, the block messages a freed object and the app
/// dies in objc_msgSend under AVAudioIOUnit::IOUnitPropertyListener.
///
/// The app's reaction to a device change is to build a fresh engine, so a delayed release of
/// the old one landed inside that exact burst every time (crash of 2026-09-11 14:32, 1.5.1).
/// Retired engines are therefore kept here. They are stopped and tapless, so they cost a
/// little memory and nothing else. The oldest are released only after a full minute with no
/// configuration change at all.
final class EngineGraveyard {
    static let shared = EngineGraveyard()

    private var engines: [AVAudioEngine] = []
    private var purge: DispatchWorkItem?
    private let quietSeconds: TimeInterval = 60

    private init() {
        // queue: nil and hop ourselves: a main-queue observer makes AVFAudio's engine queue
        // wait for main, and main waits on the engine queue whenever it touches an engine.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in DispatchQueue.main.async { self?.deviceActivity() } }
    }

    /// Hand over an engine that has already had its tap removed and been stopped and reset.
    /// Safe from any thread: the block keeps the engine alive until it is on the list.
    func bury(_ engine: AVAudioEngine) {
        DispatchQueue.main.async {
            self.engines.append(engine)
            self.deviceActivity()
        }
    }

    /// Any configuration change pushes the purge out again: a release has to land in silence.
    private func deviceActivity() {
        purge?.cancel()
        purge = nil
        guard !engines.isEmpty else { return }
        // After a full quiet minute every retired engine goes, not only the excess: an engine
        // that opened a Bluetooth microphone keeps that device in its phone-quality profile
        // for as long as it lives, which the user hears as every sound getting worse.
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let n = self.engines.count
            self.engines.removeAll()
            if n > 0 { yapdiag("graveyard: released \(n) retired engine(s) after a quiet minute") }
            self.purge = nil
        }
        purge = item
        DispatchQueue.main.asyncAfter(deadline: .now() + quietSeconds, execute: item)
    }
}
