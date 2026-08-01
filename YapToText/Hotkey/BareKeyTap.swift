import AppKit

/// Global listener for a MODIFIER-LESS dictation shortcut (a bare letter like J). Carbon's
/// RegisterEventHotKey silently ignores ordinary keys with no modifiers, so those route through
/// a CGEvent tap instead - the same infrastructure as DigitKeyTap (and InputConfig). The key is
/// swallowed so it doesn't also type into the front app.
///
/// Needs Accessibility permission like every event tap; `start` returns false when the tap can't
/// be created so the UI can say the shortcut is not live instead of failing silently.
final class BareKeyTap {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Marker stamped on the app's own synthetic events (TextInserter) so this tap never
    /// swallows or triggers on its own typing/pasting.
    static let syntheticMarker: Int64 = 0x59545054   // 'YTPT'

    private var keyCode: Int64 = -1
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Modifier spec: cmd/opt/ctrl/shift the combo REQUIRES (any other of the four = someone
    /// else's shortcut) and whether Fn/Globe must be held. Defaults preserve the original
    /// bare-key behavior: no modifiers at all.
    private var requiredFlags: CGEventFlags = []
    private var requireFn = false

    @discardableResult
    func start(keyCode: UInt32, requiredFlags: CGEventFlags = [], requireFn: Bool = false) -> Bool {
        stop()
        self.keyCode = Int64(keyCode)
        self.requiredFlags = requiredFlags
        self.requireFn = requireFn
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<BareKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
        keyCode = -1
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall; re-enable and pass the event on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else {
            return Unmanaged.passUnretained(event)
        }
        // Never react to the app's own synthetic typing/pasting.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }
        // Exact modifier match: every required modifier held, and NONE of the other three -
        // anything else is someone else's shortcut. (Original bare-key mode: all four empty.)
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let held = event.flags.intersection(mods)
        guard held == requiredFlags.intersection(mods) else {
            return Unmanaged.passUnretained(event)
        }
        if requireFn, !event.flags.contains(.maskSecondaryFn) {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .keyDown:
            // Holding the key autorepeats; only the first press counts.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            DispatchQueue.main.async { [weak self] in self?.onKeyDown?() }
            return nil
        case .keyUp:
            DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    deinit { stop() }
}
