import Foundation
import AVFoundation
import Observation

/// The History page's built-in audio player: one shared AVAudioPlayer so only one recording
/// plays at a time, with observable playing-state and progress for the row UI (play/stop
/// toggle, inline progress bar). Replaces the old fire-and-forget NSSound, which couldn't be
/// stopped and had no visible state.
@MainActor
@Observable
final class HistoryAudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = HistoryAudioPlayer()

    /// The record currently playing, or nil.
    private(set) var playingID: UUID?
    /// 0...1 through the current recording.
    private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// Play this record's audio; tapping the playing record again stops it.
    func toggle(_ record: DictationRecord) {
        if playingID == record.id { stop(); return }
        stop()
        guard let name = record.audioFileName else { return }
        let url = AudioStore.url(for: name)
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        newPlayer.delegate = self
        player = newPlayer
        playingID = record.id
        progress = 0
        newPlayer.play()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    func stop() {
        ticker?.cancel(); ticker = nil
        player?.stop(); player = nil
        playingID = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
