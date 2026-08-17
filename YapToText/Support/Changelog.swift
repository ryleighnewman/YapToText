import Foundation

/// The in-app release notes: one entry per shipped (or in-progress) version, newest first.
/// The Home header shows the CURRENT bundle version; clicking it opens this list. Add a new
/// entry here as part of preparing each release.
enum Changelog {
    struct Entry: Identifiable {
        var id: String { version }
        let version: String
        let points: [String]
    }

    /// The running app's own version string, straight from the bundle: "1.0 (4)".
    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    static let entries: [Entry] = [
        Entry(version: "1.2 (8)", points: [
            "Dramatically faster from stop to text: the AI cleanup reuses its work between dictations, both the speech and AI models warm up at launch, and needless extra passes were trimmed, so your words appear almost instantly",
            "New master switch: turn off post-transcription analysis for the fastest possible raw transcription, or leave it on for modes, formatting, and cleanup",
            "Your dictionary now shapes what the app HEARS, not just what it types, so your names and terms come out right the first time",
            "When you fix the same misheard word twice, the app offers to remember it for good",
            "A microphone health check in Settings shows how clearly you are being heard, with specific tips to improve it",
            "Better accuracy in noisy rooms and for fast speech",
            "Words you finish saying right as you press stop are no longer clipped",
            "The waveform responds the instant you start talking, with no startup lag",
            "The pop-up and its menus collapse the moment you stop, without waiting",
            "Energy-aware transcription: plugged in uses the full model, on battery it switches to the lighter one to save power - automatically, or set your own per mode",
            "An Energy page in Settings that reads your Mac and recommends the right models for it",
            "Long recordings now stream out as you go, cut at natural pauses, instead of leaving you on a spinner",
            "Ending a dictation never starts audio or video that was not already playing; a paused player is only resumed if the app actually paused it",
            "Intelligent insert adapts to the text around your cursor in more apps, including web editors",
            "Fixed a freeze that could happen at the start of a dictation while checking Music",
        ]),
        Entry(version: "1.1.1 (6)", points: [
            "The microphone releases about a second after each dictation ends - the orange indicator only shows while you dictate",
            "\u{201C}Keep the microphone warm\u{201D} now genuinely lets go when off, or when its standby window ends",
            "Launch and app switching never touch the microphone",
            "Releasing a hold-to-talk key always ends the session, even mid-startup",
            "The pop-up's opening animation is identical every time",
            "Inserting text no longer stalls the closing animation",
            "Intelligent insert reads the surrounding text more reliably",
        ]),
        Entry(version: "1.1 (4)", points: [
            "Quick Edit: select text in any app, press your key, say the change",
            "Voice corrections: \u{201C}scratch that\u{201D}, \u{201C}replace X with Y\u{201D}, \u{201C}add this to my dictionary\u{201D}",
            "Rebuilt listening engine: noisy rooms, whispers, and shouting all transcribe cleanly",
            "Auto-gain with a peak guard and soft limiter - loud speech never distorts",
            "Deeper decoding in noise recovers dropped words; fast speech gets a second listen",
            "Long pauses are compressed; silence and background noise insert nothing",
            "The half-second before your key press is captured, so first words are never clipped",
            "Any key can be a trigger, not just modifiers; conflicting bindings are flagged red",
            "Intelligent insert: mid-sentence dictation adapts case, spacing, and punctuation",
            "Insert Last types into the app you were just using",
            "Dictation never affects other apps' audio; media pause only triggers for real players",
            "Re-choreographed pop-up: the wave winds into a spinning ring while it thinks",
            "AI cleanup is much faster after the first run; lower idle CPU",
            "Separate accent, pop-up, and waveform colors, plus a full RGB mode",
            "One-click AI cleanup toggle per mode; bring your own Whisper or GGUF models",
            "Crash recovery from the first moment of audio; Quick Edit commands stay out of History",
            "VoiceOver announces every state; pop-up controls are accessibility actions",
            "Dozens of fixes, including cleanup never paraphrasing your words",
        ]),
        Entry(version: "1.0 (3)", points: [
            "Released on the Mac App Store",
            "Recording pop-up polish: cleaner edges and sizing",
            "AI cleanup prompts tuned to preserve your exact wording and tone",
            "Faster path from stopping a dictation to text on screen",
        ]),
        Entry(version: "1.0 (2)", points: [
            "Auto mode: each dictation is read and routed to the right treatment on its own",
            "Auto mode knows the destination app: Mail leans email, Messages stays casual, editors lean code",
            "End a dictation with \u{201C}make that formal\u{201D} or \u{201C}as a bullet list\u{201D} to steer the result",
            "Select text first and Auto mode shapes your dictation as a fitting reply",
            "Tap a bare modifier key (like Right \u{2318}) to start and stop dictation",
            "Redesigned menu bar popover with one-click regenerate options",
            "Smoother live text animation while transcribing",
            "Welcome tour and dictionary improvements",
            "Heavy new automated test suites for transcription cleanup quality",
        ]),
        Entry(version: "1.0 (1)", points: [
            "The first YapToText build: free, on-device dictation for the Mac",
            "Whisper transcription entirely on your Mac - nothing ever leaves it",
            "AI cleanup with Apple Intelligence or the bundled on-device model",
            "Modes: Raw, Clean Up, Note, Email, Message, and Code",
            "Dictionaries, spoken commands, history, and statistics",
        ]),
    ]
}
