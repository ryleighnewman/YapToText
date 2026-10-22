import AppKit
import Carbon.HIToolbox

/// Delivers final text to the focused app. Default path is a synthesized Cmd+V paste
/// with clipboard save/restore (works in terminals, editors, Electron). Falls back to
/// character typing when Secure Input is active (e.g. password fields) or when the user
/// prefers it.
@MainActor
enum TextInserter {
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    static func deliver(_ text: String,
                        target: OutputTarget,
                        method: InsertionMethod,
                        restoreClipboard: Bool,
                        presurround: InsertionContext.Surround? = nil) async {
        guard !text.isEmpty else { return }
        switch target {
        case .clipboardOnly:
            setClipboard(text)
        case .insertAtCursor:
            await insert(text, method: method, restoreClipboard: restoreClipboard, submit: false, presurround: presurround)
        case .sendAndSubmit:
            await insert(text, method: method, restoreClipboard: restoreClipboard, submit: true, presurround: presurround)
        }
    }

    static func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Private

    /// Set by the app at launch; read at insert time so the adapt step is user-controlled.
    static var adaptToSurroundings: () -> Bool = { false }
    /// The exact text the last insert put on screen (post-adaptation). Main-actor only.
    static private(set) var lastDelivered: String?

    private static func insert(_ text: String, method: InsertionMethod, restoreClipboard: Bool, submit: Bool, presurround: InsertionContext.Surround? = nil) async {
        // CONTEXT-AWARE INSERTION: fit the transcript into the sentence it lands in
        // (lowercase mid-sentence starts, spacing, trailing period) - deterministic AX
        // read of the focused field, no-op when the app exposes no text. Async: the
        // sandbox key-sim read awaits instead of blocking, so the panel keeps animating.
        let text = adaptToSurroundings() ? await InsertionContext.adapted(text, presurround: presurround) : text
        // What actually landed, AFTER adaptation - the only string a later "scratch that"
        // can delete by length (adapt can add or drop a space or a period).
        lastDelivered = text
        switch method {
        case .clipboardOnly:
            setClipboard(text)
        case .type:
            typeString(text)
            if submit { pressReturn() }
        case .paste:
            if isSecureInputActive {
                yapdiag("insert: paste->typeString (SecureInput ON)")
                typeString(text)          // paste is unreliable while Secure Input is on
            } else {
                yapdiag("insert: paste (AXTrusted=\(AXIsProcessTrusted()))")
                paste(text, restoreClipboard: restoreClipboard)
            }
            if submit { pressReturn() }
        }
    }

    /// changeCount of the last pasteboard write THIS app made (a transcript going out, or
    /// the user's clipboard being restored 1.5 s later). Selection capture ignores a
    /// change that is merely one of ours, so a delayed restore can never pass for a copy.
    nonisolated(unsafe) static var ownWriteChangeCount: Int = -1
    nonisolated static func noteOwnWrite(_ pb: NSPasteboard) { ownWriteChangeCount = pb.changeCount }

