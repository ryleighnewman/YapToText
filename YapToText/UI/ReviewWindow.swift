import AppKit
import SwiftUI

/// Review-before-insert: the finished dictation lands in this small floating editor instead of
/// being typed straight into the document. Return inserts (edited) text, Esc discards. The
/// window takes key focus ON PURPOSE - the whole point is one keystroke to accept.
@MainActor
final class ReviewWindow {
    static let shared = ReviewWindow()
    private var panel: NSPanel?
    private var onCommit: ((String) -> Void)?
    private var onDiscard: (() -> Void)?

    func present(text: String, appName: String?,
                 commit: @escaping (String) -> Void, discard: @escaping () -> Void) {
        dismiss(fire: false)
        onCommit = commit
        onDiscard = discard

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: ReviewSheet(
            text: text,
            appName: appName,
            onCommit: { [weak self] edited in self?.finish { self?.onCommit?(edited) } },
            onDiscard: { [weak self] in self?.finish { self?.onDiscard?() } }))
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - 230, y: v.minY + v.height * 0.22))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ action: () -> Void) {
        panel?.orderOut(nil)
        panel = nil
        action()
        onCommit = nil
        onDiscard = nil
    }

    func dismiss(fire: Bool) {
        guard panel != nil else { return }
        if fire { finish { onDiscard?() } } else { panel?.orderOut(nil); panel = nil; onCommit = nil; onDiscard = nil }
    }
}

private struct ReviewSheet: View {
    @State var text: String
    var appName: String?
    var onCommit: (String) -> Void
    var onDiscard: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.badge.checkmark").iconTint(Color.accentColor)
                Text("Review").font(.headline)
                Spacer()
                Text(appName.map { "Return inserts into \($0)" } ?? "Return inserts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 90, maxHeight: 200)
                .focused($focused)
            HStack {
                Button("Discard") { onDiscard() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Esc discards \u{00B7} \u{2318}Return inserts").font(.caption2).foregroundStyle(.tertiary)
                Button("Insert") { onCommit(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(.regularMaterial)
        .onAppear { focused = true }
    }
}
