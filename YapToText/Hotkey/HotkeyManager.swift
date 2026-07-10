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
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x59543254), id: 1)  // 'YT2T'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        return status == noErr && hotKeyRef != nil
    }

    func unregister() {
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
