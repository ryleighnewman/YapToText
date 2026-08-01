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

    // MARK: Scrubbing (the pipeline-details media player)

    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }
    private(set) var isPaused = false

    /// Jump to a fraction of the recording (drag of the scrubber). Works while playing or paused.
    func seek(_ record: DictationRecord, toFraction fraction: Double) {
        if playingID != record.id { toggle(record); player?.pause(); isPaused = true }
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.duration * fraction))
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    /// Skip forward/back by `seconds` (fast-forward / rewind buttons).
    func skip(_ record: DictationRecord, by seconds: TimeInterval) {
        guard playingID == record.id, let player else { return }
        player.currentTime = max(0, min(player.duration, player.currentTime + seconds))
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    /// Pause/resume without tearing the player down (keeps position for scrubbing).
    func playPause(_ record: DictationRecord) {
        if playingID != record.id { toggle(record); isPaused = false; return }
        guard let player else { return }
        if player.isPlaying { player.pause(); isPaused = true }
        else { player.play(); isPaused = false }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
