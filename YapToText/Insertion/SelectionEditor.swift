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
        var before = pb.changeCount
        TextInserter.postCopy()

        var changed = false
        for _ in 0..<16 {                       // up to ~400ms for the app to respond
            try? await Task.sleep(nanoseconds: 25_000_000)
            let now = pb.changeCount
            guard now != before else { continue }
            // A write of OUR OWN landing mid-poll (the clipboard restore that follows every
            // paste) is not the target app answering Cmd-C. Skip it and keep waiting.
            if now == TextInserter.ownWriteChangeCount {
                yapdiag("quickEdit: capture ignored our own clipboard write (changeCount \(now))")
                before = now
                continue
            }
            changed = true; break
        }
        var selection = changed ? pb.string(forType: .string) : nil
        // Editors that copy the whole line when nothing is selected say so (VS Code and
        // its relatives tag the pasteboard); that line is not a selection.
        if selection != nil,
           let meta = pb.string(forType: NSPasteboard.PasteboardType("vscode-editor-data")),
           meta.contains("\"isFromEmptySelection\":true") {
            yapdiag("quickEdit: capture was a whole-line copy from an empty selection - ignoring")
            selection = nil
        }
        yapdiag("quickEdit: capture changed=\(changed) text=\((selection ?? "").prefix(60).debugDescription)")
        // Only restore if we actually captured something usable; an empty snapshot (e.g. the
        // clipboard held only promised/lazy data we couldn't copy) would otherwise wipe it.
        if !saved.isEmpty { saved.write(to: pb) }
        return selection
    }
}
