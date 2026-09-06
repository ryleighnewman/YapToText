import AppKit

/// "Erase All Data": everything the app stores goes, and the app relaunches at its welcome
/// screen as if freshly installed. Downloaded models are kept unless asked for, since they
/// are gigabytes to fetch again. Permissions granted in System Settings are macOS's, not
/// ours, and stay.
@MainActor
enum AppReset {
    static func eraseEverything(includingModels: Bool) {
        // Freeze every writer first: stores flush and history clears on termination, and any
        // setting nudged during teardown would write the whole settings blob straight back.
        Persistence.writesSuspended = true
        AppSettings.writesSuspended = true
        AppDelegate.shared?.state.controller.cancel()

        let fm = FileManager.default
        let dir = Persistence.directory
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in items {
                if url.lastPathComponent == "Models", !includingModels { continue }
                try? fm.removeItem(at: url)
            }
        }
        if let id = Bundle.main.bundleIdentifier {
            // The menu bar icon's slot is where the user dragged it, not app data: keep it, or
            // the fresh item lands at the hidden far-left end of a crowded menu bar.
            let slot = UserDefaults.standard.object(forKey: AppDelegate.statusPositionKey)
            UserDefaults.standard.removePersistentDomain(forName: id)
            if let slot { UserDefaults.standard.set(slot, forKey: AppDelegate.statusPositionKey) }
            UserDefaults.standard.synchronize()
        }
        yapdiag("reset: erased app data (models \(includingModels ? "erased" : "kept")); relaunching")
        relaunch()
    }

    /// A fresh instance comes up before this one leaves, so there is never a moment with no
    /// app; the new one finds no settings and opens onboarding.
    static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, error in
            if let error { yapdiag("reset: relaunch failed \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }
}
