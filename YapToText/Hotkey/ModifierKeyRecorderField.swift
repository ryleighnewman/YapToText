import SwiftUI
import AppKit

/// Which binding a recorder field edits. The HUB commits through this role directly into
/// settings, so a commit works no matter which on-screen field instance started it.
enum KeyRecorderRole {
    case primaryDictation
    case quickEdit
}

/// THE RECORDING SESSION LIVES HERE, NOT IN THE VIEW. SwiftUI freely destroys and
/// recreates the little NSViews on busy pages (Home re-renders on every status tick),
/// and a session owned by the view died the instant that happened: the field flashed
/// armed and reverted - "the app isn't letting me change my keybinds". The hub is a
/// singleton no re-render can touch; views are disposable displays of its state.
@MainActor
final class KeyRecorderHub {
    static let shared = KeyRecorderHub()
    static let changed = Notification.Name("yap.keyRecorderHub.changed")
    static let recordingBegan = Notification.Name("yap.keyRecorder.began")
    static let recordingEnded = Notification.Name("yap.keyRecorder.ended")

    private(set) var armedRole: KeyRecorderRole?
    /// Transient guidance shown in the armed field ("Modifier keys only") when the user
    /// presses something the trigger system can't watch. Silence here was why rebinding
    /// felt broken: unsupported presses just did nothing.
    private(set) var flash: String?
    private var flashReset: Task<Void, Never>?
    private var monitor: Any?
    private var keyMonitor: Any?
    private var disarmTimer: Timer?
    private var resignObservers: [Any] = []

    func toggle(_ role: KeyRecorderRole) {
        if armedRole == role { stop() } else { begin(role) }
    }

