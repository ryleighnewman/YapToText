import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let state = AppState()
    private let hotkey = HotkeyManager()
    /// Carbon can't register a modifier-less letter; bare keys go through this event tap instead.
    private let bareKeyTap = BareKeyTap()
    private let pauseHotkey = HotkeyManager()
    private let cycleHotkey = HotkeyManager()
    private let switcherHotkey = HotkeyManager()
    private let historyHotkey = HotkeyManager()
    /// The primary dictation trigger monitor. Recreated whenever the user picks a different
    /// physical key (the historic name stays; it watched Right Command for most of its life).
    private var rightCommand = ModifierKeyMonitor()
    /// The Fn/Globe key (keyCode 63) as an alternate trigger. Works when macOS's own
    /// "Press Globe key to" action is set to Do Nothing; otherwise both fire.
    private let fnKey = ModifierKeyMonitor(keyCode: 63, flag: .function)
    // Quick Edit: hold Right Option over a selection, speak an instruction, release to apply.
    private var quickEditKey = ModifierKeyMonitor(keyCode: 61, flag: .option)
    private var quickEditKeyHeld = false
    /// Cancel window: true while a released quick-edit command is being applied by the AI.
    /// A DOUBLE TAP of the key during this window aborts the edit before it can paste.
    private var quickEditApplying = false
    private var quickEditCancelled = false
    /// Bumped for every quick-edit apply; stale in-flight tasks compare against it so a
    /// cancelled session's AI result can never paste after a new session reset the flags.
    private var quickEditGeneration = 0
    private var lastQuickEditTapAt: Date?
    /// Number keys 1-9 pick the post-processing mode while dictating (armed only then).
    private let digitTap = DigitKeyTap()
    /// Registered only while dictating (opt-in): a bare Esc that cancels on a quick double tap.
    private let cancelKey = HotkeyManager()
    private var lastEscapeAt: Date?
    private var panel: RecordingPanel?
    /// The last non-YapToText app the user was in, so "Transcribe File" and dictations started
    /// from our own window can type the result back into it.
    private(set) var lastActiveOtherApp: NSRunningApplication?
    /// When the mic route was last warmed, so routine foreground transitions (dock click, cmd-tab,
    /// opening Settings) don't re-power the mic hardware every time. Cleared when a dictation runs,
    /// since starting one tears the warm engine down and the route can then genuinely cool.
    private var lastPrewarmAt: Date?
    /// Global activity watcher: any keystroke/click/scroll anywhere means the user is at
    /// the machine and might dictate next - keep the mic route hot (throttled). Requires
    /// Accessibility, which the dictation key already needs.
    private var activityMonitor: Any?
    private var lastActivityWarm = Date.distantPast
    func installActivityPrewarm() {
        guard activityMonitor == nil else { return }
        activityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] _ in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastActivityWarm) > 8 else { return }
            self.lastActivityWarm = Date()
            guard self.state.permissions.microphoneGranted,
                  !self.state.controller.isRecording, !self.state.controller.isBusy else { return }
            // The user is at the keyboard: make sure the SPEECH MODEL is resident too, so a
            // cooldown eviction never turns into a multi-second stall on the next stop.
            // The MICROPHONE is deliberately not touched here: with keep-warm off (the
            // default) the mic opens when a dictation starts and lets go when it ends.
            self.state.controller.warmSpeechModel()
        }
    }

    private func prewarmMicIfStale() {
        guard state.permissions.microphoneGranted else { return }
        if let last = lastPrewarmAt, Date().timeIntervalSince(last) < 45 { return }
        lastPrewarmAt = Date()
        state.controller.prewarmAudioInput()
    }
    /// Fires on system memory pressure so the cached speech/cleanup models can be dropped.
    private let memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CRASH BREADCRUMBS for the diagnostics report (the sandbox cannot read macOS's
        // own crash logs, so the app keeps its own count): if the previous run never
        // wrote its clean-exit marker, it died uncleanly - crash, force-quit, or power.
        let ud = UserDefaults.standard
        if ud.object(forKey: "diag.cleanExit") != nil, ud.bool(forKey: "diag.cleanExit") == false {
            ud.set(ud.integer(forKey: "diag.uncleanExits") + 1, forKey: "diag.uncleanExits")
            ud.set(Date().timeIntervalSince1970, forKey: "diag.lastUncleanExit")
        }
        ud.set(false, forKey: "diag.cleanExit")
        AppDelegate.shared = self
        // MODEL MIGRATION (1.2.1): the bundled speech model changed from the full Turbo
        // to Turbo Q5. Most users never downloaded the full model - it lived only inside
        // the old app bundle - so after this update their selection points at a file that
        // no longer exists anywhere. Detect exactly that case and move them to Q5 (the
        // new bundled model, measured near-identical on real dictations). A user who
        // DOWNLOADED the full model keeps it: the file exists, nothing changes.
        if state.settings.selectedSpeechModelID == "whisper-large-v3-turbo",
           let fp16 = state.models.model(id: "whisper-large-v3-turbo"),
           state.models.downloads.localURL(for: fp16) == nil {
            state.settings.selectedSpeechModelID = "whisper-large-v3-turbo-q5"
            yapdiag("migration: full-turbo selection had no local file; moved to bundled Q5")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.state.controller.flashStatus("Speech model updated to the faster Turbo Q5. The full model is still available on the AI Models page.")
            }
        }
        // DEFAULT CHANGED (1.3): users on another speech model get one clear offer to
        // move to the new default, with a single click. Never repeated, never forced -
        // "Keep" is a full answer, and the AI Models page always has both.
        if !state.settings.q5SwitchOfferShown,
           state.settings.selectedSpeechModelID != "whisper-large-v3-turbo-q5" {
            state.settings.q5SwitchOfferShown = true
            let current = state.models.model(id: state.settings.selectedSpeechModelID)?.displayName
                ?? (state.settings.selectedSpeechModelID == "apple" ? "Apple Speech" : "your current model")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "A faster default model"
                alert.informativeText = "YapToText's default speech model is now Whisper Large v3 Turbo Q5: verified on hundreds of real dictations to hear as well as the full model, while loading three times faster and using a third of the memory. You're currently using \(current). Switch anytime on the AI Models page."
                alert.addButton(withTitle: "Switch to Turbo Q5")
                alert.addButton(withTitle: "Keep \(current)")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.state.settings.selectedSpeechModelID = "whisper-large-v3-turbo-q5"
                    self.state.controller.flashStatus("Speech model switched to Whisper Large v3 Turbo Q5")
                }
            }
        }
        // Build the Quick Edit popup (hidden) now, so the first key press doesn't pay
        // NSPanel + hosting-view construction on top of the selection grab.
        QuickEditWindow.shared.prewarm(controller: state.controller)
        // Seed with the app the user was in BEFORE launching us, so a dictation started right
        // away from our window has somewhere sensible to paste.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveOtherApp = front
        }

        panel = RecordingPanel(controller: state.controller, settings: state.settings)
        state.controller.onPresentPanel = { [weak self] in self?.panel?.show() }
        state.controller.onDismissPanel = { [weak self] in self?.panel?.hide() }
        state.controller.onRecordingDidStart = { [weak self] in
            guard let self else { return }
            self.lastPrewarmAt = nil   // a dictation tears down the warm engine; allow a re-warm next foreground
            self.armCancelKey()
            self.digitTap.heldModifiers = self.pushToTalkHeldModifiers()
            // Digit switching is optional: off means number keys type normally mid-dictation
            // (some people dictate numbers by keyboard). Space-pause rides the same tap, so
            // the whole tap stays off when the feature is off.
            if self.state.settings.digitModeSwitching { self.digitTap.start() }
        }
        state.controller.onRecordingDidStop = { [weak self] in
            self?.digitTap.stop()
            // Keep Escape live through transcription/cleanup so a stuck run can always be cancelled.
            self?.armCancelKey(force: true)
        }
        state.controller.onDidBecomeIdle = { [weak self] in self?.disarmCancelKey() }
        state.controller.onMenuStateChanged = { [weak self] in self?.refreshStatusIcon() }
        TextInserter.adaptToSurroundings = { [weak self] in self?.state.settings.adaptToSurroundings ?? true }
        // Key rebinding: while a recorder field is armed, the LIVE triggers stand down so
        // the pressed key reaches the field instead of starting a dictation/quick edit.
        NotificationCenter.default.addObserver(forName: KeyRecorderHub.recordingBegan,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                yapdiag("keyRecorder: triggers standing down for rebind")
                self.rightCommand.stop()
                self.fnKey.stop()
                self.quickEditKey.stop()
                self.primaryCustomTap.stop()
                self.quickEditCustomTap.stop()
            }
        }
        NotificationCenter.default.addObserver(forName: KeyRecorderHub.recordingEnded,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                yapdiag("keyRecorder: triggers restored")
                self.reloadRightCommandTrigger()
                self.reloadQuickEditKey()
            }
        }
        digitTap.onDigit = { [weak self] digit in
            guard let self else { return }
            let modes = self.state.controller.switchableModes
            guard digit >= 1, digit <= modes.count else { return }
            self.state.controller.switchMode(modes[digit - 1])
        }
        // Space bar pauses/resumes the live dictation by default (swallowed by the tap so it never
        // types a stray space into the app you're dictating into).
        digitTap.onSpace = { [weak self] in self?.state.controller.togglePause() }
        cancelKey.onKeyDown = { [weak self] in self?.handleCancelKey() }
        NotificationCenter.default.addObserver(forName: .yapTranscribeFile, object: nil, queue: .main) { [weak self] _ in
            self?.transcribeFileFromPicker()
        }

