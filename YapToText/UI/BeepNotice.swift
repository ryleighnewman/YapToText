import SwiftUI
import AppKit

/// The honest small print under Intelligent insert. Reading the text around the cursor
/// means sending a few synthetic keystrokes into the target app; an app that refuses one of
/// them makes macOS play the alert sound. Says so, and points at the one-slider cure.
struct BeepNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Reads the text around your cursor with a few invisible keystrokes. Some apps refuse one of them and macOS plays a short alert beep each time. Harmless, but if it bothers you: System Settings > Sound > drag Alert volume all the way down. Only alert beeps go quiet; music, video, and dictation sounds are unaffected.")
            Button("Open Sound Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}
