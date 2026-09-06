import SwiftUI

/// The dedicated "Dictation" page: the general dictation controls in one place -
/// trigger keys, cancel behavior, microphone conditioning, and how finished text is
/// delivered. Deeper or rarely-touched options stay in Settings.
struct DictationPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                CardSection("Keys") {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                        Text("Dictation key")
                        Picker("", selection: $settings.rightCommandTrigger) {
                            ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: settings.rightCommandTrigger) { AppDelegate.shared?.reloadRightCommandTrigger() }
                        Spacer(minLength: 8)
                        ModifierKeyRecorderField(key: $settings.primaryTriggerKey, onTurnOff: {
                            settings.rightCommandTrigger = .off
                            AppDelegate.shared?.reloadRightCommandTrigger()
                        })
                            .frame(width: 110, height: 24)
                            .onChange(of: settings.primaryTriggerKey) { AppDelegate.shared?.reloadRightCommandTrigger() }
                    }
                    Toggle("Require pressing Escape twice to cancel", isOn: $settings.doubleEscapeToCancel)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption(settings.doubleEscapeToCancel
                                ? "Escape asks for a second press within a moment before discarding a dictation."
                                : "One press of Escape cancels the dictation immediately.")
                    }
                }

                CardSection("Recording") {
                    SettingSlider("Auto-stop after silence", value: $settings.silenceTimeout, range: 0...5, step: 0.5,
                                  display: settings.silenceTimeout == 0 ? "Off" : String(format: "%.1fs", settings.silenceTimeout))
                    SettingSlider("Maximum length", value: $settings.maxRecordingSeconds, range: 0...300, step: 15,
                                  display: settings.maxRecordingSeconds == 0 ? "Off" : "\(Int(settings.maxRecordingSeconds))s")
                    Toggle("Pause music and video while dictating", isOn: $settings.pauseMediaDuringDictation)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption("App-wide defaults; any mode can override the timings in its editor. Playback pauses when dictation starts and resumes at full quality when it ends.")
                    }
                }

                CardSection("Microphone") {
                    Toggle("Reduce background noise", isOn: $settings.reduceBackgroundNoise)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("Auto-amplify quiet speech", isOn: $settings.autoAmplifyInput)
                        .toggleStyle(.switch).controlSize(.small)
                        .onChange(of: settings.autoAmplifyInput) { InputLevelMonitor.shared.autoAmplify = settings.autoAmplifyInput }
                    SubOptions {
                        Caption("Whisper-quiet speech is lifted to full clarity automatically; both run entirely on device. The input device, level meter, and boost are in Settings.")
                    }
                    InputVolumeNotice()
                }

                CardSection("Delivery") {
                    Toggle("Insert text automatically", isOn: $settings.autoInsert)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("Adapt to the surrounding text", isOn: $settings.adaptToSurroundings)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption(settings.adaptToSurroundings
                                ? "Mid-sentence dictation matches the capitalization and spacing around the cursor, and a closing period is dropped when the sentence continues."
                                : "Text is inserted exactly as transcribed, regardless of what surrounds the cursor.")
                        if settings.adaptToSurroundings { BeepNotice() }
                    }
                }

                CardSection("Pop-up") {
                    if settings.showRecordingPanel {
                        // The real panel, live: layout, position anchoring, and colors as set below.
                        DictationPopupPreview(settings: settings)
                    }
                    Toggle("Show the floating recording panel", isOn: $settings.showRecordingPanel).toggleStyle(.switch).controlSize(.small)
                        .onChange(of: settings.showRecordingPanel) { AppDelegate.shared?.reloadPanelVisibility() }
                    if settings.showRecordingPanel {
                        SubOptions {
                            Picker("Layout", selection: $settings.panelStyle) {
                                ForEach(PanelStyle.allCases) { Text($0.label).tag($0) }
                            }
                            .onChange(of: settings.panelStyle) { AppDelegate.shared?.refreshPanelSize() }
                            HStack {
                                Picker("Position", selection: $settings.panelPosition) {
                                    ForEach(PanelPosition.allCases) { Text($0.label).tag($0) }
                                }
                                .onChange(of: settings.panelPosition) { forgetPanelDrag(settings) }
                                Button("Show pop-up") { AppDelegate.shared?.previewRecordingPanel() }
                                    .buttonStyle(.solidSecondary).controlSize(.small)
                            }
                            Toggle("Snap back to this position", isOn: $settings.panelSnapsBack)
                                .toggleStyle(.switch).controlSize(.small)
                            Caption(settings.panelSnapsBack
                                    ? "The pop-up returns here for every dictation, even after you drag it."
                                    : "The pop-up stays wherever you drag it, across dictations and launches.")
                            if !settings.panelSnapsBack, settings.panelDraggedX != nil {
                                Button("Reset position") { forgetPanelDrag(settings) }
                                    .buttonStyle(.solidSecondary).controlSize(.small)
                            }
                            Caption("The panel has pause, stop, and cancel buttons while you dictate.")
                        }
                    }
                }

                CardSection("Pop-up colors") {
                    Caption("The pop-up above follows every change here as you make it.")
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

                LinkCaption("Every remaining option - insertion method, input device, sounds, backup shortcuts - lives in [Settings](yap://settings).")
                .padding(.horizontal, 4)
            }
            .padding(Space.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dictation")
    }

    private func forgetPanelDrag(_ settings: AppSettings) {
        settings.panelDraggedX = nil
        settings.panelDraggedY = nil
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

    private var panelTintBinding: Binding<Color> {
        Binding(
            get: { state.settings.panelTint ?? .blue },
            set: { state.settings.panelTintHex = $0.hexString }
        )
    }
}

    /// The pop-up color cards' living thumbnail of a pop-up: a real WaveformView fed
    /// synthesized "speech" (nothing is recorded), on a material card washed with the chosen tint.
