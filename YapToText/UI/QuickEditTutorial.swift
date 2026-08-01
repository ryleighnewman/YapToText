import SwiftUI

/// The Quick Edit teaching content, shared by the onboarding step and the What's New sheet
/// so both always tell the same story: select text, hold Right Option, say what you want -
/// like leaning over to a person at the keyboard and telling them the edit out loud.
struct QuickEditTutorial: View {
    @Environment(AppState.self) private var state
    /// Compact spacing for the sheet; roomier inside onboarding.
    var compact = false

    var body: some View {
        @Bindable var settings = state.settings
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 10) {
                Image(systemName: "option")
                    .font(.system(size: 22, weight: .semibold))
                    .iconTint(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select text in any application and hold the Right Option key. Say the change out loud - as if you're talking to a personal editor. Release the key, and it automatically edits your text.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            QuickEditDemo()

            Text("It's like telling a person at the keyboard exactly what to do:")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                exampleRow("\u{201C}Capitalize this word\u{201D}")
                exampleRow("\u{201C}Make this entire word in caps\u{201D}")
                exampleRow("\u{201C}Make this past tense\u{201D}")
                exampleRow("\u{201C}Make it sound more friendly\u{201D}")
                exampleRow("\u{201C}Add this to my dictionary\u{201D}", note: "so it's always spelled and capitalized this way")
            }
            .padding(10)
            .innerWell(radius: Metrics.sectionRadius)

            HStack {
                Text("Quick Edit key")
                Spacer()
                Picker("", selection: $settings.quickEditTrigger) {
                    ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                .onChange(of: settings.quickEditTrigger) { AppDelegate.shared?.reloadQuickEditKey() }
                ModifierKeyRecorderField(key: $settings.quickEditTriggerKey, role: .quickEdit, onTurnOff: {
                    settings.quickEditTrigger = .off
                    AppDelegate.shared?.reloadQuickEditKey()
                })
                    .frame(width: 110, height: 24)
                    .onChange(of: settings.quickEditTriggerKey) { AppDelegate.shared?.reloadQuickEditKey() }
            }
            Text("On by default. Click the field to bind a different key. Option shortcuts and accented characters still work normally.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

/// Compact appearance chooser shared by onboarding and the What's New sheet: accent color
/// presets plus the pop-up accent style, with the live pop-up preview. Every choice applies
/// instantly, so both flows are a real "pick what you want" moment, not a description.
struct AppearanceQuickPicker: View {
    @Environment(AppState.self) private var state
    /// Live demo: until the user clicks ANYTHING, the accent color cycles through the presets
    /// on its own so the styles show themselves - nobody should have to guess from swatches.
    /// The first click stops the show and keeps whatever the user chose; leaving without
    /// choosing restores the color they came in with.
    @State private var autoCycling = true
    @State private var cycleTask: Task<Void, Never>?
    @State private var originalAccentHex: String??

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
                ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
                    Button {
                        choose { settings.accentColorHex = preset.hex }
                    } label: {
                        Circle().fill(preset.color).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.primary.opacity(
                                settings.accentColorHex == preset.hex ? 0.6 : 0), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain).help(preset.name)
                }
                ColorPicker("", selection: Binding(
                    get: { state.settings.customAccent ?? .accentColor },
                    set: { c in choose { settings.accentColorHex = c.hexString } }),
                            supportsOpacity: false)
                    .labelsHidden().controlSize(.small).help("Pick any color")
            }
            GeneralSettingsView.PanelTintPreview(settings: settings)
            Picker("Pop-up background", selection: Binding(
                get: { settings.panelTintStyle },
                set: { v in choose { settings.panelTintStyle = v } })) {
                ForEach(PanelTintStyle.allCases) { Text($0.label).tag($0) }
            }
            .font(.callout)
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
                    ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
                        Button {
                            choose { settings.waveColorHex = preset.hex }
                        } label: {
                            Circle().fill(preset.color).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.primary.opacity(
                                    settings.waveColorHex == preset.hex ? 0.6 : 0), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain).help(preset.name)
                    }
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
            HStack {
                Picker("Menu bar icon", selection: Binding(
                    get: { settings.menuBarIconStyle },
                    set: { v in choose { settings.menuBarIconStyle = v; AppDelegate.shared?.refreshStatusIcon() } })) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.label).tag($0) }
                }
                .font(.callout)
            }
            Text("Change these any time in Settings \u{2192} Appearance.")
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
    private let pageCount = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                if page == 0 {
                    featuresPage
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    appearancePage
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .animation(.spring(duration: 0.45), value: page)

            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                            .frame(width: i == page ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                Button(page < pageCount - 1 ? "Continue" : "Done") {
                    if page < pageCount - 1 { page += 1 } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onDisappear {
            state.settings.lastSeenWhatsNewVersion = Changelog.currentVersion
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

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .iconTint(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Make it yours").font(.title2.weight(.bold))
                    Text("New in this update: pick your colors.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            AppearanceQuickPicker()
        }
    }
}
