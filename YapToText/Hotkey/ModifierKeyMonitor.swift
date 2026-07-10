import AppKit

/// Watches a lone Right Command press so it can start/stop dictation - the trigger the
/// hotkey APIs can't provide (Carbon can't register a bare modifier). Uses NSEvent global
/// monitors, which only deliver events when Accessibility is granted; without it this simply
/// never fires. A tap only counts if no other key was pressed while the modifier was down,
/// so Cmd-C / Cmd-Tab chords never trigger dictation.
final class ModifierKeyMonitor {
    var onDown: (() -> Void)?
    var onUp: ((_ wasCleanTap: Bool) -> Void)?
    /// Fired when another key is tapped WHILE Right Command is held (e.g. Right Command + Space to
    /// open the mode switcher). The tap counts as a chord, so releasing won't also toggle.
    var onChord: ((_ keyCode: UInt16) -> Void)?

    private var monitors: [Any] = []
    private var isDown = false
    private var interrupted = false
    private let rightCommandKeyCode: UInt16 = 54

    func start() {
        stop()
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isDown else { return }
            self.interrupted = true            // chord, not a lone tap
            self.onChord?(event.keyCode)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) { monitors.append(m) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event); return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyHandler(event); return event
        } as Any)
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        isDown = false
        interrupted = false
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == rightCommandKeyCode else {
            // A different modifier moved while ours is held: treat as a chord.
            if isDown { interrupted = true }
            return
        }
        let down = event.modifierFlags.contains(.command)
        if down && !isDown {
            isDown = true
            interrupted = false
            onDown?()
        } else if !down && isDown {
            isDown = false
            onUp?(!interrupted)
            interrupted = false
        }
    }
}
