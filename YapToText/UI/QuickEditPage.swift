import SwiftUI

/// The dedicated "Quick Edit" page: everything about editing selected text by voice -
/// the trigger, the model that applies the edits, and how the flow works.
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
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.line").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                        Text("Quick Edit key")
                        Picker("", selection: $settings.quickEditTrigger) {
                            ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: settings.quickEditTrigger) { AppDelegate.shared?.reloadQuickEditKey() }
                        Spacer(minLength: 8)
                        ModifierKeyRecorderField(key: $settings.quickEditTriggerKey, role: .quickEdit, onTurnOff: {
                            settings.quickEditTrigger = .off
                            AppDelegate.shared?.reloadQuickEditKey()
                        })
                            .frame(width: 110, height: 24)
                            .onChange(of: settings.quickEditTriggerKey) { AppDelegate.shared?.reloadQuickEditKey() }
                    }
                    SubOptions {
                        Caption(settings.quickEditTrigger == .pushToTalk
                                ? "Hold the key while you speak the change; release to apply. Double-tap to cancel a running edit."
                                : settings.quickEditTrigger == .toggle
                                ? "Tap to start listening, tap again to apply. Double-tap to cancel a running edit."
                                : "Quick Edit is off.")
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
                        HStack(spacing: 4) {
                            Caption("Want a different model?")
                            Button("Download more in AI Models") {
                                NotificationCenter.default.post(name: .yapShowDestination, object: "models")
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Quick Edit")
    }
}
