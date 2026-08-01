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
        Entry(version: "1.1 (4)", points: [
            // Editing by voice
            "Quick Edit key: select text anywhere, hold or tap your chosen key, say what to change",
            "The Quick Edit pop-up was rebuilt: one card that morphs through listening, applying, and done - your live wave condenses into the spinning ring, and the ring itself calls the verdict in green or red",
            "In tap-to-start mode, Quick Edit now waits for you: tap with nothing selected, highlight the words, and it starts listening by itself",
            "Fix a fresh dictation by voice: say \u{201C}scratch that\u{201D} to undo it, or \u{201C}replace X with Y\u{201D} to correct it, right after it lands",
            "Say \u{201C}add this to my dictionary\u{201D} over a selection to teach it a spelling forever - misheard variants are mapped automatically",
            "Quick Edit gets its own sidebar page, its own trigger styles, and its own choice of AI model",
            "A dedicated Dictation page collects the keys, microphone conditioning, and delivery options in one place",
            // Hearing you better
            "A rebuilt listening engine for hard rooms: loud background noise, whispering, and shouting over the noise all transcribe cleanly",
            "Loud speech can no longer distort: the auto-gain watches true peaks and a studio-style soft limiter replaces the hard clip that used to shred sentences",
            "Noisy or damaged clips are automatically decoded with a deeper beam search - dropped words (like a crucial \u{201C}isn\u{2019}t\u{201D}) come back",
            "Fast talkers get a second listen: machine-gun dictation is re-heard at natural pacing, and the better transcript wins",
            "Long thinking pauses are compressed before transcription, so dead air can\u{2019}t derail the model mid-dictation",
            "Said nothing? Inserted nothing. Background noise, stray periods, \u{201C}(background noise)\u{201D} captions, and looping hallucinations are all discarded instead of typed",
            "Quiet speech and whispers are carefully amplified, uneven starts are leveled, and missed words trigger an automatic second listen",
            "The auto-gain remembers your mic across launches, so the very first dictation of the day hears you (and dances) at full strength",
            "Recording reaches back in time: the half-second before you press the key is captured, so a fast first word is never clipped",
            "Instant-start recording: the mic route never sleeps, survives device changes and system sleep, and recovers mid-dictation if your headset dies",
            // System audio honesty
            "Your Mac\u{2019}s audio is untouchable now: noise handling moved fully inside the app, so dictating never stutters, echoes, or muffles other apps - before, during, or after",
            "Music pause/resume finally knows what music IS: only real players and browsers count, so a voice chat or a notification sound can never toggle your Music app out of nowhere",
            // Keys and triggers
            "Bind ANY key as the dictation or Quick Edit trigger - letters, F-keys, Space, anything - not just modifiers; bound keys are swallowed system-wide so they purely trigger",
            "Caps Lock as a trigger works on every press, with the caps light never sticking",
            "Key rebinding is bulletproof: the live triggers stand down while a field is armed, armed fields can\u{2019}t be lost or forgotten, unsupported presses explain themselves, and a key bound to BOTH triggers is flagged red in every field",
            "One press of Escape cancels by default; a require-two-presses guard is there if you want it",
            // Landing in your text
            "Intelligent insert: dictating mid-sentence adapts capitalization, spacing, and punctuation to the surrounding text - now working everywhere, including sandboxed installs, with its own switch right on Home",
            "Insert Last now means \u{201C}put it where I am\u{201D}: it types into the app you were just using, reliably, even from the menu bar pop-over",
            "Live typing at the cursor while you speak (experimental), and a review-before-insert buffer",
            // The animation system rehaul
            "The whole recording pop-up was re-choreographed: the wave splits, dives through invisible gates, and winds into a spinning ring - pixel-identical in every size, every menu, every demo",
            "The big card now condenses UPWARD onto the ring while it thinks - transcript and controls fade, the glass rides the same clock as the winding wave, and pill and ring land perfectly concentric",
            "Closing is one rising motion everywhere: controls dissolve, the card collapses upward, the pill lifts away as it narrows - and cancelling pulls the wave back into center instead of leaving it stranded",
            "Size switching is a true morph: the glass grows and shrinks in place from its anchored edge (no more backwards-feeling jumps), and the medium pill\u{2019}s right edge sweeps in with real acceleration",
            "Frame-starvation-proof: a busy Mac (first-run model loading) now slows the choreography gracefully instead of teleporting it - no more frozen, misaligned first condense",
            "Spam-proof state machines: mashing keys, cancelling mid-arm, and switching sizes mid-flight can\u{2019}t strand a tiny pill, a stale ring, or a half-collapsed card",
            // Performance
            "AI cleanup is dramatically faster after the first run: the model\u{2019}s GPU context is built once and reused instead of rebuilt every dictation (seconds saved, every time)",
            "Live preview no longer burns beam-search compute while you talk; near-zero idle CPU; models unload after idle time and reload ahead of need",
            // Looks
            "Three independent colors: app accent, pop-up background, and the pop-up waveform - each with its own picker",
            "RGB mode with speed, spread, and strength dials - the color never resets when you switch layouts, every wave on screen cycles in sync, and the rainbow follows live setting changes mid-session",
            "Softer transcript fade under the wave, gentler card shadows, one-line status while processing",
            "Menu bar icon styles: capybara, microphone, or live waveform - template-black at idle with a designed resting shape, your color only while it listens, and bars that actually dance to speech",
            // Modes and models
            "AI cleanup is a one-click switch on every mode row - flip any mode between cleanup and verbatim without opening it",
            "The cleanup model picker tells the truth: \u{201C}App default\u{201D} shows exactly which model will run",
            "Bring your own models: add any compatible Whisper or GGUF file; per-app modes editable inside each mode\u{2019}s page",
            "Smart dictionary: one-click suggestions from corrections that keep recurring",
            // Trust and safety nets
            "Quick Edit instructions are tool input, not dictations: they no longer appear in History or get resurfaced by Insert Last and Regenerate",
            "Crash-proof capture: audio streams to disk from the first moment, so even a force-quit mid-sentence is recovered at next launch",
            "Diagnostics include stability breadcrumbs (unclean exits, mid-dictation interruptions) so problems can actually be traced",
            "File pickers and save panels always open front and center - no more hunting behind windows",
            "Our privacy policy is one click away in onboarding, and the changelog you\u{2019}re reading lives at the top of About",
            // Accessibility
            "VoiceOver announces listening, transcribing, insertion, and errors - and the pop-up exposes Stop, Cancel, and Pause as accessibility actions in every size, so pointer-free users are never locked out",
            // Housekeeping
            "Search inside Commands and inside every dictionary; History pipeline details with a built-in audio player",
            "Fixes: AI cleanup can no longer paraphrase your words; turning History off deletes its recordings; your name is never added to text that isn\u{2019}t an email; back-to-back dictations always record; the stats tooltip draws above its bars; the Quick Edit tutorial highlights exactly the word it selects",
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
