import AppKit

extension NSSavePanel {   // NSOpenPanel inherits this too
    /// Run this panel modally IN FRONT, wherever it was invoked from. A bare runModal()
    /// inherits the app's activation state: triggered from the menu bar (or with Stage
    /// Manager arranging windows), YapToText isn't the active app, so the picker opened
    /// BEHIND the current app's windows and never came forward - it looked like nothing
    /// happened. Activating first and floating the panel guarantees it lands on top and
    /// takes keyboard focus. (Only the PANEL is ordered forward - deliberately not the
    /// glass main window, whose animated ordering is a macOS 26.5 crash path.)
    @discardableResult
    func runModalInFront() -> NSApplication.ModalResponse {
        level = .modalPanel
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        return runModal()
    }
}
