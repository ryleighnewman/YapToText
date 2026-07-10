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

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.allowsEmpty = allowsEmpty
        view.placeholder = placeholder
        view.combo = combo
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

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= KeyCombo.cmd }
        if flags.contains(.option)  { mods |= KeyCombo.option }
        if flags.contains(.control) { mods |= KeyCombo.control }
        if flags.contains(.shift)   { mods |= KeyCombo.shift }
        return mods
    }

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
    var onChange: ((KeyCombo?) -> Void)?
    private(set) var isRecording = false
    private var keyMonitor: Any?
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

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }
    override var acceptsFirstResponder: Bool { isRecording }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        // Capture via a LOCAL key monitor, not just the responder chain: inside a SwiftUI overlay
        // (e.g. onboarding) the view may never become first responder, so keyDown never fires. The
        // monitor always sees the keys. No Accessibility needed - it's app-local. Returning nil
        // swallows the event so the shortcut doesn't type or trigger anything else.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
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
        let mods = HotkeyRecorderField.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 || HotkeyRecorderField.isStandaloneKey(keyCode) else {
            NSSound.beep()   // needs at least one modifier (or a function key)
            return
        }
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
