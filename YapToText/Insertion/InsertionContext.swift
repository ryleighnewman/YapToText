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
        /// Worth one more, quiet read at delivery time. Set when the key-sim read got an
        /// ANSWER to its copy but an empty one (the app is alive and serving Cmd+C, it just
        /// had not moved its selection yet: a web editor starved by the decode, Gmail in
        /// Safari 2026-09-16), and when an app that has answered before went silent this
        /// time (an Electron chat app, same day). A silent app that has never answered
        /// is an empty field or a surface that cannot answer, and is left alone.
        var retryAtDelivery = false
        /// The dictation is REPLACING this selected text. Its surroundings cannot be read
        /// (the selection dance would destroy the selection), but the selection's own
        /// shape says what fits: a lowercase word mid-sentence wants a lowercase word
        /// with no period, a sentence wants a sentence.
        var replacing: String?
        static let none = Surround(before: "", after: "", available: false)
    }

    /// Adapt a dictation that replaces `selection`: match its case, its end mark, and its
    /// edge spaces. Selecting "feelings" and saying "hearing aids" used to land "Hearing
    /// aids." in the middle of the sentence (caught live, 2026-09-16).
    static func adaptReplacing(_ text: String, selection: String) -> String {
        let hadTrailingSpace = text.hasSuffix(" ")
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return text }
        let selCore = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selFirst = selCore.first(where: { $0.isLetter || $0.isNumber }) else { return text }
        // Case: a selection that starts lowercase is mid-sentence. Spare "I", contractions
        // of it, and acronyms or names whose second letter is a capital.
        if selFirst.isLowercase, let first = t.first, first.isUppercase {
            let firstWord = t.prefix(while: { $0.isLetter || $0 == "'" })
            let secondIsUpper = t.dropFirst().first?.isUppercase ?? false
            let isI = firstWord == "I" || firstWord.hasPrefix("I'")
            if !isI, !secondIsUpper { t = first.lowercased() + t.dropFirst() }
        } else if selFirst.isUppercase, let first = t.first, first.isLowercase {
            t = first.uppercased() + t.dropFirst()
        }
        // End mark: keep the selection's, not the dictation's. A word or phrase with no
        // mark takes none; a selection that ended a sentence keeps that same mark.
        let selMark = selCore.last.flatMap { ".!?,;:".contains($0) ? $0 : nil }
        while let last = t.last, ".!?,;:".contains(last) { t.removeLast() }
        if let selMark { t.append(selMark) }
        // Edge spaces: a double-click selection often carries its trailing space; give it back.
        if selection.hasPrefix(" ") { t = " " + t }
        if selection.hasSuffix(" ") || hadTrailingSpace { t += " " }
        return t
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
        // A trailing space the caller added on purpose ("Add a space after insertions")
        // must survive: trimming both ends silently cancelled that setting.
        let hadTrailingSpace = text.hasSuffix(" ")
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return text }

        // Where does the preceding text leave us? Empty field / fresh line / after a
        // sentence end = sentence start; anything else = mid-sentence.
        let visibleBefore = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevChar = visibleBefore.last
        let atSentenceStart = prevChar == nil
            || ".!?".contains(prevChar!)
            || before.hasSuffix("\n") || before.hasSuffix("\n ")

        // Caret parked just BEFORE the mark that closes the previous sentence ("...condition|. ")
        // and a whole sentence dictated there: the user means a new sentence, not a clause
        // tacked onto the old one. Close the old sentence first and keep the capital; the
        // dictation's own period is dropped below because the existing mark closes it.
        // A short phrase (three words or fewer) is still treated as a continuation.
        let afterVisible = after.drop(while: { $0 == " " })
        let afterMark = afterVisible.first
        let afterMarkRest = afterVisible.dropFirst().first
        let beforeClosingMark = !atSentenceStart
            && afterMark.map({ ".!?".contains($0) }) == true
            && (afterMarkRest == nil || afterMarkRest!.isWhitespace || afterMarkRest!.isNewline)
            && t.split(whereSeparator: { $0.isWhitespace }).count >= 4
        // ...unless the dictation opens with a joining word ("which includes...", "and then...",
        // "because..."): that is a clause extending the old sentence, so it joins with a
        // comma and a lowercase start instead of closing the sentence first.
        let firstWordRaw = t.prefix(while: { $0.isLetter || $0 == "'" })
        let firstWordLower = firstWordRaw.lowercased()
        // An acronym ("WHO reported...") is not the word "who", and a question or exclamation
        // is a sentence of its own, never a clause.
        let isAcronym = firstWordRaw.count >= 2 && firstWordRaw.allSatisfy { $0.isUppercase }
        let isQuestionOrShout = t.hasSuffix("?") || t.hasSuffix("!")
        let extendsPrevious = beforeClosingMark && !isAcronym && !isQuestionOrShout && Self.clauseOpeners.contains(firstWordLower)
        let closesPrevious = beforeClosingMark && !extendsPrevious
        if !atSentenceStart, !closesPrevious, let first = t.first, first.isUppercase {
            let firstWord = t.prefix(while: { $0.isLetter || $0 == "'" })
            let secondIsUpper = t.dropFirst().first?.isUppercase ?? false
            let isI = firstWord == "I" || firstWord.hasPrefix("I'")
            if !isI, !secondIsUpper {
                t = first.lowercased() + t.dropFirst()
            }
        }

        // The sentence continues right after the cursor: the transcript must not close it.
        // And when a terminator ALREADY sits right after the cursor, the sentence is
        // closed without our help - keeping the transcript's own period printed ".."
        // (dictating just before an existing period doubled it).
        if let nextVisible = after.first(where: { !$0.isWhitespace }) {
            let continues = nextVisible.isLowercase || ",;:)]".contains(nextVisible)
            let alreadyClosed = ".!?\u{2026}".contains(nextVisible)
            if continues || alreadyClosed, t.hasSuffix(".") { t.removeLast() }
        }

        // Spacing against the neighbors: one space where words would otherwise collide.
        if closesPrevious {
            t = ". " + t   // "...condition. And dictation tools..." with the old mark closing the new sentence
        } else if extendsPrevious {
            // "...beautiful app, which includes..."; a subordinate "because" takes no comma.
            t = (Self.noCommaOpeners.contains(firstWordLower) ? " " : ", ") + t
        } else if let lastRaw = before.last, !lastRaw.isWhitespace,
           !"([{\u{201C}\u{2018}\"'/-".contains(lastRaw) {
            t = " " + t
        }
        if let firstAfter = after.first, firstAfter.isLetter || firstAfter.isNumber {
            t += " "
        }
        // The trailing-space setting separates the insertion from the NEXT WORD; a mark
        // that closes or continues the sentence hugs the last word ("quick edit." never
        // "quick edit .").
        let nextHugs = after.first.map({ ".,!?;:)]}\u{2026}".contains($0) }) ?? false
        if hadTrailingSpace, !t.hasSuffix(" "), !(after.first?.isWhitespace ?? false), !nextHugs {
            t += " "
        }
        if nextHugs, t.hasSuffix(" ") { t = String(t.dropLast()) }
        return t
    }

    /// Words that open a clause rather than a sentence when dictated just before the mark
    /// that closes the previous sentence. Deliberately short: "so", "since", "while",
    /// "although", "plus", "that", "when", and "where" start real sentences far too often.
    private static let clauseOpeners: Set<String> = [
        "which", "who", "whom", "whose", "and", "but", "or", "nor", "because",
    ]
    private static let noCommaOpeners: Set<String> = ["because"]

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
    /// `retry` is the delivery-time second chance after a pre-read that answered empty:
    /// no probe (the pre-read's probe already ruled out a live selection a moment ago), a
    /// medium settle, no late copy. The Mac is quiet by then, so the app can keep up.
    @MainActor
    private static func keyRead(patient: Bool, retry: Bool = false) async -> (s: Surround, appAnswered: Bool) {
        guard !TextInserter.isSecureInputActive else { return (.none, false) }
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
        lastSyntheticKeyAt = Date()   // the probe Cmd+C is posted inside copyChanged
        // A SENTINEL sits on the pasteboard during the probe. Some Electron editors answer
        // an empty-selection Cmd+C by re-writing whatever the pasteboard already holds;
        // the old test for that ("the copy equals the previous clipboard") could not tell
        // it from a REAL selection whose text the user had copied a moment earlier. In
        // Gmail the user selected the whole email they had just copied, dictated over it,
        // and the read walked the caret to the end and pasted outside the selection
        // (2026-09-16). With the sentinel in place, a re-write returns the sentinel and a
        // selection returns its text, whatever the clipboard held before.
        let sentinel = "\u{E000}"
        if !retry { pb.clearContents(); pb.setString(sentinel, forType: .string) }
        let probe: String? = retry ? "" : await copyChanged(patient ? 0.15 : 0.1)
        if let probe, probe == sentinel {
            yapdiag("insertctx: probe re-wrote the clipboard - no selection")
        } else if let probe, !probe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            yapdiag("insertctx: live selection (\(probe.prefix(24).debugDescription)) - replacing, adapting to its shape")
            // Deliberate stop, not a capability failure - report unanswered so the
            // outcome stays neutral and no strike is recorded. The selection itself is
            // the context: the paste replaces it, shaped like it.
            var s = Surround.none
            s.replacing = probe
            return (s, false)
        }
        // 2 + 3. Read both sides. Slow apps (Electron especially) sometimes service the
        //    synthetic selection keys or the copy late; one quiet retry makes the read
        //    land reliably instead of silently inserting unadapted - the "intelligent
        //    insert didn't turn on" report. The waits are async, so patience is free.
        var before: String?
        var after: String?
        var atSentenceStartResult = true
        // On the critical path (insert time) a single tight attempt: an app that answers
        // does so in well under 200ms, and a silent one should not hold the delivery
        // hostage. The pre-read keeps the patient two-attempt timing - it runs hidden
        // behind AI cleanup, where waiting costs nothing.
        // ONE attempt, even when patient. Every attempt fires ~9 command-key events and the
        // target's Edit menu flashes on each one - visibly ugly, and the second attempt
        // doubled it. A longer settle below buys the same reliability for half the flashing.
        let attempts = 1
        let probeAnswered = probe != nil
        // How long the target gets to ACT on the selection keys before we copy. 30ms is
        // fine for a native text field, but a canvas-backed web editor (Google Docs,
        // Notion) runs its own JS key handling and had not moved the selection yet - the
        // copy then returned an EMPTY string, which is exactly what "smart insert does
        // nothing in Google Docs" looked like. The pre-read has time to spare, so spend it.
        let settle: UInt64 = retry ? 120_000_000 : (patient ? 240_000_000 : 30_000_000)
        let copyWait: TimeInterval = retry ? 0.22 : (patient ? 0.5 : 0.18)
        func isBlank(_ v: String?) -> Bool { (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for attempt in 0..<attempts {
            // BEFORE: select up to three words back, copy, collapse to the selection's
            // RIGHT edge (the original caret). Collapse only when something was actually
            // selected - at the document start a bare Right would WALK the caret forward.
            for _ in 0..<3 { TextInserter.postKey(0x7B, flags: optShift) }   // Opt+Shift+Left
            try? await Task.sleep(nanoseconds: settle)
            lastSyntheticKeyAt = Date()
            before = await copyChanged(copyWait)
            // LATE ANSWER: an EMPTY (not missing) copy means the app bumped the pasteboard
            // before it had moved the selection - an Electron renderer starved by the
            // whisper decode running on every core at that same moment. About one Electron
            // read in four came back this way and inserted unadapted (no space after the
            // previous sentence). The selection keys are already queued, so give the app
            // another beat and copy again: one extra Cmd+C, no extra selection keys.
            if patient, !retry, before == "" {
                try? await Task.sleep(nanoseconds: 220_000_000)
                lastSyntheticKeyAt = Date()
                if let again = await copyChanged(0.4), !isBlank(again) {
                    yapdiag("insertctx: before-read answered on the late copy")
                    before = again
                }
            }
            // Collapse ONLY when the copy answered - a non-answer means we cannot tell
            // whether anything got selected, and a bare Right with NO selection WALKS the
            // caret forward one character. Doing it unconditionally moved the cursor to
            // the wrong spot on every silent read, which is now every dictation since the
            // pre-read runs at stop. The stranded-selection risk this guarded against is
            // covered instead by the pre-read running ~a second before delivery, which
            // gives even a slow app time to service the keys before the paste lands.
            if before != nil { TextInserter.postKey(0x7C, flags: []); lastSyntheticKeyAt = Date() }   // Right: restore caret
            try? await Task.sleep(nanoseconds: 20_000_000)
            // AFTER-SIDE ECONOMY. The after-context matters only MID-sentence: it decides
            // whether the transcript's period would double an existing one and whether a
            // space is needed before a continuing word. When the before-context says the
            // caret is at a sentence start (nothing before it, or a terminator or line
            // break), skip the whole after-side read: that is 4 of the ~10 synthetic keys,
            // and its Cmd+C is an EMPTY-selection copy at the end of the text almost every
            // time - exactly the key apps refuse with a system beep (GitHub issue 4). The
            // one thing given up is the space before existing text when dictating at the
            // very start of a document, which the trailing-space setting already covers.
            let visibleBefore = (before ?? "").trimmingCharacters(in: .whitespaces)
            let atSentenceStart = isBlank(before)
                || ".!?".contains(visibleBefore.last!)
                || (before ?? "").hasSuffix("\n")
            atSentenceStartResult = atSentenceStart
            if atSentenceStart {
                yapdiag("insertctx: after-read skipped (caret at sentence start)")
                after = nil
            } else {
                // AFTER: mirror image - two words forward, collapse to the LEFT edge.
                for _ in 0..<2 { TextInserter.postKey(0x7C, flags: optShift) }   // Opt+Shift+Right
                try? await Task.sleep(nanoseconds: settle)
                lastSyntheticKeyAt = Date()
                after = await copyChanged(copyWait)
                if after != nil { TextInserter.postKey(0x7B, flags: []); lastSyntheticKeyAt = Date() }   // Left: restore caret
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // A non-nil but BLANK read on both sides means the target bumped the
            // pasteboard without having moved its selection yet: no context at all, so
            // treat it as unanswered and give it the retry rather than "adapting" to "".
            if !isBlank(before) || !isBlank(after) { break }
            if attempt + 1 >= attempts { break }
            // The retry stays: slow apps (Electron) often answer on the second attempt,
            // and counting their first-beat silence as failure got a WORKING app banned
            // by the capability cache ("smart insert stopped working" in the user's main
            // app). Dead apps now get caught by the cache instead of by skipping retries.
            yapdiag("insertctx: key-sim read empty, retrying once")
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        // The AFTER side can be starved just like the before side: an answered-empty copy
        // mid-sentence ("outside of that| region.", Gmail, 2026-09-16) let the dictation
        // land with its capital and period intact. Flag it for the delivery-time retry.
        if !retry, !isBlank(before), after == "", !atSentenceStartResult {
            var s = Surround(before: before ?? "", after: "", available: true)
            s.retryAtDelivery = true
            yapdiag("insertctx: key-sim read before=\((before ?? "").suffix(30).debugDescription) after answered empty - will retry at delivery")
            return (s, true)
        }
        guard !isBlank(before) || !isBlank(after) else {
            // Reported as UNANSWERED on purpose, so a blank read scores neutral and never
            // accrues strikes: a slow web editor that gave nothing this time is not an app
            // that can never answer, and banning it is how the feature silently died in
            // the user's main app once already.
            yapdiag("insertctx: read came back blank (before=\(before == nil ? "unanswered" : "empty"))\(retry ? " on the retry" : "") - inserting unadapted")
            var none = Surround.none
            none.retryAtDelivery = before != nil && !retry
            return (none, false)
        }
        yapdiag("insertctx: key-sim read before=\((before ?? "").suffix(30).debugDescription) after=\((after ?? "").prefix(30).debugDescription)")
        return (Surround(before: before ?? "", after: after ?? "", available: true), true)
    }

    // PER-APP CAPABILITY MEMORY: some apps never answer the key-sim read (games, some
    // Electron surfaces, terminals) - every dictation there paid the full ~2s timeout
    // budget and inserted unadapted anyway. After 3 consecutive total failures in an app
    // the read is skipped there, with a re-probe every 25th insert so an app that starts
    // cooperating (update, settings change) gets rediscovered.
    private static func failKey(_ b: String) -> String { "insertctx.fail." + b }
    private static func answeredKey(_ b: String) -> String { "insertctx.answered." + b }
    /// Has this app EVER answered a key-sim read? Silence from such an app is a starved
    /// or busy moment, not an inability, and earns the delivery-time retry.
    static func hasAnswered(bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return UserDefaults.standard.bool(forKey: answeredKey(b))
    }
    private static func blankKey(_ b: String) -> String { "insertctx.blank." + b }
    private static func skipKey(_ b: String) -> String { "insertctx.skips." + b }

    /// Web browsers are never remembered as silent: whether a read answers depends on the
    /// PAGE, not the app. Eight quiet reads on pages with no text field banned Safari for
    /// the next 25 dictations, including the ones typed into a real form.
    private static func isBrowser(_ b: String) -> Bool {
        b.hasPrefix("com.apple.Safari") || b == "com.google.Chrome" || b.hasPrefix("com.google.Chrome.")
            || b == "org.mozilla.firefox" || b == "company.thebrowser.Browser" || b == "com.microsoft.edgemac"
            || b == "com.brave.Browser" || b == "com.vivaldi.Vivaldi" || b == "com.operasoftware.Opera"
    }

    /// Apps where reading the surroundings is DESTRUCTIVE rather than merely useless.
    ///
    /// The read works by sending Opt+Shift+Left/Right to select the words around the cursor.
    /// In a normal text field those are selection keys. In a terminal they are handed to
    /// whatever full-screen program is running, which treats them as its own shortcuts:
    /// GitHub issue #5 had Microsoft Copilot CLI opening its sessions sidebar on every
    /// dictation, after which the text landed nowhere. There is nothing to adapt to at a
    /// shell prompt anyway, so skipping costs nothing and saves the timeout.
    ///
    /// Matched on the TERMINAL's bundle id, because a TUI has no bundle id of its own.
    static let readIsDestructive: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.termius.mac",
    ]

    /// The user's per-app choice, falling back to the built-in list. Set from AppDelegate so
    /// this file stays free of a settings dependency.
    nonisolated(unsafe) static var adaptOverrideLookup: (String) -> Bool? = { _ in nil }

    static func adaptIsAllowed(bundleID: String?) -> Bool {
        guard let b = bundleID else { return true }
        if let pinned = adaptOverrideLookup(b) { return pinned }
        return !readIsDestructive.contains(b)
    }

    private static func shouldSkipRead(bundleID: String?) -> Bool {
        migrateBansOnce()
        guard let b = bundleID else { return false }
        let ud = UserDefaults.standard
        if isBrowser(b) {
            if ud.integer(forKey: failKey(b)) != 0 { ud.set(0, forKey: failKey(b)); ud.set(0, forKey: blankKey(b)) }
            return false
        }
        guard ud.integer(forKey: failKey(b)) >= 5 else { return false }
        let skips = ud.integer(forKey: skipKey(b)) + 1
        // Re-probe every 10th dictation, not 25th: a wrongly banned app came back far too
        // slowly, and a re-probe costs one read.
        if skips >= 10 {
            ud.set(0, forKey: skipKey(b))
            ud.set(4, forKey: failKey(b))   // one strike from re-banning: a single failed re-probe re-skips
            yapdiag("insertctx: re-probing \(b) after 10 skipped reads")
            return false
        }
        ud.set(skips, forKey: skipKey(b))
        return true
    }

    private enum ReadOutcome { case success, failure, neutral }

    private static func recordReadOutcome(bundleID: String?, _ outcome: ReadOutcome) {
        guard let b = bundleID else { return }
        let ud = UserDefaults.standard
        switch outcome {
        case .success:
            ud.set(true, forKey: answeredKey(b))
            ud.set(0, forKey: failKey(b))
            ud.set(0, forKey: skipKey(b))
            ud.set(0, forKey: blankKey(b))
        case .failure:
            ud.set(ud.integer(forKey: failKey(b)) + 1, forKey: failKey(b))
        case .neutral:
            // Total silence is ambiguous: a dead app OR an empty field (empty-selection
            // Cmd+C never bumps the pasteboard in most native and Electron editors, and
            // an empty field needs no adaptation anyway). One or two are meaningless, so
            // they must not ban an app the way a hard failure does.
            //
            // But they cannot be free either. Reading the surroundings costs ~10 synthetic
            // key events, and a target that leaves any of them UNHANDLED makes macOS beep
            // once per event - the "system beep two or three times after a dictation"
            // report. Silence every single time is the signature of a surface that will
            // never answer, so let it accumulate toward its own, much higher bar: an
            // occasional empty field never reaches it, a never-answering app reaches it in
            // a handful of dictations and is then left alone (the every-25th re-probe
            // still rediscovers it if that ever changes).
            // Counted for the diagnostics only. It used to BAN the app at eight in a row,
            // and eight in a row is exactly what a chat app produces: every new message
            // starts in an empty composer, the read finds nothing on either side, and
            // eight messages later smart insert silently stopped working there. That
            // banned the user's main app twice and Safari once. An app that never
            // answers still costs its keystrokes; a working app that goes dark is worse.
            let blanks = ud.integer(forKey: blankKey(b)) + 1
            ud.set(blanks, forKey: blankKey(b))
        }
    }

    /// One-time: clear every ban the old blank-strike rule handed out, so an app that
    /// was silenced under 1.3.1 or 1.4 comes back on the first launch of this build.
    private static var migrated = false
    private static func migrateBansOnce() {
        guard !migrated else { return }
        migrated = true
        let ud = UserDefaults.standard
        let flag = "insertctx.migrated.blankban"
        guard !ud.bool(forKey: flag) else { return }
        var cleared = 0
        for key in ud.dictionaryRepresentation().keys where key.hasPrefix("insertctx.") {
            ud.removeObject(forKey: key); cleared += 1
        }
        ud.set(true, forKey: flag)
        if cleared > 0 { yapdiag("insertctx: cleared \(cleared) inherited capability entries") }
    }

    /// When keyRead last posted a synthetic key event, so delivery can drain exactly the
    /// remainder of the settle window instead of a fixed 140ms - and nothing at all when
    /// the read never posted (skipped app, Secure Input, AX answered). Main actor only.
    static private(set) var lastSyntheticKeyAt: Date?

    /// Read the surroundings NOW (AX when the process may, key-simulation inside the
    /// sandbox), with the per-app skip. Separated from adapt() so the read can run
    /// CONCURRENTLY with AI cleanup - its latency hides behind the model's.
    @MainActor
    static func readSurroundings(patient: Bool = false, retry: Bool = false) async -> Surround {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if !adaptIsAllowed(bundleID: bundle) {
            yapdiag("insertctx: adapt off for \(bundle ?? "?") (destructive or pinned off)")
            return .none
        }
        if shouldSkipRead(bundleID: bundle) {
            yapdiag("insertctx: skipping read for \(bundle ?? "?") (never answers)")
            return .none
        }
        var s = read()
        var appAnswered = true          // the AX path answering IS an answer
        if !s.available {
            let key = await keyRead(patient: patient, retry: retry)
            s = key.s
            appAnswered = key.appAnswered
            // Silence from an app that has answered before: retry once at delivery.
            if !retry, !s.available, !s.retryAtDelivery, s.replacing == nil, !appAnswered,
               !TextInserter.isSecureInputActive, hasAnswered(bundleID: bundle) {
                s.retryAtDelivery = true
            }
        }
        let outcome: ReadOutcome = s.available ? .success : (appAnswered ? .failure : .neutral)
        recordReadOutcome(bundleID: bundle, outcome)
        return s
    }

    /// The one-call entry the inserter uses when no pre-read is available.
    @MainActor
    static func adapted(_ text: String, presurround: Surround? = nil,
                        allowInsertTimeRead: Bool = false) async -> String {
        var s: Surround
        if presurround == nil, !allowInsertTimeRead {
            // No pre-read (focus changed mid-cleanup, or adaptation was off when the
            // session started): insert unadapted rather than driving the caret while the
            // paste is milliseconds away - synthetic selection keys racing a Cmd+V is how
            // text ends up replaced instead of inserted.
            return text
        }
        if let presurround {
            // A completed pre-read is authoritative - it already ran patiently in the
            // frontmost target during cleanup. Re-reading here would repeat the whole
            // caret dance on the critical path for the same answer.
            s = presurround
        } else {
            s = await readSurroundings()
        }
        if let sel = s.replacing { return adaptReplacing(text, selection: sel) }
        guard s.available, !(s.before.isEmpty && s.after.isEmpty) else { return text }
        return adapt(text, before: s.before, after: s.after)
    }
}
