import SwiftUI

/// The Quick Edit teaching content for onboarding: the real key row, the real card, and a
/// few example requests - select text, press the key, say what you want, like leaning over
/// to a person at the keyboard and telling them the edit out loud.
struct QuickEditTutorial: View {
    @Environment(AppState.self) private var state
    /// Compact spacing for the sheet; roomier inside onboarding.
    var compact = false

    var body: some View {
        @Bindable var settings = state.settings
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Text("Select text in any app, press your Quick Edit key, and say the change out loud, as if you were telling an editor at the keyboard. The edit lands in place.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            // The REAL key row, the same control the Quick Edit page uses: on or off, tap or
            // hold, and which key. Choices apply instantly.
            HStack(spacing: 8) {
                Image(systemName: "pencil.line").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                Text("Quick Edit key").font(.callout.weight(.medium))
                Toggle("", isOn: Binding(
                    get: { settings.quickEditTrigger != .off },
                    set: { on in
                        settings.quickEditTrigger = on ? settings.quickEditPreferredTrigger : .off
                        AppDelegate.shared?.reloadQuickEditKey()
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                if settings.quickEditTrigger != .off {
                    Picker("", selection: $settings.quickEditTrigger) {
                        ForEach(ModifierTrigger.allCases.filter { $0 != .off }) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                    .onChange(of: settings.quickEditTrigger) {
                        if settings.quickEditTrigger != .off { settings.quickEditPreferredTrigger = settings.quickEditTrigger }
                        AppDelegate.shared?.reloadQuickEditKey()
                    }
                }
                Spacer(minLength: 8)
                ModifierKeyRecorderField(key: $settings.quickEditTriggerKey, role: .quickEdit, onTurnOff: {
                    settings.quickEditTrigger = .off
                    AppDelegate.shared?.reloadQuickEditKey()
                })
                    .frame(width: 110, height: 24)
                    .disabled(settings.quickEditTrigger == .off)
                    .onChange(of: settings.quickEditTriggerKey) { AppDelegate.shared?.reloadQuickEditKey() }
            }
            Text(settings.quickEditTrigger == .off
                 ? "Off. Turn it on to edit selected text by voice with a key press."
                 : settings.quickEditTrigger == .pushToTalk
                 ? "Hold \(settings.quickEditTriggerKey.label) while you speak the change; release to apply."
                 : "Tap \(settings.quickEditTriggerKey.label) to start listening, tap again to apply.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The REAL Quick Edit card, cycling listening -> applying -> done in its own colors.
            QuickEditPopupPreview(settings: settings)

            VStack(alignment: .leading, spacing: 5) {
                exampleRow("\u{201C}Capitalize this word\u{201D}")
                exampleRow("\u{201C}Make this past tense\u{201D}")
                exampleRow("\u{201C}Make it sound more friendly\u{201D}")
                exampleRow("\u{201C}Add this to my dictionary\u{201D}", note: "so it's always spelled and capitalized this way")
            }
            .padding(10)
            .innerWell(radius: Metrics.sectionRadius)
        }
    }

    struct QuickEditDemo: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            TimelineView(.animation(minimumInterval: 0.5, paused: reduceMotion)) { timeline in
                // A 6-second loop in four beats: plain text -> word selected -> spoken command
                // appears -> the edit lands. Reduce Motion shows the finished frame only.
                let t = reduceMotion ? 5.0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6)
                let beat = Int(t / 1.5)   // 0 plain, 1 selected, 2 speaking, 3 edited
                VStack(alignment: .leading, spacing: 6) {
                    // The word is its OWN view so the selection highlight is sized by the
                    // rendered glyphs themselves - the old hand-tuned rect (76pt at x=92)
                    // drifted with font metrics and "selected" neighboring words too.
                    HStack(spacing: 0) {
                        Text("This report is ")
                        Text(beat >= 3 ? "IMPORTANT" : "important")
                            .fontWeight(beat >= 1 ? .semibold : .regular)
                            .foregroundColor(beat >= 3 ? .primary : (beat >= 1 ? Color.white : .primary))
                            .background {
                                if beat == 1 || beat == 2 {
                                    Color.accentColor.opacity(0.85)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        Text(" to me.")
                    }
                    .font(.callout)
                    HStack(spacing: 6) {
                        Image(systemName: beat == 2 ? "waveform" : "option")
                            .font(.caption).iconTint(Color.accentColor)
                        Text(beat >= 3 ? "Done." :
                             beat == 2 ? "\u{201C}Make this entire word in caps\u{201D}" :
                             beat == 1 ? "Hold Right Option\u{2026}" : "Select a word\u{2026}")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .innerWell(radius: Metrics.sectionRadius)
                .animation(.easeInOut(duration: 0.25), value: beat)
            }
        }
    }

    private func exampleRow(_ phrase: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform").font(.caption).iconTint(Color.accentColor)
            Text(phrase).font(.callout.weight(.medium))
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Appearance chooser shared by onboarding and the What's New sheet: the app accent, then
/// the REAL dictation pop-up and the REAL Quick Edit card, live, each with its own layout,
/// position, and color controls. Every choice applies instantly, so both flows are a real
/// "pick what you want" moment, not a description.
struct AppearanceQuickPicker: View {
    @Environment(AppState.self) private var state
    /// Live demo: until the user clicks ANYTHING, the accent color cycles through the presets
    /// on its own so the styles show themselves - nobody should have to guess from swatches.
    /// The first click stops the show and keeps whatever the user chose; leaving without
    /// choosing restores the color they came in with.
    @State private var autoCycling = true
    @State private var cycleTask: Task<Void, Never>?
    @State private var originalAccentHex: String??
    enum Which: Hashable { case dictation, quickEdit }
    @State private var which: Which = .dictation

    var body: some View {
        @Bindable var settings = state.settings
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App accent").font(.callout)
                Spacer()
                Button {
                    choose { settings.accentColorHex = nil }
                } label: {
                    Text("System").font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.secondary.opacity(settings.accentColorHex == nil ? 0.25 : 0.1), in: Capsule())
                }
                .buttonStyle(.plain).help("Follow the system accent color")
                presetRow(selected: settings.accentColorHex) { hex in choose { settings.accentColorHex = hex } }
                ColorPicker("", selection: Binding(
                    get: { state.settings.customAccent ?? .accentColor },
                    set: { c in choose { settings.accentColorHex = c.hexString } }),
                            supportsOpacity: false)
                    .labelsHidden().controlSize(.small).help("Pick any color")
            }

            Picker("", selection: $which) {
                Text("Dictation pop-up").tag(Which.dictation)
                Text("Quick Edit card").tag(Which.quickEdit)
            }
            .pickerStyle(.segmented).labelsHidden()

            if which == .dictation {
                // The real recording panel, in the layout and position chosen right here.
                DictationPopupPreview(settings: settings)
                HStack(spacing: 12) {
                    Picker("Layout", selection: Binding(
                        get: { settings.panelStyle },
                        set: { v in choose { settings.panelStyle = v } })) {
                        ForEach(PanelStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Position", selection: Binding(
                        get: { settings.panelPosition },
                        set: { v in choose { settings.panelPosition = v; settings.panelDraggedX = nil; settings.panelDraggedY = nil } })) {
                        ForEach(PanelPosition.allCases) { Text($0.label).tag($0) }
                    }
                }
                .font(.callout)
                Picker("Pop-up background", selection: Binding(
                    get: { settings.panelTintStyle },
                    set: { v in choose { settings.panelTintStyle = v } })) {
                    ForEach(PanelTintStyle.allCases) { Text($0.label).tag($0) }
                }
                .font(.callout)
                if settings.panelTintStyle == .custom {
                    HStack {
                        Text("Background color").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        presetRow(selected: settings.panelTintHex) { hex in choose { settings.panelTintHex = hex } }
                        ColorPicker("", selection: Binding(
                            get: { state.settings.panelTint ?? .blue },
                            set: { c in choose { settings.panelTintHex = c.hexString } }), supportsOpacity: false)
                            .labelsHidden().controlSize(.small)
                    }
                }
                // The third colour: the wave itself, separate from the app accent and from the
                // glass it floats on - with its own vividness dial and RGB controls.
                Picker("Pop-up waveform", selection: Binding(
                    get: { settings.waveColorStyle },
                    set: { v in choose { settings.waveColorStyle = v } })) {
                    ForEach(WaveColorStyle.allCases) { Text($0.label).tag($0) }
                }
                .font(.callout)
                if settings.waveColorStyle == .custom {
                    HStack {
                        Text("Wave color").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        presetRow(selected: settings.waveColorHex) { hex in choose { settings.waveColorHex = hex } }
                        ColorPicker("", selection: Binding(
                            get: { state.settings.waveTint ?? state.settings.customAccent ?? .accentColor },
                            set: { c in choose { settings.waveColorHex = c.hexString } }),
                                    supportsOpacity: false)
                            .labelsHidden().controlSize(.small).help("Pick any color")
                    }
                }
                HStack {
                    Text("Wave strength").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { settings.waveStrength },
                                          set: { v in choose { settings.waveStrength = v } }), in: 0.15...1)
                }
                if settings.waveColorStyle == .rgb {
                    HStack {
                        Text("RGB speed").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { settings.waveRGBSpeed },
                                              set: { v in choose { settings.waveRGBSpeed = v } }), in: 0.2...3)
                    }
                    HStack {
                        Text("RGB spread").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { settings.waveRGBSpread },
                                              set: { v in choose { settings.waveRGBSpread = v } }), in: 0...0.33)
                    }
                }
            } else {
                // The real Quick Edit card, cycling through its stages in its own colors.
                QuickEditPopupPreview(settings: settings)
                Picker("Card background", selection: Binding(
                    get: { settings.quickEditTintStyle },
                    set: { v in choose { settings.quickEditTintStyle = v } })) {
                    ForEach(PanelTintStyle.allCases) { Text($0.label).tag($0) }
                }
                .font(.callout)
                if settings.quickEditTintStyle == .custom {
                    HStack {
                        Text("Background color").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        presetRow(selected: settings.quickEditTintHex) { hex in choose { settings.quickEditTintHex = hex } }
                        ColorPicker("", selection: Binding(
                            get: { state.settings.quickEditTintHex.flatMap { Color(hexString: $0) } ?? .purple },
                            set: { c in choose { settings.quickEditTintHex = c.hexString } }), supportsOpacity: false)
                            .labelsHidden().controlSize(.small)
                    }
                }
                Picker("Card waveform", selection: Binding(
                    get: { settings.quickEditWaveColorStyle },
                    set: { v in choose { settings.quickEditWaveColorStyle = v } })) {
                    ForEach(WaveColorStyle.allCases) { Text($0.label).tag($0) }
                }
                .font(.callout)
                if settings.quickEditWaveColorStyle == .custom {
                    HStack {
                        Text("Wave color").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        presetRow(selected: settings.quickEditWaveColorHex) { hex in choose { settings.quickEditWaveColorHex = hex } }
                        ColorPicker("", selection: Binding(
                            get: { state.settings.quickEditWaveColorHex.flatMap { Color(hexString: $0) } ?? .purple },
                            set: { c in choose { settings.quickEditWaveColorHex = c.hexString } }), supportsOpacity: false)
                            .labelsHidden().controlSize(.small)
                    }
                }
                HStack {
                    Text("Wave strength").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { settings.quickEditWaveStrength },
                                          set: { v in choose { settings.quickEditWaveStrength = v } }), in: 0.15...1)
                }
                Text("Its own colors, so an edit never looks like a dictation. Position, snap-back, and more live on the Quick Edit page.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            HStack {
                Picker("Menu bar icon", selection: Binding(
                    get: { settings.menuBarIconStyle },
                    set: { v in choose { settings.menuBarIconStyle = v; AppDelegate.shared?.refreshStatusIcon() } })) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.label).tag($0) }
                }
                .font(.callout)
            }
            Text("Change these any time: the accent in Settings, the pop-ups on the Dictation and Quick Edit pages.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .onAppear {
            originalAccentHex = settings.accentColorHex
            cycleTask = Task { @MainActor in
                let presets = GeneralSettingsView.accentPresets
                var i = 0
                while !Task.isCancelled && autoCycling {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    guard !Task.isCancelled && autoCycling else { break }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        settings.accentColorHex = presets[i % presets.count].hex
                    }
                    i += 1
                }
            }
        }
        .onDisappear {
            cycleTask?.cancel()
            if autoCycling, let original = originalAccentHex {
                settings.accentColorHex = original   // no choice made: leave things as they were
            }
        }
    }

    /// The six preset dots, highlighting the one that matches `selected`.
    private func presetRow(selected: String?, pick: @escaping (String) -> Void) -> some View {
        ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
            Button { pick(preset.hex) } label: {
                Circle().fill(preset.color).frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.primary.opacity(selected == preset.hex ? 0.6 : 0), lineWidth: 1.5))
            }
            .buttonStyle(.plain).help(preset.name)
        }
    }

    /// A real user choice: stop the demo for good, then apply what they picked.
    private func choose(_ apply: () -> Void) {
        autoCycling = false
        cycleTask?.cancel()
        apply()
    }
}

