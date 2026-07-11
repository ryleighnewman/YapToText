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
        var userFacingLabel: String {
            switch self {
            case .idle: return "Ready"
            case .recording: return "Listening…"
            case .transcribing: return "Transcribing…"
            case .transforming: return "Cleaning up…"
            case .inserting: return "Inserting…"
            case .error(let message): return message
            }
        }
    }

    private(set) var phase: Phase = .idle {
        didSet { announceTransition(from: oldValue, to: phase) }
    }
    private(set) var liveText: String = ""
    private(set) var level: Float = 0
    /// Rolling window of real microphone levels (one entry per audio buffer), oldest first.
    /// This is what the panel's waveform draws, so it moves with actual input, not a timer.
    private(set) var levelHistory: [Float] = []
    static let levelHistoryLength = 48
    private(set) var activeMode: Mode
    private(set) var lastError: String?
    /// Extra status shown while .transforming when the cleanup model is doing its one-time load,
    /// so a slow first cleanup reads as loading instead of looking stuck (users were cancelling).
    private(set) var transformingDetail: String?
    /// True while recording is held (phase stays `.recording`, but audio is dropped).
    private(set) var isPaused = false
    /// Auto mode: a mid-dictation digit pick suspends auto routing for THIS session only.
    private var sessionAutoSuspended = false
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
        if new != .transforming { transformingDetail = nil }
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
        yapdiag("toggle: isRecording=\(isRecording) phase=\(phase.userFacingLabel)")
        if isRecording {
            stop()
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
        recorder.onSpectrum = { [weak self] bands in
            self?.visualData.spectrum = bands
        }
        let locale = mode.localeIdentifier ?? settings.localeIdentifier
        let engine = makeEngine(for: mode)
        self.engine = engine

        setLiveText("")
        level = 0
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        setPhase(.recording)
        sessionStart = Date()
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
        if settings.showRecordingPanel, scratchpadSink == nil { onPresentPanel?() }

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
            try await engine.beginSession(localeIdentifier: locale) { [weak self] update in
                Task { @MainActor in self?.setLiveText(update.combined) }
            }
            // cancel() bumped sessionID while beginSession was awaiting: this session is dead.
            // Without this check the recorder would start for a cancelled session and run
            // orphaned forever (confirmed via the live diagnostic trail before a segfault).
            guard sid == sessionID else {
                yapdiag("beginRecording: session cancelled during prologue, aborting")
                startInFlight = false
                await engine.cancel()
                if self.engine === engine { self.engine = nil }
                return
            }
            yapdiag("beginRecording: beginSession OK, starting recorder")
            try recorder.start(onBuffer: { [weak engine] buffer in
                engine?.append(buffer)
            }, onLevel: { [weak self] rawLevel in
                guard let self, !self.isPaused else { return }   // ignore any late tap that lands after pause()
                // Publish-time NaN/Inf guard: `level` is @Observable state read by several views;
                // a non-finite value here becomes a bogus CGFloat in the view graph.
                let level = rawLevel.isFinite ? min(max(rawLevel, 0), 1) : 0
                self.level = level
                self.visualData.level = level
                self.levelHistory.append(level)
                if self.levelHistory.count > Self.levelHistoryLength { self.levelHistory.removeFirst() }
                if level > 0.12 { self.lastVoiceAt = Date() }
            }, writeTo: audioURL)
            startAutoStopMonitor()
            startInFlight = false
            onRecordingDidStart?()
            // Recording is live and the file is filling: drop the crash-recovery marker so a
            // sudden quit can be recovered on the next launch.
            writeRecoveryMarker(RecoveryMarker(audioFileName: audioName, startedAt: sessionStart,
                                               modeID: sessionMode.id, localeIdentifier: locale))
            yapdiag("beginRecording: ARMED (recorder running=\(recorder.isRunning))")
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
        if isPaused { pausedAccumulated += Date().timeIntervalSince(pauseStartedAt) }
        isPaused = false
        onRecordingDidStop?()
        setPhase(.transcribing)

        Task {
            do {
                let raw = try await engine.endSession()
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
                        transformingDetail = "Reading the room…"
                        verdict = await classifyForAutoMode(source)
                        transformingDetail = nil
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
                    yapdiag("auto: verdict=\(verdict.rawValue) mode=\(chosen.name) extras=\(extras.count) replyCtx=\(context.selectedText?.count ?? 0)")
                    sessionMode = chosen
                }

                var text = vocabulary.apply(to: source, dictionaryIDs: sessionMode.dictionaryIDs)

                if sessionMode.usesAI, cleanupAvailable(for: sessionMode), !text.isEmpty {
                    // Cold GGUF load: tell the user what the wait is, so they don't cancel.
                    let cleanupID = sessionMode.languageModelID ?? settings.selectedLanguageModelID
                    if cleanupID != "apple", let m = models.model(id: cleanupID), m.runtime == .llamaCpp,
                       let url = models.downloads.localURL(for: m), !LlamaEngine.isCached(modelPath: url.path) {
                        transformingDetail = "Loading the AI model (first time only)…"
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

    /// Re-activate the app captured at record-start and wait (up to ~500ms) until it is actually
    /// frontmost, so a paste can't miss. No-op if we never had a target or it's already frontmost.
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

    private func finish(sid: Int, raw: String, final text: String) async {
        yapdiag("finish: text.len=\(text.count) autoInsert=\(settings.autoInsert)")
        guard sid == sessionID else { return }   // cancelled: do not insert or record
        setPhase(.inserting)
        if let sink = scratchpadSink {
            // In-app scratchpad (Utility hub): hand the text to the view; never type into another app.
            scratchpadSink = nil
            sink(text)
            announce(text.isEmpty ? "Nothing heard" : "Ready")
        } else {
            let target: OutputTarget = (settings.autoInsert && !sessionStartedFromSelf)
                ? sessionMode.outputTarget : .clipboardOnly
            if !text.isEmpty {
                // Trailing space so back-to-back dictations don't run together. Only when typing
                // at the cursor, and only if the text doesn't already end in whitespace.
                var delivered = text
                if settings.appendSpaceAfterInsert, target == .insertAtCursor,
                   let last = delivered.last, !last.isWhitespace {
                    delivered += " "
                }
                // Make sure the app the user dictated into is frontmost before we paste, so the
                // text can't land in a window they clicked mid-transcription (or in YapToText).
                var deliveryTarget = target
                if target != .clipboardOnly {
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
                yapdiag("finish: delivering \(delivered.count) chars target=\(deliveryTarget) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") method=\(sessionMode.insertionMethod?.rawValue ?? settings.insertionMethod.rawValue)")
                TextInserter.deliver(delivered, target: deliveryTarget,
                                     method: sessionMode.insertionMethod ?? settings.insertionMethod,
                                     restoreClipboard: settings.restoreClipboard)
                if deliveryTarget == .clipboardOnly, target != .clipboardOnly {
                    announce("Copied to clipboard")
                }
            }
            if text.isEmpty {
                announce("Nothing heard")
            } else {
                announce(target == .clipboardOnly ? "Copied to clipboard" : "Inserted")
            }
        }
        clearRecoveryMarker()   // clean end: this session no longer needs crash recovery
        if settings.saveHistory, !text.isEmpty {
            history.add(DictationRecord(
                date: sessionStart,
                rawText: raw,
                finalText: text,
                modeName: sessionMode.name,
                modeID: sessionMode.id,
                durationSeconds: max(0, Date().timeIntervalSince(sessionStart) - pausedAccumulated),
                appName: context.appName,
                appBundleID: sessionBundleID,
                localeIdentifier: sessionMode.localeIdentifier ?? settings.localeIdentifier,
                usedAI: sessionMode.usesAI && FoundationModelsTransformer.isAvailable,
                audioFileName: keepSessionAudio ? sessionAudioFileName : nil))
            if !keepSessionAudio { AudioStore.delete(sessionAudioFileName) }   // recovery-only file
        } else {
            AudioStore.delete(sessionAudioFileName)   // no record kept: don't orphan the audio
        }
        sessionAudioFileName = nil
        if settings.playSounds { Sound.playStop() }
        engine = nil
        isFinishing = false
        onDismissPanel?()   // unconditional: if the setting was toggled off mid-session, the panel must still go away
        if text.isEmpty {
            // An empty transcript used to end SILENTLY, which reads as "the app didn't paste".
            // Say so, visibly (menu bar + panel error state, auto-clears).
            setError("Didn't catch that. Nothing was transcribed.")
        } else {
            setPhase(.idle)
        }
        setLiveText("")
        level = 0
        sessionTargetApp = nil
        isScratchpadSession = false
        scheduleModelCooldown()
    }

    func cancel() {
        guard isBusy || startInFlight else { return }
        sessionID += 1            // invalidate any in-flight finishing Task
        startInFlight = false
        stopRequested = false
        errorResetTask?.cancel()
        stopAutoStopMonitor()
        recorder.stop()
        isPaused = false
        scratchpadSink = nil
        isScratchpadSession = false
        onRecordingDidStop?()
        clearRecoveryMarker()   // deliberate cancel: the user chose to discard, nothing to recover
        scheduleModelCooldown()
        AudioStore.delete(sessionAudioFileName)
        sessionAudioFileName = nil
        sessionTargetApp = nil
        let engine = self.engine
        self.engine = nil
        isFinishing = false
        Task { await engine?.cancel() }
        onDismissPanel?()   // unconditional: if the setting was toggled off mid-session, the panel must still go away
        if settings.playSounds { Sound.playError() }
        setPhase(.idle)
        setLiveText("")
        level = 0
        announce("Cancelled")
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

    private func makeEngine(for mode: Mode) -> TranscriptionEngine {
        let modelID = mode.speechModelID ?? settings.selectedSpeechModelID
        if modelID != "apple", let model = models.model(id: modelID), model.runtime != .apple {
            // Only hand off to whisper when the file is actually on disk; otherwise fall back
            // to Apple Speech so dictation always works while a default model downloads.
            if let url = models.downloads.localURL(for: model) {
                let engine = WhisperEngine(modelURL: url, modelName: model.displayName)
                engine.livePreview = settings.livePreviewEnabled
                return engine
            }
            return AppleSpeechEngine()
        }
        return AppleSpeechEngine()
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
    func prewarmAudioInput() { recorder.prewarmRoute() }

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
                let cleaned = await runCleanup(record.rawText, mode: mode, context: TransformContext(userName: settings.userName))
                var text = cleaned
                text = vocabulary.apply(to: text, dictionaryIDs: mode.dictionaryIDs)
                text = commands.apply(to: text)
                if mode.trimTrailingNewlines ?? settings.trimTrailingNewlines { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                var updated = record
                updated.finalText = text
                updated.usedAI = true
                history.update(updated)
                TextInserter.setClipboard(text)
                announce("Regenerated. Copied to clipboard.")
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
            let cleaned = await runCleanup(out, mode: mode, context: TransformContext(userName: settings.userName))
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

    private func runCleanup(_ text: String, mode: Mode, context: TransformContext) async -> String {
        guard let transformer = cleanupTransformer(for: mode) else { return text }
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
        return cleaned
    }

    // MARK: Transcribe a file

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
                let text = await polish(raw, mode: mode, context: TransformContext(userName: settings.userName))
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
    func applyAIAction(instructions: String, to text: String) async throws -> String {
        let action = Mode(name: "Action", usesAI: true, instructions: instructions)
        guard let transformer = cleanupTransformer(for: action) else { return text }
        let out = try await transformer.transform(text, mode: action, context: TransformContext(userName: settings.userName))
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
        return await polish(raw, mode: mode, context: TransformContext(userName: settings.userName))
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
        isScratchpadSession = false
        setPhase(.error(message))
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