struct PanelTintPreview: View {
    enum Source { case dictation, quickEdit }
    let settings: AppSettings
    var source: Source = .dictation
    @State private var fake = AudioVisualData(bands: 26)
    @State private var driver: Task<Void, Never>?
    /// Rainbow glass in the thumbnail: integrated per tick like the live panels, so the RGB
    /// speed slider changes pace instead of jumping to a random hue.
    @State private var rgbPhase = 0.0
    @State private var rgbTick = 0

    private var rainbowOn: Bool { source == .dictation ? settings.panelTintStyle == .rainbow : settings.quickEditTintStyle == .rainbow }
    private var rgbSpeed: Double { source == .dictation ? settings.panelRGBSpeed : settings.quickEditRGBSpeed }
    private var tint: Color? {
        _ = rgbTick
        if rainbowOn {
            guard strength > 0.01 else { return nil }
            let h = rgbPhase.truncatingRemainder(dividingBy: 1)
            return Color(hue: h < 0 ? h + 1 : h, saturation: 0.85, brightness: 1)
        }
        return source == .dictation ? settings.panelTint : settings.quickEditTint
    }
    private var strength: Double { source == .dictation ? settings.panelTintStrength : settings.quickEditTintStrength }
    private var style: WaveStyle { source == .dictation ? settings.waveStyle : settings.quickEditWaveStyle }

    var body: some View {
        WaveformView(data: fake, isActive: true, scale: 0.8,
                     style: style)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
                    if let tint {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(tint.opacity(0.12 + 0.38 * min(max(strength, 0), 1)))
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
                    var i = 0
                    while !Task.isCancelled {
                        i += 1
                        if rainbowOn {
                            rgbPhase += 0.033 * rgbSpeed / 12
                            if i % 3 == 0 { rgbTick &+= 1 }   // 10 Hz re-resolve of the wash
                        }
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

/// A labelled slider with its value readout, shared by the Dictation page and Settings.
struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) {
        self.title = title; self._value = value; self.range = range; self.step = step; self.display = display
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }
}
