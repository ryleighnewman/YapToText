import AppKit
import SwiftUI

/// The Quick Edit key's own popup: appears the moment the key is held over a selection,
/// shows the LIVE waveform while you speak, condenses it into the app's signature
/// spinning ring while the edit applies, and seals with the outcome - all in ONE stable
/// card that morphs between stages instead of swapping boxes. Small, non-activating,
/// and never steals focus from the text being edited.
///
/// Deliberately styled on `.regularMaterial`, not Liquid Glass: the live wave re-renders
/// every frame in this window's one SwiftUI graph, and per-frame renders inside a
/// DesignLibrary glass hierarchy are the macOS 26.5 crash path the recording panel needs
/// its two-graph split for. Material is immune, so this stays a single simple graph.
@MainActor
final class QuickEditWindow {
    static let shared = QuickEditWindow()

    enum Stage: Equatable {
        case listening
        case working(String)           // the command being applied
        case result(String, success: Bool)   // outcome message, auto-dismisses
        case info(String, String)      // title + explanation (e.g. "select text first"), auto-dismisses
    }

    @MainActor @Observable
    final class Model {
        var stage: Stage = .listening
        var liveCommand = ""
    }

    private let model = Model()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Whether the card is on screen right now, and in which stage - the key handlers
    /// need both to honor "press turns it off, no exceptions".
    var isShowing: Bool { (panel?.isVisible ?? false) && (panel?.alphaValue ?? 0) > 0.01 }
    var currentStage: Stage { model.stage }

    func showListening(liveTextSource controller: DictationController) {
        dismissTask?.cancel()
        model.stage = .listening
        model.liveCommand = ""
        let panel = panel ?? makePanel(controller: controller)
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Failsafe: a session that never delivers a command (cancelled with Esc, engine error)
        // must not leave "Listening…" floating forever.
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.model.stage == .listening else { return }
            self.dismiss()
        }
    }

    func showWorking(_ command: String) {
        dismissTask?.cancel()
        model.stage = .working(command)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        // The card narrows around the ring; the window shadow must follow the new shape.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel?.invalidateShadow() }
    }

    /// The INSTANT the key is released: the card must acknowledge immediately, not sit on
    /// "Listening…" for however long transcription takes (a cold model is seconds - which
    /// reads as "letting go did nothing"). Same working stage, no command text yet.
    func showHeard() {
        guard case .listening = model.stage else { return }   // never regress a later stage
        dismissTask?.cancel()
        model.stage = .working("")
        panel?.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel?.invalidateShadow() }
    }

    /// Show the outcome for a beat, then slip away. The ring itself carries the
    /// verdict: it recolors green on success, red on failure - no extra glyphs.
    func showResult(_ message: String, success: Bool = true) {
        model.stage = .result(message, success: success)
        panel?.invalidateShadow()
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Build the panel (hidden) ahead of first use, so the first key press doesn't pay
    /// NSPanel + hosting-view construction on top of everything else.
    func prewarm(controller: DictationController) {
        guard panel == nil else { return }
        panel = makePanel(controller: controller)
    }

    /// A guidance card (title + how-to line) that works even when no session ever started -
    /// e.g. the key was held with nothing selected. Creates the panel on demand.
    func showInfo(_ title: String, _ detail: String, seconds: Double = 3.5) {
        guard let controller = AppDelegate.shared?.state.controller else { return }
        dismissTask?.cancel()
        model.stage = .info(title, detail)
        let panel = panel ?? makePanel(controller: controller)
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        // A soft farewell instead of a blink: pure CA fade on the composited layer, then
        // the deferred teardown (out of any in-flight render transaction, same discipline
        // as the other floating panels).
        let win = panel
        if let layer = win?.contentView?.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "qeFade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            win?.orderOut(nil)
            win?.contentView?.layer?.removeAnimation(forKey: "qeFade")
        }
    }

    private func makePanel(controller: DictationController) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        if let settings = AppDelegate.shared?.state.settings {
            let root = QuickEditPopupView(model: model, controller: controller, settings: settings)
            panel.contentView = NSHostingView(rootView: AnyView(root.yapAccent(settings)))
        } else {
            let root = QuickEditPopupView(model: model, controller: controller, settings: nil)
            panel.contentView = NSHostingView(rootView: AnyView(root))
        }
        panel.contentView?.wantsLayer = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - 180, y: v.minY + v.height * 0.14))
    }
}

private struct QuickEditPopupView: View {
    let model: QuickEditWindow.Model
    let controller: DictationController
    let settings: AppSettings?

    private var isListening: Bool { model.stage == .listening }
    private var isWorking: Bool { if case .working = model.stage { return true }; return false }
    private var isResult: Bool { if case .result = model.stage { return true }; return false }
    private var isInfo: Bool { if case .info = model.stage { return true }; return false }
    private var resultSuccess: Bool? { if case .result(_, let ok) = model.stage { return ok }; return nil }
    /// The wave carries the verdict: the user's own style while live and applying, then
    /// the whole ring turns green (worked) or red (didn't).
    private var waveStyle: WaveStyle {
        if let ok = resultSuccess {
            return WaveStyle(tint: ok ? .green : .red, strength: 1, uniformFamily: true)
        }
        return settings?.waveStyle ?? .plain
    }
    /// Full width while there's text to read; hugging the ring once condensed.
    private var cardWidth: CGFloat { isWorking || isResult ? 200 : 320 }

    var body: some View {
        VStack(spacing: 6) {
            // THE WAVE IS THE STATUS - always mounted, one structure across every stage:
            //  listening: the live wave dancing to the voice
            //  working:   the signature condense - the wave winds into the spinning ring
            //  result:    the ring holds while the outcome seals underneath it
            //  info:      a calm idle line
            ZStack {
                WaveformView(data: controller.visualData,
                             isActive: isListening && controller.isRecording && !controller.isPaused,
                             style: waveStyle,
                             freeze: isWorking || isResult,
                             sucking: isWorking || isResult,
                             usesSharedClock: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .opacity(isInfo ? 0.35 : 1)
            }
            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isWorking {
                    Text("Press Esc to cancel")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(width: cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .symbolRenderingMode(.hierarchical)
        // ONE card that morphs: every stage change crossfades in place - never a box swap.
        .animation(.easeInOut(duration: 0.22), value: model.stage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch model.stage {
        case .listening: return "Listening for your edit\u{2026}"
        case .working(let command): return command.isEmpty ? "Got it" : "Applying your edit"
        case .result(let message, _): return message
        case .info(let heading, _): return heading
        }
    }

    private var detail: String {
        switch model.stage {
        case .listening:
            let live = controller.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            return live.isEmpty ? "Say what to change, then release the key." : "\u{201C}\(live)\u{201D}"
        case .working(let command):
            return command.isEmpty ? "Working on your edit\u{2026}" : "\u{201C}\(command)\u{201D}"
        case .result:
            return ""
        case .info(_, let explanation):
            return explanation
        }
    }
}
