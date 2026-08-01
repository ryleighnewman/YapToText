import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A click-to-record shortcut field. Click it, press the keys you want, and it captures
/// them as a `KeyCombo` (Carbon key code + modifier mask) ready for `RegisterEventHotKey`.
/// Esc cancels the capture; Delete clears the shortcut when `allowsEmpty` is true.
struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    var allowsEmpty: Bool = true
    /// Shown when no combo is set - lets a row surface a built-in default (e.g. the dictation
    /// pause key showing "Space") instead of a misleading "Not set".
    var placeholder: String = "Not set"
    /// Start listening the moment the field appears (used in onboarding, where the row invites
    /// "press your keys" - without this the field is deaf until clicked, which reads as the app
    /// not seeing the keyboard at all).
    var autoStart: Bool = false
    /// The shortcut's factory default, if it has one: enables "Reset to Default" in the
    /// field's right-click menu.
    var defaultCombo: KeyCombo? = nil

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.allowsEmpty = allowsEmpty
        view.placeholder = placeholder
        view.autoStart = autoStart
        view.combo = combo
        view.defaultCombo = defaultCombo
        view.onChange = { context.coordinator.commit($0) }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        context.coordinator.parent = self
        nsView.allowsEmpty = allowsEmpty
        nsView.placeholder = placeholder
        if !nsView.isRecording {
            nsView.combo = combo
            nsView.updateAppearance()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: HotkeyRecorderField
        init(_ parent: HotkeyRecorderField) { self.parent = parent }
        func commit(_ combo: KeyCombo?) { parent.combo = combo }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags, keyCode: UInt32 = UInt32.max) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= KeyCombo.cmd }
        if flags.contains(.option)  { mods |= KeyCombo.option }
        if flags.contains(.control) { mods |= KeyCombo.control }
        if flags.contains(.shift)   { mods |= KeyCombo.shift }
        // Fn/Globe held with an ordinary key is a real Fn combo ("Fn A"). Keys that intrinsically
        // carry .function (arrows, F-keys, the nav cluster) must NOT record a phantom Fn.
        if flags.contains(.function), !intrinsicFunctionKeys.contains(keyCode) { mods |= KeyCombo.fn }
        return mods
    }

    /// Key codes whose events always carry the .function flag on their own.
    static let intrinsicFunctionKeys: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90,                        // F13-F20
        123, 124, 125, 126,                                        // arrows
        115, 119, 116, 121, 117, 114,                              // home/end/page/fwd-delete/help
    ]

    /// Keys usable with no modifier at all (function keys).
    static func isStandaloneKey(_ keyCode: UInt32) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(keyCode)
    }
}

/// The AppKit control behind `HotkeyRecorderField`.
final class RecorderNSView: NSView {
    var combo: KeyCombo?
    var allowsEmpty = true
    var placeholder = "Not set"
    var autoStart = false
    var onChange: ((KeyCombo?) -> Void)?
    private(set) var isRecording = false
    private var keyMonitor: Any?
    private var fnHeldAlone = false
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Flexible width: a fixed intrinsic width overrides SwiftUI's .frame(width:) at
    // required priority, making the box draw wider than its slot (same bug as the
    // modifier-key field). Height stays fixed; width obeys the call site.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
    override var acceptsFirstResponder: Bool { isRecording }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var defaultCombo: KeyCombo?

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    /// Right-click on ANY shortcut field: the same little Clear / Reset menu everywhere.
    override func rightMouseDown(with event: NSEvent) {
        if isRecording { stopRecording() }
        let menu = NSMenu()
        if allowsEmpty {
            let clear = NSMenuItem(title: "Turn Off", action: #selector(clearCombo), keyEquivalent: "")
            clear.target = self
            clear.isEnabled = combo != nil
            menu.addItem(clear)
        }
        if let def = defaultCombo {
            let reset = NSMenuItem(title: "Reset to Default (\(def.displayString))", action: #selector(resetCombo), keyEquivalent: "")
            reset.target = self
            reset.isEnabled = combo != def
            menu.addItem(reset)
        }
        let record = NSMenuItem(title: "Record New Shortcut", action: #selector(beginRecordingFromMenu), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func clearCombo() {
        combo = nil
        onChange?(nil)
        updateAppearance()
    }

    @objc private func resetCombo() {
        guard let def = defaultCombo else { return }
        combo = def
        onChange?(def)
        updateAppearance()
    }

    @objc private func beginRecordingFromMenu() { startRecording() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Arm immediately when asked: the onboarding row promises "press your keys", so the
        // field must already be listening when it appears, not after a click nobody knows to make.
        if autoStart, window != nil, combo == nil, !isRecording {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isRecording else { return }
                self.startRecording()
            }
        }
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        // Capture via a LOCAL key monitor, not just the responder chain: inside a SwiftUI overlay
        // (e.g. onboarding) the view may never become first responder, so keyDown never fires. The
        // monitor always sees the keys. No Accessibility needed - it's app-local. Returning nil
        // swallows the event so the shortcut doesn't type or trigger anything else.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .flagsChanged {
                // Bare Fn/Globe as a shortcut: Fn alone never produces keyDown, only
                // flagsChanged. Press-and-release with nothing else -> record it.
                if event.keyCode == 63 {
                    if event.modifierFlags.contains(.function) {
                        self.fnHeldAlone = true   // pressed; commit on release if still alone
                    } else if self.fnHeldAlone {
                        self.fnHeldAlone = false
                        let combo = KeyCombo(keyCode: 63, modifiers: KeyCombo.fn)
                        self.combo = combo
                        self.onChange?(combo)
                        self.stopRecording()
                    }
                } else {
                    self.fnHeldAlone = false   // some other modifier moved: not a bare Fn tap
                }
                return nil
            }
            self.fnHeldAlone = false   // a real key arrived; Fn (if held) is a modifier now
            self.handle(event)
            return nil
        }
        updateAppearance()
    }

    private func stopRecording() {
        endRecording()
        window?.makeFirstResponder(nil)
    }

    private func endRecording() {
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        updateAppearance()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        if keyCode == 53 { stopRecording(); return }        // Esc: cancel capture, keep old value
        if keyCode == 51 || keyCode == 117 {                // Delete / Forward Delete: clear
            if allowsEmpty { combo = nil; onChange?(nil) }
            stopRecording()
            return
        }
        // Any key is a valid shortcut, including a bare letter or function key. A modifier-less
        // key does hijack that key globally - the UI warns about that where the combo is set.
        let mods = HotkeyRecorderField.carbonModifiers(from: event.modifierFlags, keyCode: keyCode)
        let newCombo = KeyCombo(keyCode: keyCode, modifiers: mods)
        combo = newCombo
        onChange?(newCombo)
        stopRecording()
    }

    func updateAppearance() {
        if isRecording {
            label.stringValue = "Type shortcut…"
            label.textColor = .secondaryLabelColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        } else {
            label.stringValue = combo?.displayString ?? placeholder
            label.textColor = combo == nil ? .tertiaryLabelColor : .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
