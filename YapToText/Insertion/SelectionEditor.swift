import AppKit

/// Reads the text currently selected in whatever app is frontmost, WITHOUT needing Accessibility:
/// it snapshots the clipboard, sends a synthetic Cmd-C, waits for the app to put the selection on
/// the pasteboard, then restores the clipboard. This is the same technique the paste path already
/// uses, just in reverse. Returns nil when nothing is selected (the pasteboard never changed).
@MainActor
enum SelectionEditor {
    static func captureSelection() async -> String? {
        // While Secure Input is on, synthetic Cmd-C is suppressed, so we can't read anything.
        guard !TextInserter.isSecureInputActive else { return nil }
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(pb)
        let before = pb.changeCount
        TextInserter.postCopy()

        var changed = false
        for _ in 0..<16 {                       // up to ~400ms for the app to respond
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before { changed = true; break }
        }
        let selection = changed ? pb.string(forType: .string) : nil
        // Only restore if we actually captured something usable; an empty snapshot (e.g. the
        // clipboard held only promised/lazy data we couldn't copy) would otherwise wipe it.
        if !saved.isEmpty { saved.write(to: pb) }
        return selection
    }
}
