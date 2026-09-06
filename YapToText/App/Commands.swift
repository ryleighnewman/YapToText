import SwiftUI
import AppKit

/// Menu bar commands for the main window, mirroring InputConfig's menu structure. Actions
/// that touch UI state go through NotificationCenter so the ContentView can react.
struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Mode") { NotificationCenter.default.post(name: .yapNewMode, object: nil) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { NotificationCenter.default.post(name: .yapShowSettings, object: nil) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(before: .sidebar) {
            Button("Show Home") { NotificationCenter.default.post(name: .yapShowHome, object: nil) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Show History") { NotificationCenter.default.post(name: .yapShowHistory, object: nil) }
                .keyboardShortcut("y", modifiers: .command)
        }

        CommandMenu("Dictation") {
            Button("Toggle Dictation") { state.controller.toggle() }
                .keyboardShortcut(.space, modifiers: [.command, .option])
            Button("Pause / Resume") { state.controller.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Cancel Dictation") { state.controller.cancel() }
                .keyboardShortcut(.escape, modifiers: .command)
            Button("Cycle Mode") { state.controller.cycleMode() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Regenerate Last") { state.controller.regenerateLast() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.controller.canRegenerateLast)
        }

        CommandGroup(replacing: .help) {
            Button("YapToText Help") { HelpWindowController.shared.show(state: state) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Online Help…") { NSWorkspace.shared.open(SupportLinks.siteHelp) }
            Button("YapToText Website") { NSWorkspace.shared.open(SupportLinks.site) }
            Divider()
            Button("Support YapToText…") { SupportWindowController.shared.show(state: state) }
            Button("Report an Issue…") { NSWorkspace.shared.open(SupportLinks.issues) }
            Button("View Source on GitHub") { NSWorkspace.shared.open(SupportLinks.repo) }
        }
    }
}
