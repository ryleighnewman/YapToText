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
                        restoreClipboard: Bool) {
        guard !text.isEmpty else { return }
        switch target {
        case .clipboardOnly:
            setClipboard(text)
        case .insertAtCursor:
            insert(text, method: method, restoreClipboard: restoreClipboard, submit: false)
        case .sendAndSubmit:
            insert(text, method: method, restoreClipboard: restoreClipboard, submit: true)
        }
    }

    static func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Private

    /// Set by the app at launch; read at insert time so the adapt step is user-controlled.
    static var adaptToSurroundings: () -> Bool = { true }

    private static func insert(_ text: String, method: InsertionMethod, restoreClipboard: Bool, submit: Bool) {
        // CONTEXT-AWARE INSERTION: fit the transcript into the sentence it lands in
        // (lowercase mid-sentence starts, spacing, trailing period) - deterministic AX
        // read of the focused field, no-op when the app exposes no text.
        let text = adaptToSurroundings() ? InsertionContext.adapted(text) : text
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

    private static func paste(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        // Snapshot the WHOLE clipboard (images, files, RTF, every type) - not just plain text -
        // so restoring can't drop a copied picture or file the way a text-only save does.
        let snapshot = restoreClipboard ? PasteboardSnapshot.capture(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        let borrowedToken = pb.changeCount
        postKey(0x09, flags: .maskCommand)   // Cmd+V
        if let snapshot {
            // 1.5s, not 0.3s: a busy target app (Electron, or the CPU still hot from
            // transcription) can read the pasteboard AFTER a 0.3s restore, pasting the OLD
            // clipboard - the classic "sometimes it just doesn't paste". The changeCount guard
            // below still protects anything the user copies during the window.
            // Restore with a SMART guard: a changed changeCount doesn't necessarily mean
            // the user copied something - many apps (Electron especially) rewrite the
            // pasteboard while handling the paste, which used to permanently cancel the
            // restore and leave the transcript squatting over a copied picture. If the
            // clipboard still holds OUR transcript text, restoring is always safe.
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
struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
        var copies: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            if !copy.types.isEmpty { copies.append(copy) }
        }
        return PasteboardSnapshot(items: copies)
    }

    var isEmpty: Bool { items.isEmpty }

    /// Restore the captured content, replacing whatever is currently on the pasteboard.
    func write(to pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
