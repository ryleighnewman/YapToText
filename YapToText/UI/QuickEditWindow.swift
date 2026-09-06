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
        /// Rainbow glass: laps through the spectrum, integrated per tick while the card is
        /// up (never derived from the wall clock, so the speed slider changes pace, not hue).
        var rgbPhase: Double = 0
    }

    private let model = Model()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    /// Bumped by every show; the deferred teardown from dismiss() checks it, so a card that
    /// is re-shown within the 0.2 s fade is never ordered out from under the new stage.
    private var teardownGeneration = 0
    private var rgbTimer: Timer?
    private var rgbLast: Date?

    /// Every visible stage starts here: cancel a fade/teardown in flight, run the glass
    /// timer, and forget any preview state so a drag can never resurrect the preview card.
    private func beginShow() {
        teardownGeneration &+= 1
        panel?.contentView?.layer?.removeAnimation(forKey: "qeFade")
        isPreviewing = false
        startRGBTimer()
    }

    private func startRGBTimer() {
        guard rgbTimer == nil else { return }
        rgbLast = Date()
        rgbTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickRGB() }
        }
    }
    private func stopRGBTimer() { rgbTimer?.invalidate(); rgbTimer = nil; rgbLast = nil }
    private func tickRGB() {
        let now = Date()
        let dt = min(0.5, now.timeIntervalSince(rgbLast ?? now))
        rgbLast = now
        guard let settings = AppDelegate.shared?.state.settings, settings.quickEditTintStyle == .rainbow else { return }
        model.rgbPhase += dt * settings.quickEditRGBSpeed / 12
    }

    /// Whether the card is on screen right now, and in which stage - the key handlers
    /// need both to honor "press turns it off, no exceptions".
    var isShowing: Bool { (panel?.isVisible ?? false) && (panel?.alphaValue ?? 0) > 0.01 }
    var currentStage: Stage { model.stage }

    func showListening(liveTextSource controller: DictationController) {
        dismissTask?.cancel()
        beginShow()
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
        beginShow()
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
        beginShow()
        model.stage = .working("")
        panel?.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel?.invalidateShadow() }
    }

    /// Show the outcome for a beat, then slip away. The ring itself carries the
    /// verdict: it recolors green on success, red on failure - no extra glyphs.
    func showResult(_ message: String, success: Bool = true) {
        beginShow()
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
        beginShow()
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

    /// Summoned from the Quick Edit settings page: shows the real card at its configured
    /// spot so the position can be checked and the card dragged where it should live.
    /// Every drag restarts the countdown, so it never vanishes mid-adjustment.
    private(set) var isPreviewing = false
    private var isInfoStage: Bool { if case .info = model.stage { return true }; return false }
    func preview() {
        // A live edit owns the card: never paint the preview over "Listening" or the ring.
        if let c = AppDelegate.shared?.state.controller, c.isRecording || c.isBusy { return }
        if isShowing, !isInfoStage { return }
        let snaps = AppDelegate.shared?.state.settings.quickEditSnapsBack == true
        showInfo("Quick Edit pops up here",
                 snaps ? "It opens here every time. It closes on its own."
                       : "Drag this card anywhere and it opens there next time. It closes on its own.",
                 seconds: 10)
        isPreviewing = true   // after showInfo, which clears it through beginShow()
    }
    /// A drag while previewing restarts the countdown only. Never repositions: with snap
    /// back on, a reposition would yank the card back to the preset under the cursor.
    private func extendPreview() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        isPreviewing = false
        stopRGBTimer()
        dismissTask?.cancel()
        dismissTask = nil
        teardownGeneration &+= 1
        let gen = teardownGeneration
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.teardownGeneration == gen else { return }   // re-shown meanwhile
            win?.orderOut(nil)
            win?.contentView?.layer?.removeAnimation(forKey: "qeFade")
        }
    }

    // MARK: Marketing staging (debug builds): hold any stage with a synthesized wave

    private var stagingData: AudioVisualData?
    private var stagingFeed: Task<Void, Never>?

    func stage(_ newStage: Stage, command: String) {
        guard let controller = AppDelegate.shared?.state.controller else { return }
        if stagingData == nil {
            // Rebuild the panel around a preview-fed card; endStaging() throws it away.
            let data = AudioVisualData(bands: 26)
            stagingData = data
            panel?.orderOut(nil)
            panel = makePanel(controller: controller, previewData: data)
            stagingFeed = Task { @MainActor [weak self] in
                var t = 0.0
                while !Task.isCancelled {
                    if let d = self?.stagingData { PreviewSpeech.fill(d, t: t) }
                    try? await Task.sleep(nanoseconds: 33_000_000)
                    t += 0.033
                }
            }
        }
        dismissTask?.cancel()
        beginShow()
        model.liveCommand = command
        model.stage = newStage
        guard let panel else { return }
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel?.invalidateShadow() }
    }

    func endStaging() {
        stagingFeed?.cancel(); stagingFeed = nil
        stagingData = nil
        stopRGBTimer()
        panel?.orderOut(nil)
        panel = nil   // the next real session builds a normal card
    }

    private func makePanel(controller: DictationController, previewData: AudioVisualData? = nil) -> NSPanel {
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
            let root = QuickEditPopupView(model: model, controller: controller, settings: settings, previewData: previewData)
            panel.contentView = NSHostingView(rootView: AnyView(root.yapAccent(settings)))
        } else {
            let root = QuickEditPopupView(model: model, controller: controller, settings: nil, previewData: previewData)
            panel.contentView = NSHostingView(rootView: AnyView(root))
        }
        panel.contentView?.wantsLayer = true
        // A move we did not make is the user dragging it: remember the spot so the pop-up
        // opens there from now on, across launches. The Position picker on the Quick Edit
        // page resets it.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.isProgrammaticMove, let settings = AppDelegate.shared?.state.settings else { return }
            let o = panel.frame.origin
            settings.quickEditDraggedX = Double(o.x)
            settings.quickEditDraggedY = Double(o.y)
            if self.isPreviewing { self.extendPreview() }   // keep the card up while it is being placed
        }
        return panel
    }

    private var isProgrammaticMove = false

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        let settings = AppDelegate.shared?.state.settings
        isProgrammaticMove = true
        defer { isProgrammaticMove = false }
        // With snap back off, where the user last dragged it wins, as long as that spot is
        // still on a connected screen.
        if settings?.quickEditSnapsBack != true, let x = settings?.quickEditDraggedX, let y = settings?.quickEditDraggedY {
            let saved = NSRect(x: x, y: y, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                panel.setFrameOrigin(saved.origin); return
            }
        }
        let x = v.midX - size.width / 2
        let y: CGFloat
        switch settings?.quickEditPosition ?? .bottomCenter {
        case .bottomCenter: y = v.minY + v.height * 0.14
        case .center: y = v.midY - size.height / 2
        case .topCenter: y = v.maxY - size.height - 48
        case .nearMenuBar: y = v.maxY - size.height - 8
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct QuickEditPopupView: View {
    let model: QuickEditWindow.Model
    let controller: DictationController
    let settings: AppSettings?
    /// Set by the Quick Edit page's preview: synthesized audio drives the wave and the
    /// model's liveCommand stands in for the live transcript. nil = the real card.
    var previewData: AudioVisualData? = nil

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
        return settings?.quickEditWaveStyle ?? .plain
    }
    /// The glass wash behind the card. Rainbow reads the phase the window integrates while
    /// the card is up; every other style resolves straight from the settings.
    private var glassTint: Color? {
        guard let settings else { return nil }
        if settings.quickEditTintStyle == .rainbow {
            guard settings.quickEditTintStrength > 0.01 else { return nil }
            let h = model.rgbPhase.truncatingRemainder(dividingBy: 1)
            return Color(hue: h < 0 ? h + 1 : h, saturation: 0.85, brightness: 1)
        }
        return settings.quickEditTint
    }
    private var glassStrength: Double { min(max(settings?.quickEditTintStrength ?? 0, 0), 1) }
    /// Full width while there's text to read; hugging the ring once condensed, and the sealed
    /// outcome hugs its label ("Done" needs far less room than "Applying your edit").
    private var cardWidth: CGFloat {
        if isResult {
            let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
            let label = (title as NSString).size(withAttributes: [.font: font]).width
            return min(200, max(124, ceil(label) + 56))
        }
        return isWorking ? 200 : 320
    }

    var body: some View {
        VStack(spacing: 6) {
            // THE WAVE IS THE STATUS - always mounted, one structure across every stage:
            //  listening: the live wave dancing to the voice
            //  working:   the signature condense - the wave winds into the spinning ring
            //  result:    the ring holds while the outcome seals underneath it
            //  info:      a calm idle line
            ZStack {
                WaveformView(data: previewData ?? controller.visualData,
                             isActive: previewData != nil ? isListening : (isListening && controller.isRecording && !controller.isPaused),
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
        .background {
            ZStack {
                // The settings-page preview uses a flat fill: a system material inside a
                // scrolled page leaves ghost copies of neighbouring controls behind it.
                if previewData != nil {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.08))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                }
                if let tint = glassTint {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.opacity(0.12 + 0.38 * glassStrength))
                }
            }
        }
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
            let live = (previewData != nil ? model.liveCommand : controller.liveText).trimmingCharacters(in: .whitespacesAndNewlines)
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
