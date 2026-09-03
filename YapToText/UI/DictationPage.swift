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

                CardSection("Microphone") {
                    Toggle("Reduce background noise", isOn: $settings.reduceBackgroundNoise)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("Auto-amplify quiet speech", isOn: $settings.autoAmplifyInput)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption("Whisper-quiet speech is lifted to full clarity automatically; both run entirely on device.")
                    }
                    InputVolumeNotice()
                }

                CardSection("Delivery") {
                    Toggle("Insert text automatically", isOn: $settings.autoInsert)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("Adapt to the surrounding text", isOn: $settings.adaptToSurroundings)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("Pause music and video while dictating", isOn: $settings.pauseMediaDuringDictation)
                        .toggleStyle(.switch).controlSize(.small)
                    SubOptions {
                        Caption("Mid-sentence dictation matches the capitalization and spacing around the cursor. Playback resumes at full quality when you finish.")
                        if settings.adaptToSurroundings { BeepNotice() }
                    }
                }

                HStack(spacing: 4) {
                    Caption("Every remaining option - insertion method, sounds, languages, energy - lives in")
                    Button("Settings") {
                        NotificationCenter.default.post(name: .yapShowDestination, object: "settings")
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 4)
            }
            .padding(Space.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dictation")
    }
}
