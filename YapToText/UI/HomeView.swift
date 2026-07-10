import SwiftUI
import AppKit

/// The Home pathway: a calm welcome surface. Logo and one clear place to go (Start Dictation),
/// your recent modes, and a set-up card that only appears while something still needs granting.
/// Dictionaries, History, and Settings live in the sidebar, so they are not duplicated here.
struct HomeView: View {
    @Environment(AppState.self) private var state
    var onStartDictation: () -> Void
    var onNewMode: () -> Void

    private var needsSetup: Bool {
        !(state.permissions.microphoneGranted && state.permissions.accessibilityGranted)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
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
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .navigationTitle("Home")
        .onAppear { state.permissions.refresh() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            AnimatedCapy(size: 76)
            Text("Welcome to YapToText").font(.title.weight(.semibold))
            Text("A powerful speech-to-text accessibility tool, running entirely on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: The one-key reassurance

    /// A friendly nudge so nobody feels buried by the feature set: one key is all it takes.
    /// Dismissible - the X hides it for good (it can't nag once you've read it).
    private var funNote: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("One key is all it takes").font(.callout.weight(.semibold))
                Text("This app is loaded with features, but you don't need any of them to start. Just tap Right \u{2318} and talk. Feeling curious? Every panel on the left is yours to play with.")
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
            .help("Choose your mode and dictionaries")

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

    private var quickControls: some View {
        @Bindable var settings = state.settings
        return CardSection("Quick controls") {
            Picker(selection: $settings.rightCommandTrigger) {
                ForEach(ModifierTrigger.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Right \u{2318} key")
            }
            .onChange(of: settings.rightCommandTrigger) { AppDelegate.shared?.reloadRightCommandTrigger() }
            Toggle("Show the menu bar icon", isOn: $settings.showMenuBarIcon).toggleStyle(.switch).controlSize(.small)
                .onChange(of: settings.showMenuBarIcon) { AppDelegate.shared?.reloadStatusItem() }
            if !settings.showMenuBarIcon {
                SubOptions {
                    Caption("The capybara is hidden from the menu bar. Everything still works. Come back here to turn it on again.")
                }
            }
            Toggle("Show the app in the Dock", isOn: $settings.showDockIcon).toggleStyle(.switch).controlSize(.small)
                .onChange(of: settings.showDockIcon) { AppDelegate.shared?.reloadDockIcon() }
            if !settings.showDockIcon {
                SubOptions {
                    Caption("The Dock icon is hidden. Reopen this window from the menu bar capybara or your dictation shortcut.")
                }
            }
            HStack {
                Caption("Every setting, including per-mode overrides, lives in Settings.")
                Spacer()
                Button("All Settings") {
                    NotificationCenter.default.post(name: .yapShowSettings, object: nil)
                }
                .buttonStyle(.solidSecondary)
                .controlSize(.small)
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
                      actionTitle: "Allow") {
                          Task {
                              // If it was previously denied, requestAccess can't re-prompt -
                              // send the user straight to System Settings instead of no-op.
                              let ok = await state.permissions.requestMicrophone()
                              if !ok { state.permissions.openMicrophoneSettings() }
                          }
                      }
            Divider()
            statusRow(symbol: "accessibility", title: "Accessibility (optional)",
                      subtitle: "Unlocks the Right \u{2318} dictation key and reading selected text. The keyboard shortcut works without it.",
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
        Tip(text: "Say \u{201C}smiley face\u{201D} and Commands turn it into the emoji, right in your text.", dest: .commands),
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