    private func begin(_ role: KeyRecorderRole) {
        stop()
        armedRole = role
        yapdiag("keyRecorder: armed \(role)")
        // The live triggers stand down so the pressed key reaches the recorder instead
        // of starting a dictation or quick edit.
        NotificationCenter.default.post(name: Self.recordingBegan, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let role = self.armedRole else { return event }
            yapdiag("keyRecorder: flagsChanged code=\(event.keyCode)")
            // Commit on the PRESS of a recognized key. Caps Lock is a toggle: either
            // transition of its bit is a press.
            if let picked = PrimaryTriggerKey.allCases.first(where: { $0.keyCode == event.keyCode }),
               picked.keyCode == 57 || event.modifierFlags.contains(picked.flag) {
                self.commit(picked, for: role)
                return nil
            }
            // A recognizable key that ISN'T watchable (left cmd - the system owns too
            // much of it) still deserves a reaction, not silence.
            self.showFlash("Try the right-side keys, Fn, or Caps Lock")
            return event
        }
        // ANY other key commits as a CUSTOM trigger - zero restrictions. The key gets
        // swallowed app-wide by the trigger tap from then on, which is exactly the deal
        // the user is making ("this key IS my dictation key now").
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let role = self.armedRole else { return event }
            yapdiag("keyRecorder: custom keyDown code=\(event.keyCode)")
            self.commit(.custom(event.keyCode), for: role)
            return nil
        }
        // An armed session must never outlive the user's attention: disarm when the app
        // deactivates or after 10 quiet seconds. (No per-window coupling - the hub can't
        // know which window its current field lives in, and it doesn't need to.)
        disarmTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            Task { @MainActor in KeyRecorderHub.shared.stop() }
        }
        resignObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if KeyRecorderHub.shared.armedRole != nil {
                    yapdiag("keyRecorder: auto-disarm (app deactivated)")
                    KeyRecorderHub.shared.stop()
                }
            }
        })
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func commit(_ key: PrimaryTriggerKey, for role: KeyRecorderRole) {
        guard let settings = AppDelegate.shared?.state.settings else { stop(); return }
        yapdiag("keyRecorder: committed \(key.label) for \(role)")
        switch role {
        case .primaryDictation:
            settings.primaryTriggerKey = key
            AppDelegate.shared?.reloadRightCommandTrigger()
        case .quickEdit:
            settings.quickEditTriggerKey = key
            AppDelegate.shared?.reloadQuickEditKey()
        }
        stop()
    }

    private func showFlash(_ message: String) {
        flash = message
        NotificationCenter.default.post(name: Self.changed, object: nil)
        flashReset?.cancel()
        flashReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = nil
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func stop() {
        guard armedRole != nil || monitor != nil else { return }
        armedRole = nil
        flash = nil
        flashReset?.cancel(); flashReset = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        disarmTimer?.invalidate(); disarmTimer = nil
        for o in resignObservers { NotificationCenter.default.removeObserver(o) }
        resignObservers.removeAll()
        NotificationCenter.default.post(name: Self.recordingEnded, object: nil)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// A click-to-scan field for a trigger key - the same interaction as every other shortcut
/// field (click, then press), but it listens for a bare MODIFIER tap (flagsChanged), which
/// ordinary key recorders can't see. The view is a pure display of the hub's state.
struct ModifierKeyRecorderField: NSViewRepresentable {
    @Binding var key: PrimaryTriggerKey
    var role: KeyRecorderRole = .primaryDictation
    /// Right-click "Turn Off": disables the feature this key drives (each site knows how).
    var onTurnOff: (() -> Void)? = nil

    func makeNSView(context: Context) -> ModifierRecorderNSView {
        let view = ModifierRecorderNSView()
        view.current = key
        view.role = role
        view.onTurnOff = onTurnOff
        return view
    }

    func updateNSView(_ nsView: ModifierRecorderNSView, context: Context) {
        nsView.current = key
        nsView.role = role
        nsView.onTurnOff = onTurnOff
        nsView.updateAppearance()
    }
}

final class ModifierRecorderNSView: NSView {
    var current: PrimaryTriggerKey = .rightCommand
    var role: KeyRecorderRole = .primaryDictation
    var onTurnOff: (() -> Void)?
    private var hubObserver: Any?
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
        hubObserver = NotificationCenter.default.addObserver(
            forName: KeyRecorderHub.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAppearance() }
        }
        updateAppearance()
    }

    deinit {
        if let hubObserver { NotificationCenter.default.removeObserver(hubObserver) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // NSViewRepresentable: the intrinsic width must be FLEXIBLE, not fixed - a hard 150
    // beat SwiftUI's .frame(width:) at required priority, so the view drew 150pt wide in a
    // 110pt slot and hung past its card's padding (the clipped-looking key fields).
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        yapdiag("keyRecorder: mouseDown role=\(role)")
        KeyRecorderHub.shared.toggle(role)
    }

    /// Same right-click grammar as every other shortcut field: Turn Off / Record.
    override func rightMouseDown(with event: NSEvent) {
        KeyRecorderHub.shared.stop()
        let menu = NSMenu()
        if onTurnOff != nil {
            let off = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        let record = NSMenuItem(title: "Record New Key", action: #selector(beginRecordingFromMenu), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func turnOff() { onTurnOff?() }
    @objc private func beginRecordingFromMenu() {
        if KeyRecorderHub.shared.armedRole != role { KeyRecorderHub.shared.toggle(role) }
    }

    /// The same physical key bound to BOTH the dictation and quick edit triggers is
    /// allowed - but it must be IMPOSSIBLE to miss. Both fields go red.
    private var conflicted: Bool {
        guard let st = AppDelegate.shared?.state.settings else { return false }
        return st.primaryTriggerKey == st.quickEditTriggerKey
            && st.rightCommandTrigger != .off && st.quickEditTrigger != .off
    }

    func updateAppearance() {
        if KeyRecorderHub.shared.armedRole == role {
            label.stringValue = KeyRecorderHub.shared.flash ?? "Tap a key\u{2026}"
            label.textColor = .secondaryLabelColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        } else if conflicted {
            label.stringValue = current.label
            label.textColor = .systemRed
            layer?.borderColor = NSColor.systemRed.cgColor
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.10).cgColor
            toolTip = "This key is bound to BOTH dictation and Quick Edit - whichever fires first wins."
        } else {
            label.stringValue = current.label
            label.textColor = .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            toolTip = nil
        }
    }
}
