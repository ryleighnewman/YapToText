import SwiftUI
import AppKit

/// The Home pathway: a calm welcome surface. Logo and one clear place to go (Start Dictation),
/// your recent modes, and a set-up card that only appears while something still needs granting.
/// Dictionaries, History, and Settings live in the sidebar, so they are not duplicated here.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var showChangelog = false
    var onStartDictation: () -> Void
    var onNewMode: () -> Void

    private var needsSetup: Bool {
        !(state.permissions.microphoneGranted && state.permissions.accessibilityGranted)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if let suggestion = state.vocabulary.pendingSuggestion { correctionSuggestion(suggestion) }
                if !state.settings.hasDismissedHomeNote { funNote }
                if needsSetup { setupCard }
                primaryActions
                quickControls
                if !state.history.records.isEmpty { statsCard }
                footer
            }
            .frame(maxWidth: Metrics.pageWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, -2)
            .padding(.bottom, 28)
        }
        .navigationTitle("Home")
        .onAppear { state.permissions.refresh() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            AnimatedCapy(size: 76)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Welcome to YapToText").font(.title.weight(.semibold))
                // Tiny grey version, part of the same line - still the release-notes button.
                Button { showChangelog = true } label: {
                    Text(Changelog.currentVersion)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("What's new in this version")
                .popover(isPresented: $showChangelog, arrowEdge: .bottom) { changelogPopover }
            }
            Text("Local Powerful Dictation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var changelogPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What's new").font(.headline)
                ForEach(Changelog.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.version).font(.subheadline.weight(.semibold))
                        ForEach(entry.points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\u{2022}").foregroundStyle(.secondary)
                                Text(point).font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 380, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }

    // MARK: The one-key reassurance

    /// A friendly nudge so nobody feels buried by the feature set: one key is all it takes.
    /// Dismissible - the X hides it for good (it can't nag once you've read it).
    /// The note names whatever key ACTUALLY starts dictation right now, so it never lies after
    /// someone changes the trigger: Right Command when that trigger is on, else the custom hotkey.
    private var dictationKeyName: String {
        if state.settings.rightCommandTrigger != .off { return "Right \u{2318}" }
        return state.settings.hotkey.displayString
    }

    private var funNote: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("One key is all it takes").font(.callout.weight(.semibold))
                Text("This app is loaded with customizability and deeper features, but all you have to do is tap \(dictationKeyName) and talk. Everything on the left is optional.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .padding(.trailing, 14)   // room so text never runs under the close button
        .innerWell(radius: Metrics.panelRadius)
        .overlay(alignment: .topTrailing) {
            Button { state.settings.hasDismissedHomeNote = true } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Dismiss")
            .accessibilityLabel("Dismiss this note")
        }
    }


    /// Surfaced when the user has corrected the same mishear enough times: offer to make it a
    /// permanent fix, which also primes Whisper to hear it right next time.
    private func correctionSuggestion(_ s: LearnedCorrection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.callout).foregroundStyle(Color.accentColor).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Make this correction stick?").font(.caption.weight(.semibold))
                Text("You've changed \u{201C}\(s.from)\u{201D} to \u{201C}\(s.to)\u{201D} more than once. Add it and YapToText will spell it that way automatically - and listen for it, so it's heard right in the first place.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Add it") { state.vocabulary.acceptSuggestion() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Not now") { state.vocabulary.dismissSuggestion() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .innerWell(radius: Metrics.panelRadius)
    }

    /// Compact, closable pointer to Dictionaries - same pattern as the one-key note.
    private var dictionaryTip: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fix a misheard word once").font(.caption.weight(.semibold))
                Text("Add it in Dictionaries, or select the right spelling anywhere, press your Quick Edit key, and say \u{201C}add this to my dictionary\u{201D}.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .padding(.trailing, 14)
        .innerWell(radius: Metrics.panelRadius)
        .overlay(alignment: .topTrailing) {
            Button { state.settings.hasDismissedDictionaryTip = true } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(5)
            .help("Dismiss")
            .accessibilityLabel("Dismiss this tip")
        }
    }

    // MARK: Primary actions

    private var primaryActions: some View {
        HStack(spacing: 12) {
            Button(action: onStartDictation) {
                Label("Start Dictation", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.solid)
            .controlSize(.large)
            .help("Start dictating right now")

            Button(action: onNewMode) {
                Label("New Mode", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.solidSecondary)
            .controlSize(.large)
        }
    }

    // MARK: Quick controls (the everyday switches, right on Home)

    /// The little "this is where you change the keys" affordance: every binding row gets one.
    private func editBindingLink(_ help: String = "Change this binding on the Dictation page") -> some View {
        Button {
            NotificationCenter.default.post(name: .yapShowDestination, object: "dictation")
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "keyboard").font(.caption2)
                Text("Edit binding").font(.caption2)
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var quickControls: some View {
        @Bindable var settings = state.settings
        return CardSection("Quick controls") {
            // One line each, with the ACTUAL binding editors inline - no trip to Settings.
            // Exactly like the "Menu bar icon | Capybara" row: label, then the picker
            // right beside it (same standard popup style, natural width) - and the key
            // recorder field alone on the far right.
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
            // Intelligent insert rides right under its key: the context-aware step that
            // fits mid-sentence dictation into the text around the cursor.
            SubOptions {
                Toggle("Intelligent insert", isOn: $settings.adaptToSurroundings)
                    .toggleStyle(.switch).controlSize(.small)
                Caption("Mid-sentence dictation matches the spacing and capitalization around your cursor.")
            }
            HStack(spacing: 8) {
                Image(systemName: "pencil.line").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                Text("Quick Edit key")
                    .help("Select text, press the key, say the change.")
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
            // A breath of padding separates the key bindings (above) from the system looks (below).
            // MASTER SWITCH for the whole mode/AI system. Off = extremely rapid transcription:
            // your words typed exactly as spoken, no AI stage at all.
            Toggle("Post-transcription analysis", isOn: $settings.aiCleanupEnabled)
                .toggleStyle(.switch).controlSize(.small)
            SubOptions {
                Caption(settings.aiCleanupEnabled
                    ? "Modes, Auto, and AI cleanup run after each transcription."
                    : "Off: your words land exactly as spoken, with no AI.")
            }
            Toggle("Auto mode", isOn: $settings.autoContextMode)
                .toggleStyle(.switch).controlSize(.small)
                .analysisGated(state)
            if settings.aiCleanupEnabled, settings.autoContextMode {
                SubOptions {
                    Caption("Emails become emails, chat stays as spoken, the rest is cleaned up.")
                    if settings.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Caption("Sign emails as:")
                            NameCaptureField()
                        }
                    }
                }
            }
            if !settings.hasDismissedDictionaryTip { dictionaryTip }
            HStack(spacing: 8) {
                Image(systemName: "menubar.rectangle").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                Text("Menu bar icon")
                Toggle("", isOn: $settings.showMenuBarIcon).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.showMenuBarIcon) { AppDelegate.shared?.reloadStatusItem() }
                if settings.showMenuBarIcon {
                    Picker("", selection: $settings.menuBarIconStyle) {
                        ForEach(MenuBarIconStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: settings.menuBarIconStyle) { AppDelegate.shared?.refreshStatusIcon() }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            HStack(spacing: 8) {
                Image(systemName: "dock.rectangle").font(.caption).iconTint(Color.accentColor).frame(width: 16)
                Text("Dock icon")
                Toggle("", isOn: $settings.showDockIcon).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.showDockIcon) { AppDelegate.shared?.reloadDockIcon() }
                Spacer(minLength: 0)
            }
            if !settings.showDockIcon {
                SubOptions { Caption("Reopen this window from the menu bar icon or your dictation key.") }
            }
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        let records = state.history.records
        let words = state.history.totalWords
        let seconds = records.reduce(0) { $0 + $1.durationSeconds }
        let minutes = seconds / 60
        let wpm = minutes > 0.05 ? Int((Double(words) / minutes).rounded()) : 0
        return CardSection("Your dictation") {
            HStack(spacing: 0) {
                StatPill("\(records.count)", "dictations")
                StatPill("\(words)", "words")
                StatPill(minutes >= 60 ? String(format: "%.1f h", minutes / 60) : "\(Int(minutes)) min", "speaking")
                if wpm > 0 {
                    StatPill("\(wpm)", "words/min")
                }
            }
        }
    }

    // MARK: Setup card

    private var setupCard: some View {
        CardSection("Get set up") {
            statusRow(symbol: "mic.fill", title: "Microphone",
                      subtitle: "Required so YapToText can hear you.",
                      granted: state.permissions.microphoneGranted,
                      // 5.1.1(iv): pre-permission buttons must use neutral wording
                      // ("Continue"), never "Allow" - App Review flagged this.
                      actionTitle: "Continue") {
                          Task {
                              // If it was previously denied, requestAccess can't re-prompt -
                              // send the user straight to System Settings instead of no-op.
                              let ok = await state.permissions.requestMicrophone()
                              if !ok { state.permissions.openMicrophoneSettings() }
                          }
                      }
            Divider()
            statusRow(symbol: "accessibility", title: "Accessibility (needed for auto-paste)",
                      subtitle: "Required to paste your words into other apps automatically, for the Right \u{2318} key, and for reading selected text. Without it, dictations are copied to the clipboard instead.",
                      granted: state.permissions.accessibilityGranted,
                      actionTitle: "Grant") {
                          state.permissions.promptAccessibility()
                          state.permissions.openAccessibilitySettings()
                      }
            if !state.permissions.accessibilityGranted {
                HStack {
                    Text("Accessibility not sticking? Reveal the app to drag it into the list.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Show in Finder") { state.permissions.revealAppInFinder() }.buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
            HStack {
                Caption("Granted something in System Settings and it isn't showing here yet?")
                Spacer()
                Button {
                    state.permissions.refresh()
                    AppDelegate.shared?.reloadRightCommandTrigger()
                    AppDelegate.shared?.reloadHotkey()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.solidSecondary).controlSize(.small)
                .help("Re-read permissions and re-arm the shortcuts")
            }
        }
        // Poll while the card is visible: TCC grants made in System Settings don't push a
        // notification, so without this the card looked stale until the app was reactivated.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let before = state.permissions.accessibilityGranted
                state.permissions.refresh()
                if !before && state.permissions.accessibilityGranted {
                    AppDelegate.shared?.reloadRightCommandTrigger()
                    AppDelegate.shared?.reloadHotkey()
                }
            }
        }
    }

    private func statusRow(symbol: String, title: String, subtitle: String,
                           granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        BadgeRow(symbol: symbol, title: title, subtitle: subtitle) {
            if granted {
                Image(systemName: "checkmark.circle.fill").iconTint(.green).accessibilityLabel("Granted")
            } else {
                Button(actionTitle, action: action)
            }
        }
    }

    private var footer: some View { QuickTipsPill() }
}

/// A quiet rotating pill of one-line feature tips - it replaces the old Quick Start Tour button.
/// The text swaps on a slow clock with NO animated transaction (glass-stability rule for the main
/// window), and the pill keeps a stable single-Text structure.
private struct QuickTipsPill: View {
    /// A tip plus where in the app it pays off. Linked tips are clickable and jump straight
    /// to the relevant page, so the tip is a door, not just trivia.
    private struct Tip { let text: String; var dest: AppDestination? }

    private static let tips: [Tip] = [
        Tip(text: "Press 1-9 while dictating to pick how your words come out: email, note, message.", dest: .modes),
        Tip(text: "Tap Space mid-dictation to pause; tap it again to resume.", dest: .settings),
        Tip(text: "Press Esc while dictating to cancel. Nothing is typed or saved.", dest: nil),
        Tip(text: "Set Right \u{2318} to hold-to-talk and use it like a walkie-talkie.", dest: .settings),
        Tip(text: "Drop any audio or video file on the Utility page to transcribe it.", dest: .utility),
        Tip(text: "Select text in any app, then use the menu bar\u{2019}s Regenerate menu to rewrite it with any mode.", dest: nil),
        Tip(text: "Not happy with how a mode writes? Open it and edit its instructions. Every mode is yours to tweak.", dest: .modes),
        Tip(text: "Dictionaries auto-correct names and jargon the mic keeps mishearing.", dest: .dictionaries),
        Tip(text: "Say \u{201C}insert smiley face\u{201D} and Commands turn it into the emoji, right in your text.", dest: .commands),
        Tip(text: "Regenerate your last dictation as an email straight from the menu bar.", dest: nil),
        Tip(text: "Search the sidebar to jump to any setting in seconds.", dest: nil),
        Tip(text: "Everything runs on your Mac. Your voice is never uploaded.", dest: .models),
        Tip(text: "Curious how much you dictate? Statistics charts your words, streaks, and busiest hours.", dest: .stats),
        Tip(text: "If the app ever crashes mid-sentence, don't worry: your recording is rescued on the next launch and waiting in History.", dest: .history),
        Tip(text: "Need to whisper? Turn up the input boost or auto-amplify in Settings and quiet speech still comes through clearly.", dest: .settings),
    ]

    @State private var index = Int.random(in: 0..<QuickTipsPill.tips.count)
    @State private var rotator: Task<Void, Never>?

    var body: some View {
        let tip = Self.tips[index]
        return Button {
            guard let dest = tip.dest else { return }
            NotificationCenter.default.post(name: .yapShowDestination, object: dest.rawValue)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "lightbulb.max").iconTint(.accentColor).font(.caption)
                Text(tip.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if tip.dest != nil {
                    Image(systemName: "arrow.right.circle").iconTint(.accentColor).font(.caption)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(tip.dest == nil)
        .help(tip.dest == nil ? "" : "Open the page this tip is about")
        .onAppear {
            rotator?.cancel()
            rotator = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    guard !Task.isCancelled else { return }
                    index = (index + 1) % Self.tips.count
                }
            }
        }
        .onDisappear { rotator?.cancel(); rotator = nil }
        .accessibilityLabel("Tip: \(tip.text)")
    }
}
