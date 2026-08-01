import AppKit

/// Audio cues for start/stop/error - user-selectable from the built-in system sounds.
/// The names are synced from AppSettings at load and on every change.
enum Sound {
    /// The pickable palette: every classic macOS alert sound, by its NSSound name.
    static let options = ["Tink", "Pop", "Glass", "Ping", "Purr", "Bottle", "Blow",
                          "Hero", "Submarine", "Morse", "Frog", "Funk", "Basso", "Sosumi"]

    nonisolated(unsafe) static var startName = "Tink"
    nonisolated(unsafe) static var stopName = "Bottle"
    nonisolated(unsafe) static var errorName = "Funk"

    /// When any cue last played - MediaPauser uses this to avoid mistaking OUR sounds for
    /// the user's music (which made it "resume" music that was never playing).
    nonisolated(unsafe) static var lastPlayedAt: Date = .distantPast

    static func playStart() { lastPlayedAt = Date(); NSSound(named: startName)?.play() }
    static func playStop() { lastPlayedAt = Date(); NSSound(named: stopName)?.play() }
    static func playError() { lastPlayedAt = Date(); NSSound(named: errorName)?.play() }

    /// Preview a sound by name (used by the pickers so choosing = hearing).
    static func preview(_ name: String) { NSSound(named: name)?.play() }
}
