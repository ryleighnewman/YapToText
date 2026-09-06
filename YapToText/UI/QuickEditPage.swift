import SwiftUI

/// The dedicated "Quick Edit" page: everything about editing text by voice - the key
/// and whether it is on, spoken corrections after a dictation, where the pop-up appears
/// and its own colors, the model that applies the edits, and how the flow works.
struct QuickEditPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                CardSection("How it works", subtitle: "Select text anywhere, press your Quick Edit key, and say the change.") {
                    QuickEditTutorial.QuickEditDemo()
                    Caption("Works with rewrites (\u{201C}make this formal\u{201D}), fixes (\u{201C}capitalize this\u{201D}), and \u{201C}add this to my dictionary\u{201D} to teach spellings forever.")
                }

                CardSection("Key") {
                    Toggle("Quick Edit key", isOn: Binding(
                        get: { settings.quickEditTrigger != .off },
                        set: { on in
                            settings.quickEditTrigger = on ? settings.quickEditPreferredTrigger : .off
                            AppDelegate.shared?.reloadQuickEditKey()
                        }))
                        .toggleStyle(.switch).controlSize(.small)
                    if settings.quickEditTrigger != .off {
                        SubOptions {
                            HStack(spacing: 8) {
                                Image(systemName: "pencil.line").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                                Text("Responds to")
                                Picker("", selection: $settings.quickEditTrigger) {
                                    ForEach(ModifierTrigger.allCases.filter { $0 != .off }) { Text($0.label).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                                .onChange(of: settings.quickEditTrigger) {
                                    if settings.quickEditTrigger != .off { settings.quickEditPreferredTrigger = settings.quickEditTrigger }
                                    AppDelegate.shared?.reloadQuickEditKey()
                                }
                                Spacer(minLength: 8)
                                ModifierKeyRecorderField(key: $settings.quickEditTriggerKey, role: .quickEdit, onTurnOff: {
                                    settings.quickEditTrigger = .off
                                    AppDelegate.shared?.reloadQuickEditKey()
                                })
                                    .frame(width: 110, height: 24)
                                    .onChange(of: settings.quickEditTriggerKey) { AppDelegate.shared?.reloadQuickEditKey() }
                            }
                            Caption(settings.quickEditTrigger == .pushToTalk
                                    ? "Hold the key while you speak the change; release to apply. Double-tap to cancel a running edit."
                                    : "Tap to start listening, tap again to apply. Double-tap to cancel a running edit.")
                        }
                    } else {
                        SubOptions {
                            Caption("Turn it on to edit selected text by voice with a key press.")
                        }
                    }
                }

                CardSection("Corrections by voice") {
                    Toggle("Fix a dictation by speaking again", isOn: $settings.quickEditDetection)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption(settings.quickEditDetection
                                ? "Right after text lands, \u{201C}scratch that\u{201D} removes it and \u{201C}replace X with Y\u{201D} fixes it, no key needed. Only an exact whole phrase counts, within 30 seconds."
                                : "Spoken phrases like \u{201C}scratch that\u{201D} are inserted as ordinary text.")
                        if settings.quickEditDetection, !settings.autoInsert {
                            Caption("Needs Insert text automatically, which is off on the Dictation page.")
                        }
                    }
                }

                CardSection("Position") {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.bottomthird.inset.filled").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                        Text("Pop-up opens at")
                        Picker("", selection: $settings.quickEditPosition) {
                            ForEach(PanelPosition.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: settings.quickEditPosition) {
                            settings.quickEditDraggedX = nil
                            settings.quickEditDraggedY = nil
                            if QuickEditWindow.shared.isPreviewing { QuickEditWindow.shared.preview() }
                        }
                        Spacer(minLength: 8)
                        Button("Show pop-up") { QuickEditWindow.shared.preview() }
                            .buttonStyle(.solidSecondary).controlSize(.small)
                    }
                    Toggle("Snap back to this position", isOn: $settings.quickEditSnapsBack)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption(settings.quickEditSnapsBack
                                ? "The pop-up opens here every time, even after you drag it."
                                : "The pop-up stays wherever you drag it, across edits and launches.")
                        if !settings.quickEditSnapsBack, settings.quickEditDraggedX != nil {
                            Button("Reset position") {
                                settings.quickEditDraggedX = nil
                                settings.quickEditDraggedY = nil
                                if QuickEditWindow.shared.isPreviewing { QuickEditWindow.shared.preview() }
                            }
                            .buttonStyle(.solidSecondary).controlSize(.small)
                        }
                    }
                }

                CardSection("Pop-up colors") {
                    // The real card, cycling listening -> applying -> done, in its own colors.
                    QuickEditPopupPreview(settings: settings)
                    Picker("Card background color", selection: $settings.quickEditTintStyle) {
                        ForEach(PanelTintStyle.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.quickEditTintStyle != .off {
                        SubOptions {
                            if settings.quickEditTintStyle == .custom {
                                HStack {
                                    Text("Color").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
                                        Button { settings.quickEditTintHex = preset.hex } label: {
                                            Circle().fill(preset.color).frame(width: 16, height: 16)
                                                .overlay(Circle().strokeBorder(.primary.opacity(
                                                    settings.quickEditTintHex == preset.hex ? 0.6 : 0), lineWidth: 1.5))
                                        }
                                        .buttonStyle(.plain).help(preset.name)
                                    }
                                    ColorPicker("", selection: quickEditTintBinding, supportsOpacity: false)
                                        .labelsHidden().controlSize(.small).help("Pick any color")
                                }
                            }
                            HStack {
                                Text("Strength").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $settings.quickEditTintStrength, in: 0.05...1)
                            }
                            if settings.quickEditTintStyle == .rainbow {
                                HStack {
                                    Text("RGB speed").font(.caption).foregroundStyle(.secondary)
                                    Slider(value: $settings.quickEditRGBSpeed, in: 0.2...3)
                                }
                            }
                        }
                    }
                    Picker("Card waveform color", selection: $settings.quickEditWaveColorStyle) {
                        ForEach(WaveColorStyle.allCases) { Text($0.label).tag($0) }
                    }
                    SubOptions {
                        if settings.quickEditWaveColorStyle == .custom {
                            HStack {
                                Text("Color").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                ForEach(GeneralSettingsView.accentPresets, id: \.hex) { preset in
                                    Button { settings.quickEditWaveColorHex = preset.hex } label: {
                                        Circle().fill(preset.color).frame(width: 16, height: 16)
                                            .overlay(Circle().strokeBorder(.primary.opacity(
                                                settings.quickEditWaveColorHex == preset.hex ? 0.6 : 0), lineWidth: 1.5))
                                    }
                                    .buttonStyle(.plain).help(preset.name)
                                }
                                ColorPicker("", selection: quickEditWaveColorBinding, supportsOpacity: false)
                                    .labelsHidden().controlSize(.small).help("Pick any color")
                            }
                        }
                        HStack {
                            Text("Strength").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.quickEditWaveStrength, in: 0.15...1)
                        }
                        if settings.quickEditWaveColorStyle == .rgb {
                            HStack {
                                Text("RGB speed").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $settings.quickEditWaveRGBSpeed, in: 0.2...3)
                            }
                            HStack {
                                Text("RGB spread").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $settings.quickEditWaveRGBSpread, in: 0...0.33)
                            }
                        }
                        Caption("These colors belong to the Quick Edit card alone, so it never looks like a dictation. Purple out of the box.")
                        Button("Match the dictation pop-up") {
                            settings.quickEditTintStyle = settings.panelTintStyle
                            settings.quickEditTintHex = settings.panelTintHex
                            settings.quickEditTintStrength = settings.panelTintStrength
                            settings.quickEditRGBSpeed = settings.panelRGBSpeed
                            settings.quickEditWaveColorStyle = settings.waveColorStyle
                            settings.quickEditWaveColorHex = settings.waveColorHex
                            settings.quickEditWaveStrength = settings.waveStrength
                            settings.quickEditWaveRGBSpeed = settings.waveRGBSpeed
                            settings.quickEditWaveRGBSpread = settings.waveRGBSpread
                        }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                    }
                }

                CardSection("Intelligence") {
                    // Only models that are actually ON DISK are offered - picking a model
                    // that isn't downloaded would silently fall back and confuse.
                    let downloaded = state.models.languageModels.filter {
                        state.models.downloads.localURL(for: $0) != nil
                    }
                    Picker("Model for edits", selection: Binding(
                        get: {
                            let id = settings.quickEditModelID ?? ""
                            return downloaded.contains(where: { $0.id == id }) ? id : ""
                        },
                        set: { settings.quickEditModelID = $0.isEmpty ? nil : $0 })) {
                        Text("Same as dictation").tag("")
                        ForEach(downloaded) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    SubOptions {
                        Caption(settings.quickEditModelID == nil
                                ? "Edits use the same on-device model as dictation cleanup."
                                : "Edits use this model; dictation cleanup keeps its own.")
                        LinkCaption("Want a different model? [Download more in AI Models](yap://models).")
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Quick Edit")
    }

    private var quickEditTintBinding: Binding<Color> {
        Binding(
            get: { state.settings.quickEditTintHex.flatMap { Color(hexString: $0) } ?? .purple },
            set: { state.settings.quickEditTintHex = $0.hexString }
        )
    }

    private var quickEditWaveColorBinding: Binding<Color> {
        Binding(
            get: { state.settings.quickEditWaveColorHex.flatMap { Color(hexString: $0) } ?? state.settings.customAccent ?? .accentColor },
            set: { state.settings.quickEditWaveColorHex = $0.hexString }
        )
    }
}
