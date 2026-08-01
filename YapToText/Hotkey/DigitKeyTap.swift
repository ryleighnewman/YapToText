import AppKit

/// While a dictation is in progress, plain number keys 1-9 pick which post-processing mode the
/// finished transcript is fed through - press 2 mid-sentence and the whole message comes out as
/// an email - and the SPACE bar pauses/resumes the dictation. A CGEvent tap (armed ONLY while
/// recording) swallows those keys so they don't also reach the app you're dictating into. Modified
/// keys (Cmd-1, Cmd-Space, etc.) pass through untouched. Needs Accessibility, same as the Right
/// Command trigger.
final class DigitKeyTap {
    var onDigit: ((Int) -> Void)?
    /// Space bar pressed (bare) mid-dictation: the default pause/resume toggle.
    var onSpace: (() -> Void)?

    /// Modifier flags a push-to-talk trigger holds down while you dictate (Right Command,
    /// or the modifiers in a chord like Control-Option-Space). These are subtracted before
    /// the bare-key check so a digit pressed mid-sentence still switches modes even though
    /// the trigger key is physically held.
    var heldModifiers: CGEventFlags = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// ANSI keycode for the space bar.
    private static let spaceKeyCode: Int64 = 49
    /// ANSI keycodes for the digit row, 1...9.
    private static let digitCodes: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DigitKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr) else { return }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system paused the tap (timeout / user input protection).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        // Our own synthetic events (live typing, paste keystrokes) must pass straight through -
        // otherwise a live-typed digit or space would be swallowed as a mode-switch/pause.
        guard event.getIntegerValueField(.eventSourceUserData) != BareKeyTap.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Only BARE keys act as controls; keep Cmd-1, Opt-2, Cmd-Space etc. working normally.
        // A push-to-talk trigger is held down while you dictate, so ignore exactly those
        // trigger modifiers - any OTHER modifier still passes the key through untouched.
        let mods = event.flags
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            .subtracting(heldModifiers)
        guard mods.isEmpty else { return Unmanaged.passUnretained(event) }

        if keyCode == Self.spaceKeyCode {
            if type == .keyDown { DispatchQueue.main.async { [weak self] in self?.onSpace?() } }
            return nil   // swallow space so it pauses instead of typing into the focused app
        }
        guard let digit = Self.digitCodes[keyCode] else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            let d = digit
            DispatchQueue.main.async { [weak self] in self?.onDigit?(d) }
        }
        return nil   // swallow both down and up so nothing reaches the focused app
    }
}
