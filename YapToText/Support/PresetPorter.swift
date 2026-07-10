import Foundation
import AppKit

/// Exports and imports an app-wide preset: everything the user has built in the sandbox -
/// settings, modes, dictionaries, commands, and AI actions - as one shareable JSON file.
/// History and audio are deliberately excluded (personal content, not configuration).
@MainActor
enum PresetPorter {
    private static let settingsKey = "com.ryleighnewman.YapToText.settings"
    private static let files = ["modes.json", "vocabulary.json", "commands.json", "aiactions.json"]

    struct Bundle_: Codable {
        var format = "yaptotext-preset"
        var version = 1
        var exportedAt: Date = Date()
        /// File name -> its JSON contents (as UTF-8 string).
        var stores: [String: String] = [:]
        /// The raw settings blob (JSON string).
        var settings: String?
    }

    static func export() {
        var bundle = Bundle_()
        for file in files {
            let url = Persistence.url(file)
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                bundle.stores[file] = text
            }
        }
        if let data = UserDefaults.standard.data(forKey: settingsKey) {
            bundle.settings = String(data: data, encoding: .utf8)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "YapToText Preset.yappreset.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(bundle) else { return }
        try? data.write(to: url)
    }

    /// Restores a preset file over the current configuration, then relaunches the app so
    /// every store reloads cleanly from disk.
    static func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(Bundle_.self, from: data),
              bundle.format == "yaptotext-preset" else {
            let alert = NSAlert()
            alert.messageText = "Not a YapToText preset"
            alert.informativeText = "That file doesn't look like an exported YapToText preset."
            alert.runModal()
            return
        }
        for (file, text) in bundle.stores {
            guard files.contains(file) else { continue }   // never write arbitrary paths
            try? Data(text.utf8).write(to: Persistence.url(file))
        }
        if let settings = bundle.settings {
            UserDefaults.standard.set(Data(settings.utf8), forKey: settingsKey)
        }
        relaunch()
    }

    /// Quit and reopen so all stores pick up the imported files.
    private static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