/// One-time "here's what's new" sheet for people who already finished onboarding, shown once
/// per app version (Changelog.currentVersion is the key). It's a small PAGED flow - a welcome
/// page introducing this release's features, then further pages that slide in (this release:
/// the appearance customization) - and the same infrastructure carries future updates: add a
/// page, update the copy, done.
struct WhatsNewView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if page == 0 { featuresPage } else { appearancePage }

            HStack {
                if page == 1 {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.25)) { page = 0 } }
                }
                Spacer()
                if page == 0 {
                    Button("Make it yours") { withAnimation(.easeInOut(duration: 0.25)) { page = 1 } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onReceive(NotificationCenter.default.publisher(for: .init("yapDebugWhatsNewPage"))) { note in
            if let p = note.object as? Int { page = p }
        }
        .onDisappear {
            state.settings.lastSeenWhatsNewVersion = Changelog.whatsNewKey
        }
    }

    /// The pop-ups, live, with their new controls: the same chooser onboarding uses.
    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make it yours").font(.title2.weight(.bold))
            Text("The dictation pop-up and the Quick Edit card each have their own layout, position, and colors now. Try them here; everything applies instantly.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AppearanceQuickPicker()
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AnimatedCapy(size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to version \(Changelog.currentVersion)").font(.title2.weight(.bold))
                    Text("Here's what's new since your last update.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let latest = Changelog.entries.first {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(latest.points.prefix(10), id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{2022}").foregroundStyle(.secondary)
                            Text(point).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("The full list is under the version number on the Home page.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(12)
                .innerWell(radius: Metrics.sectionRadius)
            }
        }
    }

}
