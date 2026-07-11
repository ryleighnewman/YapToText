import SwiftUI

/// The deeper preferences, split out of General so the everyday page stays scannable: output
/// plumbing, per-app overrides, history retention, and backups.
struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        SettingsPage {
            CardSection("Text output") {
                Toggle("Live transcription preview", isOn: $settings.livePreviewEnabled).toggleStyle(.switch).controlSize(.small)
                SubOptions {
                    Caption("Shows your words in the panel while you speak. With Whisper models this runs extra passes of the model during recording; turn it off to save battery.")
                }
                Toggle("Insert text automatically", isOn: $settings.autoInsert).toggleStyle(.switch).controlSize(.small)
                SubOptions {
                    if settings.autoInsert {
                        Picker("Method", selection: $settings.insertionMethod) {
                            ForEach(InsertionMethod.allCases) { Text($0.label).tag($0) }
                        }
                        if settings.insertionMethod != .clipboardOnly, !state.permissions.accessibilityGranted {
                            Caption("Automatic pasting needs the Accessibility permission. Until it's granted, dictations are copied to the clipboard instead. Grant it on the Home page.")
                        }
                        if settings.insertionMethod == .paste {
                            Picker("Afterwards, the clipboard keeps", selection: $settings.restoreClipboard) {
                                Text("What I had copied before").tag(true)
                                Text("The dictated text").tag(false)
                            }
                            Caption(settings.restoreClipboard
                                    ? "Your original clipboard, even images and files, is put back after the paste."
                                    : "The dictated text stays on the clipboard so you can paste it again.")
                        }
                    } else {
                        Caption("Each dictation is copied to the clipboard instead of being typed.")
                    }
                }
                Toggle("Trim trailing whitespace", isOn: $settings.trimTrailingNewlines).toggleStyle(.switch).controlSize(.small)
                Toggle("End each dictation with a space", isOn: $settings.appendSpaceAfterInsert).toggleStyle(.switch).controlSize(.small)
                SubOptions {
                    Caption("So back-to-back dictations don't run together. History keeps the text without the extra space.")
                }
                Caption("App-wide defaults. Each mode can override the method and trimming in its Output section.")
            }

            PerAppModesSection()


            CardSection("Your name") {
                TextField("e.g. Ryleigh", text: $settings.userName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .innerWell(radius: 7)
                Caption("Used to sign your emails and personalize AI formatting. AI modes sign off with this instead of writing \u{201C}[Your Name]\u{201D}. Leave blank to skip sign-offs.")
            }

            CardSection("AI cleanup") {
                Caption("AI formatting is decided by the mode you pick. AI modes (Clean Up, Email, Note, Message) rewrite your transcript; Raw Transcription inserts your exact words. Switch modes any time, including mid-dictation with the number keys.")
            }

            CardSection("Energy") {
                Picker("Keep models in memory", selection: $settings.modelCooldownSeconds) {
                    Text("Only while dictating").tag(0)
                    Text("10 seconds after use").tag(10)
                    Text("30 seconds after use").tag(30)
                    Text("2 minutes after use").tag(120)
                    Text("15 minutes after use").tag(900)
                    Text("Until quit").tag(-1)
                }
                Caption("Loaded speech and AI models answer instantly but hold memory. Unloading sooner saves energy and memory; the next dictation after an unload takes a few extra seconds while the model reloads. \u{201C}Only while dictating\u{201D} is the deepest saver.")
            }

            CardSection("History & audio") {
                Toggle("Save dictation history", isOn: $settings.saveHistory)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.saveHistory) {
                        if settings.saveHistory, settings.historyRetention == .off {
                            settings.historyRetention = .all
                            state.history.applyRetention(.all)
                        }
                    }
                SubOptions {
                    if settings.saveHistory {
                        Picker("Keep", selection: $settings.historyRetention) {
                            ForEach([HistoryRetention.all, .last500, .last100, .sessionOnly]) { Text($0.label).tag($0) }
                        }
                        .onChange(of: settings.historyRetention) { state.history.applyRetention(settings.historyRetention) }
                        Toggle("Also save the audio recording", isOn: $settings.saveAudio).toggleStyle(.switch).controlSize(.small)
                        if settings.saveAudio {
                            SubOptions {
                                Caption("Audio stays on your Mac in the app's data folder and can be replayed from History.")
                            }
                        }
                        Toggle("Clear history when I quit", isOn: $settings.clearHistoryOnQuit).toggleStyle(.switch).controlSize(.small)
                        Picker("Auto-delete old items", selection: $settings.autoDeleteDays) {
                            Text("Never").tag(0)
                            Text("After 7 days").tag(7)
                            Text("After 30 days").tag(30)
                            Text("After 90 days").tag(90)
                        }
                    } else {
                        Caption("Dictations are used once and never stored.")
                    }
                }
            }

            CardSection("Backup & sharing") {
                HStack {
                    TipRow(icon: "square.and.arrow.up", title: "Share your whole setup",
                           message: "Everything you've configured: modes, dictionaries, commands, AI actions, and settings. History is never included.")
                    Spacer()
                    VStack(spacing: 6) {
                        Button("Export Preset…") { PresetPorter.export() }.buttonStyle(.solidSecondary).controlSize(.small)
                        Button("Import Preset…") { PresetPorter.importPreset() }.buttonStyle(.solidSecondary).controlSize(.small)
                    }
                }
            }

        }
        .navigationTitle("Advanced")
    }
}
