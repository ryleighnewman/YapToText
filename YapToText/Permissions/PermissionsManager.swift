import AppKit
import AVFoundation
import ApplicationServices
import Observation

/// Tracks and requests the two TCC grants YapToText can use: Microphone (required, to hear
/// you) and Accessibility (optional, to read selected text / detect the active app). Text
/// insertion itself works without Accessibility because it posts to the HID event tap.
@MainActor
@Observable
final class PermissionsManager {
    var microphoneGranted = false
    var accessibilityGranted = false

    func refresh() {
        // Assign only on change so re-checks (on activation, on view appear) don't churn views.
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        if mic != microphoneGranted { microphoneGranted = mic }
        if ax != accessibilityGranted { accessibilityGranted = ax }
    }

    var allGranted: Bool { microphoneGranted && accessibilityGranted }

    @discardableResult
    func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            microphoneGranted = true
            return true
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
        return granted
    }

    /// Shows the system Accessibility prompt (only if not already trusted) and opens the pane.
    /// The user must flip the switch themselves; it cannot be granted programmatically.
    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        // The modern (Ventura+) pane URL, with the classic one as a fallback.
        if !open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            _ = open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    func openMicrophoneSettings() {
        if !open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") {
            _ = open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    /// Reveal the running app in Finder so the user can drag it into the Accessibility list.
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @discardableResult
    private func open(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
