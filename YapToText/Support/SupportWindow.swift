import SwiftUI
import AppKit

/// Opens Support (tip jar + links) in its own window, mirroring InputConfig's
/// TipJarWindowController rather than burying it in a settings tab.
@MainActor
final class SupportWindowController {
    static let shared = SupportWindowController()
    private var window: NSWindow?
    private init() {}

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SupportSettingsView()
            .environment(state)
            .background(AppWindowBackground()))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Support YapToText"
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.setContentSize(hosting.view.fittingSize)
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}
