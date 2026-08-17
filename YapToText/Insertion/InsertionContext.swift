import AppKit
import ApplicationServices

/// Context-aware insertion: reads the text AROUND the cursor in the focused field (via
/// the same Accessibility permission pasting already uses) and adapts the transcript to
/// fit - deterministically, no AI involved:
///
/// - Mid-sentence (the text before the cursor doesn't end a sentence): the transcript's
///   leading capital is lowercased, sparing "I", "I'll"-style contractions, and
///   acronyms/proper-looking words (second letter uppercase).
/// - The transcript's trailing period is dropped when the existing sentence continues
///   right after the cursor (next visible character is lowercase or joining punctuation).
/// - Spacing: exactly one space is guaranteed against the character before the cursor
///   (unless it's whitespace or an opening bracket/quote) and before the character after
///   it (when the text continues with a letter or digit).
///
/// Apps that don't expose their text through AX (some Electron surfaces, secure fields)
/// simply return `available: false` and the transcript inserts unchanged.
enum InsertionContext {
    struct Surround {
        var before: String
        var after: String
        var available: Bool
        static let none = Surround(before: "", after: "", available: false)
    }

    /// Read up to `maxChars` on each side of the cursor/selection in the focused element.
    /// Must run AFTER the target app is frontmost (the focused element must be theirs).
    static func read(maxChars: Int = 120) -> Surround {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success,
              let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else {
            yapdiag("insertctx: focused element unavailable err=\(focusErr.rawValue)")
            return .none
        }
        let element = unsafeDowncast(focusedAny as AnyObject, to: AXUIElement.self)

        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success,
              let rangeAny = rangeRef, CFGetTypeID(rangeAny) == AXValueGetTypeID() else {
            yapdiag("insertctx: no selected-range attr err=\(rangeErr.rawValue)")
            return .none
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeAny as AnyObject, to: AXValue.self), .cfRange, &range) else { return .none }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return .none }

        let ns = text as NSString
        let caret = min(max(0, range.location), ns.length)
        let beforeStart = max(0, caret - maxChars)
        let before = ns.substring(with: NSRange(location: beforeStart, length: caret - beforeStart))
        let selEnd = min(ns.length, caret + max(0, range.length))
        let after = ns.substring(with: NSRange(location: selEnd, length: min(maxChars, ns.length - selEnd)))
        return Surround(before: before, after: after, available: true)
    }

    /// Deterministic adaptation of `text` to its surroundings. Pure function - testable.
    static func adapt(_ text: String, before: String, after: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return text }

        // Where does the preceding text leave us? Empty field / fresh line / after a
        // sentence end = sentence start; anything else = mid-sentence.
        let visibleBefore = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevChar = visibleBefore.last
        let atSentenceStart = prevChar == nil
            || ".!?".contains(prevChar!)
            || before.hasSuffix("\n") || before.hasSuffix("\n ")

        if !atSentenceStart, let first = t.first, first.isUppercase {
            let firstWord = t.prefix(while: { $0.isLetter || $0 == "'" })
            let secondIsUpper = t.dropFirst().first?.isUppercase ?? false
            let isI = firstWord == "I" || firstWord.hasPrefix("I'")
            if !isI, !secondIsUpper {
                t = first.lowercased() + t.dropFirst()
            }
        }

        // The sentence continues right after the cursor: the transcript must not close it.
        if let nextVisible = after.first(where: { !$0.isWhitespace }) {
            let continues = nextVisible.isLowercase || ",;:)]".contains(nextVisible)
            if continues, t.hasSuffix(".") { t.removeLast() }
        }

        // Spacing against the neighbors: one space where words would otherwise collide.
        if let lastRaw = before.last, !lastRaw.isWhitespace,
           !"([{\u{201C}\u{2018}\"'/-".contains(lastRaw) {
            t = " " + t
        }
        if let firstAfter = after.first, firstAfter.isLetter || firstAfter.isNumber {
            t += " "
        }
        return t
    }

    /// SANDBOX-SAFE fallback: the App Sandbox rejects the AX read above with
    /// kAXErrorCannotComplete (-25204) - a sandboxed process may post events but never
    /// read another app's UI tree. So when AX fails, read the context the only way the
    /// sandbox allows: briefly SELECT a few words on each side of the caret with
    /// synthetic word-selection keys, copy them, and put the caret back - all inside the
    /// insert moment, with the clipboard snapshot-restored around it.
    ///
    /// Deliberate abort conditions (returning .none inserts the transcript unchanged):
    /// - Secure Input active (synthetic selection keys are unreliable there).
    /// - A live selection exists (probe copy changes the pasteboard): dictating over a
    ///   selection must REPLACE it - the selection dance would destroy it. Also covers
    ///   editors that copy the whole line on an empty selection (VS Code-style).
    @MainActor
    private static func keyRead() async -> Surround {
        guard !TextInserter.isSecureInputActive else { return .none }
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        defer { snapshot.write(to: pb) }

        /// Cmd+C, then wait briefly for the pasteboard to change. nil = nothing copied
        /// (empty selection), which is itself information. The waits are async: this runs
        /// on the main actor, and blocking here froze the wave mid-choreography.
        func copyChanged(_ timeout: TimeInterval) async -> String? {
            let token = pb.changeCount
            TextInserter.postCopy()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if pb.changeCount != token { return pb.string(forType: .string) ?? "" }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            return nil
        }
        let optShift: CGEventFlags = [.maskAlternate, .maskShift]

        // 1. Probe: if copying RIGHT NOW yields NON-EMPTY text, there is a live selection
        //    (or a copy-line-on-empty editor) - hands off either way. But browsers
        //    (Safari/Chrome running Reddit's rich editor) bump the pasteboard changeCount
        //    on an empty-selection Cmd+C while writing an EMPTY string; the old check
        //    treated any non-nil result - including "" - as a selection and bailed, so
        //    smart insert never engaged inside Reddit. An empty copy is never a selection
        //    worth preserving, so only a non-empty probe aborts the read.
        if let probe = await copyChanged(0.15),
           !probe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            yapdiag("insertctx: live selection - inserting unadapted")
            return .none
        }
        // 2 + 3. Read both sides. Slow apps (Electron especially) sometimes service the
        //    synthetic selection keys or the copy late; one quiet retry makes the read
        //    land reliably instead of silently inserting unadapted - the "intelligent
        //    insert didn't turn on" report. The waits are async, so patience is free.
        var before: String?
        var after: String?
        for attempt in 0..<2 {
            // BEFORE: select up to three words back, copy, collapse to the selection's
            // RIGHT edge (the original caret). Collapse only when something was actually
            // selected - at the document start a bare Right would WALK the caret forward.
            for _ in 0..<3 { TextInserter.postKey(0x7B, flags: optShift) }   // Opt+Shift+Left
            try? await Task.sleep(nanoseconds: 30_000_000)
            before = await copyChanged(attempt == 0 ? 0.25 : 0.4)
            if before != nil { TextInserter.postKey(0x7C, flags: []) }       // Right: restore caret
            try? await Task.sleep(nanoseconds: 20_000_000)
            // AFTER: mirror image - two words forward, collapse to the LEFT edge.
            for _ in 0..<2 { TextInserter.postKey(0x7C, flags: optShift) }   // Opt+Shift+Right
            try? await Task.sleep(nanoseconds: 30_000_000)
            after = await copyChanged(attempt == 0 ? 0.25 : 0.4)
            if after != nil { TextInserter.postKey(0x7B, flags: []) }        // Left: restore caret
            try? await Task.sleep(nanoseconds: 20_000_000)
            if before != nil || after != nil { break }
            yapdiag("insertctx: key-sim read empty, retrying once")
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        guard before != nil || after != nil else { return .none }
        yapdiag("insertctx: key-sim read before=\((before ?? "").suffix(30).debugDescription) after=\((after ?? "").prefix(30).debugDescription)")
        return Surround(before: before ?? "", after: after ?? "", available: true)
    }

    /// The one-call entry the inserter uses: read surroundings (AX when the process may,
    /// key-simulation inside the sandbox), adapt if possible.
    @MainActor
    static func adapted(_ text: String) async -> String {
        var s = read()
        if !s.available { s = await keyRead() }
        guard s.available, !(s.before.isEmpty && s.after.isEmpty) else { return text }
        return adapt(text, before: s.before, after: s.after)
    }
}
