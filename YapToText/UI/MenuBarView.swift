import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    /// When the current regenerate was tapped, used to drive its progress ring.
    @State private var regenStartedAt: Date?
    /// The Regenerate square flips the popover to an inline options page (a nested SwiftUI Menu
    /// inside a transient popover misfires - the popover closes the moment the menu opens).
    @State private var showRegenerate = false
    /// Non-nil while the brief "Regenerating as …" confirmation plays before the popover fades.
    @State private var launching: String?

    var body: some View {
        Group {
            if showRegenerate {
                regenerateOptions
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    modeInputRow
                    quickActions
                    Divider()
                    recentSection
                    Divider()
                    footer
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .yapAccent(state.settings)
        .symbolRenderingMode(.hierarchical)
        .focusEffectDisabled()   // nothing pre-selected when the popover opens
        .yapWindowBackground()
    }

    // MARK: Header (brand + the one action that matters)

    private var header: some View {
        HStack(spacing: 8) {
            // The in-app icon MIRRORS the menu bar icon style the user picked, so the popover
            // and the thing they clicked to open it always look like the same app.
            Group {
                switch state.settings.menuBarIconStyle {
                case .capybara:
                    Image("CapyGlyph")
                        .renderingMode(.template).resizable().scaledToFit()
                case .microphone:
                    Image(systemName: "mic.fill").font(.system(size: 20, weight: .medium))
                case .waveform:
                    Image(systemName: "waveform").font(.system(size: 20, weight: .medium))
                case .bubble:
                    Image(systemName: "bubble.left.fill").font(.system(size: 20, weight: .medium))
                case .dot:
                    Image(systemName: "circle.fill").font(.system(size: 14, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            .iconTint(Color.accentColor)
            .accessibilityHidden(true)
            Text("YapToText").font(.headline)
            Spacer()
            if state.controller.isRecording {
                // Plain circular transport controls, matching the dictation panel's language.
                // Cancel leads the row: dictations are cancellable at every stage, not just
                // during transcription.
                circleControl("xmark", "Cancel", tint: .secondary) { state.controller.cancel() }
                circleControl(state.controller.isPaused ? "play.fill" : "pause.fill",
                              state.controller.isPaused ? "Resume" : "Pause",
                              tint: .accentColor) { state.controller.togglePause() }
                circleControl("stop.fill", "Stop and insert", tint: .red) { state.controller.stop() }
            } else if state.controller.isBusy {
                circleControl("xmark", "Cancel", tint: .secondary) { state.controller.cancel() }
            } else {
                recordPill
            }
        }
    }

    /// A circular icon control - the same visual language as the dictation panel's transport row.
    private func circleControl(_ symbol: String, _ help: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Compact, TRANSLUCENT record control beside the title - accent at reduced opacity so the
    /// frosted popover shows through, instead of the old full-width solid-blue slab.
    private var recordPill: some View {
        let controller = state.controller
        return Button {
            controller.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(controller.isRecording ? "Stop" : "Start Dictation")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background((controller.isRecording ? Color.yapRecord : Color.accentColor).opacity(0.72),
                        in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state.settings.rightCommandTrigger != .off ? "Or tap Right \u{2318}"
              : "Or press \(state.settings.hotkey.displayString)")
    }

    // MARK: Mode + Input selectors (side by side, unmistakably clickable)

    @State private var inputDevices: [AudioInputDevices.Device] = []

    private var modeInputRow: some View {
        HStack(spacing: 8) {
            Menu {
                // Numbered to match the 1-9 keys that switch modes MID-DICTATION, so the menu
                // itself teaches the keyboard shortcut.
                let switchable = state.controller.switchableModes
                Section("Press its number while dictating:") {
                    ForEach(Array(switchable.prefix(9).enumerated()), id: \.element.id) { index, mode in
                        let isAuto = mode.id == BuiltInModes.auto.id
                        let isCurrent = isAuto ? state.settings.autoContextMode
                                               : (!state.settings.autoContextMode && mode.id == state.settings.activeModeID)
                        Button {
                            state.controller.selectMode(mode)
                        } label: {
                            Label("\(index + 1)   \(mode.name)",
                                  systemImage: isCurrent ? "checkmark" : mode.iconSystemName)
                        }
                    }
                }
                let unnumbered = state.modeStore.allModes.filter { mode in
                    !switchable.prefix(9).contains { $0.id == mode.id }
                }
                if !unnumbered.isEmpty {
                    Section("More modes:") {
                        ForEach(unnumbered) { mode in
                            Button {
                                state.controller.selectMode(mode)
                            } label: {
                                Label(mode.name, systemImage: mode.id == state.settings.activeModeID ? "checkmark" : mode.iconSystemName)
                            }
                        }
                    }
                }
            } label: {
                selectorLabel("Mode", icon: state.controller.activeMode.iconSystemName,
                              value: state.controller.activeMode.name)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Switch how your words get formatted")
            .analysisGated(state)   // modes do nothing while post-transcription analysis is off

            Menu {
                Button {
                    state.settings.inputDeviceUID = nil
                } label: {
                    Label("System Default", systemImage: state.settings.inputDeviceUID == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(inputDevices) { device in
                    Button {
                        state.settings.inputDeviceUID = device.uid
                    } label: {
                        Label(device.name, systemImage: state.settings.inputDeviceUID == device.uid ? "checkmark" : "mic")
                    }
                }
            } label: {
                selectorLabel("Input", icon: "mic", value: currentInputName)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Which microphone YapToText listens to")
        }
        .onAppear { inputDevices = AudioInputDevices.all() }
    }

    /// A labelled dropdown chip: label and value sit right next to each other, with the chevron
    /// making it obvious this is something you click to change.
    private func selectorLabel(_ label: String, icon: String, value: String) -> some View {
        // A PILL that reads as a button: the solid-secondary capsule (same family as the app's
        // secondary buttons) with the chevron - unmistakably clickable.
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).iconTint(.accentColor)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(label): \(value)")
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    private var currentInputName: String {
        guard let uid = state.settings.inputDeviceUID else { return "System Default" }
        return inputDevices.first { $0.uid == uid }?.name
            ?? AudioInputDevices.device(forUID: uid)?.name
            ?? "System Default"
    }

    // MARK: Quick actions (four fixed square buttons under the mode title)

    private var quickActions: some View {
        // Only genuine menu-bar actions here. History lives under Recent's "See all", and modes are
        // switched right above in the mode row, so those navigation buttons were redundant.
        HStack(spacing: 8) {
            squareButton("Transcribe file", "waveform.badge.magnifyingglass") {
                NotificationCenter.default.post(name: .yapTranscribeFile, object: nil)
            }
            regenerateButton
            insertLastButton
        }
    }

    /// Types the most recent dictation into the app you were last using, straight from the menu
    /// bar. Grays out until there is something in History to insert.
    private var insertLastButton: some View {
        let last = state.history.records.first
        let busy = state.controller.insertLastBusy
        return squareButton(busy ? "Inserting\u{2026}" : "Insert last", "text.insert") {
            guard !busy, let text = last?.finalText else { return }
            AppDelegate.shared?.insertIntoLastApp(text)
        }
        .overlay(alignment: .topTrailing) {
            if busy { ProgressView().controlSize(.small).padding(6) }
        }
        .disabled(last == nil || busy)
        .opacity(last == nil ? 0.35 : 1)
        .help(last == nil ? "Nothing to insert yet - dictate something first"
                          : "Type your last dictation into the app you were just using")
    }

    private func squareButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18)).iconTint(Color.accentColor)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 62)
            .innerWell(radius: 11)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// Regenerate: opens the inline options page. A plain button (no nested menu), so the click
    /// always registers inside the popover. Disabled only while a regeneration is running.
    private var regenerateButton: some View {
        let busy = !state.controller.regeneratingIDs.isEmpty
        return squareButton("Regenerate", "arrow.clockwise") { showRegenerate = true }
            .disabled(busy)
            .help("Regenerate your last dictation, or rewrite selected text, in any mode")
    }

    // MARK: Regenerate options (inline page)

    /// Which source the user is regenerating. nil = still choosing between the two.
    private enum RegenTarget { case lastDictation, selection }
    @State private var regenTarget: RegenTarget?

    private var regenerateOptions: some View {
        let canLast = state.controller.canRegenerateLast
        return ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        // Step back one level: source page -> chooser -> main popover.
                        if regenTarget != nil { regenTarget = nil } else { showRegenerate = false }
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    Text(regenTarget == nil ? "Regenerate"
                         : regenTarget == .lastDictation ? "Most recent dictation" : "Selected text")
                        .font(.headline)
                    Spacer()
                }
                switch regenTarget {
                case nil:
                    // Step 1: pick WHAT to regenerate - two plain choices, nothing else.
                    VStack(spacing: 6) {
                        choiceCard("Most recent dictation", icon: "clock.arrow.circlepath",
                                   detail: canLast ? "Redo your last dictation in a different style"
                                                   : "Dictate something first",
                                   enabled: canLast) { regenTarget = .lastDictation }
                        choiceCard("Selected text", icon: "text.cursor",
                                   detail: "Rewrite whatever text is selected in your last app",
                                   enabled: true) { regenTarget = .selection }
                    }
                case .lastDictation:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Redo it as…").font(.caption).foregroundStyle(.secondary)
                            VStack(spacing: 2) {
                                ForEach(state.modeStore.allModes.filter { $0.usesAI }) { mode in
                                    optionRow(mode.name, mode.iconSystemName, enabled: canLast) {
                                        regenStartedAt = Date()
                                        launch(mode.name) { state.controller.regenerateLast(using: mode) }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: 330)
                case .selection:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Rewrite it as…").font(.caption).foregroundStyle(.secondary)
                                VStack(spacing: 2) {
                                    ForEach(state.modeStore.allModes.filter { $0.usesAI }) { mode in
                                        optionRow(mode.name, mode.iconSystemName, enabled: true) {
                                            launch(mode.name) { AppDelegate.shared?.regenerateSelection(using: mode) }
                                        }
                                    }
                                }
                            }
                            if !state.actions.actions.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Divider().opacity(0.4)
                                    Text("Or apply a one-shot edit").font(.caption).foregroundStyle(.secondary)
                                    VStack(spacing: 2) {
                                        ForEach(state.actions.actions) { action in
                                            optionRow(action.name, action.iconSystemName, enabled: true) {
                                                launch(action.name) { AppDelegate.shared?.regenerateSelection(applying: action) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: 330)
                }
            }
            .opacity(launching == nil ? 1 : 0)

            if let launching {
                workingCard(launching)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .onChange(of: showRegenerate) { if !showRegenerate { regenTarget = nil } }
    }

    /// A big friendly two-line choice used on the first regenerate step.
    private func choiceCard(_ title: String, icon: String, detail: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).iconTint(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    /// A brief, pretty confirmation shown right where the options were: a spinner and the mode
    /// name, held for a beat so the click lands with intent, then the popover fades closed and the
    /// actual work runs (which must switch apps to paste, so it can't run while the popover shows).
    private func workingCard(_ label: String) -> some View {
        VStack(spacing: 14) {
            // The signature condense: an idle wave folds through the gates into the
            // spinning ring - the app's own loader, same choreography as the panel.
            WaveformView(data: AudioVisualData(bands: 26), isActive: false,
                         style: state.settings.waveStyle, sucking: true, usesSharedClock: false)
                .frame(width: 200)
            Text("Regenerating as \(label)")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).frame(height: 220)
    }

    /// Play the confirmation, fade the popover out, then start the work. The two short delays let
    /// the "Regenerating…" card breathe and the NSPopover's own close animation finish before any
    /// app-switching happens, so the exit reads as a smooth fade instead of a spazzy snap.
    private func launch(_ label: String, run: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.22)) { launching = label }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            AppDelegate.shared?.closeMenuPopover()   // animated fade-out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                run()
                showRegenerate = false
                launching = nil
            }
        }
    }

    @ViewBuilder
    private func optionSection<C: View>(_ title: String, hint: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.5)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) { content() }
        }
    }

    private func optionRow(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).iconTint(Color.accentColor).frame(width: 18)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !state.history.records.isEmpty {
                    Button("See all") { openMainWindow(destination: .yapShowHistory) }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            if state.history.records.isEmpty {
                Text("No dictations yet. Press \(state.settings.hotkey.displayString) and start talking.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(state.history.records.prefix(3)) { record in
                    HStack(alignment: .top, spacing: 6) {
                        Text(record.finalText).font(.caption).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        iconButton("doc.on.doc", "Copy") { TextInserter.setClipboard(record.finalText) }
                            .font(.caption2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        // Left: the meta actions (quit, support). Right: the "go to the app" cluster, with Settings
        // in the far-right corner and Open the window right beside it. The brand app icon lives up
        // top in the header status row, not here.
        HStack(spacing: 16) {
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Quit YapToText")
            Button {
                NSApp.activate(ignoringOtherApps: true)
                SupportWindowController.shared.show(state: state)
            } label: {
                Image(systemName: "heart.fill").iconTint(.pink)
            }
            .buttonStyle(.plain).help("Support YapToText")
            Spacer()
            iconButton("macwindow", "Open the window") { openMainWindow(destination: .yapShowHome) }
            iconButton("gearshape", "Settings") { openMainWindow(destination: .yapShowSettings) }
        }
        .font(.body)
    }

    // MARK: Helpers

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// The menu bar is a separate scene, so opening the app means bringing the main window
    /// forward and asking ContentView to switch to the right destination.
    private func openMainWindow(destination: Notification.Name) {
        NSApp.activate(ignoringOtherApps: true)
        let existing = NSApp.windows.filter { $0.canBecomeMain }
        if existing.isEmpty {
            // The window was CLOSED and SwiftUI destroyed it - makeKeyAndOrderFront has nothing
            // to raise (this was "the menu bar buttons don't reopen the app"). A reopen event -
            // the same thing clicking the Dock icon sends - makes SwiftUI recreate the window.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration())
            // Give the new window a beat to exist before ContentView is asked to navigate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: destination, object: nil)
            }
            return
        }
        for window in existing { window.makeKeyAndOrderFront(nil) }
        NotificationCenter.default.post(name: destination, object: nil)
    }
}
