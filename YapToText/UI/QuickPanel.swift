import AppKit
import SwiftUI
import Observation

/// One row in the quick panel.
struct QuickPanelItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var subtitle: String?
    var icon: String
    init(id: UUID = UUID(), title: String, subtitle: String? = nil, icon: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }
}

@MainActor @Observable
final class QuickPanelModel {
    var title = ""
    var items: [QuickPanelItem] = []
    var selection = 0
}

/// A borderless panel that CAN become key, so it receives arrow/number keys while floating over
/// whatever app you're in.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A reusable command-palette-style overlay: a floating list you drive with the arrow keys,
/// number keys (1-9), Return to pick, and Escape to dismiss. Used by the mode switcher and the
/// AI actions picker. One shared instance; only one panel is ever on screen.
@MainActor
final class QuickPanel {
    static let shared = QuickPanel()

    private let model = QuickPanelModel()
    private var panel: KeyPanel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onPick: ((Int) -> Void)?

    func present(title: String, items: [QuickPanelItem], preselect: Int = 0,
                 onPick: @escaping (Int) -> Void) {
        guard !items.isEmpty else { return }
        self.onPick = onPick
        model.title = title
        model.items = items
        model.selection = min(max(preselect, 0), items.count - 1)

        let panel = panel ?? makePanel()
        self.panel = panel
        sizeAndCenter(panel, rows: items.count)
        installMonitor(for: panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        removeMonitor()
        // Defer the window teardown out of any in-flight SwiftUI render transaction (same Liquid
        // Glass crash class as the recording panel).
        let win = panel
        DispatchQueue.main.async { win?.orderOut(nil) }
        onPick = nil
    }

    // MARK: Building

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let root = QuickPanelView(model: model,
                                  onPick: { [weak self] index in self?.commit(index) })
        if let settings = AppDelegate.shared?.state.settings {
            panel.contentView = NSHostingView(rootView: AnyView(root.yapAccent(settings)))
        } else {
            panel.contentView = NSHostingView(rootView: AnyView(root))
        }
        return panel
    }

    private func sizeAndCenter(_ panel: NSPanel, rows: Int) {
        let width: CGFloat = 440
        let height = min(CGFloat(rows) * 48 + 58, 520)
        panel.setContentSize(NSSize(width: width, height: height))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2 + 60)
            panel.setFrameOrigin(origin)
        }
    }

    // MARK: Keyboard

    private func installMonitor(for panel: NSPanel) {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Enqueue on the main actor's executor properly. assumeIsolated here would trap on
            // macOS 26.5 whenever the executor-identity check fails (swift_task_checkIsolated
            // does NOT honor the legacy override) - the same crash class as SwiftUI's own button
            // actions. A Task hop is the safe way onto the main actor.
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let count = model.items.count
        guard count > 0 else { return false }
        switch event.keyCode {
        case 125: model.selection = min(model.selection + 1, count - 1); return true   // down
        case 126: model.selection = max(model.selection - 1, 0); return true            // up
        case 36, 76: commit(model.selection); return true                              // return / enter
        case 53: dismiss(); return true                                                // escape
        default:
            if let n = Self.numberKey(event.keyCode), n >= 1, n <= min(count, 9) {
                commit(n - 1); return true
            }
            return false
        }
    }

    private func commit(_ index: Int) {
        guard model.items.indices.contains(index) else { dismiss(); return }
        let handler = onPick
        dismiss()
        handler?(index)
    }

    private static func numberKey(_ code: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][code]
    }
}

private struct QuickPanelView: View {
    let model: QuickPanelModel
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(index, item).id(index)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { proxy.scrollTo(model.selection, anchor: .center) }
            }
        }
        .frame(width: 440)
        .symbolRenderingMode(.hierarchical)
        .yapGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ index: Int, _ item: QuickPanelItem) -> some View {
        let selected = index == model.selection
        return Button { onPick(index) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).foregroundStyle(.primary)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if index < 9 {
                    Text("\(index + 1)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
