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

    private static func insert(_ text: String, method: InsertionMethod, restoreClipboard: Bool, submit: Bool) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let pb = NSPasteboard.general
                // Only put the user's clipboard back if nothing else claimed it meanwhile -
                // otherwise we'd clobber something they copied during the paste window.
                guard pb.changeCount == borrowedToken else { return }
                snapshot.write(to: pb)
            }
        }
    }

    /// Type a literal string by posting keyboard events whose characters are set with
    /// keyboardSetUnicodeString, in 20-UTF-16-unit chunks (the API's per-event limit). This is
    /// the same approach as InputConfig's InputSimulator - posting per-character instead drops
    /// and reorders characters under load, which is why fast typing came out garbled. Chunking
    /// keeps capitals, symbols, emoji, and non-Latin text intact because the characters bypass
    /// keycode translation entirely.
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

    /// Post Cmd-C to copy the current selection (used by the selection editor).
    static func postCopy() { postKey(0x08, flags: .maskCommand) }   // Cmd+C

    private static func pressReturn() { postKey(0x24, flags: []) }   // Return

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
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
