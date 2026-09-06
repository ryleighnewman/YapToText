import SwiftUI

/// The deeper preferences, split out of General so the everyday page stays scannable: output
/// plumbing, per-app overrides, history retention, and backups.
struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmRestore = false
    @State private var confirmErase = false

    var body: some View {
        @Bindable var settings = state.settings
        SettingsPage {
            CardSection("Text output") {
                Toggle("Live transcription preview", isOn: $settings.livePreviewEnabled).toggleStyle(.switch).controlSize(.small)
                SubOptions {
                    Caption("Shows your words while you speak. Costs extra battery with Whisper models.")
                }
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
                    } else {
                        LinkCaption("Insert text automatically is off, so each dictation is copied to the clipboard. Turn it on from the [Dictation page](yap://dictation).")
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
                LinkCaption("App-wide defaults; each mode can override the method and trimming in its Output section. Whether text inserts at all, and how it adapts to the text around the cursor, is on the [Dictation page](yap://dictation).")
            }

            PerAppModesSection()


            CardSection("Your name") {
                TextField("e.g. Ryleigh", text: $settings.userName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .innerWell(radius: 7)
                Caption("Used to sign your emails and personalize AI formatting. AI modes sign off with this instead of writing \u{201C}[Your Name]\u{201D}. Leave blank to skip sign-offs.")
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

            CardSection("Restore defaults") {
                HStack {
                    TipRow(icon: "arrow.counterclockwise", title: "Put every setting back to its default",
                           message: settings.restoreUndo == nil
                               ? "Modes, dictionaries, commands, AI actions, and history are kept."
                               : "Defaults restored. Undo brings back exactly what you had, until you quit.")
                    Spacer()
                    if settings.restoreUndo != nil {
                        Button("Undo") { settings.undoRestore() }.buttonStyle(.solidSecondary).controlSize(.small)
                    }
                    Button("Restore Defaults\u{2026}") { confirmRestore = true }.buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
            .confirmationDialog("Restore all settings to their defaults?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore Defaults", role: .destructive) { settings.restoreDefaults() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every setting on every page goes back to how it was on first launch. Modes, dictionaries, commands, AI actions, and history are kept. You can undo until you quit the app.")
            }

            CardSection("Start over") {
                HStack {
                    TipRow(icon: "trash", title: "Erase all data and start from scratch",
                           message: "Every setting, mode, dictionary, command, and AI action, plus your whole history and saved audio. The app relaunches at its welcome screen.")
                    Spacer()
                    Button("Erase All Data\u{2026}") { confirmErase = true }.buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
            .confirmationDialog("Erase everything and start over?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase All Data", role: .destructive) { AppReset.eraseEverything(includingModels: false) }
                Button("Erase All Data and Downloaded Models", role: .destructive) { AppReset.eraseEverything(includingModels: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Settings, modes, dictionaries, commands, AI actions, history, and saved audio are deleted, and the app relaunches at its welcome screen. Downloaded models are kept unless you choose to erase them too. Permissions granted in System Settings stay.")
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

            Divider().padding(.vertical, 4)

            Text("After a dictation lands").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Caption("Press the app's send key as soon as your words are inserted, so a dictated message goes out on its own. Return in most chat and assistant apps, \u{2318}Return in a few.")
            ForEach(settings.appAfterInsert.keys.sorted(), id: \.self) { bundleID in
                HStack(spacing: 8) {
                    AppIconView(bundleID: bundleID)
                    Text(AppCatalog.name(for: bundleID)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.appAfterInsert[bundleID] ?? .none },
                        set: { settings.appAfterInsert[bundleID] = $0 }
                    )) {
                        ForEach(AfterInsertAction.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 190)
                    Button {
                        settings.appAfterInsert.removeValue(forKey: bundleID)
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Stop pressing a key in this app")
                }
            }
            Menu {
                ForEach(AppCatalog.runningApps().filter { settings.appAfterInsert[$0.bundleID] == nil }, id: \.bundleID) { app in
                    Button(app.name) { settings.appAfterInsert[app.bundleID] = .returnKey }
                }
            } label: {
                Label("Add App", systemImage: "plus")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}
