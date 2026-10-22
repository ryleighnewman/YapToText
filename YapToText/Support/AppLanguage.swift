import AppKit

/// The languages YapToText is translated into, the same set as InputConfig, and the app's
/// own choice among them. "Same as the system" follows System Settings > General > Language
/// & Region (where a per-app language can be set too); a choice made here is stored for
/// YapToText alone, which macOS applies at the next launch.
enum AppLanguage {
    /// Localization identifiers, English first, then by code.
    static let codes = ["en", "ar", "cs", "da", "de", "es", "fi", "fr", "he", "hu", "id", "it", "ja", "ko",
                        "nb", "nl", "pl", "pt-BR", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    private static let key = "AppleLanguages"

    /// A language's name in that language ("Deutsch", "日本語").
    static func nativeName(_ code: String) -> String {
        let l = Locale(identifier: code)
        let name = l.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: l) + name.dropFirst()
    }

    /// The language picked for YapToText, or nil when it follows the system. Read from the
    /// app's own domain only, so the system list never counts as a choice.
    static var chosen: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first else { return nil }
        if codes.contains(first) { return first }
        let base = Locale(identifier: first).language.languageCode?.identifier
        guard let match = Bundle.preferredLocalizations(from: codes, forPreferences: [first]).first,
              match != "en" || base == "en" else { return nil }
        return match
    }

    /// The language the app is showing now.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The language the next launch will show: the choice, or the first of the system's
    /// languages the app has.
    static var nextLaunch: String {
        let prefs = chosen.map { [$0] } ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: codes, forPreferences: prefs).first ?? "en"
    }

    /// Stores the choice for the next launch (nil follows the system).
    static func choose(_ code: String?) {
        if let code { UserDefaults.standard.set([code], forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Set while a language change is restarting the app.
    @MainActor static var relaunchPending = false

    /// Quits through the normal path and starts a new copy as the quit completes, so the
    /// language takes effect. The new copy's single-instance check waits for this one.
    @MainActor
    static func relaunch() {
        relaunchPending = true
        NSApplication.shared.terminate(nil)
    }

    /// From applicationWillTerminate: start the replacement.
    @MainActor
    static func launchReplacement() {
        guard relaunchPending else { return }
        relaunchPending = false
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }
}
