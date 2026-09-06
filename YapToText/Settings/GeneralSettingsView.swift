import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state
    /// Green "it's over here" glow on the Shortcuts card, fired by the Home page's
    /// Edit binding links. Fades out on its own.
    @State private var highlightShortcuts = false

    var body: some View {
        @Bindable var settings = state.settings
        let startStop = Binding<KeyCombo?>(
            get: { settings.hotkey },
            set: { if let combo = $0 { settings.hotkey = combo } })   // never cleared (allowsEmpty: false)
        SettingsPage {
            CardSection("Shortcuts") {
                // The dictation key and the Quick Edit key live on their own pages, where their
                // behavior is explained; this card holds everything else, one visual grammar.
                LinkCaption("The dictation key is on the [Dictation page](yap://dictation) and the Quick Edit key on the [Quick Edit page](yap://quickEdit).")
                hotkeyRow("Backup shortcut", combo: startStop, allowsEmpty: false,
                          defaultCombo: .default,
                          onChange: { AppDelegate.shared?.reloadHotkey() })
                SubOptions {
                    Picker("Backup behavior", selection: $settings.hotkeyBehavior) {
                        ForEach(HotkeyBehavior.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: settings.hotkeyBehavior) { AppDelegate.shared?.reloadHotkey() }
                }
                if !state.mainHotkeyActive {
                    Caption("That shortcut is already in use by another app. Pick a different one.")
                }
                if settings.rightCommandTrigger != .off, !state.permissions.accessibilityGranted {
                    Caption("The dictation key needs Accessibility. Grant it on the Home screen; the backup works without it.")
                }
                Divider().opacity(0.25).padding(.vertical, 6)

                // GROUP 2 - editing by voice.
                hotkeyRow("Redo last dictation", combo: $settings.redoLastHotkey, allowsEmpty: true,
                          onChange: { AppDelegate.shared?.reloadRedoHotkey() })

                Divider().opacity(0.25).padding(.vertical, 6)

                // GROUP 3 - while dictating.
                hotkeyRow("Pause / resume", combo: $settings.pauseHotkey, allowsEmpty: true,
                          placeholder: "Space (default)",
                          onChange: { AppDelegate.shared?.reloadPauseHotkey() })
                hotkeyRow("Cycle mode", combo: $settings.cycleModeHotkey, allowsEmpty: true,
                          onChange: { AppDelegate.shared?.reloadCycleHotkey() })
                Toggle("Number keys switch modes", isOn: $settings.digitModeSwitching)
                    .toggleStyle(.switch).controlSize(.small)
                Toggle("Esc cancels dictation", isOn: $settings.cancelOnDoubleEscape)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.cancelOnDoubleEscape) { AppDelegate.shared?.reloadCancelKey() }

                Divider().opacity(0.25).padding(.vertical, 6)

                // GROUP 4 - afterwards.
                hotkeyRow("Paste recent dictation", combo: $settings.historyPaletteHotkey, allowsEmpty: true,
                          onChange: { AppDelegate.shared?.reloadHistoryHotkey() })
                Caption("Click any field and press keys to record; right-click it to clear or reset.")
            }
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous)
                    .stroke(LinearGradient(colors: [.green, .mint],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2.5)
                    .shadow(color: .green.opacity(0.45), radius: 10)
                    .opacity(highlightShortcuts ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(.easeInOut(duration: 0.5), value: highlightShortcuts)
            .onReceive(NotificationCenter.default.publisher(for: .yapHighlightShortcuts)) { _ in
                highlightShortcuts = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    highlightShortcuts = false
                }
            }

            CardSection("Auto mode") {
                Toggle("Adapt to what you're saying", isOn: $settings.autoContextMode)
                    .toggleStyle(.switch).controlSize(.small)
                if settings.autoContextMode, settings.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                    SubOptions {
                        Text("One thing Auto mode needs: your name, so emails are signed by you and never with a made-up placeholder.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NameCaptureField()
                    }
                }
                Caption("Each dictation gets the right treatment on its own: emails become emails, chat stays as spoken. End with \u{201C}make that formal\u{201D} to steer it, or select text first for a fitting reply.")
                Button("Edit it here") {
                    NotificationCenter.default.post(name: .yapShowMode, object: BuiltInModes.auto.id)
                }
                .buttonStyle(.link).font(.caption)
            }

            CardSection("Microphone") {
                Picker("Input source", selection: $settings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(AudioInputDevices.all()) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .onChange(of: settings.inputDeviceUID) {
                    // The meter below must follow the pick, or the page looks like it never updated.
                    InputLevelMonitor.shared.deviceUID = settings.inputDeviceUID
                    InputLevelMonitor.shared.restart()
                }
                Caption("Which microphone YapToText listens to. If the chosen one is unplugged, it falls back to the system default.")
                Text("Live input level").font(.caption).foregroundStyle(.secondary)
                LiveInputMeter()   // isolated observer - only the bar re-renders
                MicHealthReadout() // live SNR verdict + guidance, same render isolation
                InputVolumeNotice()
                Toggle("Keep the microphone warm", isOn: $settings.keepMicWarm)
                    .toggleStyle(.switch).controlSize(.small)
                SubOptions {
                    if settings.keepMicWarm {
                        HStack {
                            Text("Stay warm for").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.micWarmMinutes, in: 1...30, step: 1)
                            Text("\(Int(settings.micWarmMinutes)) min").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        Caption("Ready instantly for the next dictation. The mic indicator stays on while warm.")
                    } else {
                        Caption("The mic shuts off after each dictation; the next one may miss the first second.")
                    }
                }
                LinkCaption("Noise reduction and auto-amplify are on the [Dictation page](yap://dictation).")
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
                InputLevelMonitor.shared.deviceUID = settings.inputDeviceUID
                InputLevelMonitor.shared.start()
            }
            .onDisappear { InputLevelMonitor.shared.stop() }

            CardSection("Sounds") {
                Toggle("Play start and stop sounds", isOn: $settings.playSounds).toggleStyle(.switch).controlSize(.small)
                if settings.playSounds {
                    SubOptions {
                        soundPicker("Start sound", $settings.soundStart)
                        soundPicker("Stop sound", $settings.soundStop)
                        soundPicker("Error sound", $settings.soundError)
                        Caption("Picking a sound plays it, so you can audition each one.")
                    }
                }
            }

            CardSection("Appearance") {
                HStack {
                    Text("App accent color")
                    Spacer()
                    ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
                        Button {
                            settings.accentColorHex = preset.hex
                        } label: {
                            Circle().fill(preset.color).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.primary.opacity(
                                    settings.accentColorHex == preset.hex ? 0.6 : 0), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain).help(preset.name)
                    }
                    ColorPicker("", selection: accentBinding, supportsOpacity: false)
                        .labelsHidden().controlSize(.small).help("Pick any color")
                }
                SubOptions {
                    Caption(settings.accentColorHex == nil
                            ? "Buttons and highlights follow your system accent color."
                            : "Buttons and highlights use your custom color everywhere in the app.")
                    if settings.accentColorHex != nil {
                        Button("Use the system accent") { settings.accentColorHex = nil }
                            .buttonStyle(.solidSecondary).controlSize(.small)
                    }
                    LinkCaption("The pop-up's layout, position, and colors are on the [Dictation page](yap://dictation).")
                }
            }

            CardSection("System") {
                Toggle("Launch YapToText at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.launchAtLogin) { LaunchAtLogin.set(settings.launchAtLogin) }
                Picker("Menu bar icon", selection: $settings.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.menuBarIconStyle) { AppDelegate.shared?.refreshStatusIcon() }
                Toggle("Colored status in the menu bar", isOn: $settings.menuBarColoredStatus)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.menuBarColoredStatus) { AppDelegate.shared?.refreshStatusIcon() }
                SubOptions {
                    Caption(settings.menuBarColoredStatus
                            ? "The icon tints with the dictation state: red while recording, green on insert."
                            : "The icon stays monochrome in every state and adapts to the menu bar.")
                    if settings.menuBarIconStyle == .waveform, settings.menuBarColoredStatus {
                        HStack {
                            Text("Visualizer color")
                            Spacer()
                            if settings.visualizerColorHex != nil {
                                Button("Match accent") {
                                    settings.visualizerColorHex = nil
                                    AppDelegate.shared?.refreshStatusIcon()
                                }
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                            }
                            ColorPicker("", selection: visualizerColorBinding, supportsOpacity: false)
                                .labelsHidden().controlSize(.small)
                        }
                        Caption(settings.visualizerColorHex == nil
                                ? "The live bars use your accent color. Pick any color to override it."
                                : "The live bars use this color.")
                    }
                }
                HStack(spacing: 12) {
                    permissionPill(granted: state.permissions.microphoneGranted, on: "Microphone", off: "Microphone needed")
                    permissionPill(granted: state.permissions.accessibilityGranted, on: "Accessibility on", off: "Accessibility needed to paste", optional: true)
                    Spacer()
                    Button("Review setup") { NotificationCenter.default.post(name: .yapShowHome, object: nil) }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
        }
        .navigationTitle("Preferences")
        .onAppear { state.permissions.refresh() }
    }

    // MARK: Appearance helpers

    static let accentPresets: [(name: String, hex: String, color: Color)] = [
        ("Blue", "#0A84FF", Color(hexString: "#0A84FF") ?? .blue),
        ("Purple", "#BF5AF2", Color(hexString: "#BF5AF2") ?? .purple),
        ("Pink", "#FF375F", Color(hexString: "#FF375F") ?? .pink),
        ("Orange", "#FF9F0A", Color(hexString: "#FF9F0A") ?? .orange),
        ("Green", "#30D158", Color(hexString: "#30D158") ?? .green),
        ("Teal", "#64D2FF", Color(hexString: "#64D2FF") ?? .teal),
    ]

    private var accentBinding: Binding<Color> {
        Binding(
            get: { state.settings.customAccent ?? .accentColor },
            set: { state.settings.accentColorHex = $0.hexString }
        )
    }


    private var visualizerColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = state.settings.visualizerColorHex, let c = Color(hexString: hex) { return c }
                return state.settings.customAccent ?? .accentColor
            },
            set: {
                state.settings.visualizerColorHex = $0.hexString
                AppDelegate.shared?.refreshStatusIcon()
            }
        )
    }


    private func soundPicker(_ label: String, _ selection: Binding<String>) -> some View {
        Picker(label, selection: Binding(
            get: { selection.wrappedValue },
            set: { selection.wrappedValue = $0; Sound.preview($0) }   // choosing = hearing
        )) {
            ForEach(Sound.options, id: \.self) { Text($0).tag($0) }
        }
    }

    private func hotkeyRow(_ title: String, combo: Binding<KeyCombo?>, allowsEmpty: Bool,
                           placeholder: String = "Not set",
                           defaultCombo: KeyCombo? = nil,
                           onChange: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            HotkeyRecorderField(combo: combo, allowsEmpty: allowsEmpty, placeholder: placeholder,
                                defaultCombo: defaultCombo)
                .frame(width: 110, height: 24)
                .onChange(of: combo.wrappedValue) { onChange() }
                .accessibilityLabel("\(title) shortcut")
                .accessibilityValue(combo.wrappedValue?.displayString ?? "Not set")
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