#if DEBUG
        // Self-test hooks (debug builds only): let a shell script drive the real dictation
        // pipeline - start/stop/cancel exactly as the hotkeys would - so the Liquid Glass crash
        // can be reproduced and bisected autonomously instead of by hand.
        let dnc = DistributedNotificationCenter.default()
        // Marketing/diagnostic navigation: jump the main window to any sidebar destination,
        // and open the menu bar popover, from the shell (debug builds only).
        dnc.addObserver(forName: .init("yap.debug.goto"), object: nil, queue: .main) { note in
            if let raw = note.object as? String {
                NotificationCenter.default.post(name: .yapShowDestination, object: raw)
            }
        }
        dnc.addObserver(forName: .init("yap.debug.switcher"), object: nil, queue: .main) { [weak self] _ in
            self?.showModeSwitcher()
        }
        dnc.addObserver(forName: .init("yap.debug.menupopover"), object: nil, queue: .main) { [weak self] _ in
            self?.toggleMenuPopover(nil)
        }
        dnc.addObserver(forName: .init("yap.debug.dumpBigRaw"), object: nil, queue: .main) { [weak self] _ in
            // Recovery hook: print the longest dictation's RAW transcript to stderr in chunks,
            // so a truncated cleanup can be recovered from outside the TCC-protected container.
            guard let recs = self?.state.history.records,
                  let big = recs.max(by: { $0.durationSeconds < $1.durationSeconds }) else { return }
            yapdiag("BIGRAW dur=\(big.durationSeconds) len=\(big.rawText.count)")
            var rest = Substring(big.rawText)
            var i = 0
            while !rest.isEmpty {
                let chunk = rest.prefix(700)
                yapdiag("BIGRAW[\(i)] \(chunk)")
                rest = rest.dropFirst(700)
                i += 1
            }
        }
        dnc.addObserver(forName: .init("yap.debug.fixTrigger"), object: nil, queue: .main) { [weak self] _ in
            self?.state.settings.rightCommandTrigger = .toggle
            self?.reloadRightCommandTrigger()
            yapdiag("debug: trigger restored to toggle; AX=\(AXIsProcessTrusted())")
        }
        // BATCH TRANSCRIPTION HARNESS: reads /tmp/yap-test-jobs.json ([{"path":...,"ref":...}]),
        // runs each file through the REAL pipeline (decoder -> enhancer -> whisper) with no
        // clipboard, insertion, history, or UI side effects, and writes
        // /tmp/yap-test-results.json ([{"path":...,"ref":...,"text":...,"seconds":...}]).
        dnc.addObserver(forName: .init("yap.debug.cleanupBench"), object: nil, queue: .main) { [weak self] _ in
            guard let self,
                  let phi = self.state.models.languageModels.first(where: { $0.runtime == .llamaCpp }),
                  let modelURL = self.state.models.downloads.localURL(for: phi) else {
                yapdiag("cleanupBench: no local cleanup model"); return
            }
            Task.detached(priority: .userInitiated) {
                struct Res: Codable { var text: String; var plain: String; var spec: String
                                      var plainSeconds: Double; var specSeconds: Double; var identical: Bool }
                let tmpDir = FileManager.default.temporaryDirectory
                guard let data = try? Data(contentsOf: tmpDir.appendingPathComponent("yap-cleanup-jobs.json")),
                      let texts = try? JSONDecoder().decode([String].self, from: data) else {
                    yapdiag("cleanupBench: no readable jobs file"); return
                }
                let system = FoundationModelsTransformer.systemPrompt()
                var results: [Res] = []
                for text in texts {
                    let user = FoundationModelsTransformer.cleanupUserPrompt(for: text, mode: BuiltInModes.clean, context: TransformContext())
                    var t0 = Date()
                    let plain = (try? LlamaEngine.complete(modelPath: modelURL.path, system: system, user: user, maxTokens: 1400)) ?? "<ERR>"
                    let plainS = Date().timeIntervalSince(t0)
                    t0 = Date()
                    let spec = (try? LlamaEngine.complete(modelPath: modelURL.path, system: system, user: user, draft: text, maxTokens: 1400)) ?? "<ERR>"
                    let specS = Date().timeIntervalSince(t0)
                    results.append(Res(text: text, plain: plain, spec: spec,
                                       plainSeconds: plainS, specSeconds: specS, identical: plain == spec))
                    if let out = try? JSONEncoder().encode(results) {
                        try? out.write(to: tmpDir.appendingPathComponent("yap-cleanup-results.json"))
                    }
                }
                yapdiag("cleanupBench: DONE - \(results.count) texts")
            }
        }
        dnc.addObserver(forName: .init("yap.debug.transcribeBatch"), object: nil, queue: .main) { [weak self] _ in
            guard let controller = self?.state.controller else { return }
            Task { @MainActor in
                struct Job: Codable { var path: String; var ref: String? }
                struct Res: Codable { var path: String; var ref: String?; var text: String; var seconds: Double }
                let tmpDir = FileManager.default.temporaryDirectory
                guard let data = try? Data(contentsOf: tmpDir.appendingPathComponent("yap-test-jobs.json")),
                      let jobs = try? JSONDecoder().decode([Job].self, from: data) else {
                    yapdiag("testBatch: no readable jobs file at \(tmpDir.path)"); return
                }
                var results: [Res] = []
                for job in jobs {
                    let start = Date()
                    let text = (try? await controller.debugTranscribeQuiet(URL(fileURLWithPath: job.path))) ?? "<ERROR>"
                    results.append(Res(path: job.path, ref: job.ref, text: text,
                                       seconds: Date().timeIntervalSince(start)))
                    if let out = try? JSONEncoder().encode(results) {
                        try? out.write(to: tmpDir.appendingPathComponent("yap-test-results.json"))
                    }
                }
                yapdiag("testBatch: DONE - \(results.count) files")
            }
        }
        dnc.addObserver(forName: .init("yap.debug.style"), object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.object as? String,
                  let style = PanelStyle(rawValue: raw) else { return }
            self.state.settings.panelStyle = style
            self.refreshPanelSize()
        }
        dnc.addObserver(forName: .init("yap.debug.toggle"), object: nil, queue: .main) { [weak self] _ in
            self?.state.controller.toggle()
        }
        dnc.addObserver(forName: .init("yap.debug.cancel"), object: nil, queue: .main) { [weak self] _ in
            self?.state.controller.cancel()
        }
        dnc.addObserver(forName: .init("yap.debug.freezeMenuIcon"), object: nil, queue: .main) { _ in
            MenuBarIcon.frozenForDiagnostics.toggle()
        }
        dnc.addObserver(forName: .init("yap.debug.freezeWave"), object: nil, queue: .main) { _ in
            WaveformView.frozenForDiagnostics.toggle()
        }
        dnc.addObserver(forName: .init("yap.debug.freezeTypewriter"), object: nil, queue: .main) { _ in
            TypewriterText.frozenForDiagnostics.toggle()
        }
        dnc.addObserver(forName: .init("yap.debug.togglePanel"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.state.settings.showRecordingPanel.toggle()
            yapdiag("debug: showRecordingPanel=\(self.state.settings.showRecordingPanel)")
        }
        dnc.addObserver(forName: .init("yap.debug.closeWindow"), object: nil, queue: .main) { _ in
            for window in NSApp.windows where window.canBecomeMain { window.close() }
            yapdiag("debug: main windows closed")
        }
        dnc.addObserver(forName: .init("yap.debug.ctxprobe"), object: nil, queue: .main) { _ in
            // Context-insertion diagnosis: read the surroundings of whatever is focused
            // RIGHT NOW and log what adapt would do with a canned transcript.
            Task { @MainActor in
                let adapted = await InsertionContext.adapted("Very very much better.")
                yapdiag("ctxprobe: adapted=\(adapted.debugDescription)")
            }
        }
        dnc.addObserver(forName: .init("yap.debug.waveboost"), object: nil, queue: .main) { note in
            // Marketing shots: crank the drawn wave amplitude (object = multiplier string).
            WaveformView.demoAmpBoost = Double((note.object as? String) ?? "1") ?? 1
        }
        dnc.addObserver(forName: .init("yap.debug.qedemo"), object: nil, queue: .main) { [weak self] _ in
            // Walk the Quick Edit popup through its stages for visual verification.
            guard let controller = self?.state.controller else { return }
            QuickEditWindow.shared.showListening(liveTextSource: controller)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                QuickEditWindow.shared.showWorking("make it sound more formal")
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                QuickEditWindow.shared.showResult("Done")
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                QuickEditWindow.shared.showListening(liveTextSource: controller)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                QuickEditWindow.shared.showWorking("delete the second paragraph")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                QuickEditWindow.shared.showResult("Couldn't apply that edit", success: false)
            }
        }
        dnc.addObserver(forName: .init("yap.debug.insertlast"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let text = self.state.history.records.first?.finalText else { return }
            self.insertIntoLastApp(text)
        }
        dnc.addObserver(forName: .init("yap.debug.regenselect"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let mode = self.state.modeStore.allModes.first(where: { $0.usesAI }) else { return }
            self.regenerateSelection(using: mode)
        }
        dnc.addObserver(forName: .init("yap.debug.regenaction"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let action = self.state.actions.actions.first else { return }
            self.regenerateSelection(applying: action)
        }
        dnc.addObserver(forName: .init("yap.debug.phitest"), object: nil, queue: .main) { [weak self] _ in
            // Headless quality check: run one messy sentence through the bundled Phi and log it.
            guard let self,
                  let phi = self.state.models.languageModels.first(where: { $0.runtime == .llamaCpp }),
                  let url = self.state.models.downloads.localURL(for: phi) else {
                yapdiag("phitest: no bundled GGUF found"); return
            }
            let messy = "um so hey can you uh send me the the quarterly numbers before friday and also we should probably um schedule a meeting about the new design thing thanks"
            Task {
                do {
                    let mode = BuiltInModes.clean
                    let out = try await LlamaTransformer(modelURL: url)
                        .transform(messy, mode: mode, context: TransformContext())
                    yapdiag("phitest IN : \(messy)")
                    yapdiag("phitest OUT: \(out)")
                } catch {
                    yapdiag("phitest FAILED: \(error)")
                }
            }
        }
        // Corpus torment: run /tmp/yap-corpus.json (array of {input, modeHint}) through the REAL
        // Auto pipeline - heuristic classify, live model transform, full sanitize - and write
        // /tmp/yap-corpus-out.json. Drives the shipping model with no rebuild between cases.
        dnc.addObserver(forName: .init("yap.debug.corpus"), object: nil, queue: .main) { [weak self] _ in
            guard let self,
                  let phi = self.state.models.languageModels.first(where: { $0.runtime == .llamaCpp }),
                  let url = self.state.models.downloads.localURL(for: phi),
                  let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/corpus-in.json"),
                  let cases = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
                yapdiag("corpus: missing model or \(NSHomeDirectory())/corpus-in.json"); return
            }
            Task {
                let transformer = LlamaTransformer(modelURL: url)
                var results: [[String: String]] = []
                for c in cases {
                    let input = c["input"] ?? ""
                    // Mirror DictationController's Auto routing: strip a trailing directive, run the
                    // instant heuristic screen; Clean Up is the conservative default when ambiguous.
                    let directive = AutoContext.extractDirective(input)
                    let base = directive?.text ?? input
                    let verdict = AutoContext.screen(base)
                    let mode: Mode
                    switch verdict {
                    case .some(.email): mode = BuiltInModes.email
                    case .some(.note): mode = BuiltInModes.note
                    case .some(.message): mode = BuiltInModes.raw
                    case .some(.code): mode = BuiltInModes.code
                    default: mode = BuiltInModes.clean
                    }
                    var out = ""
                    do { out = try await transformer.transform(base, mode: mode, context: TransformContext()) }
                    catch { out = "ERROR: \(error)" }
                    results.append(["input": input,
                                    "screen": verdict.map { "\($0)" } ?? "ai-would-decide",
                                    "mode": mode.name,
                                    "output": out])
                    yapdiag("corpus[\(results.count)/\(cases.count)] \(mode.name): \(out.prefix(80))")
                }
                if let outData = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) {
                    try? outData.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/corpus-out.json"))
                    yapdiag("corpus: wrote \(results.count) results")
                }
            }
        }
#endif

        reloadHotkey()
        reloadPauseHotkey()
        reloadCycleHotkey()
        reloadSwitcherHotkey()
        reloadHistoryHotkey()
        reloadRightCommandTrigger()
        reloadModeHotkeys()
        reloadDockIcon()
        reloadStatusItem()
        state.permissions.refresh()
        state.controller.refreshActiveMode()
        // Warm the mic route so the FIRST dictation after launch doesn't record silence while
        // CoreAudio initializes the input. Only when mic permission is already granted - never
        // trigger the permission prompt before the user does anything.
        if state.permissions.microphoneGranted {
            lastPrewarmAt = Date()
            state.controller.prewarmAudioInput()
        }
        // Preload BOTH on-device models a few seconds after launch (off the startup path), so
        // even the FIRST dictation transcribes AND cleans up instantly - no cold model load or
        // Metal shader compile at stop time. Staggered so they don't fight for GPU/disk at once:
        // speech first (needed earlier in the pipeline), then the cleanup model.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.state.controller.warmSpeechModel()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.state.controller.warmLanguageModel()
        }

        // Re-check permissions whenever the app returns to the foreground, so a grant made in
        // System Settings (e.g. Accessibility) is detected immediately without a relaunch.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.state.permissions.refresh()
            InputLevelMonitor.shared.resume()
            // Coming to the foreground often precedes a dictation - re-warm the mic route so the
            // first words are never swallowed by cold input hardware. Debounced so repeated
            // foreground transitions don't re-power the mic when nothing changed.
            self?.prewarmMicIfStale()
            // Re-arm the Accessibility-dependent input readers. The Right Command monitor and the
            // digit/space tap only come alive once Accessibility is granted; if the user grants it
            // AFTER launch (or it wasn't ready at launch), the global monitor installed with no
            // permission is dead. Re-installing it here makes the trigger work without a relaunch.
            self?.reloadRightCommandTrigger()
            self?.installActivityPrewarm()
        }
        // Persist edited commands/actions whenever we leave the foreground, not just on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.state.commands.flush()
            self?.state.actions.flush()
            // Drop the meter's mic tap when we're not frontmost, so no audio thread runs idle.
            InputLevelMonitor.shared.suspend()
        }

        // Track the last non-self app so file transcription can return the text to it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastActiveOtherApp = app
        }

        if state.settings.launchAtLogin { LaunchAtLogin.set(true) }
        yapdiag("launch: AXIsProcessTrusted=\(AXIsProcessTrusted()) rightCmd=\(state.settings.rightCommandTrigger.rawValue) hotkeyBehavior=\(state.settings.hotkeyBehavior.rawValue) engine=\(state.settings.engine.rawValue) speech=\(state.settings.selectedSpeechModelID) aiCleanup=\(state.settings.aiCleanupEnabled)")
        state.history.pruneOlderThan(days: state.settings.autoDeleteDays)
        prepareSpeechModel()
        // If the last session died mid-dictation, rescue whatever audio made it to disk.
        state.controller.recoverCrashedSessionIfNeeded()
        // Orphaned recordings (no history record points at them) are swept a beat after
        // launch - after crash recovery has had the chance to claim its file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            let referenced = Set(self.state.history.records.compactMap { $0.audioFileName })
            AudioStore.sweepOrphans(referenced: referenced)
        }
        // If the user's active mode already uses AI cleanup, warm the GGUF now so their FIRST
        // dictation doesn't sit in a long cold load (which read as "not pasting" and got
        // cancelled). Raw-mode users skip this and keep the tiny idle footprint.
        // Launch-time GGUF prewarm removed: the recording-start prewarm already overlaps
        // the load with the user speaking, so parking ~2.3GB from launch bought nothing
        // for users who don't dictate right away. (Perf audit, 1.1)


        // Under system memory pressure, drop the cached multi-GB model handles (whisper context +
        // GGUF). They lazy-reload on next use; eviction is inference-safe (guarded by the same
        // locks the engines run under).
        memoryPressureSource.setEventHandler { [weak self] in
            WhisperEngine.evictCachedContext()
            LlamaEngine.evictCachedModel()
            // Don't let the very next keystroke reload gigabytes while the system is
            // still starved - the activity re-warm stands down for a few minutes.
            Task { @MainActor in self?.state.controller.suppressModelWarmUntil = Date().addingTimeInterval(300) }
            yapdiag("memory pressure: evicted cached models")
        }
        memoryPressureSource.resume()
    }

    /// Re-show the main window when the user clicks the Dock icon after closing it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "diag.cleanExit")
        // Stop any in-flight dictation cleanly (releases the recorder/engine, restores the
        // clipboard, hides the panel) before we clear anything.
        state.controller.cancel()
        state.commands.flush()
        state.actions.flush()
        if state.settings.clearHistoryOnQuit {
            state.history.clear()
        }
    }

    // MARK: Hotkeys

    /// The modifier flags a push-to-talk trigger holds down while dictating, so the digit
    /// tap can still see bare number keys pressed mid-sentence.
    private func pushToTalkHeldModifiers() -> CGEventFlags {
        var flags: CGEventFlags = []
        if state.settings.hotkeyBehavior == .pushToTalk {
            let carbon = state.settings.hotkey.modifiers
            if carbon & KeyCombo.cmd != 0 { flags.insert(.maskCommand) }
            if carbon & KeyCombo.shift != 0 { flags.insert(.maskShift) }
            if carbon & KeyCombo.option != 0 { flags.insert(.maskAlternate) }
            if carbon & KeyCombo.control != 0 { flags.insert(.maskControl) }
            if state.settings.hotkey.includesFn { flags.insert(.maskSecondaryFn) }
        }
        if state.settings.rightCommandTrigger == .pushToTalk {
            flags.insert(state.settings.primaryTriggerKey.cgFlag)
        }
        if state.settings.fnKeyTrigger == .pushToTalk {
            flags.insert(.maskSecondaryFn)
        }
        return flags
    }

    func reloadHotkey() {
        let down: () -> Void
        let up: (() -> Void)?
        switch state.settings.hotkeyBehavior {
        case .toggle:
            down = { [weak self] in self?.state.controller.toggle() }
            up = nil
        case .pushToTalk:
            down = { [weak self] in
                guard let c = self?.state.controller else { return }
                if c.isProcessing { return }   // transcription in flight: don't discard it on a stray press
                if c.isBusy && !c.isRecording { c.cancel() } else { c.start() }
            }
            up = { [weak self] in self?.state.controller.stop() }
        }
        let combo = state.settings.hotkey
        bareKeyTap.stop()
        hotkey.unregister()
        if combo.modifiers == 0 && !HotkeyRecorderField.isStandaloneKey(combo.keyCode) {
            // A bare letter/key: Carbon ignores these, so listen via the event tap.
            // start() returns false without Accessibility - surfaced as an inactive hotkey.
            bareKeyTap.onKeyDown = down
            bareKeyTap.onKeyUp = up
            state.mainHotkeyActive = bareKeyTap.start(keyCode: combo.keyCode)
        } else {
            hotkey.onKeyDown = down
            hotkey.onKeyUp = up
            state.mainHotkeyActive = hotkey.register(combo)
        }
    }

    func reloadPauseHotkey() {
        pauseHotkey.unregister()
        guard let combo = state.settings.pauseHotkey else { return }
        pauseHotkey.onKeyDown = { [weak self] in self?.state.controller.togglePause() }
        pauseHotkey.register(combo)
    }

    func reloadCycleHotkey() {
        cycleHotkey.unregister()
        guard let combo = state.settings.cycleModeHotkey else { return }
        cycleHotkey.onKeyDown = { [weak self] in self?.state.controller.cycleMode() }
        cycleHotkey.register(combo)
    }

    func reloadSwitcherHotkey() {
        switcherHotkey.unregister()
        guard let combo = state.settings.switcherHotkey else { return }
        switcherHotkey.onKeyDown = { [weak self] in self?.showModeSwitcher() }
        switcherHotkey.register(combo)
    }

    func reloadHistoryHotkey() {
        historyHotkey.unregister()
        if let combo = state.settings.historyPaletteHotkey {
            historyHotkey.onKeyDown = { [weak self] in self?.showHistoryPalette() }
            historyHotkey.register(combo)
        }
        reloadRedoHotkey()
    }

    private let redoHotkey = HotkeyManager()
    func reloadRedoHotkey() {
        redoHotkey.unregister()
        guard let combo = state.settings.redoLastHotkey else { return }
        redoHotkey.onKeyDown = { [weak self] in self?.state.controller.redoLastInsertion() }
        redoHotkey.register(combo)
    }

    /// A palette of your most recent dictations; picking one types it at the cursor.
    func showHistoryPalette() {
        let records = Array(state.history.records.prefix(9))
        guard !records.isEmpty else {
            state.controller.announceStatus("No dictations yet")
            return
        }
        let target = NSWorkspace.shared.frontmostApplication
        let items = records.map { record in
            QuickPanelItem(title: String(record.finalText.prefix(70)).replacingOccurrences(of: "\n", with: " "),
                           subtitle: "\(record.modeName) · \(record.date.formatted(date: .omitted, time: .shortened))",
                           icon: "clock.arrow.circlepath")
        }
        QuickPanel.shared.present(title: "Insert Recent Dictation", items: items) { [weak self] index in
            Task { await self?.paste(records[index].finalText, into: target) }
        }
    }

    /// Re-activate `target`, wait until it is actually frontmost, then deliver the text.
    /// Shared by AI actions and the history palette so a paste can't land in the wrong app.
    private func paste(_ text: String, into target: NSRunningApplication?) async {
        guard let target, target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            state.controller.flashStatus("Lost the target app - select text and try again")
            return
        }
        // Robust activation (up to ~1s, with a second nudge and a settle beat) - the old 500ms
        // loop lost the race returning from another app, which surfaced as "Couldn't return".
        await waitUntilFrontmost(target)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            state.controller.flashStatus("Couldn't return to the app to paste")
            return
        }
        await TextInserter.deliver(text, target: .insertAtCursor,
                             method: state.settings.insertionMethod,
                             restoreClipboard: state.settings.restoreClipboard)
        state.controller.announceStatus("Inserted")
    }

    /// Type `text` into the app the user was last in (the Utility hub's Insert buttons). Falls back
    /// to the clipboard if there's no other app to return to.
    /// The app the user was in before ours - the natural paste target. Falls back to the
    /// TOPMOST on-screen window that isn't ours when nothing has been tracked yet (fresh launch
    /// with YapToText frontmost was leaving this nil, so first dictations went clipboard-only).
    func previousApp() -> NSRunningApplication? {
        if let last = lastActiveOtherApp, !last.isTerminated { return last }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in info {   // front-to-back order
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    func insertIntoLastApp(_ text: String) {
        guard !text.isEmpty else { return }
        // "Put it WHERE I AM": the app the user was working in right before opening the
        // popover. The old behavior (the app the dictation originally belonged to) was
        // technically correct and practically invisible - the text kept landing in an app
        // the user wasn't looking at, which read as the button doing nothing.
        let target: NSRunningApplication? = {
            if let app = lastActiveOtherApp, !app.isTerminated { return app }
            // Fallback: nothing tracked yet (fresh launch straight into the popover) -
            // the dictation's own origin app is the best remaining guess.
            if let bid = state.history.records.first?.appBundleID,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first(where: { !$0.isTerminated }) {
                return app
            }
            return nil
        }()
        yapdiag("insertLast: target=\(target?.localizedName ?? "nil") (lastActive=\(lastActiveOtherApp?.localizedName ?? "nil"), historyApp=\(state.history.records.first?.appName ?? "nil"))")
        // INSTANT response: spinner on now, popover out of the way now - the activation
        // handoff and paste then happen without a transient popover fighting focus.
        state.controller.insertLastBusy = true
        closeMenuPopover()
        Task {
            await paste(text, into: target)
            state.controller.insertLastBusy = false
        }
    }

    /// CUSTOM (non-modifier) trigger keys ride dedicated swallowing event taps - the
    /// pressed key stops typing anywhere and becomes the trigger, full stop.
    private let primaryCustomTap = BareKeyTap()
    private let quickEditCustomTap = BareKeyTap()

    func reloadRightCommandTrigger() {
        // Rebuild the monitor around whichever key the user picked as the trigger.
        rightCommand.stop()
        primaryCustomTap.stop()
        let key = state.settings.primaryTriggerKey
        let trigger = state.settings.rightCommandTrigger
        if key.isCustom {
            if trigger != .off {
                let ptt = trigger == .pushToTalk
                primaryCustomTap.onKeyDown = { [weak self] in
                    guard let self else { return }
                    if ptt {
                        if !self.state.controller.isRecording { self.state.controller.start() }
                    } else {
                        self.state.controller.toggle()
                    }
                }
                primaryCustomTap.onKeyUp = { [weak self] in
                    guard let self, ptt else { return }
                    // Unconditional: a release during the arm window (phase not yet
                    // .recording) must still end the session - stop() defers itself via
                    // stopRequested, and no-ops when idle.
                    self.state.controller.stop()
                }
                primaryCustomTap.start(keyCode: UInt32(key.keyCode))
            }
            reloadFnKeyTrigger()
            return
        }
        rightCommand = ModifierKeyMonitor(keyCode: key.keyCode, flag: key.flag)
        // Caps Lock is a toggle at the hardware level (no held state exists), so
        // push-to-talk degrades gracefully to tap-to-start/stop on it.
        let mode: ModifierTrigger = (key == .capsLock && trigger == .pushToTalk)
            ? .toggle : trigger
        configureModifierTrigger(rightCommand, mode: mode)
        reloadFnKeyTrigger()
    }

    func reloadFnKeyTrigger() {
        configureModifierTrigger(fnKey, mode: state.settings.fnKeyTrigger)
        reloadQuickEditKey()
    }

    /// One Carbon hotkey per mode that has a dedicated activation shortcut: press it anywhere
    /// and dictation starts in that mode; press again to stop. Rebuilt whenever modes change.
    private var modeHotkeys: [UUID: HotkeyManager] = [:]

    func reloadModeHotkeys() {
        for (_, manager) in modeHotkeys { manager.unregister() }
        modeHotkeys.removeAll()
        for mode in state.modeStore.allModes {
            guard let combo = mode.activationHotkey else { continue }
            let manager = HotkeyManager()
            let modeID = mode.id
            manager.onKeyDown = { [weak self] in
                guard let self else { return }
                let c = self.state.controller
                if c.isRecording { c.stop(); return }
                if c.isBusy { return }
                if let m = self.state.modeStore.allModes.first(where: { $0.id == modeID }) {
                    c.selectMode(m)
                    c.start()
                }
            }
            if manager.register(combo) { modeHotkeys[modeID] = manager }
            else { yapdiag("mode hotkey: couldn't register \(combo.displayString) for \(mode.name)") }
        }
    }

    func reloadQuickEditKey() {
        quickEditKey.stop()
        quickEditCustomTap.stop()
        let trigger = state.settings.quickEditTrigger
        state.settings.quickEditKeyEnabled = trigger != .off   // legacy flag stays in sync
        guard trigger != .off else { return }
        // Rebuild around whichever key the user bound (Right Option by default).
        let key = state.settings.quickEditTriggerKey
        // Caps Lock is a hardware toggle (no held state), so hold-to-talk degrades to
        // tap-to-start/stop on it - same rule as the dictation key.
        let ptt = trigger == .pushToTalk && key != .capsLock

        // THE CONTRACT, no exceptions:
        //  toggle: press turns it on; press turns it off. A press while listening ends
        //          the session and applies; a press over ANY other card (select-text
        //          info, applying, result) shuts the whole surface down.
        //  hold:   press turns it on; release turns it off. Release while listening (or
        //          still arming) ends and applies; release over anything else dismisses.
        // Turn the Quick Edit surface OFF no matter what it is doing.
        let shutDown: () -> Void = { [weak self] in
            guard let self else { return }
            self.disarmQuickEditSelectionRetry()
            if self.quickEditApplying {
                self.quickEditCancelled = true
                self.quickEditApplying = false
                yapdiag("quickEdit: key press cancelled the apply")
            }
            if self.state.controller.isScratchpadSession {
                self.state.controller.cancel()
            }
            QuickEditWindow.shared.dismiss()
        }
        let down: () -> Void = { [weak self] in
            guard let self else { return }
            if ptt {
                self.quickEditKeyHeld = true
                if self.quickEditApplying || QuickEditWindow.shared.isShowing {
                    // A press over a leftover card starts FRESH: off, then on.
                    shutDown()
                }
                if !self.state.controller.isRecording, !self.state.controller.isBusy {
                    self.beginQuickEdit()
                }
            } else {
                if self.state.controller.isScratchpadSession {
                    self.state.controller.stop()          // press #2 while listening: end + apply
                    QuickEditWindow.shared.showHeard()
                } else if self.quickEditApplying || QuickEditWindow.shared.isShowing {
                    shutDown()                            // press over any other card: off
                } else if !self.state.controller.isBusy {
                    self.beginQuickEdit()                 // press while off: on
                }
            }
        }
        let up: () -> Void = { [weak self] in
            guard let self, ptt else { return }
            self.quickEditKeyHeld = false
            if self.state.controller.isScratchpadSession {
                // Ends the session in EVERY phase: stop() defers itself while the start
                // is still arming (stopRequested) and stops a live recording outright.
                self.state.controller.stop()
                // Acknowledge the release IMMEDIATELY - never sit on "Listening…"
                // through a slow transcription.
                QuickEditWindow.shared.showHeard()
            } else if QuickEditWindow.shared.isShowing {
                // No session behind the card (select-text info, a stale listening shell):
                // release means off. Working/result cards ride out their own dismissal.
                switch QuickEditWindow.shared.currentStage {
                case .listening, .info: QuickEditWindow.shared.dismiss()
                default: break
                }
            }
        }

        if key.isCustom {
            quickEditCustomTap.onKeyDown = down
            quickEditCustomTap.onKeyUp = up
            quickEditCustomTap.start(keyCode: UInt32(key.keyCode))
        } else {
            quickEditKey = ModifierKeyMonitor(keyCode: key.keyCode, flag: key.flag)
            quickEditKey.onDown = down
            quickEditKey.onUp = { _ in up() }
            quickEditKey.start()
        }
    }

    /// True when a Quick Edit instruction is a dictionary request rather than a text edit.
    /// Whole-utterance match only, with the natural phrasings people actually say.
    static func isAddToDictionary(_ utterance: String) -> Bool {
        var t = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".,!?".contains(last) { t.removeLast() }
        // Forgiving on purpose: recognizers drop articles and add fillers around this exact
        // phrase constantly. Requires the verbs and "dictionary", tolerates the middle.
        let pattern = "^(please |okay |ok )?(can you |could you )?(add|put|save) (this|this word|this phrase|that|it)?( word| phrase| name)? ?(to|into|in) ?(the |my |your )?dictionary,?( please)?\\.?$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Add the selected text to the first dictionary as heard-lowercase -> exact-casing, so the
    /// recognizer's flat output is corrected to this spelling from now on.
    private func addSelectionToDictionary(_ selection: String) {
        let word = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 80 else {
            state.controller.flashStatus("Select a word or short phrase to add it to the dictionary")
            return
        }
        // Already covered? Don't stack duplicates.
        let heard = word.lowercased()
        let exists = state.vocabulary.dictionaries.contains { dict in
            dict.replacements.contains { $0.from.lowercased() == heard }
        }
        guard !exists else {
            state.controller.flashStatus("\u{201C}\(word)\u{201D} is already in your dictionary")
            return
        }
        state.vocabulary.addReplacement(Replacement(from: heard, to: word))
        state.controller.flashStatus("Added \u{201C}\(word)\u{201D} to your dictionary")
        yapdiag("quickEdit: added '\(word)' to dictionary")
        // Sound-alike expansion: the case-fix alone only helps when the recognizer heard the
        // word LETTER-PERFECT. For a name like "Ryleigh" it usually hears "Riley" - so ask the
        // AI for the common spellings a recognizer would produce, and map those too.
        expandSoundAlikes(for: word)
    }

    /// Ask the on-device AI for the likely mishearings of a freshly-added dictionary word and
    /// add each as a substitution toward the correct spelling. Strictly filtered and capped, so
    /// a hallucinated answer can never pollute the dictionary; failure is silent (the exact-match
    /// entry is already in place).
    func expandSoundAlikes(for word: String) {
        // Single words only: phrases don't have phonetic twins in a useful way.
        guard !word.contains(" "), word.count >= 3 else { return }
        Task { [weak self] in
            guard let self else { return }
            let prompt = "The word or name is: \(word)\nList up to 5 DIFFERENT spellings that a speech recognizer would likely produce when someone says this word aloud (common homophones and phonetic spellings). Rules: output ONLY the spellings, comma-separated, all lowercase, single words, no numbering, no explanations, and do not include \(word) itself."
            guard let reply = try? await self.state.controller.applyAIAction(
                instructions: "You list likely speech-recognition spellings of a word. Output only a comma-separated list.",
                to: prompt) else { return }
            let existing = Set(self.state.vocabulary.dictionaries.flatMap { $0.replacements.map { $0.from.lowercased() } })
            let target = word.lowercased()
            let variants = reply.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .punctuationCharacters) }
                .filter { candidate in
                    candidate.count >= 3 && candidate.count <= 24
                    && candidate != target
                    && candidate.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
                    && !existing.contains(candidate)
                    // Sanity: a real sound-alike shares the first letter's sound more often
                    // than not; requiring the same first letter blocks most hallucinations.
                    && candidate.first == target.first
                }
                .prefix(4)
            guard !variants.isEmpty else { return }
            for variant in variants {
                self.state.vocabulary.addReplacement(Replacement(from: variant, to: word))
            }
            yapdiag("quickEdit: sound-alikes for '\(word)': \(variants.joined(separator: ", "))")
            self.state.controller.flashStatus("Also mapped \(variants.count) sound-alike\(variants.count == 1 ? "" : "s") to \u{201C}\(word)\u{201D}")
        }
    }

    /// Quick Edit session: grab the selection from the frontmost app, then dictate an
    /// instruction into a scratchpad sink; the transcript runs as a one-shot AI action on
    /// the selection and replaces it in place.
    private func beginQuickEdit() {
        disarmQuickEditSelectionRetry()   // a live entry supersedes any pending retry
        let c = state.controller
        guard !c.isBusy, !c.isProcessing else {
            yapdiag("quickEdit: beginQuickEdit BLOCKED (isBusy=\(c.isBusy) isProcessing=\(c.isProcessing))")
            return
        }
        let target = NSWorkspace.shared.frontmostApplication
        yapdiag("quickEdit: beginQuickEdit front=\(target?.localizedName ?? "?") trigger=\(state.settings.quickEditTrigger) key=\(state.settings.quickEditTriggerKey)")
        // Window FIRST, selection second: the popup used to wait behind captureSelection's
        // Cmd-C + up-to-400ms clipboard poll, which read as "the popup opens slowly". Showing
        // it the instant the key goes down makes the feature feel wired to the key.
        QuickEditWindow.shared.showListening(liveTextSource: state.controller)
        Task { [weak self] in
            guard let self else { return }
            let selection = await SelectionEditor.captureSelection()
            yapdiag("quickEdit: captureSelection -> \(selection == nil ? "nil (nothing copied)" : "\(selection!.count) chars") secureInput=\(TextInserter.isSecureInputActive)")
            guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Nothing selected: teach in the moment, in the feature's own popup - a status
                // flash elsewhere is invisible when someone is looking at their document.
                if TextInserter.isSecureInputActive {
                    QuickEditWindow.shared.showInfo("Can't read the selection",
                        "Secure Input is on (usually a password field). Click into normal text and try again.")
                } else if self.state.settings.quickEditTrigger == .toggle {
                    // TOGGLE mode: the tap already meant "I want to edit". Keep the card up,
                    // watch for the selection being made, and enter listening BY ITSELF the
                    // moment text is highlighted - no second tap, and no card vanishing
                    // right as the user clicks into their document.
                    QuickEditWindow.shared.showInfo("Select some text first",
                        "Highlight the words to change - the edit starts by itself.", seconds: 12)
                    self.armQuickEditSelectionRetry()
                } else {
                    QuickEditWindow.shared.showInfo("Select some text first",
                        "Highlight the words you want to change, then hold \(self.state.settings.quickEditTriggerKey.label) and say the edit - like \u{201C}capitalize this\u{201D}.")
                }
                return
            }
            // The key may already be up if the press was just a tap; don't start a session
            // that nothing will ever stop - and take the already-showing popup down with it.
            // Only push-to-talk requires the key to still be held (release = stop). In
            // TOGGLE mode nothing holds - this guard silently killed every toggle-mode
            // session right after "Listening…" appeared.
            guard self.state.settings.quickEditTrigger != .pushToTalk || self.quickEditKeyHeld else {
                QuickEditWindow.shared.dismiss(); return
            }
            self.state.controller.startScratchpad { [weak self] instruction in
                guard let self else { return }
                let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    QuickEditWindow.shared.showResult("Didn't catch an instruction", success: false)
                    return
                }
                // Dictionary command: "add this to my dictionary" makes the SELECTED text a
                // permanent substitution (lowercase-heard -> exact selected casing), so the
                // recognizer spells and capitalizes it this way forever. Handled locally -
                // no AI round trip for a bookkeeping request.
                yapdiag("quickEdit: instruction='\(trimmed)' dictionaryCommand=\(Self.isAddToDictionary(trimmed))")
                if Self.isAddToDictionary(trimmed) {
                    self.addSelectionToDictionary(text)
                    QuickEditWindow.shared.showResult("Added \u{201C}\(text.prefix(30))\u{201D} to your dictionary")
                    return
                }
                QuickEditWindow.shared.showWorking(trimmed)
                self.quickEditApplying = true
                self.quickEditCancelled = false
                self.armCancelKey(force: true)   // Esc stays live through the whole apply
                self.quickEditGeneration += 1
                let gen = self.quickEditGeneration
                self.runAIAction(AIAction(name: "Quick Edit", iconSystemName: "pencil.line",
                                          instructions: trimmed), on: text, target: target,
                                 isCancelled: { [weak self] in
                                     guard let self else { return true }
                                     return self.quickEditCancelled || self.quickEditGeneration != gen
                                 }) { [weak self] ok in
                    guard let self, self.quickEditGeneration == gen else { return }   // stale session
                    self.quickEditApplying = false
                    self.disarmCancelKey()
                    guard !self.quickEditCancelled else { return }   // window already says "Cancelled"
                    QuickEditWindow.shared.showResult(ok ? "Done" : "Couldn't apply that edit", success: ok)
                }
            }
        }
    }

    /// Toggle-mode "select first" helper: after the nudge, one global mouse-up watcher
    /// waits for the user to finish highlighting; when a selection exists, the quick edit
    /// re-enters on its own. Auto-disarms after 12s or the moment a session starts.
    private var quickEditRetryMonitor: Any?
    private func disarmQuickEditSelectionRetry() {
        if let m = quickEditRetryMonitor { NSEvent.removeMonitor(m); quickEditRetryMonitor = nil }
    }
    private func armQuickEditSelectionRetry() {
        disarmQuickEditSelectionRetry()
        let deadline = Date().addingTimeInterval(12)
        quickEditRetryMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }
            if Date() > deadline { self.disarmQuickEditSelectionRetry(); return }
            guard !self.state.controller.isRecording, !self.state.controller.isBusy else {
                self.disarmQuickEditSelectionRetry(); return
            }
            Task { @MainActor [weak self] in
                guard let self, self.quickEditRetryMonitor != nil else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)   // let the drag settle
                guard self.quickEditRetryMonitor != nil else { return }
                let selection = await SelectionEditor.captureSelection()
                guard let text = selection,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.disarmQuickEditSelectionRetry()
                yapdiag("quickEdit: selection appeared after nudge - re-entering")
                self.beginQuickEdit()
            }
        }
        // Hard stop with the card's own timeout so the monitor can't outlive the nudge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) { [weak self] in
            self?.disarmQuickEditSelectionRetry()
        }
    }

    /// Shared wiring for a bare-modifier dictation trigger (Right Command, Fn/Globe).
    private func configureModifierTrigger(_ monitor: ModifierKeyMonitor, mode: ModifierTrigger) {
        monitor.stop()
        guard mode != .off else { return }

        switch mode {
        case .toggle:
            monitor.onDown = nil
            monitor.onUp = { [weak self] clean in
                guard clean else { return }   // part of a chord like Cmd-C: ignore
                self?.state.controller.toggle()
            }
        case .pushToTalk:
            monitor.onDown = { [weak self] in
                guard let c = self?.state.controller else { return }
                // A press while a previous dictation is still transcribing/cleaning up must NOT
                // discard it (the reported spam-the-key bug). Ignore it; it finishes and lands.
                if c.isProcessing { return }
                if c.isBusy && !c.isRecording { c.cancel() } else { c.start() }
            }
            monitor.onUp = { [weak self] _ in self?.state.controller.stop() }
        case .off:
            monitor.onDown = nil
            monitor.onUp = nil
        }

        monitor.start()
    }

    // MARK: Quick panels (mode switcher + AI actions)

    func showModeSwitcher() {
        // The controller's canonical switch list: Auto occupies slot 1 whenever it's enabled.
        let modes = state.controller.switchableModes
        guard !modes.isEmpty else { return }
        let items = modes.map {
            QuickPanelItem(title: $0.name, subtitle: $0.usesAI ? "AI cleanup" : "Verbatim", icon: $0.iconSystemName)
        }
        let current = modes.firstIndex { $0.id == state.settings.activeModeID } ?? 0
        QuickPanel.shared.present(title: "Switch Mode", items: items, preselect: current) { [weak self] index in
            self?.state.controller.selectMode(modes[index])
        }
    }

    func showAIActions() {
        // Grab the selection while the target app is still frontmost, before our panel takes focus.
        let target = NSWorkspace.shared.frontmostApplication
        Task { [weak self] in
            guard let self else { return }
            let selection = await SelectionEditor.captureSelection()
            guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state.controller.announceStatus(TextInserter.isSecureInputActive
                    ? "Secure Input is on, so the selection can't be read"
                    : "Select some text first")
                return
            }
            guard FoundationModelsTransformer.isAvailable else {
                self.state.controller.announceStatus("Apple Intelligence isn't available")
                return
            }
            let actions = self.state.actions.actions
            guard !actions.isEmpty else { return }
            let items = actions.map { QuickPanelItem(title: $0.name, icon: $0.iconSystemName) }
            QuickPanel.shared.present(title: "AI Action on Selection", items: items) { [weak self] index in
                self?.runAIAction(actions[index], on: text, target: target)
            }
        }
    }

    /// Menu-bar path: rewrite whatever text is selected in the PREVIOUS app through a mode's
    /// full pipeline, then paste the result back over the selection. Replaces the old
    /// shortcut-plus-quick-panel flow with one obvious menu action.
    func regenerateSelection(using mode: Mode) {
        let target = lastActiveOtherApp
        Task { [weak self] in
            guard let self else { return }
            // The selection lives in the previous app; bring it forward so AX can read it.
            yapdiag("regenSelection(mode=\(mode.name)): target=\(target?.localizedName ?? "nil") front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            await self.waitUntilFrontmost(target)
            let selection = await SelectionEditor.captureSelection()
            yapdiag("regenSelection: captured len=\(selection?.count ?? -1)")
            guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state.controller.flashStatus(TextInserter.isSecureInputActive
                    ? "Secure Input is on, so the selection can't be read"
                    : "Select some text first")
                return
            }
            do {
                let result = try await self.state.controller.preview(text, mode: mode)
                yapdiag("regenSelection: result len=\(result.count)")
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.state.controller.flashStatus("No changes made")
                    return
                }
                await self.paste(result, into: target)
            } catch {
                yapdiag("regenSelection FAILED: \(error)")
                self.state.controller.flashStatus("Couldn't regenerate the selection")
            }
        }
    }

    /// Menu-bar path: run an AI Action (translate, summarize, custom) on whatever text is
    /// selected in the previous app, then paste the result back over the selection.
    func regenerateSelection(applying action: AIAction) {
        let target = lastActiveOtherApp
        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilFrontmost(target)
            let selection = await SelectionEditor.captureSelection()
            yapdiag("regenAction(\(action.name)): target=\(target?.localizedName ?? "nil") captured len=\(selection?.count ?? -1)")
            guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state.controller.flashStatus(TextInserter.isSecureInputActive
                    ? "Secure Input is on, so the selection can't be read"
                    : "Select some text first")
                return
            }
            self.runAIAction(action, on: text, target: target)
        }
    }

    /// Bring `app` forward and wait until it truly is (up to ~1s), plus a settle beat so its key
    /// window accepts the synthetic Cmd+C. A fixed 180ms lost the race on slower app switches,
    /// which made selection capture come back empty.
    private func waitUntilFrontmost(_ app: NSRunningApplication?) async {
        guard let app else { return }
        // COOPERATIVE ACTIVATION (macOS 14+): when WE are the active app - which is
        // exactly the state after clicking the menu bar popover - activating another app
        // is silently refused unless the active app YIELDS first. Skipping the yield is
        // why "Insert again" only sometimes returned to the target ("not working").
        func nudge() {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
            app.activate(options: [.activateIgnoringOtherApps])
        }
        nudge()
        for i in 0..<48 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            if i == 16 || i == 32 { nudge() }   // re-nudge
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        yapdiag("waitFrontmost: want=\(app.localizedName ?? "?") pid=\(app.processIdentifier) got=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    private func runAIAction(_ action: AIAction, on text: String, target: NSRunningApplication?,
                             isCancelled: (() -> Bool)? = nil,
                             onFinish: ((Bool) -> Void)? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.state.controller.applyAIAction(
                    instructions: action.instructions, to: text,
                    modelID: action.name == "Quick Edit" ? self.state.settings.quickEditModelID : nil)
                // The LAST safe moment to bail: a quick-edit double-tap cancel must land
                // BEFORE anything touches the user's document.
                if isCancelled?() == true {
                    yapdiag("runAIAction: cancelled before paste; discarding result")
                    return
                }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.state.controller.announceStatus("No changes made")
                    onFinish?(false)
                    return
                }
                await self.paste(result, into: target)
                onFinish?(true)
            } catch {
                yapdiag("runAIAction FAILED: \(error)")
                if isCancelled?() != true { self.state.controller.flashStatus("AI action failed") }
                onFinish?(false)
            }
        }
    }

    /// Pick an audio file and transcribe it with the active mode. The result is typed into the app
    /// you were in when you started (falling back to the clipboard), plus saved to History.
    func transcribeFileFromPicker() {
        // Capture the target BEFORE our window/the picker take focus: prefer the current frontmost
        // app, but if that's already us, use the last other app we saw.
        let front = NSWorkspace.shared.frontmostApplication
        let target = (front?.bundleIdentifier == Bundle.main.bundleIdentifier) ? lastActiveOtherApp : front
        // Do NOT bring our glass main window forward here. On macOS 26.5, animating a window that
        // hosts .glassEffect content forward (via NSAnimationContext) can segfault Apple's
        // DesignLibrary glass renderer - a crash seen right after hitting Transcribe. The file
        // picker is modal and presents itself, and the result is delivered to `target`, so the main
        // window never needs to animate in for this flow.
        let panel = NSOpenPanel()
        panel.title = "Transcribe a File"
        panel.message = "Choose any audio or video file. YapToText transcribes its audio track."
        // No content-type filter: accept any file regardless of extension. We decode the audio
        // track ourselves, so video files and unusual containers work too.
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModalInFront() == .OK, let url = panel.url else { return }
        state.controller.transcribeFile(url, insertInto: target)
    }

    // MARK: Double-Escape cancel

    /// Escape is grabbed globally only while a dictation is in progress, so it does not
    /// interfere with Escape in other apps the rest of the time. A press cancels and discards.
    /// `force` arms Escape even when the cancel-on-Escape setting is off - used during processing
    /// so a stuck transcription/cleanup can always be cancelled with the keyboard.
    private func armCancelKey(force: Bool = false) {
        guard force || state.settings.cancelOnDoubleEscape else { return }
        lastEscapeAt = nil
        cancelKey.register(KeyCombo(keyCode: 53, modifiers: 0))   // Esc, no modifiers
    }

    private func disarmCancelKey() {
        cancelKey.unregister()
        lastEscapeAt = nil
    }

    /// Called when the setting is toggled so a change takes effect during an in-progress
    /// dictation instead of leaving Esc grabbed (or ungrabbed) until the next one.
    func reloadCancelKey() {
        guard state.controller.isRecording else { return }
        if state.settings.cancelOnDoubleEscape { armCancelKey() } else { disarmCancelKey() }
    }

    /// Hide the panel immediately when its setting is switched off (it used to linger until the
    /// next session because every hide was gated on the same setting).
    func reloadPanelVisibility() {
        if !state.settings.showRecordingPanel { panel?.hide() }
    }

    /// Re-apply the panel size to a panel that is already on screen (Size changed mid-dictation).
    func refreshPanelSize() { panel?.applySizeIfVisible() }

    /// Show or hide the Dock icon. `.accessory` drops the Dock tile (and the app menu); reach the
    /// window again from the menu bar icon or the dictation shortcut. `.regular` restores it.
    func reloadDockIcon() {
        NSApp.setActivationPolicy(state.settings.showDockIcon ? .regular : .accessory)
        if state.settings.showDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Menu bar item (manual NSStatusItem - never SwiftUI)

    /// The menu bar capy is a plain AppKit status item. Its image is redrawn by direct
    /// `button.image` assignment (driven by the controller's onMenuStateChanged callback), which
    /// creates ZERO SwiftUI render transactions - a MenuBarExtra label re-rendering inside the
    /// system's glass menu bar was a macOS 26.5 DesignLibrary crash surface during every dictation
    /// (blink ~1.6Hz while recording, spinner ~14fps while processing).
    private var statusItem: NSStatusItem?
    private var menuPopover: NSPopover?

    func reloadStatusItem() {
        if state.settings.showMenuBarIcon {
            guard statusItem == nil else { return }
            // variableLength: the mark is slightly wider than tall (content-fitted art), and a
            // square item would clip its sides.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggleMenuPopover(_:))
            statusItem = item
            refreshStatusIcon()
            startMenuBlink()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Smoothed per-bar levels for the waveform icon: raw levelHistory arrives in ~43ms steps,
    /// which reads as a choppy low-frame-rate wave. Each 30fps refresh eases the displayed bars
    /// toward their targets, so the motion is continuous even between level samples.
    private var waveDisplay: [Float] = []

    func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        var levels = state.controller.levelHistory
        if state.settings.menuBarIconStyle == .waveform, !levels.isEmpty {
            let target = Array(levels.suffix(9))
            if waveDisplay.count != target.count { waveDisplay = target }
            for i in 0..<target.count {
                waveDisplay[i] += (target[i] - waveDisplay[i]) * 0.45   // ease at 30fps
            }
            levels = waveDisplay
        }
        button.image = MenuBarIcon.image(phase: state.controller.phase,
                                         pulse: state.controller.menuPulseLevel,
                                         spin: state.controller.menuSpin,
                                         lid: menuBlinkLid,
                                         clock: state.controller.menuClock,
                                         style: state.settings.menuBarIconStyle,
                                         colored: state.settings.menuBarColoredStatus,
                                         levels: levels,
                                         waveformTint: waveformTint())
    }

    /// The waveform visualizer's color: the dedicated visualizer color if the user picked one,
    /// otherwise their custom accent. nil = classic monochrome.
    private func waveformTint() -> NSColor? {
        guard state.settings.menuBarIconStyle == .waveform else { return nil }
        // AT STANDBY the icon is a TEMPLATE like every other menu bar item - monochrome,
        // adapting to the bar. The accent color only lights it while a session is live,
        // so color means "listening/working", not "always blue".
        guard state.controller.isRecording || state.controller.isBusy else { return nil }
        if let hex = state.settings.visualizerColorHex, let c = Color(hexString: hex) { return NSColor(c) }
        if let accent = state.settings.customAccent { return NSColor(accent) }
        return nil
    }

    // MARK: Menu bar blink

    /// The same periodic blink the in-app capy does, at menu-bar cost: ~6 frames every ~5s
    /// (plain AppKit image swaps, zero SwiftUI transactions, nothing when the item is hidden).
    private var menuBlinkLid: Double = 0
    private var blinkTimer: Timer?

    func startMenuBlink() {
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 5.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runBlink() }
        }
        timer.tolerance = 1.0   // let the system coalesce wakeups; exact timing doesn't matter
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func runBlink() {
        guard statusItem != nil else { return }
        let frames: [Double] = [0.45, 0.95, 1.0, 0.7, 0.3, 0]
        for (i, lid) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.035) { [weak self] in
                guard let self else { return }
                self.menuBlinkLid = lid
                self.refreshStatusIcon()
            }
        }
    }

    func closeMenuPopover() { menuPopover?.performClose(nil) }

    @objc private func toggleMenuPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let popover = menuPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView().environment(state))
        menuPopover = popover
        // Make the POPOVER window key so its controls get first-click - but do NOT activate the
        // whole app: NSApp.activate raised the main YapToText window over whatever the user was
        // working in every time they opened the menu bar (visible as a flash of the app before
        // regenerate switched back). Keying just the popover window is enough for its plain
        // buttons since the Regenerate flow no longer uses nested menus.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func handleCancelKey() {
        // A Quick Edit mid-APPLY is cancelled here too (its session already ended, so
        // controller.cancel() alone wouldn't reach it) - this replaced the old
        // double-tap-the-key cancel: Esc is the one cancel gesture everywhere.
        if quickEditApplying {
            quickEditCancelled = true
            quickEditApplying = false
            QuickEditWindow.shared.showResult("Cancelled - nothing was changed", success: false)
            yapdiag("quickEdit: cancelled by Esc")
            return
        }
        // Default: ONE Escape cancels immediately. The double-press confirmation is an
        // opt-in (Settings > Keys) for people who hit Esc reflexively.
        guard state.settings.doubleEscapeToCancel else {
            state.controller.cancel()
            return
        }
        let now = Date()
        if let last = lastEscapeAt, now.timeIntervalSince(last) < 0.6 {
            lastEscapeAt = nil
            state.controller.cancel()
        } else {
            lastEscapeAt = now
            state.controller.flashStatus("Press Esc again to cancel")
        }
    }

    // Setup lives inline on the Home screen; there is deliberately no setup popup window.

    private func prepareSpeechModel() {
        guard state.settings.engine == .appleSpeech, #available(macOS 26.0, *) else { return }
        let locale = state.settings.localeIdentifier
        Task.detached(priority: .utility) {
            try? await AppleSpeechEngine().prepare(localeIdentifier: locale, progress: nil)
        }
    }
}
