import AppKit
import ApplicationServices

/// Reads lightweight context from the system: the frontmost app and any text the user
/// has selected in the focused field. Used for per-app mode switching and AI context.
enum AccessibilityReader {
    static func frontmostApp() -> (name: String?, bundleID: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }

    /// The currently selected text in the focused UI element, if readable via Accessibility.
    static func focusedSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // Bound the synchronous AX IPC so a hung target app cannot stall the caller.
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused else { return nil }
        let element = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
