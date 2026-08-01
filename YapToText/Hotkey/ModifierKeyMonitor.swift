import AppKit

/// Watches a lone Right Command press so it can start/stop dictation - the trigger the
/// hotkey APIs can't provide (Carbon can't register a bare modifier). Uses NSEvent global
/// monitors, which only deliver events when Accessibility is granted; without it this simply
/// never fires. A tap only counts if no other key was pressed while the modifier was down,
/// so Cmd-C / Cmd-Tab chords never trigger dictation.
import IOKit
import IOKit.hidsystem

final class ModifierKeyMonitor {
    /// Flip the system caps-lock LOCK STATE off so a caps-as-trigger press never leaves
    /// the light on or capitals engaged. Plain IOHIDSystem parameter connection - no
    /// special entitlements; if the sandbox refuses, the trigger still works and only
    /// the light misbehaves (logged once).
    /// When we last forced the lock off, so the flagsChanged that reset emits (bit
    /// clearing, keyCode 57) is never mistaken for a fresh user press.
    private static var lastForcedOff = Date.distantPast

    static func forceCapsLockOff() {
        lastForcedOff = Date()
        var connect: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            yapdiag("capsLock: IOHIDSystem open refused; lock state not reset")
            return
        }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
        IOServiceClose(connect)
    }

    var onDown: (() -> Void)?
    var onUp: ((_ wasCleanTap: Bool) -> Void)?
    /// Fired when another key is tapped WHILE Right Command is held (e.g. Right Command + Space to
    /// open the mode switcher). The tap counts as a chord, so releasing won't also toggle.
    var onChord: ((_ keyCode: UInt16) -> Void)?

    /// Which modifier this instance watches. Defaults to Right Command; the Fn/Globe key (keyCode
    /// 63, .function flag) uses the same flagsChanged mechanics. Note .function alone is NOT unique
    /// (arrows and F-keys carry it too) - the keyCode gate below is what isolates the actual key.
    let watchedKeyCode: UInt16
    let watchedFlag: NSEvent.ModifierFlags
    init(keyCode: UInt16 = 54, flag: NSEvent.ModifierFlags = .command) {
        watchedKeyCode = keyCode
        watchedFlag = flag
    }

    private var monitors: [Any] = []
    /// The system-wide keyDown monitor is installed ONLY while Right Command is held. Left always
    /// on, it would wake this app's main thread on every keystroke the user types in any app -
    /// purely to detect a chord that can only happen during the hold window.
    private var globalKeyMonitor: Any?
    private var isDown = false
    private var interrupted = false

    func start() {
        stop()
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        // Global flagsChanged stays on - it's how we catch the Right Command press itself, and
        // modifier events are far rarer than keystrokes.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { monitors.append(m) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event); return event
        } as Any)
        // Local keyDown fires only when THIS app is focused, so its idle cost is ~zero - keep it on.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event.keyCode); return event
        } as Any)
    }

    func stop() {
        removeGlobalKeyMonitor()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        isDown = false
        interrupted = false
    }

    private func handleKey(_ keyCode: UInt16) {
        guard isDown else { return }
        interrupted = true                     // chord, not a lone tap
        onChord?(keyCode)
    }

    private func installGlobalKeyMonitor() {
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event.keyCode)
        }
    }

    private func removeGlobalKeyMonitor() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    private func handleFlags(_ event: NSEvent) {
        // CAPS LOCK is a toggle at the HID level: a press flips the .capsLock bit (there
        // is no held state to track). Each press that turns the bit ON counts as one
        // clean tap - and the OS lock state is immediately forced back OFF (IOKit), so
        // the light never sticks and typing never goes to capitals. The forced reset
        // emits a bit-clearing flagsChanged, which the contains() check below ignores.
        if watchedKeyCode == 57 {
            guard event.keyCode == 57 else { return }
            let bitOn = event.modifierFlags.contains(.capsLock)
            yapdiag("capsLock: flagsChanged bit=\(bitOn ? "on" : "off")")
            // EITHER transition is a physical press. Requiring the bit to turn ON made
            // the trigger dead whenever the lock was already engaged (light left on by
            // a failed reset, or toggled before the app launched): that press CLEARS
            // the bit and was ignored - "caps lock cannot be detected".
            if !bitOn, Date().timeIntervalSince(Self.lastForcedOff) < 0.3 {
                return   // the clearing event our own reset just emitted, not the user
            }
            if bitOn { Self.forceCapsLockOff() }   // never leave the light/capitals on
            onDown?()
            onUp?(true)
            return
        }
        guard event.keyCode == watchedKeyCode else {
            // A different modifier moved while ours is held: treat as a chord.
            if isDown { interrupted = true }
            return
        }
        let down = event.modifierFlags.contains(watchedFlag)
        if down && !isDown {
            isDown = true
            interrupted = false
            installGlobalKeyMonitor()          // arm chord detection only for the hold window
            onDown?()
        } else if !down && isDown {
            isDown = false
            removeGlobalKeyMonitor()
            onUp?(!interrupted)
            interrupted = false
        }
    }
}
