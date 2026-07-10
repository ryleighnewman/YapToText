import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    /// When the current regenerate was tapped, used to drive its progress ring.
    @State private var regenStartedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            modeInputRow
            quickActions
            Divider()
            recentSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .symbolRenderingMode(.hierarchical)
        .focusEffectDisabled()   // nothing pre-selected when the popover opens
        .containerBackground(.ultraThinMaterial, for: .window)
    }

    // MARK: Header (brand + the one action that matters)

    private var header: some View {
        HStack(spacing: 8) {
            Image("CapyGlyph")
                .renderingMode(.template).resizable().scaledToFit()
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
                        Button {
                            state.controller.selectMode(mode)
                        } label: {
                            Label("\(index + 1)   \(mode.name)",
                                  systemImage: mode.id == state.settings.activeModeID ? "checkmark" : mode.iconSystemName)
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
        return squareButton("Insert last", "text.insert") {
            if let text = last?.finalText { AppDelegate.shared?.insertIntoLastApp(text) }
        }
        .disabled(last == nil)
        .opacity(last == nil ? 0.45 : 1)
        .help(last == nil ? "Dictate something first" : "Type your last dictation into the previous app")
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

    /// Regenerate: expands to pick which mode to re-run the last dictation as; picking one
    /// regenerates in place (progress ring), then shows "Copied" - it's copied to the clipboard.
    /// Never starts recording. Disabled when there's nothing to regenerate.
    private var regenerateButton: some View {
        let busy = !state.controller.regeneratingIDs.isEmpty
        let copied = state.controller.lastRegeneratedID != nil && !busy
        let enabled = state.controller.canRegenerateLast
        let aiModes = state.modeStore.allModes.filter { $0.usesAI }
        // SINGLE CLICK opens the options (no hidden right-click): rewrite the selected text or
        // regenerate the last dictation, each through any mode. The label is built from the same
        // pieces as Transcribe file / Insert last so all three squares render identically.
        return Menu {
            Section("Selected text as:") {
                ForEach(aiModes) { mode in
                    Button {
                        AppDelegate.shared?.regenerateSelection(using: mode)
                    } label: { Label(mode.name, systemImage: mode.iconSystemName) }
                }
            }
            Section("Last dictation as:") {
                ForEach(aiModes) { mode in
                    Button {
                        regenStartedAt = Date()
                        state.controller.regenerateLast(using: mode)
                    } label: { Label(mode.name, systemImage: mode.iconSystemName) }
                }
            }
        } label: {
            VStack(spacing: 6) {
                if busy {
                    TimelineView(.periodic(from: regenStartedAt ?? .now, by: 0.08)) { timeline in
                        let elapsed = regenStartedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                        let pct = min(0.95, elapsed / 4.5)   // smooth estimate; snaps away when done
                        ZStack {
                            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                            Circle().trim(from: 0, to: pct)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(pct * 100))").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .frame(width: 22, height: 22)
                    }
                } else if copied {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).iconTint(.green)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 18))
                        .iconTint(Color.accentColor)
                        .opacity(enabled ? 1 : 0.45)
                }
                Text(busy ? "Working" : copied ? "Copied" : "Regenerate").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 62)
            .innerWell(radius: 11)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(busy || !enabled)
        .help(enabled ? "Rewrite your selected text, or regenerate the last dictation, in any mode"
                      : "Dictate something first to regenerate")
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
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: destination, object: nil)
    }
}
