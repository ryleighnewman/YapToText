import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let state = AppState()
    private let hotkey = HotkeyManager()
    private let pauseHotkey = HotkeyManager()
    private let cycleHotkey = HotkeyManager()
    private let switcherHotkey = HotkeyManager()
    private let historyHotkey = HotkeyManager()
    private let rightCommand = ModifierKeyMonitor()
    /// Number keys 1-9 pick the post-processing mode while dictating (armed only then).
    private let digitTap = DigitKeyTap()
    /// Registered only while dictating (opt-in): a bare Esc that cancels on a quick double tap.
    private let cancelKey = HotkeyManager()
    private var lastEscapeAt: Date?
    private var panel: RecordingPanel?
    /// The last non-YapToText app the user was in, so "Transcribe File" and dictations started
    /// from our own window can type the result back into it.
    private(set) var lastActiveOtherApp: NSRunningApplication?
    /// Fires on system memory pressure so the cached speech/cleanup models can be dropped.
    private let memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
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
            self.armCancelKey()
            self.digitTap.heldModifiers = self.pushToTalkHeldModifiers()
            self.digitTap.start()
        }
        state.controller.onRecordingDidStop = { [weak self] in
            self?.digitTap.stop()
            // Keep Escape live through transcription/cleanup so a stuck run can always be cancelled.
            self?.armCancelKey(force: true)
        }
        state.controller.onDidBecomeIdle = { [weak self] in self?.disarmCancelKey() }
        state.controller.onMenuStateChanged = { [weak self] in self?.refreshStatusIcon() }
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
#endif

        reloadHotkey()
        reloadPauseHotkey()
        reloadCycleHotkey()
        reloadSwitcherHotkey()
        reloadHistoryHotkey()
        reloadRightCommandTrigger()
        reloadDockIcon()
        reloadStatusItem()
        state.permissions.refresh()
        state.controller.refreshActiveMode()
        // Warm the mic route so the FIRST dictation after launch doesn't record silence while
        // CoreAudio initializes the input. Only when mic permission is already granted - never
        // trigger the permission prompt before the user does anything.
        if state.permissions.microphoneGranted { state.controller.prewarmAudioInput() }

        // Re-check permissions whenever the app returns to the foreground, so a grant made in
        // System Settings (e.g. Accessibility) is detected immediately without a relaunch.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.state.permissions.refresh()
            InputLevelMonitor.shared.resume()
            // Re-arm the Accessibility-dependent input readers. The Right Command monitor and the
            // digit/space tap only come alive once Accessibility is granted; if the user grants it
            // AFTER launch (or it wasn't ready at launch), the global monitor installed with no
            // permission is dead. Re-installing it here makes the trigger work without a relaunch.
            self?.reloadRightCommandTrigger()
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
        offerRecommendedModelsIfNeeded()
        state.history.pruneOlderThan(days: state.settings.autoDeleteDays)
        prepareSpeechModel()
        // If the last session died mid-dictation, rescue whatever audio made it to disk.
        state.controller.recoverCrashedSessionIfNeeded()
        // If the user's active mode already uses AI cleanup, warm the GGUF now so their FIRST
        // dictation doesn't sit in a long cold load (which read as "not pasting" and got
        // cancelled). Raw-mode users skip this and keep the tiny idle footprint.
        if state.controller.activeMode.usesAI,
           let model = state.models.model(id: state.settings.selectedLanguageModelID),
           model.runtime == .llamaCpp,
           let url = state.models.downloads.localURL(for: model) {
            LlamaEngine.prewarm(modelPath: url.path)
        }

        // Under system memory pressure, drop the cached multi-GB model handles (whisper context +
        // GGUF). They lazy-reload on next use; eviction is inference-safe (guarded by the same
        // locks the engines run under).
        memoryPressureSource.setEventHandler {
            WhisperEngine.evictCachedContext()
            LlamaEngine.evictCachedModel()
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
        }
        if state.settings.rightCommandTrigger == .pushToTalk {
            flags.insert(.maskCommand)
        }
        return flags
    }

    func reloadHotkey() {
        switch state.settings.hotkeyBehavior {
        case .toggle:
            hotkey.onKeyDown = { [weak self] in self?.state.controller.toggle() }
            hotkey.onKeyUp = nil
        case .pushToTalk:
            hotkey.onKeyDown = { [weak self] in
                guard let c = self?.state.controller else { return }
                if c.isBusy && !c.isRecording { c.cancel() } else { c.start() }
            }
            hotkey.onKeyUp = { [weak self] in self?.state.controller.stop() }
        }
        state.mainHotkeyActive = hotkey.register(state.settings.hotkey)
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
        guard let combo = state.settings.historyPaletteHotkey else { return }
        historyHotkey.onKeyDown = { [weak self] in self?.showHistoryPalette() }
        historyHotkey.register(combo)
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
            state.controller.announceStatus("Lost the target app")
            return
        }
        target.activate()
        var focused = false
        for _ in 0..<20 {   // up to ~500ms
            try? await Task.sleep(nanoseconds: 25_000_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                focused = true; break
            }
        }
        guard focused else {
            state.controller.announceStatus("Couldn't return to the app")
            return
        }
        TextInserter.deliver(text, target: .insertAtCursor,
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
        let target = lastActiveOtherApp
        Task { await paste(text, into: target) }
    }

    func reloadRightCommandTrigger() {
        rightCommand.stop()
        let mode = state.settings.rightCommandTrigger
        guard mode != .off else { return }

        switch mode {
        case .toggle:
            rightCommand.onDown = nil
            rightCommand.onUp = { [weak self] clean in
                guard clean else { return }   // part of a chord like Cmd-C: ignore
                self?.state.controller.toggle()
            }
        case .pushToTalk:
            rightCommand.onDown = { [weak self] in
                guard let c = self?.state.controller else { return }
                // Pressing while a previous dictation is still processing means "cancel it".
                if c.isBusy && !c.isRecording { c.cancel() } else { c.start() }
            }
            rightCommand.onUp = { [weak self] _ in self?.state.controller.stop() }
        case .off:
            rightCommand.onDown = nil
            rightCommand.onUp = nil
        }

        rightCommand.start()
    }

    // MARK: Quick panels (mode switcher + AI actions)

    func showModeSwitcher() {
        let modes = state.modeStore.allModes.filter(\.isEngaged)
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
            target?.activate()
            try? await Task.sleep(nanoseconds: 180_000_000)
            let selection = await SelectionEditor.captureSelection()
            guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state.controller.announceStatus(TextInserter.isSecureInputActive
                    ? "Secure Input is on, so the selection can't be read"
                    : "Select some text first")
                return
            }
            do {
                let result = try await self.state.controller.preview(text, mode: mode)
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.state.controller.announceStatus("No changes made")
                    return
                }
                await self.paste(result, into: target)
            } catch {
                self.state.controller.announceStatus("Couldn't regenerate the selection")
            }
        }
    }

    private func runAIAction(_ action: AIAction, on text: String, target: NSRunningApplication?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.state.controller.applyAIAction(instructions: action.instructions, to: text)
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.state.controller.announceStatus("No changes made")
                    return
                }
                await self.paste(result, into: target)
            } catch {
                self.state.controller.announceStatus("AI action failed")
            }
        }
    }

    /// One-time startup offer: download the recommended models (Whisper Large v3 Turbo for
    /// speech, Qwen2.5 3B for cleanup) so defaults work at full quality. Declining keeps the
    /// instant Apple engines; everything stays downloadable later on the AI Models page.
    private func offerRecommendedModelsIfNeeded() {
        guard !state.settings.offeredModelDownloads else { return }
        let wanted = ["whisper-large-v3-turbo", "phi-3.5-mini-instruct-q4"]
            .compactMap { state.models.model(id: $0) }
            .filter { state.models.downloads.localURL(for: $0) == nil }
        guard !wanted.isEmpty else { state.settings.offeredModelDownloads = true; return }
        state.settings.offeredModelDownloads = true
        let totalGB = wanted.reduce(0.0) { $0 + $1.sizeMB } / 1024
        let names = wanted.map(\.displayName).joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "Download the recommended models?"
        alert.informativeText = "For the best accuracy, YapToText uses \(names) (\(String(format: "%.1f", totalGB)) GB, one time). Everything runs and stays on your Mac. Until they finish, the built-in Apple engines are used."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            for model in wanted { state.models.downloads.download(model) }
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
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

    func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = MenuBarIcon.image(phase: state.controller.phase,
                                         pulse: state.controller.menuPulseLevel,
                                         spin: state.controller.menuSpin,
                                         lid: menuBlinkLid,
                                         clock: state.controller.menuClock)
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func handleCancelKey() {
        // Escape fully cancels: stop and discard. Nothing is transcribed, inserted, or saved to
        // History - a cancel means the dictation never happened.
        state.controller.cancel()
    }

    // Setup lives inline on the Home screen; there is deliberately no setup popup window.

    private func prepareSpeechModel() {
        guard state.settings.engine == .appleSpeech else { return }
        let locale = state.settings.localeIdentifier
        Task.detached(priority: .utility) {
            try? await AppleSpeechEngine().prepare(localeIdentifier: locale, progress: nil)
        }
    }
}
