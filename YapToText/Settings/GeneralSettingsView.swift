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
                // GROUP 1 - starting and stopping. Every field: click to record, right-click
                // for Clear / Reset. One visual grammar for every shortcut on this page.
                HStack {
                    Text("Dictation key")
                    Spacer()
                    ModifierKeyRecorderField(key: $settings.primaryTriggerKey, onTurnOff: {
                        settings.rightCommandTrigger = .off
                        AppDelegate.shared?.reloadRightCommandTrigger()
                    })
                        .frame(width: 110, height: 24)
                        .onChange(of: settings.primaryTriggerKey) { AppDelegate.shared?.reloadRightCommandTrigger() }
                }
                SubOptions {
                    Picker("It responds to", selection: $settings.rightCommandTrigger) {
                        ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: settings.rightCommandTrigger) { AppDelegate.shared?.reloadRightCommandTrigger() }
                }
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
                Toggle("Require pressing Escape twice to cancel", isOn: $settings.doubleEscapeToCancel)
                    .toggleStyle(.switch).controlSize(.small)

                Divider().opacity(0.25).padding(.vertical, 6)

                // GROUP 2 - editing by voice.
                HStack {
                    Text("Quick Edit key")
                    Spacer()
                    Picker("", selection: $settings.quickEditTrigger) {
                        ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: settings.quickEditTrigger) { AppDelegate.shared?.reloadQuickEditKey() }
                    ModifierKeyRecorderField(key: $settings.quickEditTriggerKey, role: .quickEdit, onTurnOff: {
                        settings.quickEditTrigger = .off
                        AppDelegate.shared?.reloadQuickEditKey()
                    })
                        .frame(width: 110, height: 24)
                        .onChange(of: settings.quickEditTriggerKey) { AppDelegate.shared?.reloadQuickEditKey() }
                }
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

            CardSection("Recording") {
                slider("Auto-stop after silence", value: $settings.silenceTimeout, range: 0...5, step: 0.5,
                       display: settings.silenceTimeout == 0 ? "Off" : String(format: "%.1fs", settings.silenceTimeout))
                slider("Maximum length", value: $settings.maxRecordingSeconds, range: 0...300, step: 15,
                       display: settings.maxRecordingSeconds == 0 ? "Off" : "\(Int(settings.maxRecordingSeconds))s")
                Caption("These are the app-wide defaults. Any mode can override them in its editor.")
                Toggle("Pause music and video while dictating", isOn: $settings.pauseMediaDuringDictation)
                    .toggleStyle(.switch).controlSize(.small)
                SubOptions {
                    Caption("Playback pauses when dictation starts and resumes when it ends.")
                }
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
                Toggle("Reduce background noise", isOn: $settings.reduceBackgroundNoise)
                    .toggleStyle(.switch).controlSize(.small)
                if settings.reduceBackgroundNoise {
                    SubOptions {
                        Caption("Noisy recordings are conditioned before transcription: speech is measured against the room, lifted to a clean level, and decoded with a deeper search. Runs entirely in the app, so other apps' audio is never touched.")
                    }
                }
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
                        Toggle("Snap back to this position", isOn: $settings.panelSnapsBack)
                            .toggleStyle(.switch).controlSize(.small)
                        Caption(settings.panelSnapsBack
                                ? "The pop-up returns here for every dictation, even after you drag it."
                                : "The pop-up stays wherever you drag it.")
                        Caption("The panel has pause, stop, and cancel buttons while you dictate.")
                    }
                }
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
                }
                // Live miniature of the pop-up: animates freely (fake audio, no listening) and
                // reflects every tint change the moment it's made.
                PanelTintPreview(settings: settings)
                Picker("Pop-up background color", selection: $settings.panelTintStyle) {
                    ForEach(PanelTintStyle.allCases) { Text($0.label).tag($0) }
                }
                if settings.panelTintStyle != .off {
                    SubOptions {
                        if settings.panelTintStyle == .custom {
                            HStack {
                                Text("Color").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                ColorPicker("", selection: panelTintBinding, supportsOpacity: false)
                                    .labelsHidden().controlSize(.small)
                            }
                        }
                        HStack {
                            Text("Strength").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.panelTintStrength, in: 0.05...1)
                        }
                        if settings.panelTintStyle == .rainbow {
                            HStack {
                                Text("RGB speed").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $settings.panelRGBSpeed, in: 0.2...3)
                            }
                        }
                        if settings.panelTintStyle != .rainbow {
                            Caption(settings.panelTintStyle == .accent
                                    ? "The panel's glass is washed with your accent color."
                                    : "Washes the floating recording panel's glass with this color. The next time the panel appears, it uses the new tint.")
                        }
                    }
                }
                // THIRD colour: the wave itself, independent of both the app accent and the
                // glass behind it - so the ribbons can sing against their own background.
                Picker("Pop-up waveform color", selection: $settings.waveColorStyle) {
                    ForEach(WaveColorStyle.allCases) { Text($0.label).tag($0) }
                }
                SubOptions {
                    if settings.waveColorStyle == .custom {
                        HStack {
                            Text("Color").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
                                Button {
                                    settings.waveColorHex = preset.hex
                                } label: {
                                    Circle().fill(preset.color).frame(width: 16, height: 16)
                                        .overlay(Circle().strokeBorder(.primary.opacity(
                                            settings.waveColorHex == preset.hex ? 0.6 : 0), lineWidth: 1.5))
                                }
                                .buttonStyle(.plain).help(preset.name)
                            }
                            ColorPicker("", selection: waveColorBinding, supportsOpacity: false)
                                .labelsHidden().controlSize(.small).help("Pick any color")
                        }
                    }
                    HStack {
                        Text("Strength").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.waveStrength, in: 0.15...1)
                    }
                    if settings.waveColorStyle == .rgb {
                        HStack {
                            Text("RGB speed").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.waveRGBSpeed, in: 0.2...3)
                        }
                        HStack {
                            Text("RGB spread").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.waveRGBSpread, in: 0...0.33)
                        }
                    }
                    Caption(settings.waveColorStyle == .rgb
                            ? "The ribbons ride the spectrum. Speed sets the cycle rate; spread fans the ribbons apart in hue - all the way down pulses the whole wave as one colour."
                            : settings.waveColorStyle == .accent
                            ? "The wave follows your app accent color. Strength sets how vivid the ribbons are."
                            : "The wave uses this color and its neighbouring shades. Strength sets how vivid the ribbons are.")
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

    private var waveColorBinding: Binding<Color> {
        Binding(
            get: {
                if let c = state.settings.waveTint { return c }
                return state.settings.customAccent ?? .accentColor
            },
            set: { state.settings.waveColorHex = $0.hexString }
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

    private var panelTintBinding: Binding<Color> {
        Binding(
            get: { state.settings.panelTint ?? .blue },
            set: { state.settings.panelTintHex = $0.hexString }
        )
    }

    /// The Appearance card's living thumbnail of the recording pop-up: a real WaveformView fed
    /// synthesized "speech" (nothing is recorded), on a material card washed with the chosen tint.
    struct PanelTintPreview: View {
        let settings: AppSettings
        @State private var fake = AudioVisualData(bands: 26)
        @State private var driver: Task<Void, Never>?

        var body: some View {
            WaveformView(data: fake, isActive: true, scale: 0.8,
                         style: settings.waveStyle)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
                        if let tint = settings.panelTint {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(tint.opacity(0.12 + 0.38 * min(max(settings.panelTintStrength, 0), 1)))
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.8))
                .onAppear {
                    driver?.cancel()
                    driver = Task { @MainActor in
                        // Lively synthetic speech at 30fps, only while this card is visible.
                        // The old rhythm sat at ZERO for half of a ~7s cycle (it read as a
                        // static line); this one always breathes - a constant floor with
                        // overlapping fast bursts, so the preview visibly dances the whole time.
                        var t = 0.0
                        while !Task.isCancelled {
                            let pulse: Double = 0.5 + 0.5 * sin(t * 2.3)
                            let chatter: Double = 0.5 + 0.5 * sin(t * 6.1 + 1.3)
                            let burst: Double = 0.25 + 0.75 * pulse * chatter
                            fake.level = Float(0.2 + 0.6 * burst)
                            var bands = [Float](repeating: 0, count: 26)
                            for i in 0..<26 {
                                let u: Double = Double(i) / 25.0
                                let shape: Double = sin(u * .pi)
                                let ripple: Double = 0.55 + 0.45 * sin(t * 7.0 + u * 11.0)
                                let floorGlow: Double = 0.12 * shape
                                bands[i] = Float(max(0.0, floorGlow + burst * shape * ripple))
                            }
                            fake.spectrum = bands
                            try? await Task.sleep(nanoseconds: 33_000_000)
                            t += 0.033
                        }
                    }
                }
                .onDisappear { driver?.cancel(); driver = nil }
                .accessibilityHidden(true)
        }
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
