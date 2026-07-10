import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        let startStop = Binding<KeyCombo?>(
            get: { settings.hotkey },
            set: { if let combo = $0 { settings.hotkey = combo } })   // never cleared (allowsEmpty: false)
        SettingsPage {
            CardSection("Shortcuts") {
                // ONE trigger concept: Right Command is THE way to start and stop. The keyboard
                // combo underneath is its clearly-labelled backup (it works even before
                // Accessibility is granted), not a second competing start/stop control.
                Picker(selection: $settings.rightCommandTrigger) {
                    ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Start / stop: Right \u{2318} key")
                }
                .onChange(of: settings.rightCommandTrigger) { AppDelegate.shared?.reloadRightCommandTrigger() }
                SubOptions {
                    if settings.rightCommandTrigger != .off {
                        Caption(state.permissions.accessibilityGranted
                                ? "A lone tap of Right Command controls dictation. Keyboard shortcuts that use it still work normally."
                                : "Needs Accessibility permission to watch the key. Grant it on the Home screen.")
                    }
                    hotkeyRow("Backup shortcut", combo: startStop, allowsEmpty: false,
                              onChange: { AppDelegate.shared?.reloadHotkey() },
                              reset: { settings.hotkey = .default; AppDelegate.shared?.reloadHotkey() })
                    Picker("Backup behavior", selection: $settings.hotkeyBehavior) {
                        ForEach(HotkeyBehavior.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: settings.hotkeyBehavior) { AppDelegate.shared?.reloadHotkey() }
                    Caption("The backup starts and stops dictation too, and works even without Accessibility.")
                }
                hotkeyRow("Pause / resume", combo: $settings.pauseHotkey, allowsEmpty: true,
                          placeholder: "Space (default)",
                          onChange: { AppDelegate.shared?.reloadPauseHotkey() })
                SubOptions {
                    Caption("Space pauses and resumes by default while you're dictating. It's captured only during a recording, so it never types a space into your document. Record a combo here to also pause from anywhere.")
                }
                hotkeyRow("Cycle mode", combo: $settings.cycleModeHotkey, allowsEmpty: true,
                          onChange: { AppDelegate.shared?.reloadCycleHotkey() })
                Caption("While dictating, number keys 1-9 pick the post-processing mode. Press 2 mid-sentence and the finished text comes out in mode 2's format. The digit is captured, so it never types into your document.")
                hotkeyRow("Insert recent dictation", combo: $settings.historyPaletteHotkey, allowsEmpty: true,
                          onChange: { AppDelegate.shared?.reloadHistoryHotkey() })
                Caption("Click a field, then press the keys you want. Delete clears it; Esc cancels.")
                Toggle("Esc cancels dictation", isOn: $settings.cancelOnDoubleEscape)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.cancelOnDoubleEscape) { AppDelegate.shared?.reloadCancelKey() }
                if settings.cancelOnDoubleEscape {
                    SubOptions {
                        Caption("While dictating, Esc is captured by YapToText and won't reach the app underneath. It cancels and discards the dictation. Nothing is inserted or saved.")
                    }
                }
                if !state.mainHotkeyActive {
                    Caption("That shortcut is already in use by another app. Pick a different one.")
                }
            }

            CardSection("Recording") {
                slider("Auto-stop after silence", value: $settings.silenceTimeout, range: 0...5, step: 0.5,
                       display: settings.silenceTimeout == 0 ? "Off" : String(format: "%.1fs", settings.silenceTimeout))
                slider("Maximum length", value: $settings.maxRecordingSeconds, range: 0...300, step: 15,
                       display: settings.maxRecordingSeconds == 0 ? "Off" : "\(Int(settings.maxRecordingSeconds))s")
                Caption("These are the app-wide defaults. Any mode can override them in its editor.")
            }

            CardSection("Microphone") {
                Picker("Input source", selection: $settings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(AudioInputDevices.all()) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                Caption("Which microphone YapToText listens to. If the chosen one is unplugged, it falls back to the system default.")
                Text("Live input level").font(.caption).foregroundStyle(.secondary)
                LiveInputMeter()   // isolated observer - only the bar re-renders
                Toggle("Auto-amplify quiet speech", isOn: $settings.autoAmplifyInput)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.autoAmplifyInput) { InputLevelMonitor.shared.autoAmplify = settings.autoAmplifyInput }
                SubOptions {
                    Caption("Automatically raises the gain when you speak softly, so even whispering gets picked up, and eases off when you're loud.")
                }
                HStack(spacing: Space.m) {
                    Text("Input boost").frame(width: 84, alignment: .leading)
                    Slider(value: $settings.inputGain, in: 1...12)
                        .onChange(of: settings.inputGain) { InputLevelMonitor.shared.gain = Float(settings.inputGain) }
                    Text(String(format: "%.1f\u{00D7}", settings.inputGain))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                Caption("Speak now and watch the meter. Raise the boost until normal speech reaches the green-to-yellow zone without sitting in the red.")
            }
            .onAppear {
                InputLevelMonitor.shared.gain = Float(settings.inputGain)
                InputLevelMonitor.shared.autoAmplify = settings.autoAmplifyInput
                InputLevelMonitor.shared.start()
            }
            .onDisappear { InputLevelMonitor.shared.stop() }

            CardSection("Pop-up") {
                Toggle("Show the floating recording panel", isOn: $settings.showRecordingPanel).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.showRecordingPanel) { AppDelegate.shared?.reloadPanelVisibility() }
                if settings.showRecordingPanel {
                    SubOptions {
                        Picker("Layout", selection: $settings.panelStyle) {
                            ForEach(PanelStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .onChange(of: settings.panelStyle) { AppDelegate.shared?.refreshPanelSize() }
                        Picker("Position", selection: $settings.panelPosition) {
                            ForEach(PanelPosition.allCases) { Text($0.label).tag($0) }
                        }
                        Caption("The panel has pause, stop, and cancel buttons while you dictate.")
                    }
                }
                Toggle("Play start and stop sounds", isOn: $settings.playSounds).toggleStyle(.switch).controlSize(.small)
            }

            CardSection("System") {
                Toggle("Launch YapToText at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.launchAtLogin) { LaunchAtLogin.set(settings.launchAtLogin) }
                HStack(spacing: 12) {
                    permissionPill(granted: state.permissions.microphoneGranted, on: "Microphone", off: "Microphone needed")
                    permissionPill(granted: state.permissions.accessibilityGranted, on: "Accessibility on", off: "Accessibility optional", optional: true)
                    Spacer()
                    Button("Review setup") { NotificationCenter.default.post(name: .yapShowHome, object: nil) }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
        }
        .navigationTitle("Preferences")
        .onAppear { state.permissions.refresh() }
    }

    private func hotkeyRow(_ title: String, combo: Binding<KeyCombo?>, allowsEmpty: Bool,
                           placeholder: String = "Not set",
                           onChange: @escaping () -> Void, reset: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            HotkeyRecorderField(combo: combo, allowsEmpty: allowsEmpty, placeholder: placeholder)
                .frame(width: 150, height: 24)
                .onChange(of: combo.wrappedValue) { onChange() }
                .accessibilityLabel("\(title) shortcut")
                .accessibilityValue(combo.wrappedValue?.displayString ?? "Not set")
            if let reset {
                Button { reset() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).controlSize(.small).help("Reset to default")
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    private func permissionPill(granted: Bool, on: String, off: String, optional: Bool = false) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(granted ? Color.green : (optional ? Color.secondary.opacity(0.5) : Color.orange))
                .frame(width: 7, height: 7)
            Text(granted ? on : off).font(.caption).foregroundStyle(.secondary)
        }
    }
}
