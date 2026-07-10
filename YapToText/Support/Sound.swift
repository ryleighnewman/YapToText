import AppKit

/// Subtle audio cues for start/stop/error, using built-in system sounds.
enum Sound {
    static func playStart() { NSSound(named: "Tink")?.play() }
    static func playStop() { NSSound(named: "Bottle")?.play() }
    static func playError() { NSSound(named: "Funk")?.play() }
}
