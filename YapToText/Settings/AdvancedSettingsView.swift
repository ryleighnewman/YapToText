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
                    Caption("Shows your words while you speak. Costs extra battery with Whisper models.")
                }
                Toggle("Insert text automatically", isOn: $settings.autoInsert).toggleStyle(.switch).controlSize(.small)
                if settings.autoInsert {
                    Toggle("Type text live as you speak", isOn: $settings.liveTyping)
                        .toggleStyle(.switch).controlSize(.small)
                    if settings.liveTyping {
                        SubOptions {
                            Caption("Words are typed at the cursor while you're still talking; AI modes swap in the polished version at the end. Needs Accessibility.")
                        }
                    }
                }
                if settings.autoInsert {
                    Toggle("Review before inserting", isOn: $settings.reviewBeforeInsert)
                        .toggleStyle(.switch).controlSize(.small)
                    if settings.reviewBeforeInsert {
                        SubOptions {
                            Caption("Finished text lands in a floating editor first: \u{2318}Return inserts, Esc discards.")
                            Toggle("Only for long dictations (200+ characters)", isOn: $settings.reviewLongTextOnly)
                                .toggleStyle(.switch).controlSize(.small)
                            Caption(settings.reviewLongTextOnly
                                    ? "Short phrases insert instantly; long ones - where a silent wrong guess really hurts - stop for a look first."
                                    : "Every dictation stops in the review buffer, no matter how short.")
                        }
                    }
                    Toggle("Quick edits by voice", isOn: $settings.quickEditDetection)
                        .toggleStyle(.switch).controlSize(.small)
                    if settings.quickEditDetection {
                        SubOptions {
                            Caption("Right after an insert, \u{201C}scratch that\u{201D} removes it and \u{201C}replace X with Y\u{201D} fixes it. Only exact whole phrases count.")
                        }
                    }
                }
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
                        Toggle("Adapt to the surrounding text", isOn: $settings.adaptToSurroundings)
                            .toggleStyle(.switch).controlSize(.small)
                        Caption(settings.adaptToSurroundings
                                ? "Inserting mid-sentence lowercases the first word, fixes spacing, and drops a closing period when the sentence continues."
                                : "Text is inserted exactly as transcribed, regardless of what surrounds the cursor.")
                        if settings.adaptToSurroundings { BeepNotice() }
                    } else {
                        Caption("Each dictation is copied to the clipboard instead of being typed.")
                    }
                    if settings.autoInsert {
                        appMethodOverrides
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
                                FolderCaption(prefix: "Audio stays on your Mac in the app's ",
                                              linkText: "data folder",
                                              url: AudioStore.directory,
                                              suffix: " and can be replayed from History.")
                            }
                        }
                        Toggle("Record cancelled dictations", isOn: $settings.recordCancelledDictations).toggleStyle(.switch).controlSize(.small)
                        if settings.recordCancelledDictations {
                            SubOptions {
                                Caption("When you cancel a dictation, its transcript is still saved to History. It is never inserted into an app.")
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

    /// Per-app insertion pins: some apps mishandle simulated paste (or typing) - the user can
    /// pin whichever method actually works there, and it wins over the mode and global choice.
    private var appMethodOverrides: some View {
        @Bindable var settings = state.settings
        return VStack(alignment: .leading, spacing: 6) {
            Text("Per-app method").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Caption("Pin paste or type for apps that reject the default; the pin wins for that app.")
            ForEach(settings.appInsertionOverrides.keys.sorted(), id: \.self) { bundleID in
                HStack(spacing: 8) {
                    AppIconView(bundleID: bundleID)
                    Text(AppCatalog.name(for: bundleID)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.appInsertionOverrides[bundleID] ?? .paste },
                        set: { settings.appInsertionOverrides[bundleID] = $0 }
                    )) {
                        ForEach(InsertionMethod.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 190)
                    Button {
                        settings.appInsertionOverrides.removeValue(forKey: bundleID)
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove this override")
                }
            }
            Menu {
                ForEach(AppCatalog.runningApps().filter { settings.appInsertionOverrides[$0.bundleID] == nil }, id: \.bundleID) { app in
                    Button(app.name) { settings.appInsertionOverrides[app.bundleID] = .type }
                }
            } label: {
                Label("Add App Override", systemImage: "plus")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}
