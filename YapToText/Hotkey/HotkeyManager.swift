import AppKit
import Carbon.HIToolbox

/// Registers the global dictation shortcut via Carbon `RegisterEventHotKey`. This is
/// narrowly scoped and needs NO Accessibility or Input Monitoring permission, and it
/// delivers both key-down and key-up so push-to-talk works.
final class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false

    /// Returns false if the shortcut could not be registered (usually because it is already
    /// claimed by the system or another app), so the UI can warn instead of silently failing.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        // Fn/Globe combos: Carbon cannot express the Fn modifier at all, so these route through
        // a CGEvent tap (needs Accessibility, which every Fn feature already needs). The tap
        // swallows the chord so "Fn A" never also types an "a".
        if combo.includesFn, combo.keyCode == 63 {
            // BARE Fn/Globe: a modifier, so it never produces keyDown events - only the
            // flagsChanged monitor can see it (same mechanics as the Right Command trigger).
            let monitor = ModifierKeyMonitor(keyCode: 63, flag: .function)
            monitor.onDown = { [weak self] in self?.onKeyDown?() }
            monitor.onUp = { [weak self] clean in if clean { self?.onKeyUp?() } }
            monitor.start()
            fnMonitor = monitor
            return true
        }
        if combo.includesFn {
            let tap = BareKeyTap()
            tap.onKeyDown = { [weak self] in self?.onKeyDown?() }
            tap.onKeyUp = { [weak self] in self?.onKeyUp?() }
            var flags: CGEventFlags = []
            if combo.modifiers & KeyCombo.cmd != 0     { flags.insert(.maskCommand) }
            if combo.modifiers & KeyCombo.option != 0  { flags.insert(.maskAlternate) }
            if combo.modifiers & KeyCombo.control != 0 { flags.insert(.maskControl) }
            if combo.modifiers & KeyCombo.shift != 0   { flags.insert(.maskShift) }
            guard tap.start(keyCode: combo.keyCode, requiredFlags: flags, requireFn: true) else { return false }
            fnTap = tap
            return true
        }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x59543254), id: 1)  // 'YT2T'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        return status == noErr && hotKeyRef != nil
    }

    private var fnTap: BareKeyTap?
    private var fnMonitor: ModifierKeyMonitor?

    func unregister() {
        fnTap?.stop()
        fnTap = nil
        fnMonitor?.stop()
        fnMonitor = nil
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetEventDispatcherTarget(), { _, eventRef, userData -> OSStatus in
            guard let eventRef, let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(eventRef)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) {
                    manager.onKeyDown?()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    manager.onKeyUp?()
                }
            }
            return noErr
        }, 2, &eventTypes, context, &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