    private static func paste(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        // Snapshot the WHOLE clipboard (images, files, RTF, every type) - not just plain text -
        // so restoring can't drop a copied picture or file the way a text-only save does.
        let snapshot = restoreClipboard ? PasteboardSnapshot.capture(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        // VERIFY before pressing paste. If a stray synthetic Cmd+C from the surround read
        // lands in this window it silently replaces our transcript with the target's own
        // selection, and Cmd+V then pastes that. Cheap to re-assert; catastrophic to skip.
        if pb.string(forType: .string) != text {
            pb.clearContents()
            pb.setString(text, forType: .string)
            yapdiag("insert: clipboard was clobbered before paste - re-asserted the transcript")
        }
        let borrowedToken = pb.changeCount
        noteOwnWrite(pb)
        postKey(0x09, flags: .maskCommand)   // Cmd+V
        if let snapshot {
            // REAL DATA ON THE PASTEBOARD, ALWAYS. Promised data (NSPasteboardItemDataProvider)
            // is the only way to learn the exact moment a paste lands, and it was tried twice
            // for that reason. It costs too much: the pasting app has to call BACK into this
            // process for the bytes instead of reading what is already there, so every paste
            // waits on our main thread and the delay is plainly felt. Handing the transcript
            // over as real bytes keeps pasting instant, which matters far more than shaving a
            // second off returning the clipboard.
            //
            // 1.5s, not 0.3s: a busy target app (Electron, or the CPU still hot from
            // transcription) can read the pasteboard AFTER a 0.3s restore and paste the OLD
            // clipboard - the classic "sometimes it just doesn't paste".
            //
            // The guard is SMART: a changed changeCount doesn't necessarily mean the user
            // copied something - many apps rewrite the pasteboard while handling the paste,
            // which used to permanently cancel the restore and leave the transcript squatting
            // over a copied picture. If the clipboard still holds OUR text, restoring is safe.
            func attemptRestore(retry: Bool) {
                let pb = NSPasteboard.general
                let stillOurs = pb.changeCount == borrowedToken
                    || pb.string(forType: .string) == text
                if stillOurs {
                    snapshot.write(to: pb)
                } else if retry {
                    // One second chance: the target may still be mid-paste-normalization.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        attemptRestore(retry: false)
                    }
                }
                // Neither ours nor retryable: the user genuinely copied something new -
                // leave it alone.
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                attemptRestore(retry: true)
            }
            // A browser can service a leftover Cmd+C from the surround read AFTER the
            // transcript was loaded: its empty copy wipes the clipboard, and the Cmd+V it
            // handles next pastes nothing (Gmail in Safari 2026-10-21; Chrome reports). An
            // EMPTY clipboard this soon after our paste can only be that, so put the
            // transcript back and paste once more: the first paste put nothing in.
            if InsertionContext.isBrowser(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") {
                var repasted = false
                func watch(_ left: Int) {
                    guard left > 0, !repasted else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let pb = NSPasteboard.general
                        // Exactly an empty STRING: a copied image or file (no string at all)
                        // is the user's own copy and must never trigger a second paste.
                        if pb.changeCount != borrowedToken, pb.string(forType: .string) == "" {
                            repasted = true
                            pb.clearContents()
                            pb.setString(text, forType: .string)
                            noteOwnWrite(pb)
                            postKey(0x09, flags: .maskCommand)
                            yapdiag("insert: clipboard was wiped by a late empty copy after the paste - pasted again")
                            return
                        }
                        watch(left - 1)
                    }
                }
                watch(24)   // ~1.2 s, inside the 1.5 s restore window
            }
        }
    }

    /// Type a literal string by posting keyboard events whose characters are set with
    /// keyboardSetUnicodeString, in 20-UTF-16-unit chunks (the API's per-event limit). This is
    /// the same approach as InputConfig's InputSimulator - posting per-character instead drops
    /// and reorders characters under load, which is why fast typing came out garbled. Chunking
    /// keeps capitals, symbols, emoji, and non-Latin text intact because the characters bypass
    /// keycode translation entirely.
    /// Live typing: type a small newly-finalized delta at the cursor WHILE dictation continues.
    /// Uses the character-typing path (no clipboard involvement, so the user's clipboard is
    /// never churned mid-sentence). Deltas are short, so per-event cost stays negligible.
    static func typeLive(_ delta: String) {
        guard !delta.isEmpty else { return }
        typeString(delta)
    }

    private static func typeString(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.setIntegerValueField(.eventSourceUserData, value: BareKeyTap.syntheticMarker)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.setIntegerValueField(.eventSourceUserData, value: BareKeyTap.syntheticMarker)
                up.post(tap: .cghidEventTap)
            }
            index += 20
        }
    }

    /// Delete `count` characters behind the cursor (quick edit: "scratch that"). Posted as
    /// individual Delete presses with a short gap so target apps register every one; capped
    /// by callers to keep the worst case brief.
    static func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: BareKeyTap.syntheticMarker)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: BareKeyTap.syntheticMarker)
                up.post(tap: .cghidEventTap)
            }
            usleep(3_000)
        }
    }

    /// Post Cmd-C to copy the current selection (used by the selection editor).
    static func postCopy() { postKey(0x08, flags: .maskCommand) }   // Cmd+C

    private static func pressReturn() { postKey(0x24, flags: []) }   // Return

    /// Internal (not private): InsertionContext's sandbox-safe context read drives the
    /// caret with these to select-and-copy the words around the cursor.
    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: BareKeyTap.syntheticMarker)
            down.post(tap: .cghidEventTap)
        }
        // A real keypress has width. Zero-interval synthetic down/up pairs get coalesced or
        // dropped by some apps' event loops; 8ms makes the pair unmissable.
        usleep(8_000)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: BareKeyTap.syntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }
}

/// A deep copy of everything on a pasteboard: every item and every type representation it
/// carries. Capturing the concrete data (not the live `NSPasteboardItem`s, which the system
/// invalidates on `clearContents()`) is what lets us restore images, files, and rich text -
/// the content a plain-text save silently loses. Lazily-promised data (e.g. some file promises)
/// can't be read ahead of time, so those types are skipped; everything with real bytes survives.
///
/// The snapshot holds plain data, never `NSPasteboardItem`s: an item can be written to a
/// pasteboard only once, and a second `writeObjects` with it raises NSInvalidArgumentException
/// ("already associated with another pasteboard"). Intelligent Insert restores the same
/// snapshot twice when a slow app answers its copy late (the read's own restore, then
/// settleUnansweredRead), and that exception, swallowed by AppKit mid-task, left the main
/// thread's concurrency state broken until the next main-actor check crashed (1.5.3, Gmail
/// in Safari). Every write therefore builds fresh items.
struct PasteboardSnapshot {
    /// One entry per pasteboard item, each holding every type that had real bytes, in order.
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    /// The plain text the clipboard held when the snapshot was taken, if any.
    var string: String? {
        for item in items {
            if let data = item.first(where: { $0.type == .string })?.data,
               let s = String(data: data, encoding: .utf8) { return s }
        }
        return nil
    }

    static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
        var copies: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            let entries = item.types.compactMap { type in item.data(forType: type).map { (type: type, data: $0) } }
            if !entries.isEmpty { copies.append(entries) }
        }
        return PasteboardSnapshot(items: copies)
    }

    var isEmpty: Bool { items.isEmpty }

    /// Restore the captured content, replacing whatever is currently on the pasteboard.
    /// Safe to call any number of times.
    func write(to pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items.map { entries in
                let item = NSPasteboardItem()
                for entry in entries { item.setData(entry.data, forType: entry.type) }
                return item
            })
        }
        TextInserter.noteOwnWrite(pb)
    }
}
