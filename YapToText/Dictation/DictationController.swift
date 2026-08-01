import Foundation
import AppKit
import SwiftUI
import AVFoundation
import Observation
import Accessibility

/// The heart of the app: orchestrates record -> transcribe -> (AI clean up) -> insert ->
/// save-to-history for a single dictation, and exposes observable state for the UI.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case transforming
        case inserting
        case error(String)

        /// Single source of truth for the phase label, shared by the menu bar and the panel.
        /// The busy phases pull from small pools of fun variations - a fresh one per session
        /// (stable within a session so the label never flickers mid-thought).
        var userFacingLabel: String {
            switch self {
            case .idle: return "Ready"
            case .recording: return Phase.pick(Phase.listeningLines)
            case .transcribing: return Phase.pick(Phase.transcribingLines)
            case .transforming: return Phase.pick(Phase.transformingLines)
            case .inserting: return Phase.pick(Phase.insertingLines)
            case .error(let message): return message
            }
        }

        static let listeningLines = ["Listening…", "All ears…", "Go ahead, yap…", "Hearing you out…"]
        static let transcribingLines = ["Transcribing…", "Deciphering the yap…", "Untangling the words…",
                                        "Writing it all down…", "Catching every word…"]
        static let transformingLines = ["Cleaning up…", "Reading the room…", "Polishing the yap…",
                                        "Making you sound great…", "Dotting the i's…"]
        static let insertingLines = ["Inserting…", "Delivering the goods…", "Sliding it in place…"]

        /// One variation per dictation: reseeded when a session starts, constant until the next.
        nonisolated(unsafe) static var sessionSeed = 0
        static func pick(_ pool: [String]) -> String { pool[sessionSeed % pool.count] }
    }

    private(set) var phase: Phase = .idle {
        didSet { announceTransition(from: oldValue, to: phase) }
    }
    private(set) var liveText: String = ""
    private(set) var level: Float = 0
    /// Rolling window of real microphone levels (one entry per audio buffer), oldest first.
    /// This is what the panel's waveform draws, so it moves with actual input, not a timer.
    private(set) var levelHistory: [Float] = []
    /// True while the recording panel is playing its close choreography: the expanded
    /// layout fades its transcript/bottom bar and leaves the wave to carry the exit.
    var panelIsClosing = false
    /// True from show() until the panel actually orders out (set by RecordingPanel).
    /// The condense latch reads it: releasing the latch while the panel is still on
    /// screen snapped the ring back into a full-width wave in front of the user.
    var panelIsPresented = false
    /// Insert Last in flight (menu bar): drives the button's spinner so the click has
    /// INSTANT feedback while the target app comes forward and the paste lands.
    var insertLastBusy = false
    static let levelHistoryLength = 48
    private(set) var activeMode: Mode
    private(set) var lastError: String?
    /// Extra status shown during the finishing pipeline (.transcribing / .transforming) when
    /// something non-obvious is happening - loading the speech model, loading the cleanup model,
    /// or Auto reading context - so a slow step reads as progress instead of looking stuck (users
    /// were cancelling). nil = show the plain phase label.
    private(set) var statusDetail: String?
    /// True while recording is held (phase stays `.recording`, but audio is dropped).
    private(set) var isPaused = false
    /// Auto mode: a mid-dictation digit pick suspends auto routing for THIS session only.
    private var sessionAutoSuspended = false
    /// Live typing (experimental): when this session qualifies, newly FINALIZED words are typed
    /// at the cursor while dictation continues. `liveTypedText` is everything already typed, so
    /// finish() can deliver only the remainder and can never duplicate what's on screen.
    private var sessionLiveTyping = false
    private var liveTypedText = ""
    /// True for a dictation started from the in-app Utility scratchpad (not a global dictation), so
    /// the Utility card shows its inline recording UI ONLY for its own session and never lights up
    /// for a background global dictation. Cleared when the whole session ends.
    private(set) var isScratchpadSession = false
    /// History records currently being regenerated (drives the row spinner), and the last one
    /// that just finished (drives the brief green "updated" flash in History).
    private(set) var regeneratingIDs: Set<UUID> = []
    private(set) var lastRegeneratedID: UUID?
    /// Drives the menu bar bubble's recording blink. A low-rate timer flips this only while
    /// recording; a display-linked animation in the menu bar label would peg the CPU.
    private(set) var menuPulseLevel = 0.0
    /// Rotation for the menu bar's little processing spinner (advances only while transcribing or
    /// cleaning up). Unbounded; the renderer takes it mod 360.
    private(set) var menuSpin: Double = 0
    /// Free-running clock while recording (seconds); drives the menu bar bubble's bouncing dots.
    private(set) var menuClock: Double = 0
    /// The app that was frontmost when recording began - the one the user is dictating into.
    /// finish() re-activates it before pasting so text lands there, not in whatever happens to
    /// be frontmost when transcription completes (a window the user clicked, or YapToText).
    private var sessionTargetApp: NSRunningApplication?
    /// Quick edit: what the last dictation left on screen (and where), so a follow-up
    /// "scratch that" or "replace X with Y" can act on it instead of being typed.
    private var lastInsert: (text: String, date: Date, pid: pid_t?)?
    /// Forensics for the history record: what was actually delivered and how it went.
    private var sessionDelivered: String?
    private var sessionOutcome: String?
    private var sessionCleanupModel: String?
    private var sessionAutoVerdict: String?
    /// True when the dictation began with YapToText itself frontmost - delivery falls back to the
    /// clipboard (see beginRecording for the crash rationale).
    private var sessionStartedFromSelf = false
    /// Whether the session's audio file outlives the session (user has history + audio saving on).
    /// The file itself is ALWAYS written while recording as the crash-recovery net.
    private var keepSessionAudio = false

    /// Set by AppDelegate to show/hide the floating panel.
    var onPresentPanel: (() -> Void)?
    var onDismissPanel: (() -> Void)?
    /// Fired when active recording begins/ends. AppDelegate uses these to arm the
    /// double-Escape cancel key only while the user is actually dictating.
    var onRecordingDidStart: (() -> Void)?
    var onRecordingDidStop: (() -> Void)?
    /// Fired when the whole pipeline returns to idle (after recording AND any processing). Used to
    /// keep the Escape cancel key armed through transcription/cleanup so a stuck run can be killed.
    var onDidBecomeIdle: (() -> Void)?
    /// Fired whenever the menu-bar icon's inputs change (phase, blink, spinner tick). AppDelegate
    /// redraws the NSStatusItem image directly in AppKit - deliberately NOT observation-driven, so
    /// the icon never creates SwiftUI render transactions in the system's glass menu bar.
    var onMenuStateChanged: (() -> Void)?

    private let settings: AppSettings
    private let modeStore: ModeStore
    private let vocabulary: VocabularyStore
    private let commands: CommandStore
    private let history: HistoryStore
    private let permissions: PermissionsManager
    private let models: ModelLibrary

    private let recorder = AudioRecorder()
    private let aiTransformer = FoundationModelsTransformer()
    /// Live FFT spectrum + level for the panel visualizer, read every display frame.
    let visualData = AudioVisualData(bands: 26)
    private var engine: TranscriptionEngine?

    private var sessionStart = Date()
    private var sessionMode: Mode
    private var sessionBundleID: String?
    private var sessionAudioFileName: String?
    private var context = TransformContext()
    private var isFinishing = false
    /// When set, the next completed dictation is delivered here (the Utility hub's in-app
    /// scratchpad) instead of being typed into another app, and the floating panel is suppressed.
    private var scratchpadSink: ((String) -> Void)?
    private var autoStopMonitor: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var menuPulseTimer: Task<Void, Never>?
    /// Energy saver: unloads the cached speech/AI models after the configured idle time.
    private var modelCooldownTask: Task<Void, Never>?
    private var lastVoiceAt = Date()
    /// Wall-clock time spent paused this session, subtracted from the hard length cap and the
    /// saved duration so both count only the audio we actually captured.
    private var pausedAccumulated: TimeInterval = 0
    /// When the mic actually stopped. History durations (and the words-per-minute stat built
    /// on them) use this, so transcription/AI time can never inflate speaking time.
    private var recordingEndedAt: Date?
    private var pauseStartedAt = Date()

    /// Monotonic id for the current dictation. Bumped by start() and cancel() so a
    /// finishing Task can tell if the session it belongs to was cancelled out from under it.
    private var sessionID = 0
    /// True while start()'s async prologue (mic prompt) runs before phase == .recording.
    private var startInFlight = false
    /// Set when a push-to-talk key is released before recording has actually begun, so we
    /// can stop as soon as it does (otherwise a quick tap records forever).
    private var stopRequested = false

    init(settings: AppSettings, modeStore: ModeStore, vocabulary: VocabularyStore,
         commands: CommandStore, history: HistoryStore, permissions: PermissionsManager, models: ModelLibrary) {
        self.settings = settings
        self.modeStore = modeStore
        self.vocabulary = vocabulary
        self.commands = commands
        self.history = history
        self.permissions = permissions
        self.models = models
        let mode = modeStore.mode(withID: settings.activeModeID) ?? BuiltInModes.raw
        self.activeMode = mode
        self.sessionMode = mode
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        switch phase {
        case .idle, .error: return false
        default: return true
        }
    }
    /// True while a stopped dictation is transcribing or being AI-cleaned (the finishing pipeline).
    /// A trigger-key press during this window must be IGNORED, never turned into a cancel - cancelling
    /// here silently discards the recording the user is waiting on. Deliberate cancel = Esc / panel.
    var isProcessing: Bool { isFinishing }
    private var isErrorPhase: Bool { if case .error = phase { return true }; return false }

    /// EVERY phase / live-text mutation goes through these, inside a no-animation transaction.
    /// These observables re-render views in the glass-heavy MAIN WINDOW (StatusStrip and friends);
    /// when the mutation arrives as an ANIMATED SwiftUI transaction, AppKit runs the layout under
    /// NSAnimationContext and macOS 26.5's DesignLibrary glass renderer can segfault mid-flush -
    /// the remaining crash surface when dictating with our own window focused. A non-animated
    /// transaction takes the plain layout path.
    private func setPhase(_ new: Phase) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { phase = new }
        // Keep any loading/status detail during the finishing pipeline; clear it everywhere else.
        switch new {
        case .transcribing, .transforming: break
        default: statusDetail = nil
        }
    }

    private func setLiveText(_ new: String) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { liveText = new }
    }

    var statusText: String { phase.userFacingLabel }

    // MARK: Mode selection

    func refreshActiveMode() {
        // With Auto routing on, "Auto" IS the active mode as far as the UI is concerned; the
        // stored activeModeID keeps the user's last real mode for when Auto is turned off.
        if settings.autoContextMode {
            activeMode = BuiltInModes.auto
            return
        }
        activeMode = modeStore.mode(withID: settings.activeModeID) ?? BuiltInModes.raw
        if activeMode.usesAI { aiTransformer.prewarm(instructions: activeMode.instructions) }
    }

    /// Deliberate selection (menus, panel): picking Auto turns Auto routing on; picking any real
    /// mode is an explicit manual choice, so Auto routing turns off.
    func selectMode(_ mode: Mode) {
        if mode.id == BuiltInModes.auto.id {
            settings.autoContextMode = true
        } else {
            settings.autoContextMode = false
            settings.activeModeID = mode.id
        }
        refreshActiveMode()
    }

    /// Modes offered by the panel / switcher (engaged only). When Auto mode is enabled it takes
    /// slot 1 everywhere (digit keys, menu bar numbering); everything else shifts down. When it's
    /// off it disappears from switchers but stays available on the Modes page and in Settings.
    var switchableModes: [Mode] {
        (settings.autoContextMode ? [BuiltInModes.auto] : []) + modeStore.allModes.filter(\.isEngaged)
    }

    /// Switch modes from the floating panel, mid-dictation included: the in-flight session
    /// adopts the new mode's AI cleanup, dictionaries, and output. (The transcription model
    /// and language can't change mid-session; they apply from the next dictation.)
    func switchMode(_ mode: Mode) {
        // Mid-dictation, with Auto on, a digit pick is a ONE-OFF override: this session uses the
        // chosen mode, Auto stays on for the next dictation. Digit 1 (Auto) restores routing.
        if isBusy, settings.autoContextMode {
            if mode.id == BuiltInModes.auto.id {
                sessionAutoSuspended = false
                activeMode = BuiltInModes.auto
            } else {
                sessionAutoSuspended = true
                sessionMode = mode
                activeMode = mode
            }
            return
        }
        selectMode(mode)
        if isBusy { sessionMode = mode }
    }

    func cycleMode() {
        // Only cycle through engaged modes; a mode turned off in its editor is skipped.
        let modes = switchableModes
        guard !modes.isEmpty else { return }
        let idx = modes.firstIndex { $0.id == settings.activeModeID } ?? -1
        selectMode(modes[(idx + 1) % modes.count])
    }

    // MARK: Recording lifecycle

    /// The primary control: while recording it stops and finishes; while transcribing, cleaning
    /// up, or inserting it CANCELS the in-flight work (pressing the key mid-process means "never
    /// mind"); otherwise it starts a new dictation.
    func toggle() {
        yapdiag("toggle: isRecording=\(isRecording) phase=\(phase.userFacingLabel) isFinishing=\(isFinishing)")
        if isRecording {
            stop()
        } else if isFinishing {
            // Transcription / AI cleanup is already running. A stray, double, or spammed press here
            // used to hit the `cancel()` branch and THROW AWAY the in-flight result - the recording
            // never got saved or inserted. Ignore it instead: the work finishes and lands normally.
            // Deliberate cancellation is still available via the panel's Stop/X or double-Escape.
            yapdiag("toggle: ignored press during \(phase.userFacingLabel); letting it finish")
        } else if isBusy || startInFlight {
            cancel()
        } else {
            start()
        }
    }

    func start() {
        modelCooldownTask?.cancel()
        yapdiag("start: phase=\(phase.userFacingLabel)")
        guard phase == .idle || isErrorPhase else { yapdiag("start: BAILED (phase not idle)"); return }
        // Release the Settings input meter's mic tap so our recorder owns the input alone.
        InputLevelMonitor.shared.stop()
        lastError = nil
        errorResetTask?.cancel()
        sessionID += 1
        startInFlight = true
        stopRequested = false
        isPaused = false
        recorder.isPaused = false
        Task {
            let granted = await permissions.requestMicrophone()
            guard granted else {
                startInFlight = false
                setError("Microphone access is needed. Enable it in System Settings > Privacy & Security > Microphone.")
                return
            }
            await beginRecording()
        }
    }

    private func beginRecording() async {
        // Frontmost app is a fast, sandbox-safe read; do it synchronously.
        let (appName, bundleID) = AccessibilityReader.frontmostApp()
        // Remember the app to paste back into. We must NEVER paste into our own window (synthesizing
        // a Cmd-V into our glass window is a CONFIRMED macOS 26.5 DesignLibrary crash), so when the
        // dictation starts with YapToText frontmost - e.g. the user just opened the app and started
        // talking - the target is the app they were in BEFORE us. Only when there is truly nowhere
        // to paste does delivery fall back to the clipboard.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            sessionTargetApp = AppDelegate.shared?.previousApp()
            sessionStartedFromSelf = sessionTargetApp == nil
        } else {
            sessionTargetApp = front
            sessionStartedFromSelf = false
        }
        yapdiag("beginRecording: front=\(front?.localizedName ?? "nil") lastOther=\(AppDelegate.shared?.lastActiveOtherApp?.localizedName ?? "nil") target=\(sessionTargetApp?.localizedName ?? "nil") fromSelf=\(sessionStartedFromSelf)")
        let mode = modeStore.resolvedMode(activeID: settings.activeModeID,
                                          appBundleID: bundleID,
                                          overrides: settings.perAppModeOverrides)
        sessionMode = mode
        sessionAutoSuspended = false
        // Live typing now arms for EVERY insert-at-cursor session, including AI and Auto modes
        // (the old raw-only gate made the toggle appear to do nothing for anyone using Auto).
        // For AI sessions the stream is typed live and finish() reconciles: when cleanup changed
        // the text, the typed stream is backspaced away and the final version delivered.
        liveTypedText = ""
        sessionLiveTyping = settings.liveTyping && settings.autoInsert
            && mode.outputTarget == .insertAtCursor
            && !sessionStartedFromSelf && AXIsProcessTrusted()
        if sessionLiveTyping { yapdiag("live typing: armed for this session (AI=\(mode.usesAI || settings.autoContextMode))") }
        // With Auto routing on, the UI keeps saying "Auto"; sessionMode stays the resolved real
        // mode as the routing fallback.
        activeMode = settings.autoContextMode ? BuiltInModes.auto : mode
        sessionBundleID = bundleID
        // Selected-text is a synchronous Accessibility IPC that can stall on a busy target
        // app; read it off the main actor so it never delays the start of recording.
        context = TransformContext(
            appName: appName,
            selectedText: nil,
            clipboard: mode.includeClipboard ? NSPasteboard.general.string(forType: .string) : nil,
            userName: settings.userName)

        // If this session's cleanup runs on a GGUF, start loading it NOW, in parallel with the
        // recording, so the model is warm by the time transcription finishes. Loading at app
        // launch instead kept ~2GB resident for users who never touch an AI mode.
        if mode.usesAI || settings.autoContextMode {
            let cleanupID = mode.languageModelID ?? settings.selectedLanguageModelID
            if cleanupID != "apple", let cleanupModel = models.model(id: cleanupID),
               cleanupModel.runtime == .llamaCpp,
               let cleanupURL = models.downloads.localURL(for: cleanupModel) {
                LlamaEngine.prewarm(modelPath: cleanupURL.path)
            }
        }
        recorder.preferredDeviceUID = settings.inputDeviceUID
        recorder.inputGain = Float(settings.inputGain)
        recorder.autoAmplify = settings.autoAmplifyInput
        recorder.reduceNoise = settings.reduceBackgroundNoise
        recorder.keepWarm = settings.keepMicWarm
        recorder.warmSeconds = settings.micWarmMinutes * 60
        // The FFT/spectrum pipeline only feeds the waveform visualizers. When neither the floating
        // panel nor the Utility scratchpad wave can be on screen this session, skip the per-buffer
        // analysis entirely. Start-time gate on purpose: the tap captures the callback by value,
        // so a mid-session change couldn't take effect anyway. (The menu bar mini-waveform uses
        // levelHistory from onLevel, not the spectrum, so it keeps animating either way.)
        if scratchpadSink != nil || settings.showRecordingPanel {
            recorder.onSpectrum = { [weak self] bands in
                self?.visualData.spectrum = bands
            }
        } else {
            recorder.onSpectrum = nil
        }
        let locale = mode.localeIdentifier ?? settings.localeIdentifier
        let engine = makeEngine(for: mode)
        self.engine = engine

        setLiveText("")
        level = 0
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        setPhase(.recording)
        sessionStart = Date()
        recordingEndedAt = nil
        sessionDelivered = nil
        sessionOutcome = nil
        sessionCleanupModel = nil
        sessionAutoVerdict = nil
        Phase.sessionSeed &+= 1   // fresh fun-label variation each dictation
        if settings.pauseMediaDuringDictation { MediaPauser.pauseIfPlaying() }
        lastVoiceAt = Date()
        pausedAccumulated = 0

        // ALWAYS record the session to disk (.caf streams incrementally, so a crash mid-sentence
        // leaves a readable file): this is the crash-recovery net. If the user has audio saving
        // off, the file is deleted at every CLEAN end of the session - it only ever survives an
        // actual crash, where the next launch recovers and then discards it.
        keepSessionAudio = settings.saveHistory && settings.saveAudio
        let audioName = AudioStore.newFileName()
        sessionAudioFileName = audioName
        let audioURL: URL? = AudioStore.url(for: audioName)

        if settings.playSounds { Sound.playStart() }
        // The Utility hub scratchpad shows its own inline waveform, so skip the floating panel.
        if settings.showRecordingPanel, scratchpadSink == nil, case .recording = phase {
            // A cancel racing the arm sequence must not re-present a panel that the
            // cancel just dismissed - nobody would ever dismiss it again (stuck pill).
            onPresentPanel?()
        }

        if mode.includeSelectedText || settings.autoContextMode {
            let sid = sessionID
            Task.detached(priority: .userInitiated) { [weak self] in
                let selected = AccessibilityReader.focusedSelectedText()
                await MainActor.run { [weak self] in
                    guard let self, self.sessionID == sid else { return }
                    self.context.selectedText = selected
                }
            }
        }

        let sid = sessionID
        do {
            // CAPTURE FIRST, WARM UP SECOND: the recorder starts immediately - waveform moving,
            // audio rolling - while the speech session arms in parallel. Buffers that arrive
            // before the session is ready are held in `pending` and flushed in afterwards, so
            // the first words are never lost to engine warm-up.
            let pending = PendingAudio()
            let recorderBuffer: (AVAudioPCMBuffer) -> Void = { [weak engine] buffer in
                if pending.gate(buffer) { engine?.append(buffer) }
            }
            let recorderLevel: (Float) -> Void = { [weak self] rawLevel in
                guard let self, !self.isPaused else { return }   // ignore any late tap that lands after pause()
                // Publish-time NaN/Inf guard: `level` is @Observable state read by several views;
                // a non-finite value here becomes a bogus CGFloat in the view graph.
                let level = rawLevel.isFinite ? min(max(rawLevel, 0), 1) : 0
                self.level = level
                self.visualData.level = level
                self.levelHistory.append(level)
                if self.levelHistory.count > Self.levelHistoryLength { self.levelHistory.removeFirst() }
                if level > 0.12 { self.lastVoiceAt = Date() }
            }
            // NEVER start the audio engine on the main thread: AVAudioEngine.start() is
            // synchronous and has been seen HANGING inside CoreAudio (frozen app, End button
            // dead, sample shows the main thread parked in engine start). Run it detached with
            // its own timeout; on timeout the session fails visibly and the next one gets a
            // fresh engine, while the UI stays alive throughout.
            let recorder = self.recorder
            do {
                try await Self.withArmTimeout(seconds: 5) {
                    try await Task.detached(priority: .userInitiated) {
                        try recorder.start(onBuffer: recorderBuffer, onLevel: recorderLevel, writeTo: audioURL)
                    }.value
                }
            } catch {
                recorder.startFreshNextSession = true   // the hung/failed engine is poisoned
                throw error
            }
            yapdiag("beginRecording: recorder LIVE (capture-first), arming speech session…")
            // DEAD-ROUTE WATCHDOG: a session's input route can come up delivering buffers of pure
            // zeros for its entire life. If no genuine signal arrives quickly, rebuild the
            // recorder on a brand-new engine WITHOUT ending the session.
            Task { [weak self] in
                guard let self else { return }
                // Noise reduction outputs PURE ZEROS during silence, so under it this
                // watchdog needs a LONGER fuse (a quiet first second is normal) - but it
                // must still exist: with it fully disabled, a genuinely dead route after
                // long uptime left the app PERMANENTLY deaf (caught live: "Listening..."
                // with a flat wave, all-zero buffers, no rescue).
                // (Voice processing is permanently off, so silence never means a VP gate
                // is eating the signal - a short fuse is safe on every route now.)
                let fuse = 1.0
                if await self.recorder.waitUntilLive(timeout: fuse) { return }
                guard sid == self.sessionID, self.phase == .recording, !self.isPaused else { return }
                // Rescue INSTANTLY on the plain route: skip voice processing for the
                // rebuild (enabling it costs 1-2s of deafness), and do NOT poison the
                // next session - the fresh engine here is the whole fix.
                self.recorder.reduceNoise = false
                yapdiag("beginRecording: route DEAD after \(fuse)s (all-zero buffers); rebuilding engine")
                self.recorder.stop()
                do {
                    // Keep writing the SAME session file: crash recovery and saved-audio
                    // history must cover the rescued remainder, not reference a stub.
                    try self.recorder.start(onBuffer: recorderBuffer, onLevel: recorderLevel,
                                            writeTo: audioURL, forceFreshEngine: true)
                    if await self.recorder.waitUntilLive(timeout: 2.5) {
                        yapdiag("beginRecording: rebuilt route is LIVE")
                    } else {
                        yapdiag("beginRecording: rebuilt route STILL dead")
                        self.flashStatus("The microphone isn't delivering audio. Try again, or pick another input in Settings.")
                    }
                } catch {
                    yapdiag("beginRecording: dead-route rebuild failed: \(error)")
                }
            }
            // Arm timeout: beginSession can hang FOREVER when audio input is broken (seen live:
            // no mic attribution -> SpeechAnalyzer never returns, startInFlight stuck true, the
            // app reads as crashed/frozen while every keypress logs a useless stop()). 12s is
            // far beyond any legitimate cold start; after that, fail visibly instead.
            try await Self.withArmTimeout(seconds: 12) {
            try await engine.beginSession(localeIdentifier: locale) { [weak self] update in
                Task { @MainActor in
                    guard let self else { return }
                    self.setLiveText(update.combined)
                    // Live typing: type only NEWLY FINALIZED text (volatile guesses still change,
                    // so they never touch the target app). Only clean prefix growth is typed; a
                    // revision of already-typed text stops further live output for the session -
                    // what's on screen stays, and finish() reconciles without duplicating.
                    if self.sessionLiveTyping, self.isRecording, !self.isPaused {
                        // Whisper only ever streams VOLATILE text (finalized arrives at the very
                        // end), so live typing follows whichever stream exists - typing new words
                        // as they come and backspacing the tail when the engine revises a guess.
                        var stream = update.finalized.isEmpty ? update.volatile : update.finalized
                        let windowed = stream.hasPrefix("\u{2026}")
                        if windowed { stream.removeFirst() }   // preview-window ellipsis
                        let typed = self.liveTypedText
                        if windowed, !stream.isEmpty {
                            // The preview WINDOW slid: older sentences fell out of `stream`, so a
                            // plain diff would "delete" them off screen. Align instead: find the
                            // longest tail of what's typed that starts this window, and APPEND
                            // only what's new. Never deletes earlier text.
                            var overlap = min(typed.count, stream.count)
                            while overlap > 0, !typed.hasSuffix(String(stream.prefix(overlap))) { overlap -= 1 }
                            let delta = String(stream.dropFirst(overlap))
                            if !delta.isEmpty, overlap > 0 || typed.isEmpty {
                                self.liveTypedText = typed + delta
                                TextInserter.typeLive(delta)
                            }
                        } else if !stream.isEmpty, stream != typed {
                            let common = zip(typed, stream).prefix(while: { $0 == $1 }).count
                            let deletes = typed.count - common
                            if deletes > 24 {
                                // NEVER eat earlier sentences: whisper's preview window slides
                                // (older text drops out of it), so a big "revision" is usually
                                // the window moving, not the words changing. Anything beyond a
                                // small tail correction freezes live output; finish() reconciles
                                // once with the real final text.
                                yapdiag("live typing: large revision (\(deletes) chars); freezing live output")
                                self.sessionLiveTyping = false
                            } else {
                                if deletes > 0 { TextInserter.deleteBackward(count: deletes) }
                                let delta = String(stream.dropFirst(common))
                                self.liveTypedText = stream
                                if !delta.isEmpty { TextInserter.typeLive(delta) }
                            }
                        }
                    }
                }
            }
            }
            // cancel() bumped sessionID while beginSession was awaiting: this session is dead.
            // The recorder is ALREADY capturing (capture-first), so it must be stopped here too.
            guard sid == sessionID else {
                yapdiag("beginRecording: session cancelled during prologue, aborting")
                startInFlight = false
                recorder.stop()
                await engine.cancel()
                if self.engine === engine { self.engine = nil }
                return
            }
            // Session armed: flush everything captured while it warmed up, then go direct.
            let queued = pending.arm()
            for buffer in queued { engine.append(buffer) }
            yapdiag("beginRecording: session armed; flushed \(queued.count) buffered chunks")
            startAutoStopMonitor()
            startInFlight = false
            onRecordingDidStart?()
            // Recording is live and the file is filling: drop the crash-recovery marker so a
            // sudden quit can be recovered on the next launch.
            writeRecoveryMarker(RecoveryMarker(audioFileName: audioName, startedAt: sessionStart,
                                               modeID: sessionMode.id, localeIdentifier: locale))
            yapdiag("beginRecording: ARMED (recorder running=\(recorder.isRunning))")
            announce("Listening")
            // A push-to-talk key released during the async prologue lands here.
            if stopRequested { stopRequested = false; stop() }
        } catch {
            yapdiag("beginRecording: THREW \(error)")
            startInFlight = false
            recorder.stop()
            await engine.cancel()
            self.engine = nil
            clearRecoveryMarker()
            AudioStore.delete(sessionAudioFileName)
            sessionAudioFileName = nil
            onDismissPanel?()   // unconditional: if the setting was toggled off mid-session, the panel must still go away
            setError(Self.message(for: error))
        }
    }

    /// Capture-first buffering: audio recorded while the speech session is still arming.
    /// The tap calls gate() on the audio thread; once the session is ready, arm() hands the
    /// backlog over exactly once and every later buffer flows straight through.
    private final class PendingAudio: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        private var armed = false

        /// Returns true when the buffer should go directly to the engine (session armed).
        func gate(_ buffer: AVAudioPCMBuffer) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if armed { return true }
            if buffers.count < 700 { buffers.append(buffer) }   // ~30s cap; beyond that, oldest-first is fine to drop
            return false
        }

        /// Mark the session live and return everything captured while it warmed up.
        func arm() -> [AVAudioPCMBuffer] {
            lock.lock(); defer { lock.unlock() }
            armed = true
            let queued = buffers
            buffers = []
            return queued
        }
    }

    /// Race `operation` against a wall clock. beginSession has no timeout of its own, and a
    /// hung one bricks the whole controller (startInFlight never clears).
    private static func withArmTimeout(seconds: Double, _ operation: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TranscriptionError.unavailable("The microphone or speech engine didn't start. Check the Microphone permission in System Settings > Privacy, then try again.")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func stop() {
        yapdiag("stop: phase=\(phase.userFacingLabel) startInFlight=\(startInFlight) isFinishing=\(isFinishing) engine=\(engine != nil)")
        yapdiag("stop: levelHistory n=\(levelHistory.count) max=\(String(format: "%.2f", levelHistory.max() ?? 0)) min=\(String(format: "%.2f", levelHistory.min() ?? 0))")
        // Key released before recording is FULLY armed: remember it and bail. This must be
        // checked BEFORE the phase guard - phase flips to .recording early in beginRecording's
        // async prologue, so a quick tap's release could land here with startInFlight still true
        // and run the whole stop path against a half-initialized session (endSession racing
        // beginSession, recorder.stop before recorder.start -> orphaned recorder). That race
        // segfaulted the audio engine (rc=139, caught in the live diagnostic trail).
        if startInFlight { stopRequested = true; return }
        guard phase == .recording else { return }
        guard !isFinishing, let engine else { return }
        isFinishing = true
        let sid = sessionID
        stopAutoStopMonitor()
        recorder.stop()
        recordingEndedAt = Date()   // speaking time ends HERE, not after transcription/AI cleanup
        if isPaused { pausedAccumulated += Date().timeIntervalSince(pauseStartedAt) }
        isPaused = false
        onRecordingDidStop?()
        setPhase(.transcribing)
        announce("Transcribing")
        // If the speech model still has to load (cold Whisper context), say so - a slow first
        // transcribe used to look frozen. Apple Speech reports nil, so nothing changes there.
        statusDetail = engine.modelLoadingDetail

        Task {
            do {
                let raw = try await engine.endSession()
                statusDetail = nil   // model is warm now; let the cleanup phase set its own detail
                yapdiag("stop: endSession raw.len=\(raw.count) sid==cur:\(sid == sessionID)")
                guard sid == sessionID else { return }   // cancelled while finishing

                // AUTO MODE: pick the post-processor from what was said, where it's going, and
                // how the user asked. Signals, cheapest first: trailing spoken directive ->
                // heuristic text screen -> destination-app bias -> one-word AI tiebreak.
                var source = raw
                if settings.autoContextMode, !sessionAutoSuspended,
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var extras: [String] = []

                    // Trailing spoken directive ("... make that formal") is a command, not content.
                    if let (stripped, directive) = AutoContext.extractDirective(source) {
                        source = stripped
                        extras.append(directive)
                        yapdiag("auto: directive=\(directive)")
                    }

                    let verdict: AutoContext.Verdict
                    if let quick = AutoContext.screen(source) {
                        verdict = quick
                    } else if let bias = AutoContext.destinationBias(bundleID: sessionBundleID) {
                        verdict = bias
                        yapdiag("auto: destination bias from \(sessionBundleID ?? "?")")
                    } else {
                        setPhase(.transforming)
                        statusDetail = "Reading the room…"
                        verdict = await classifyForAutoMode(source)
                        statusDetail = nil
                    }
                    guard sid == sessionID else { return }

                    var chosen: Mode
                    switch verdict {
                    case .email:   chosen = modeStore.mode(withID: BuiltInModes.email.id) ?? BuiltInModes.email
                    case .message: chosen = modeStore.mode(withID: BuiltInModes.rawTranscriptionID) ?? BuiltInModes.raw
                    case .note:    chosen = modeStore.mode(withID: BuiltInModes.note.id) ?? BuiltInModes.note
                    case .code:    chosen = modeStore.mode(withID: BuiltInModes.code.id) ?? BuiltInModes.code
                    case .cleanup:
                        // Auto's default pass repairs the transcript, it does NOT edit the user's
                        // voice: Clean Up's rewrite instructions are replaced with a conservative
                        // fix-what-was-misheard prompt.
                        chosen = modeStore.mode(withID: BuiltInModes.clean.id) ?? BuiltInModes.clean
                        chosen.instructions = AutoContext.conservativeCleanup
                    }
                    // The thinking pipeline, narrated: the pop-up says WHAT Auto detected and
                    // what it's doing about it, instead of a generic "cleaning up".
                    switch verdict {
                    case .email:   statusDetail = "Email detected - formatting and signing\u{2026}"
                    case .message: statusDetail = "Casual message detected - keeping it as spoken\u{2026}"
                    case .note:    statusDetail = "Note detected - structuring it\u{2026}"
                    case .code:    statusDetail = "Code comment detected - formatting for code\u{2026}"
                    case .cleanup: statusDetail = "Cleaning up what was misheard - nothing rewritten\u{2026}"
                    }

                    // Formatting verdicts may change LAYOUT, never the user's wording or tone -
                    // unless the user explicitly spoke a directive, which takes precedence.
                    if verdict != .message, extras.isEmpty {
                        extras.append(AutoContext.preserveGuard)
                    }

                    // Letter-shaped text: carry the recipient into the formatting.
                    if verdict == .email, let name = AutoContext.recipient(in: source) {
                        extras.append("The recipient's name is \(name). Address them naturally.")
                    }
                    // A directive forces an AI pass even when the base verdict keeps words as spoken.
                    if !extras.isEmpty, !chosen.usesAI {
                        chosen = modeStore.mode(withID: BuiltInModes.clean.id) ?? BuiltInModes.clean
                    }
                    if chosen.usesAI {
                        chosen.includeSelectedText = true   // reply context captured at record start
                        extras.append("Write in the same language the user dictated. Do not translate.")
                        if context.selectedText?.isEmpty == false {
                            extras.append("The user is replying to the text they had selected (provided as reference). Write their message accordingly; output ONLY their message.")
                        }
                        chosen.instructions += "\n" + extras.map { "- " + $0 }.joined(separator: "\n")
                    }
                    sessionAutoVerdict = verdict.rawValue
                    yapdiag("auto: verdict=\(verdict.rawValue) mode=\(chosen.name) extras=\(extras.count) replyCtx=\(context.selectedText?.count ?? 0)")
                    sessionMode = chosen
                }

                var text = vocabulary.apply(to: source, dictionaryIDs: sessionMode.dictionaryIDs)

                if sessionMode.usesAI, cleanupAvailable(for: sessionMode), !text.isEmpty {
                    // Cold GGUF load: tell the user what the wait is, so they don't cancel.
                    let cleanupID = sessionMode.languageModelID ?? settings.selectedLanguageModelID
                    if cleanupID != "apple", let m = models.model(id: cleanupID), m.runtime == .llamaCpp,
                       let url = models.downloads.localURL(for: m), !LlamaEngine.isCached(modelPath: url.path) {
                        statusDetail = "Loading the AI model (first time only)…"
                    }
                    setPhase(.transforming)
                    let cleaned = await runCleanup(text, mode: sessionMode, context: context)
                    guard sid == sessionID else { return }
                    if cleaned != text {
                        text = vocabulary.apply(to: cleaned, dictionaryIDs: sessionMode.dictionaryIDs)
                    }
                }
                // Spoken-symbol commands run LAST so an AI rewrite can't drop or reflow an emoji.
                text = commands.apply(to: text)
                if sessionMode.trimTrailingNewlines ?? settings.trimTrailingNewlines {
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                yapdiag("stop: final.len=\(text.count) -> finish")
                await finish(sid: sid, raw: raw, final: text)
            } catch {
                yapdiag("stop: THREW \(error)")
                guard sid == sessionID else { return }
                self.engine = nil
                isFinishing = false
                // Transcription failed but the app is alive: the error is surfaced right now, so
                // don't leave a recovery marker that would re-surface this session next launch.
                clearRecoveryMarker()
                if !keepSessionAudio { AudioStore.delete(sessionAudioFileName) }
                sessionAudioFileName = nil
                onDismissPanel?()   // unconditional: if the setting was toggled off mid-session, the panel must still go away
                setError(Self.message(for: error))
            }
        }
    }

    /// Re-activate the app captured at record-start and wait (up to ~1.2s, via activate()) until it
    /// is actually frontmost, so a paste can't miss. No-op if we never had a target or it's already frontmost.
    /// Bring the session's target app forward. Returns false only when there IS a known target
    /// and it refused to come frontmost - the caller then falls back to the clipboard instead of
    /// pasting into whatever random window is in front.
    private func focusTargetApp() async -> Bool {
        guard let app = sessionTargetApp, !app.isTerminated else { return true }
        return await activate(app)
    }

    /// Bring `app` to the front and wait (up to ~1.2s, with a second nudge) until it actually is,
    /// so a paste/type can't miss. Returns true once it's frontmost (or already was).
    private func activate(_ app: NSRunningApplication) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        app.activate()
        for attempt in 0..<48 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                // Frontmost is necessary but not sufficient: give the key window a beat to
                // actually accept events before any keystroke is posted.
                try? await Task.sleep(nanoseconds: 60_000_000)
                return true
            }
            if attempt == 20 { app.activate() }   // second nudge halfway through
        }
        return false
    }

    // MARK: Review before insert

    /// Show the finished text in the floating review buffer. Return (or the Insert button)
    /// delivers the possibly-edited text into the app the user dictated into; Esc discards.
    private func presentReview(_ text: String, target: OutputTarget) {
        let app = sessionTargetApp
        let method = sessionMode.insertionMethod ?? settings.insertionMethod
        let restore = settings.restoreClipboard
        ReviewWindow.shared.present(text: text, appName: app?.localizedName, commit: { edited in
            Task { @MainActor [weak self] in
                let trimmed = edited
                guard !trimmed.isEmpty else { return }
                if let app, !app.isTerminated {
                    app.activate(options: [.activateIgnoringOtherApps])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                TextInserter.deliver(trimmed, target: target, method: method, restoreClipboard: restore)
                self?.announce("Inserted")
            }
        }, discard: { [weak self] in
            self?.announce("Discarded")
        })
    }

    // MARK: Quick edit ("scratch that" / "replace X with Y")

    private enum QuickEdit {
        case scratch
        case replace(from: String, to: String)
    }

    /// Recognize an utterance that is EXACTLY an edit phrase - never a sentence containing one,
    /// so ordinary dictation is never intercepted.
    private static func parseQuickEdit(_ utterance: String) -> QuickEdit? {
        var t = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".,!?".contains(last) { t.removeLast() }
        let lower = t.lowercased()
        let scratchPhrases = ["scratch that", "delete that", "undo that", "erase that",
                              "never mind", "nevermind", "forget that"]
        if scratchPhrases.contains(lower) { return .scratch }
        // "replace A with B" / "change A to B" - matched on the original text so B keeps its casing.
        if let regex = try? NSRegularExpression(pattern: "^(?:replace|change)\\s+(.+?)\\s+(?:with|to)\\s+(.+)$",
                                                options: [.caseInsensitive]),
           let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let fromRange = Range(m.range(at: 1), in: t), let toRange = Range(m.range(at: 2), in: t) {
            return .replace(from: String(t[fromRange]), to: String(t[toRange]))
        }
        return nil
    }

    /// If `utterance` is an edit phrase aimed at the text we just inserted (same app, within 30s),
    /// perform it in place and return true. Any doubt at all -> return false and the utterance is
    /// delivered normally.
    private func performQuickEdit(utterance: String) async -> Bool {
        guard let edit = DictationController.parseQuickEdit(utterance),
              let last = lastInsert,
              Date().timeIntervalSince(last.date) < 30,
              !last.text.isEmpty, last.text.count <= 600,
              sessionTargetApp?.processIdentifier == last.pid else { return false }
        if case .replace(let from, _) = edit,
           !last.text.lowercased().contains(from.lowercased()) {
            // The phrase parsed like an edit but doesn't refer to the last insert -
            // it's probably real content ("replace the filter with a new one"). Deliver it.
            return false
        }
        guard await focusTargetApp() else { return false }
        switch edit {
        case .scratch:
            TextInserter.deleteBackward(count: last.text.count)
            lastInsert = nil
            announce("Scratched")
            yapdiag("quickEdit: scratched \(last.text.count) chars")
        case .replace(let from, let to):
            guard let range = last.text.range(of: from, options: [.caseInsensitive, .backwards]) else { return false }
            let corrected = last.text.replacingCharacters(in: range, with: to)
            TextInserter.deleteBackward(count: last.text.count)
            TextInserter.typeLive(corrected)
            lastInsert = (text: corrected, date: Date(), pid: last.pid)
            announce("Replaced")
            yapdiag("quickEdit: replaced '\(from)' -> '\(to)'")
        }
        return true
    }

    private func finish(sid: Int, raw: String, final text: String) async {
        yapdiag("finish: text.len=\(text.count) autoInsert=\(settings.autoInsert)")
        guard sid == sessionID else { return }   // cancelled: do not insert or record
        setPhase(.inserting)
        // Scratchpad sessions (Quick Edit instructions, the Utility page) are TOOL INPUT,
        // not dictations: they must never enter History. Left recorded, an instruction
        // like "capitalize everything" became the "last dictation" - Insert Last pasted
        // it and Regenerate rewrote it.
        let isToolSession = scratchpadSink != nil
        if let sink = scratchpadSink {
            // In-app scratchpad (Utility hub): hand the text to the view; never type into another app.
            scratchpadSink = nil
            sink(text)
            announce(text.isEmpty ? "Nothing heard" : "Ready")
        } else {
            let target: OutputTarget = (settings.autoInsert && !sessionStartedFromSelf)
                ? sessionMode.outputTarget : .clipboardOnly
            var quickEditHandled = false
            if !text.isEmpty, settings.quickEditDetection, target == .insertAtCursor,
               liveTypedText.isEmpty, AXIsProcessTrusted() {
                quickEditHandled = await performQuickEdit(utterance: text)
                if quickEditHandled { sessionOutcome = "voice quick edit" }
            }
            var reviewHandled = false
            if !text.isEmpty, !quickEditHandled, settings.reviewBeforeInsert,
               target != .clipboardOnly, liveTypedText.isEmpty,
               // Long-only scope: short phrases auto-insert; the long ones - where a silent
               // wrong guess actually hurts - stop for a look first.
               !settings.reviewLongTextOnly || text.count >= 200 {
                presentReview(text, target: target)
                reviewHandled = true
                sessionOutcome = "sent to review buffer"
            }
            if !text.isEmpty, !quickEditHandled, !reviewHandled {
                // Live typing reconciliation: some or all of this text is ALREADY on screen.
                // Deliver only the remainder when the final text cleanly extends what was typed;
                // if processing (vocabulary, commands) changed it, keep what's typed rather than
                // duplicating - History always holds the fully processed version.
                var liveAlreadyDelivered = false
                var liveRemainder: String? = nil
                if !liveTypedText.isEmpty, target == .insertAtCursor {
                    if text == liveTypedText {
                        liveAlreadyDelivered = true
                    } else if text.hasPrefix(liveTypedText) {
                        liveRemainder = String(text.dropFirst(liveTypedText.count))
                    } else if liveTypedText.count <= 600, await focusTargetApp() {
                        // Cleanup (AI, dictionaries, commands) rewrote the text: erase the typed
                        // stream and let the final version deliver normally in its place. This is
                        // what makes live typing usable WITH AI modes - live words while you
                        // speak, polished words the moment it's done.
                        yapdiag("live typing: cleanup rewrote text; replacing \(liveTypedText.count) typed chars")
                        TextInserter.deleteBackward(count: liveTypedText.count)
                        liveTypedText = ""
                    } else {
                        liveAlreadyDelivered = true
                        yapdiag("live typing: final text diverged from typed stream; not re-delivering")
                    }
                }
                // Trailing space so back-to-back dictations don't run together. Only when typing
                // at the cursor, and only if the text doesn't already end in whitespace.
                var delivered = liveRemainder ?? text
                if settings.appendSpaceAfterInsert, target == .insertAtCursor,
                   let last = (delivered.isEmpty ? liveTypedText : delivered).last, !last.isWhitespace {
                    delivered += " "
                }
                // Make sure the app the user dictated into is frontmost before we paste, so the
                // text can't land in a window they clicked mid-transcription (or in YapToText).
                if liveAlreadyDelivered || (liveRemainder != nil && delivered.isEmpty) {
                    // Everything is already on screen from live typing; nothing left to deliver.
                    // (The shared announce below still says "Inserted".)
                } else {
                var deliveryTarget = target
                // Synthetic paste/type events are silently DROPPED by macOS without the
                // Accessibility permission - and the clipboard restore would then erase the text
                // entirely. Degrade honestly: leave the text on the clipboard and say so.
                // Per-app override first: some apps hate simulated paste (or typing) and the
                // user can pin the method that works for them in Advanced settings.
                let method = settings.appInsertionOverrides[sessionBundleID ?? ""]
                    ?? sessionMode.insertionMethod ?? settings.insertionMethod
                var announcedAXFallback = false
                if target != .clipboardOnly, method != .clipboardOnly, !AXIsProcessTrusted() {
                    yapdiag("finish: no Accessibility permission; delivering to clipboard instead")
                    deliveryTarget = .clipboardOnly
                    announcedAXFallback = true
                    announce("Copied to clipboard. Grant Accessibility in Settings to paste automatically.")
                }
                if deliveryTarget != .clipboardOnly {
                    // If the user DELIBERATELY switched to another app mid-dictation, honor it:
                    // paste where their cursor is now. Only drag focus back to the origin app
                    // when the thing in front is YapToText itself (panel click) or nothing usable.
                    let front = NSWorkspace.shared.frontmostApplication
                    let frontIsSelf = front?.bundleIdentifier == Bundle.main.bundleIdentifier
                    let userSwitched = front != nil && !frontIsSelf
                        && front!.processIdentifier != sessionTargetApp?.processIdentifier
                        && front!.activationPolicy == .regular
                    if userSwitched {
                        yapdiag("finish: user switched to \(front!.localizedName ?? "?") mid-dictation; pasting there")
                    }
                    let focused = userSwitched ? true : await focusTargetApp()
                    if !focused {
                        // The target never came forward. Pasting now would dump the text into
                        // whatever IS forward - worse than not pasting. Keep it on the clipboard
                        // and say so.
                        yapdiag("finish: target app never came frontmost; falling back to clipboard")
                        deliveryTarget = .clipboardOnly
                    }
                }
                yapdiag("finish: delivering \(delivered.count) chars target=\(deliveryTarget) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") method=\(method.rawValue)")
                TextInserter.deliver(delivered, target: deliveryTarget,
                                     method: method,
                                     restoreClipboard: settings.restoreClipboard)
                sessionDelivered = delivered
                sessionOutcome = deliveryTarget == .clipboardOnly
                    ? (announcedAXFallback ? "failed: needs Accessibility, copied instead" : "copied to clipboard")
                    : (method == .type ? "typed" : "pasted")
                if deliveryTarget == .clipboardOnly, target != .clipboardOnly, !announcedAXFallback {
                    announce("Copied to clipboard")
                }
                if deliveryTarget != .clipboardOnly {
                    // Remember what just landed on screen so a follow-up "scratch that" /
                    // "replace X with Y" can act on it.
                    lastInsert = (text: liveTypedText + delivered, date: Date(),
                                  pid: sessionTargetApp?.processIdentifier)
                }
                }
                if liveAlreadyDelivered || (liveRemainder != nil && delivered.isEmpty) {
                    lastInsert = (text: liveTypedText, date: Date(),
                                  pid: sessionTargetApp?.processIdentifier)
                    sessionDelivered = liveTypedText
                    sessionOutcome = "live-typed"
                }
            }
            if text.isEmpty {
                announce("Nothing heard")
            } else if reviewHandled {
                announce("Ready to review")
            } else if !quickEditHandled {
                announce(target == .clipboardOnly ? "Copied to clipboard" : "Inserted")
            }
        }
        clearRecoveryMarker()   // clean end: this session no longer needs crash recovery
        if settings.saveHistory, !text.isEmpty, !isToolSession {
            history.add(DictationRecord(
                date: sessionStart,
                rawText: raw,
                finalText: text,
                modeName: sessionMode.name,
                modeID: sessionMode.id,
                durationSeconds: max(0, (recordingEndedAt ?? Date()).timeIntervalSince(sessionStart) - pausedAccumulated),
                appName: context.appName,
                appBundleID: sessionBundleID,
                localeIdentifier: sessionMode.localeIdentifier ?? settings.localeIdentifier,
                usedAI: sessionMode.usesAI && FoundationModelsTransformer.isAvailable,
                audioFileName: keepSessionAudio ? sessionAudioFileName : nil,
                deliveredText: sessionDelivered,
                outcome: sessionOutcome,
                processSeconds: recordingEndedAt.map { max(0, Date().timeIntervalSince($0)) },
                cleanupModel: sessionCleanupModel,
                autoVerdict: sessionAutoVerdict))
            if !keepSessionAudio { AudioStore.delete(sessionAudioFileName) }   // recovery-only file
        } else {
            AudioStore.delete(sessionAudioFileName)   // no record kept: don't orphan the audio
        }
        sessionAudioFileName = nil
        if settings.playSounds { Sound.playStop() }
        engine = nil
        isFinishing = false
        if text.isEmpty {
            // An empty transcript used to end SILENTLY, which reads as "the app didn't paste".
            // Say so, visibly - and HOLD the panel open long enough to actually read it. The
            // old order dismissed the panel first, so the message flashed for a blink and
            // vanished before anyone could see what went wrong.
            setError("Didn't catch that. Nothing was transcribed.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                // Never yank a panel a NEW dictation has since re-opened.
                if !self.isBusy { self.onDismissPanel?() }
            }
        } else {
            onDismissPanel?()   // unconditional: if the setting was toggled off mid-session, the panel must still go away
            setPhase(.idle)
        }
        setLiveText("")
        level = 0
        sessionTargetApp = nil
        isScratchpadSession = false
        if MediaPauser.isPendingResume { recorder.releaseVoiceProcessingNow() }   // playback resumes at FULL quality
        MediaPauser.resumeIfPaused()
        scheduleModelCooldown()
    }

    func cancel() {
        guard isBusy || startInFlight else { return }
        // "Record cancelled dictations": instead of throwing the recording away, transcribe it and
        // quietly file the raw transcript in History (never inserted anywhere, never AI-processed -
        // the user cancelled, so we do the minimum: preserve what was said). Only a genuine mic
        // recording qualifies; a scratchpad session or a cancel during transcription does not.
        let archiveCancelled = settings.recordCancelledDictations
            && phase == .recording && engine != nil && !isScratchpadSession
        if archiveCancelled, let engineToDrain = engine {
            let start = sessionStart
            let mode = sessionMode
            let bundleID = sessionBundleID
            let appName = sessionTargetApp?.localizedName
            let paused = pausedAccumulated + (isPaused ? Date().timeIntervalSince(pauseStartedAt) : 0)
            let keepAudio = settings.saveAudio && settings.saveHistory
            let audioFile = sessionAudioFileName
            let saveHistory = settings.saveHistory
            let localeID = mode.localeIdentifier ?? settings.localeIdentifier
            recorder.stop()
            // Drain the engine on its own Task; it holds its own reference so nulling self.engine
            // below is safe. Independent of sessionID (the archive completes regardless of cancel).
            Task { [weak self] in
                let raw = (try? await engineToDrain.endSession()) ?? ""
                guard let self else { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if saveHistory, !trimmed.isEmpty {
                    self.history.add(DictationRecord(
                        date: start, rawText: raw, finalText: raw,
                        modeName: mode.name, modeID: mode.id,
                        durationSeconds: max(0, Date().timeIntervalSince(start) - paused),
                        appName: appName, appBundleID: bundleID,
                        localeIdentifier: localeID, usedAI: false,
                        audioFileName: keepAudio ? audioFile : nil))
                    if !keepAudio { AudioStore.delete(audioFile) }
                } else {
                    AudioStore.delete(audioFile)
                }
            }
        }
        sessionID += 1            // invalidate any in-flight finishing Task
        startInFlight = false
        stopRequested = false
        sessionLiveTyping = false
        liveTypedText = ""
        errorResetTask?.cancel()
        stopAutoStopMonitor()
        if !archiveCancelled { recorder.stop() }   // archive path already stopped the recorder
        isPaused = false
        scratchpadSink = nil
        isScratchpadSession = false
        onRecordingDidStop?()
        clearRecoveryMarker()   // deliberate cancel: the user chose to discard, nothing to recover
        if MediaPauser.isPendingResume { recorder.releaseVoiceProcessingNow() }   // playback resumes at FULL quality
        MediaPauser.resumeIfPaused()
        scheduleModelCooldown()
        if !archiveCancelled { AudioStore.delete(sessionAudioFileName) }   // archive path owns the audio
        sessionAudioFileName = nil
        sessionTargetApp = nil
        let engine = self.engine
        self.engine = nil
        isFinishing = false
        if !archiveCancelled { Task { await engine?.cancel() } }   // archive path drains its own engine
        if settings.playSounds { Sound.playError() }
        // PHASE FIRST, THEN DISMISS. Every close choreography in RecordingPanel.hide() is
        // gated on the session being over (!isRecording / !isBusy); dismissing while the
        // phase still said .recording skipped all of them, so a cancel got no glass pinch,
        // no card collapse - the panel just blinked out while the wave played its farewell.
        setPhase(.idle)
        setLiveText("")
        level = 0
        onDismissPanel?()   // unconditional: if the setting was toggled off mid-session, the panel must still go away
        announce(archiveCancelled ? "Cancelled, saved to History" : "Cancelled")
    }

    // MARK: Pause / resume

    /// Hold the recording: keep the session and engine alive but stop feeding it audio, so
    /// nothing spoken while paused is transcribed or saved. Auto-stop is suspended too.
    func pause() {
        guard phase == .recording, !isPaused else { return }
        isPaused = true
        recorder.isPaused = true
        pauseStartedAt = Date()
        stopAutoStopMonitor()
        level = 0
        announce("Paused")
    }

    func resume() {
        guard phase == .recording, isPaused else { return }
        isPaused = false
        recorder.isPaused = false
        pausedAccumulated += Date().timeIntervalSince(pauseStartedAt)
        lastVoiceAt = Date()   // don't let the silence timer fire on the gap we just skipped
        startAutoStopMonitor()
        announce("Resumed")
    }

    func togglePause() {
        guard phase == .recording else { return }
        isPaused ? resume() : pause()
    }

    // MARK: Engine + auto-stop

    /// Warm the ACTIVE mode's whisper model into RAM in the background. Called at launch
    /// and on user activity, so a cooldown-evicted (or never-loaded) model is resident
    /// again BEFORE the next dictation instead of stalling its "Transcribing…" for seconds.
    /// Set (with a deadline) when memory pressure evicted the models: activity re-warm
    /// must NOT reload gigabytes while the system is still under pressure.
    var suppressModelWarmUntil = Date.distantPast

    func warmSpeechModel() {
        guard Date() >= suppressModelWarmUntil else { return }
        let modelID = activeMode.speechModelID ?? settings.selectedSpeechModelID
        guard modelID != "apple", let model = models.model(id: modelID), model.runtime != .apple,
              let url = models.downloads.localURL(for: model) else { return }
        WhisperEngine.warmContext(at: url.path)
        // The re-warmed model must not become PERMANENTLY resident: the eviction clock
        // restarts, exactly as it does after a dictation. Without this, one keystroke
        // after a cooldown eviction parked 1.6GB in RAM until quit.
        scheduleModelCooldown()
    }

    private func makeEngine(for mode: Mode) -> TranscriptionEngine {
        let modelID = mode.speechModelID ?? settings.selectedSpeechModelID
        if modelID != "apple", let model = models.model(id: modelID), model.runtime != .apple {
            // Only hand off to whisper when the file is actually on disk; otherwise fall back
            // to Apple Speech so dictation always works while a default model downloads.
            if let url = models.downloads.localURL(for: model) {
                yapdiag("makeEngine: WHISPER \(model.displayName) at \(url.path)")
                let engine = WhisperEngine(modelURL: url, modelName: model.displayName)
                engine.livePreview = settings.livePreviewEnabled
                return engine
            }
            yapdiag("makeEngine: model \(modelID) selected but NOT on disk; falling back to Apple Speech")
        }
        if #available(macOS 26.0, *) { yapdiag("makeEngine: APPLE SPEECH (modelID=\(modelID))"); return AppleSpeechEngine() }
        // Pre-26 macOS has no SpeechAnalyzer: Whisper is the only speech engine. Reach for ANY
        // downloaded Whisper model rather than dead-ending.
        if let fallback = models.catalogFallbackWhisperURL() {
            let engine = WhisperEngine(modelURL: fallback.url, modelName: fallback.name)
            engine.livePreview = settings.livePreviewEnabled
            return engine
        }
        return UnavailableEngine(message: "Download a Whisper model in Settings > Models to dictate on this version of macOS.")
    }

    private func startAutoStopMonitor() {
        // Per-mode overrides win; nil falls back to the app-wide preference.
        let silence = sessionMode.silenceTimeout ?? settings.silenceTimeout
        let maxDuration = sessionMode.maxRecordingSeconds ?? settings.maxRecordingSeconds
        guard silence > 0 || maxDuration > 0 else { return }
        autoStopMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.phase == .recording else { return }
                let now = Date()
                let elapsed = now.timeIntervalSince(self.sessionStart) - self.pausedAccumulated
                if maxDuration > 0, elapsed >= maxDuration { self.stop(); return }
                if silence > 0, elapsed > 1.0, now.timeIntervalSince(self.lastVoiceAt) >= silence {
                    self.stop(); return
                }
            }
        }
    }

    private func stopAutoStopMonitor() {
        autoStopMonitor?.cancel()
        autoStopMonitor = nil
    }

    /// Warm the microphone route at launch (see AudioRecorder.prewarmRoute).
    /// Activity ping from AppDelegate's global input monitor: user is at the keyboard,
    /// keep the route hot for the next few moments.
    func holdMicWarmForActivity() {
        recorder.reduceNoise = settings.reduceBackgroundNoise
        recorder.holdWarmForActivity()
    }

    func prewarmAudioInput() {
        // The prewarm engine MUST match the session's voice-processing state: arm() toggling
        // it later on the running warm engine fails (-10849) and leaves the route dead - the
        // "app is deaf for 2 seconds after launch" bug (0 buffers for 1s, then a 1.6s fresh-
        // engine rebuild). Warm the route in its final configuration instead.
        recorder.reduceNoise = settings.reduceBackgroundNoise
        recorder.prewarmRoute()
        recorder.installKeepAlive()   // revive the route after sleep/lock/device changes
    }

    // MARK: Crash recovery

    /// If the app dies mid-dictation (crash, force quit, power loss), the words must not be lost:
    /// audio streams to a .caf on disk during EVERY session, and this marker names the live
    /// session. It's removed at every clean end (finish / cancel / error), so its presence at
    /// launch means the last session never finished - recover it.
    private struct RecoveryMarker: Codable {
        var audioFileName: String
        var startedAt: Date
        var modeID: UUID?
        var localeIdentifier: String
    }

    private static var recoveryMarkerURL: URL { Persistence.url("recovery-session.json") }

    private func writeRecoveryMarker(_ marker: RecoveryMarker) {
        try? JSONEncoder().encode(marker).write(to: Self.recoveryMarkerURL, options: .atomic)
    }

    private func clearRecoveryMarker() {
        try? FileManager.default.removeItem(at: Self.recoveryMarkerURL)
    }

    /// Called once at launch. If a recovery marker survives from a crashed session, transcribe the
    /// audio that made it to disk through the normal pipeline, keep the result in History (when
    /// history is on) and on the clipboard, then clean up. The audio file itself is kept only if
    /// the user saves audio; otherwise it's discarded after the text is rescued.
    func recoverCrashedSessionIfNeeded() {
        guard let data = try? Data(contentsOf: Self.recoveryMarkerURL),
              let marker = try? JSONDecoder().decode(RecoveryMarker.self, from: data) else { return }
        clearRecoveryMarker()
        let url = AudioStore.url(for: marker.audioFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let keep = settings.saveHistory && settings.saveAudio
        let mode = marker.modeID.flatMap { modeStore.mode(withID: $0) } ?? activeMode
        yapdiag("recovery: found crashed session \(marker.audioFileName), transcribing")
        UserDefaults.standard.set(true, forKey: "diag.lastUncleanMidDictation")
        Task {
            // Anything under ~half a second of audio is a stray tap, not lost words.
            let duration: Double = (try? AVAudioFile(forReading: url)).map {
                Double($0.length) / $0.processingFormat.sampleRate
            } ?? 0
            guard duration >= 0.5 else { AudioStore.delete(marker.audioFileName); return }
            do {
                let text = try await transcribe(fileURL: url, mode: mode)
                guard !text.isEmpty else { AudioStore.delete(marker.audioFileName); return }
                if settings.saveHistory {
                    history.add(DictationRecord(
                        date: marker.startedAt, rawText: text, finalText: text,
                        modeName: mode.name, modeID: mode.id, durationSeconds: duration,
                        appName: "Recovered after a crash", appBundleID: nil,
                        localeIdentifier: marker.localeIdentifier,
                        usedAI: mode.usesAI && FoundationModelsTransformer.isAvailable,
                        audioFileName: keep ? marker.audioFileName : nil))
                }
                if !keep { AudioStore.delete(marker.audioFileName) }
                TextInserter.setClipboard(text)
                announce("Recovered your last dictation. It's in History and on the clipboard.")
                yapdiag("recovery: rescued \(text.count) chars")
            } catch {
                yapdiag("recovery: transcription failed: \(error)")
                if !keep { AudioStore.delete(marker.audioFileName) }
            }
        }
    }

    // MARK: Regenerate

    /// Re-run the AI transform for a past dictation, update its history entry, and copy the
    /// new text to the clipboard. Works from the History list or the menu bar.
    /// The AI mode Regenerate uses for a record, in priority order: the record's own mode if it's
    /// AI, else the current mode if it's AI, else the built-in Clean Up - so Regenerate can always
    /// reformat a dictation, even a plain Raw one. Returns nil only when NO cleanup model is
    /// available at all (Apple Intelligence off and nothing downloaded) - the one case the button
    /// should stay greyed.
    func regenerationMode(for record: DictationRecord) -> Mode? {
        // 1) the record's own AI mode, then 2) the current mode if AI - use whichever can run now.
        let direct: [Mode?] = [
            record.modeID.flatMap { modeStore.mode(withID: $0) }.flatMap { $0.usesAI ? $0 : nil },
            activeMode.usesAI ? activeMode : nil,
        ]
        for case let mode? in direct where cleanupAvailable(for: mode) { return mode }
        // 3) fall back to Clean Up so even a Raw dictation can be reformatted. Point it at whatever
        //    cleanup engine is actually available: its default (Apple Intelligence) if that works,
        //    otherwise the first downloaded language model.
        var clean = modeStore.mode(withID: BuiltInModes.clean.id) ?? BuiltInModes.clean
        if cleanupAvailable(for: clean) { return clean }
        if let llm = models.languageModels.first(where: { models.isSelectable($0) && !$0.isBuiltIn }) {
            clean.languageModelID = llm.id
            if cleanupAvailable(for: clean) { return clean }
        }
        return nil
    }

    func regenerate(_ record: DictationRecord) {
        guard let mode = regenerationMode(for: record) else {
            announce("Turn on Apple Intelligence or download a cleanup model to regenerate.")
            return
        }
        performRegenerate(record, mode: mode)
    }

    /// Regenerate the most recent dictation with an EXPLICIT AI mode (the menu-bar mode picker),
    /// updating History and copying the result to the clipboard.
    func regenerateLast(using mode: Mode) {
        guard let last = history.records.first else { return }
        guard mode.usesAI, cleanupAvailable(for: mode) else {
            announce("That mode has no cleanup engine available right now.")
            return
        }
        performRegenerate(last, mode: mode)
    }

    private func performRegenerate(_ record: DictationRecord, mode: Mode) {
        guard !regeneratingIDs.contains(record.id) else { return }
        regeneratingIDs.insert(record.id)
        Task {
            defer { regeneratingIDs.remove(record.id) }
            do {
                let cleaned = await runCleanup(record.rawText, mode: mode, context: TransformContext(userName: promptUserName(for: mode)))
                var text = cleaned
                text = vocabulary.apply(to: text, dictionaryIDs: mode.dictionaryIDs)
                text = commands.apply(to: text)
                if mode.trimTrailingNewlines ?? settings.trimTrailingNewlines { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                var updated = record
                updated.finalText = text
                updated.usedAI = true
                history.update(updated)
                // If the ORIGINAL of this record is still sitting on screen from the last
                // insert, swap it in place - regenerate should visibly produce output, not
                // silently park it on the clipboard (the old behavior read as "nothing happened").
                if record.id == history.records.first?.id, await replaceLastInsert(with: text) {
                    announce("Regenerated and replaced")
                } else {
                    TextInserter.setClipboard(text)
                    announce("Regenerated. Copied to clipboard.")
                }
                // Brief green "updated" flash on the row / the menu-bar "Copied" state.
                lastRegeneratedID = record.id
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if lastRegeneratedID == record.id { lastRegeneratedID = nil }
            } catch {
                announce("Couldn't regenerate. \(Self.message(for: error))")
            }
        }
    }

    /// Regenerate the most recent dictation (menu bar / command) - through an AI mode even if it was
    /// dictated raw.
    func regenerateLast() {
        guard let last = history.records.first else { return }
        regenerate(last)
    }

    /// Swap the text the last dictation left on screen for `replacement`: bring the target app
    /// back, backspace the old insert, type the new one. False when there's nothing recent to
    /// replace (caller falls back to the clipboard).
    private func replaceLastInsert(with replacement: String) async -> Bool {
        guard let last = lastInsert, !last.text.isEmpty, last.text.count <= 600,
              Date().timeIntervalSince(last.date) < 300, AXIsProcessTrusted() else { return false }
        if let pid = last.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let newText = replacement + (last.text.hasSuffix(" ") ? " " : "")
        TextInserter.deleteBackward(count: last.text.count)
        TextInserter.typeLive(newText)
        lastInsert = (text: newText, date: Date(), pid: last.pid)
        return true
    }

    /// The redo shortcut: erase what the last dictation inserted, re-run it through its AI
    /// pipeline, and insert the fresh result in its place. One key, whole loop.
    func redoLastInsertion() {
        guard canRegenerateLast else {
            announce("Nothing recent to redo")
            return
        }
        regenerateLast()
    }

    var canRegenerateLast: Bool {
        guard let last = history.records.first else { return false }
        return regenerationMode(for: last) != nil
    }

    // MARK: Preview (mode Test Bench)

    /// Run a mode against sample text exactly as a real dictation would: vocabulary
    /// substitutions, then the AI transform when the mode uses AI and Apple Intelligence is
    /// available. Lets the mode editor show what a mode produces before you use it.
    func preview(_ text: String, mode: Mode) async throws -> String {
        var out = vocabulary.apply(to: text, dictionaryIDs: mode.dictionaryIDs)
        if mode.usesAI, cleanupAvailable(for: mode), !out.isEmpty {
            let cleaned = await runCleanup(out, mode: mode, context: TransformContext(userName: promptUserName(for: mode)))
            if cleaned != out {
                out = vocabulary.apply(to: cleaned, dictionaryIDs: mode.dictionaryIDs)
            }
        }
        out = commands.apply(to: out)
        if mode.trimTrailingNewlines ?? settings.trimTrailingNewlines { out = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    /// One-word AI classification for Auto mode's ambiguous cases. Any failure or absence of an
    /// engine degrades safely to Clean Up.
    private func classifyForAutoMode(_ text: String) async -> AutoContext.Verdict {
        let probe = Mode(name: "Classifier", usesAI: true, instructions: AutoContext.aiPrompt)
        guard let transformer = cleanupTransformer(for: probe) else { return .cleanup }
        let sample = String(text.prefix(400))
        guard let reply = try? await transformer.transform(sample, mode: probe, context: TransformContext()) else {
            return .cleanup
        }
        return AutoContext.verdict(fromAI: reply)
    }

    // MARK: Cleanup engine routing

    /// The cleanup transformer to use: a downloaded GGUF (per-mode override, else the global
    /// selection) when its file is on disk; otherwise Apple's Foundation model; nil if neither
    /// is usable (caller inserts the raw transcript).
    /// The user's name is AMMUNITION for signing - small local models sign with any name
    /// they're given regardless of instructions (the recurring "- R" on plain cleanups).
    /// So the prompt only ever CONTAINS the name when the mode's job includes a sign-off:
    /// the Email mode, or custom instructions that mention signing. Everywhere else the
    /// no-name prompt branch applies, which explicitly forbids invented signatures.
    private func promptUserName(for mode: Mode) -> String? {
        // Match explicit signing LANGUAGE only. Loose words backfire: Clean Up's instructions
        // mention "email addresses", and matching on "email" handed the name to Phi, which
        // promptly signed a plain cleanup with it.
        let signingWords = ["sign-off", "signoff", "signature", "sign as", "sign the", "sign it"]
        let wantsSignature = mode.id == BuiltInModes.email.id
            || signingWords.contains { mode.instructions.localizedCaseInsensitiveContains($0) }
        return wantsSignature ? settings.userName : nil
    }

    private func cleanupTransformer(for mode: Mode) -> (any TextTransformer)? {
        // GGUF cleanup is BACK ON: the old segfault was never a llama/ggml version mismatch - the
        // package simply never defined GGML_USE_CPU, so ggml's backend registry had no CPU device
        // and llama's loader null-dereffed in make_cpu_buft_list. Fixed in Vendor Package.swift.
        let modelID = mode.languageModelID ?? settings.selectedLanguageModelID
        if modelID != "apple", let model = models.model(id: modelID), model.runtime == .llamaCpp,
           let url = models.downloads.localURL(for: model) {
            return LlamaTransformer(modelURL: url)
        }
        if FoundationModelsTransformer.isAvailable { return aiTransformer }
        // Apple Intelligence unavailable or switched off: fall back to the bundled GGUF (Phi-3.5
        // ships inside the app) so AI cleanup works on EVERY Mac with zero Apple dependency.
        if let fallback = models.languageModels.first(where: { $0.runtime == .llamaCpp && models.downloads.localURL(for: $0) != nil }),
           let url = models.downloads.localURL(for: fallback) {
            return LlamaTransformer(modelURL: url)
        }
        return nil
    }

    /// Whether ANY cleanup engine can run for this mode right now.
    func cleanupAvailable(for mode: Mode) -> Bool { cleanupTransformer(for: mode) != nil }

    /// Energy settings: after the configured idle time, drop the cached Whisper context and
    /// Phi model so the app goes back to a tiny footprint. Any new session cancels the timer.
    /// 0 seconds = unload immediately after each dictation; -1 = keep loaded until quit.
    private func scheduleModelCooldown() {
        modelCooldownTask?.cancel()
        let seconds = settings.modelCooldownSeconds
        guard seconds >= 0 else { return }
        modelCooldownTask = Task { @MainActor [weak self] in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            WhisperEngine.evictCachedContext()
            LlamaEngine.evictCachedModel()
            yapdiag("energy: models unloaded after \(seconds)s idle")
        }
    }

    /// One cleanup call, whichever engine is selected. Falls back to the input on empty/failed.
    /// True when the model ECHOED reference material (the selected text or clipboard fed in as
    /// context) instead of writing the user's words: nearly all of the output's words come from
    /// the reference. Reference is context, never content - an echo must never be pasted.
    private static func echoesReference(_ output: String, _ reference: String?) -> Bool {
        guard let ref = reference, ref.count > 80 else { return false }
        let outWords = output.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard outWords.count > 15 else { return false }
        let refSet = Set(ref.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let overlap = outWords.filter { refSet.contains($0) }.count
        return Double(overlap) / Double(outWords.count) > 0.85
    }

    /// Human-readable name of the engine cleanupTransformer(for:) would pick - recorded into
    /// history so a bad output can be blamed on the right model. Mirrors that function's order.
    private func cleanupEngineName(for mode: Mode) -> String? {
        let modelID = mode.languageModelID ?? settings.selectedLanguageModelID
        if modelID != "apple", let model = models.model(id: modelID), model.runtime == .llamaCpp,
           models.downloads.localURL(for: model) != nil {
            return model.displayName
        }
        if FoundationModelsTransformer.isAvailable { return "Apple Intelligence" }
        if let fallback = models.languageModels.first(where: { $0.runtime == .llamaCpp && models.downloads.localURL(for: $0) != nil }) {
            return fallback.displayName
        }
        return nil
    }

    /// Backstop for the recurring phantom "- R": when no signature was authorized for this
    /// pass (context.userName is nil), a trailing line that is JUST the user's name (with an
    /// optional dash) was invented by the model - drop it. Only fires when the raw dictation
    /// didn't itself end with the name.
    private func stripUnauthorizedSignoff(_ cleaned: String, raw: String) -> String {
        let name = settings.userName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return cleaned }
        var lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty else { return cleaned }
        let stripped = last.drop(while: { "-\u{2013}\u{2014} ".contains($0) })
        guard stripped.caseInsensitiveCompare(name) == .orderedSame else { return cleaned }
        let rawTail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTail.lowercased().hasSuffix(name.lowercased()) else { return cleaned }
        lines.removeLast()
        while let tail = lines.last, tail.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        yapdiag("cleanup: stripped unauthorized sign-off \u{201C}\(last)\u{201D}")
        return lines.joined(separator: "\n")
    }

    private func runCleanup(_ text: String, mode: Mode, context: TransformContext) async -> String {
        guard let transformer = cleanupTransformer(for: mode) else { return text }
        // THE choke point for the name: whatever context a caller built (the live-session one
        // includes the name unconditionally), the prompt only carries it if this mode signs.
        var context = context
        context.userName = promptUserName(for: mode)
        sessionCleanupModel = cleanupEngineName(for: mode)
        guard let cleaned = try? await transformer.transform(text, mode: mode, context: context),
              !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        // If the model answered/refused instead of cleaning, DISCARD it and keep the raw words -
        // never insert an assistant reply into the user's document.
        if FoundationModelsTransformer.looksLikeAssistantResponse(cleaned) {
            yapdiag("cleanup: discarded assistant-style output, using raw transcript")
            return text
        }
        // Runaway-hallucination guard: cleanup fixes and reformats, it never MASSIVELY expands.
        // If the output balloons far past the input (e.g. a 15-word note became a 250-word "guide")
        // the model fabricated content - keep the raw transcript instead.
        let inWords = text.split(whereSeparator: \.isWhitespace).count
        let outWords = cleaned.split(whereSeparator: \.isWhitespace).count
        if inWords > 0, outWords > max(inWords * 3, inWords + 40) {
            yapdiag("cleanup: discarded over-expanded output (\(inWords)->\(outWords) words)")
            return text
        }
        // Reference-echo guard: output that is essentially the SELECTION or CLIPBOARD came from
        // the context, not the dictation - keep the user's own words instead.
        if Self.echoesReference(cleaned, context.selectedText) || Self.echoesReference(cleaned, context.clipboard) {
            yapdiag("cleanup: discarded reference-echo output, using raw transcript")
            return text
        }
        // PARAPHRASE-DRIFT guard (Clean Up only - other modes rewrite by design): cleanup
        // must PRESERVE the user's wording, but a small model on a long input slides into
        // formalizing paraphrase ("make sure to" -> "ensure that", invented connectives).
        // If too few of the raw content words survived, the model rewrote rather than
        // cleaned - keep the user's own words. (Caught live: a 100s dictation came back
        // restyled with fabricated phrasing.)
        if mode.id == BuiltInModes.clean.id {
            let rawWords = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count >= 4 }
            if rawWords.count >= 25 {
                let cleanSet = Set(cleaned.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                let kept = rawWords.filter { cleanSet.contains($0) }.count
                let retention = Double(kept) / Double(rawWords.count)
                if retention < 0.72 {
                    yapdiag("cleanup: discarded paraphrase-drift output (retention \(String(format: "%.2f", retention))), using raw transcript")
                    return text
                }
            }
        }
        if context.userName == nil {
            return stripUnauthorizedSignoff(cleaned, raw: text)
        }
        return cleaned
    }

    // MARK: Transcribe a file

#if DEBUG
    /// Test-harness transcription: the full real pipeline (media decode -> speech
    /// enhancer -> whisper, same engine selection as a live session) with ZERO side
    /// effects - no clipboard, no insertion, no history, no UI phases.
    func debugTranscribeQuiet(_ url: URL) async throws -> String {
        let mode = activeMode
        let engine = makeEngine(for: mode)
        (engine as? WhisperEngine)?.livePreview = false
        try await engine.beginSession(localeIdentifier: mode.localeIdentifier ?? settings.localeIdentifier) { _ in }
        try await MediaAudioDecoder.decode(url: url) { buffer in engine.append(buffer) }
        return try await engine.endSession()
    }
#endif

    /// Transcribe an existing audio file with the active mode, exactly like superwhisper's
    /// "Transcribe file". Result goes to the clipboard and History (not typed, since there's no
    /// live cursor context). Runs off any live dictation.
    func transcribeFile(_ url: URL, insertInto target: NSRunningApplication? = nil) {
        guard phase == .idle || isErrorPhase else { return }
        lastError = nil
        errorResetTask?.cancel()
        let mode = activeMode
        let locale = mode.localeIdentifier ?? settings.localeIdentifier
        setPhase(.transcribing)
        Task {
            do {
                let engine = makeEngine(for: mode)
                (engine as? WhisperEngine)?.livePreview = false   // no UI wants partials here
                try await engine.beginSession(localeIdentifier: locale) { _ in }
                // Decode the audio track of ANY media file - audio or video, any extension - so
                // an .mp4, a .mov, or a renamed clip all work, not just AVAudioFile's formats.
                try await MediaAudioDecoder.decode(url: url) { buffer in engine.append(buffer) }
                let raw = try await engine.endSession()
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setError("No speech found in \(url.lastPathComponent).")
                    return
                }
                setPhase(.transforming)
                let text = await polish(raw, mode: mode, context: TransformContext(userName: promptUserName(for: mode)))
                // Always keep it on the clipboard as a reliable fallback, then - if we know which
                // app was active when the file was picked - type it in at the cursor, just like a
                // live dictation, instead of making the user paste it themselves.
                TextInserter.setClipboard(text)
                var inserted = false
                if settings.autoInsert, let target, !text.isEmpty,
                   target.bundleIdentifier != Bundle.main.bundleIdentifier, !target.isTerminated {
                    setPhase(.inserting)
                    if await activate(target) {
                        TextInserter.deliver(text, target: .insertAtCursor,
                                             method: mode.insertionMethod ?? settings.insertionMethod,
                                             restoreClipboard: settings.restoreClipboard)
                        inserted = true
                    }
                }
                if settings.saveHistory {
                    history.add(DictationRecord(date: Date(), rawText: raw, finalText: text,
                        modeName: mode.name, modeID: mode.id, durationSeconds: 0,
                        appName: url.lastPathComponent, appBundleID: nil, localeIdentifier: locale,
                        usedAI: mode.usesAI && FoundationModelsTransformer.isAvailable, audioFileName: nil))
                }
                announce(inserted ? "Transcribed \(url.lastPathComponent). Inserted."
                                  : "Transcribed \(url.lastPathComponent). Copied to clipboard.")
                setPhase(.idle)
            } catch {
                setError("Couldn't transcribe \(url.lastPathComponent). \(Self.message(for: error))")
            }
        }
    }

    /// The shared text pipeline: dictionaries, then AI cleanup (falling back to the transcript
    /// if it's empty), then commands, then trimming. Used by file transcription.
    private func polish(_ raw: String, mode: Mode, context: TransformContext) async -> String {
        var text = vocabulary.apply(to: raw, dictionaryIDs: mode.dictionaryIDs)
        if mode.usesAI, cleanupAvailable(for: mode), !text.isEmpty {
            let cleaned = await runCleanup(text, mode: mode, context: context)
            if cleaned != text {
                text = vocabulary.apply(to: cleaned, dictionaryIDs: mode.dictionaryIDs)
            }
        }
        text = commands.apply(to: text)
        if mode.trimTrailingNewlines ?? settings.trimTrailingNewlines {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: AI actions (on selected text)

    /// Run a one-shot AI action's instructions over arbitrary text (e.g. the current selection).
    func applyAIAction(instructions: String, to text: String, modelID: String? = nil) async throws -> String {
        var action = Mode(name: "Action", usesAI: true, instructions: instructions)
        if let modelID { action.languageModelID = modelID }
        guard let transformer = cleanupTransformer(for: action) else { return text }
        let out = try await transformer.transform(text, mode: action, context: TransformContext(userName: promptUserName(for: action)))
        // Same guards as the dictation pipeline: never deliver an assistant-style reply or a
        // runaway expansion as if it were the transformed text.
        if FoundationModelsTransformer.looksLikeAssistantResponse(out) {
            yapdiag("aiAction: discarded assistant-style output")
            return text
        }
        let inWords = text.split(whereSeparator: \.isWhitespace).count
        let outWords = out.split(whereSeparator: \.isWhitespace).count
        if inWords > 0, outWords > max(inWords * 3, inWords + 60) {
            yapdiag("aiAction: discarded over-expanded output (\(inWords)->\(outWords))")
            return text
        }
        return out
    }

    // MARK: Utility hub

    /// Dictate into the in-app scratchpad: records exactly like a normal dictation (live waveform,
    /// live preview, chosen mode's cleanup) but the finished text is handed to `sink` for the view
    /// to display, instead of being typed into another app. The floating panel is suppressed.
    func startScratchpad(sink: @escaping (String) -> Void) {
        guard phase == .idle || isErrorPhase else { return }
        scratchpadSink = sink
        isScratchpadSession = true
        start()
    }

    /// Transcribe a media file and RETURN the finished text (dictionaries + AI + commands) rather
    /// than inserting it. Used by the Utility hub, which shows the result in-app. Runs on its own
    /// engine so it doesn't disturb the live-dictation state.
    func transcribe(fileURL url: URL, mode: Mode) async throws -> String {
        let locale = mode.localeIdentifier ?? settings.localeIdentifier
        let engine = makeEngine(for: mode)
        try await engine.beginSession(localeIdentifier: locale) { _ in }
        try await MediaAudioDecoder.decode(url: url) { engine.append($0) }
        let raw = try await engine.endSession()
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.unavailable("No speech was found in \(url.lastPathComponent).")
        }
        return await polish(raw, mode: mode, context: TransformContext(userName: promptUserName(for: mode)))
    }

    /// Speak a short status to VoiceOver / used to surface selection-editing feedback.
    func announceStatus(_ message: String) { announce(message) }

    /// A user-VISIBLE transient status: shows in the panel and menu bar as a brief error-style
    /// flash (auto-clears), and is spoken to VoiceOver. For paths whose failures used to be
    /// silent to sighted users (selection capture, AI actions).
    func flashStatus(_ message: String) {
        yapdiag("status: \(message)")
        setError(message)
    }

    // MARK: VoiceOver announcements

    /// Speak dictation state to VoiceOver users. The floating panel is purely visual, so
    /// without these the whole capture-transcribe-insert cycle is silent to a blind user.
    /// Posted from the controller so they fire even when no app window is focused.
    /// No-ops when VoiceOver is off.
    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    /// Drive the menu bar icon's live state with a single low-rate timer (so the icon costs almost
    /// nothing): a red bubble blink while recording, a spinner-above-the-head while processing, and
    /// nothing when idle.
    private func updateMenuAnimation(for phase: Phase) {
        menuPulseTimer?.cancel()
        menuPulseTimer = nil
        menuPulseLevel = 0
        switch phase {
        case .recording:
            // Smooth breathing pulse: a continuous level (0..1) on a ~1.9s sine, updated at a
            // modest 12.5fps only while recording - no hard light/dark flash.
            menuPulseTimer = Task { @MainActor [weak self] in
                // ~30fps while recording: smooth enough for the color gradient AND the bubble's
                // bouncing dots (plain AppKit image swaps; nothing runs when idle).
                var t = 0.0
                while !Task.isCancelled {
                    guard let self, self.isRecording else { return }
                    self.menuPulseLevel = 0.5 - 0.5 * cos(t * 2 * .pi / 1.9)
                    self.menuClock = t
                    self.onMenuStateChanged?()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                    t += 0.033
                }
            }
        case .transcribing, .transforming:
            menuSpin = 0
            menuPulseTimer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 70_000_000)   // ~14 fps, only while processing
                    guard let self else { return }
                    switch self.phase { case .transcribing, .transforming: break; default: return }
                    self.menuSpin += 0.055
                    self.onMenuStateChanged?()
                }
            }
        default:
            menuSpin = 0
        }
        onMenuStateChanged?()
    }

    private func announceTransition(from old: Phase, to new: Phase) {
        guard old != new else { return }
        updateMenuAnimation(for: new)
        if new == .idle { onDidBecomeIdle?() }
        switch new {
        case .recording: announce("Listening")
        case .transcribing: announce("Transcribing")
        case .transforming: announce("Cleaning up")
        case .error(let message): announce("Dictation error. \(message)")
        case .inserting, .idle:
            break   // completion and cancel are announced with precise wording at the call site
        }
    }

    private func setError(_ message: String) {
        lastError = message
        let ud = UserDefaults.standard
        ud.set(ud.integer(forKey: "diag.errorCount") + 1, forKey: "diag.errorCount")
        ud.set(Date().timeIntervalSince1970, forKey: "diag.lastErrorAt")
        isScratchpadSession = false
        setPhase(.error(message))
        announce(message)
        if settings.playSounds { Sound.playError() }
        errorResetTask?.cancel()
        errorResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.isErrorPhase else { return }
            self.setPhase(.idle)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
