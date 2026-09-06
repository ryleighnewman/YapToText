import SwiftUI

/// In-page copies of the REAL pop-ups, so the settings pages show the thing itself: the
/// recording panel in the chosen layout and the Quick Edit card through its stages, each
/// driven by synthesized speech. Nothing here records or inserts, and neither view takes
/// clicks. The glass behind the recording panel is a material stand-in (see PreviewChrome).

/// Synthetic "speech" shared by both previews: a constant floor with overlapping bursts,
/// so the wave always breathes.
enum PreviewSpeech {
    /// `energy` > 1 saturates the bursts (marketing stills); the in-app previews use 1.
    static func fill(_ data: AudioVisualData, t: Double, energy: Double = 1) {
        let pulse = 0.5 + 0.5 * sin(t * 2.3)
        let chatter = 0.5 + 0.5 * sin(t * 6.1 + 1.3)
        let burst = min(1.0, energy * (0.25 + 0.75 * pulse * chatter))
        data.level = Float(min(1.0, energy * (0.2 + 0.6 * burst)))
        var bands = [Float](repeating: 0, count: 26)
        for i in 0..<26 {
            let u = Double(i) / 25.0
            let shape = sin(u * .pi)
            let ripple = 0.55 + 0.45 * sin(t * 7.0 + u * 11.0)
            bands[i] = Float(max(0.0, 0.12 * shape + burst * shape * ripple))
        }
        data.spectrum = bands
    }
}

/// The recording pop-up's card, a flat translucent fill instead of Liquid Glass. The live
/// panel keeps its glass in a separate never-re-rendering graph because per-frame renders
/// inside a glass hierarchy are the macOS 26.5 crash path, and a system material inside a
/// scrolled page ghosts neighbouring controls. Shape, rim, tint, and shadow match.
struct PreviewChrome: View {
    var size: CGSize
    var alignment: Alignment
    var margin: CGFloat
    var tint: Color?
    var tintStrength: Double

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                if let tint, tintStrength > 0.01 {
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .fill(tint.opacity(0.12 + 0.38 * min(max(tintStrength, 0), 1)))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(margin)
    }
}

/// The Dictation page's copy of the recording pop-up: the real RecordingPanelView in the
/// layout picked above it, anchored the way the chosen position anchors it, with the live
/// transcript typing itself out. Follows every layout, position, and color change at once.
struct DictationPopupPreview: View {
    /// When a demo drives the panel (onboarding's controls step), it says which stage the
    /// panel is in; nil lets the preview run its own endless listening loop.
    enum DemoPhase: Equatable { case idle, listening, processing, closing }

    @Environment(AppState.self) private var state
    let settings: AppSettings
    var demoPhase: DemoPhase? = nil
    @State private var preview: DictationController?
    @State private var driver: Task<Void, Never>?
    @State private var cardSize = CGSize(width: RecordingPanel.panelWidth, height: 118)
    @State private var rgbPhase = 0.0
    @State private var rgbTick = 0

    private static let script = "The waveform follows your voice, and your words land here while you are still talking."

    private var tint: Color? {
        _ = rgbTick
        if settings.panelTintStyle == .rainbow {
            guard settings.panelTintStrength > 0.01 else { return nil }
            let h = rgbPhase.truncatingRemainder(dividingBy: 1)
            return Color(hue: h < 0 ? h + 1 : h, saturation: 0.85, brightness: 1)
        }
        return settings.panelTint
    }

    var body: some View {
        ZStack {
            // A driven demo removes the panel between takes rather than fading it: the panel's
            // Liquid Glass chips keep a stale snapshot of whatever was behind them while their
            // layer sits at zero opacity, which showed the previous onboarding step as a ghost.
            if let preview, demoPhase != .idle {
                ZStack {
                    PreviewChrome(size: cardSize, alignment: settings.panelPosition.cardAlignment,
                                  margin: RecordingPanel.shadowMargin, tint: tint, tintStrength: settings.panelTintStrength)
                    RecordingPanelView(controller: preview, settings: settings,
                                       width: RecordingPanel.panelWidth, margin: RecordingPanel.shadowMargin,
                                       onCardSize: { size in
                                           if size.width > 1, size.height > 1 { cardSize = size }
                                       })
                        .allowsHitTesting(false)
                }
                // The real farewell: the transcript and transport fade first (the view does
                // that itself once panelIsClosing is set), then the whole card pinches into
                // the ring and fades, the same 0.15 s lead and 0.32 s collapse as the live
                // panel's chrome animation.
                .scaleEffect(demoPhase == .closing ? 0.04 : 1, anchor: ringAnchor)
                .opacity(demoPhase == .closing ? 0 : 1)
                .animation(demoPhase == .closing ? .easeIn(duration: 0.32).delay(0.15) : nil, value: demoPhase)
                .transition(.identity)
            }
        }
        .frame(width: RecordingPanel.windowSize.width, height: RecordingPanel.windowSize.height)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: demoPhase)
        .accessibilityHidden(true)
        .onAppear { start(); applyDemoPhase() }
        .onChange(of: demoPhase) { applyDemoPhase() }
        .onDisappear { driver?.cancel(); driver = nil }
    }

    /// Where the ring sits inside the box, so the closing pinch aims at it like the live panel.
    private var ringAnchor: UnitPoint {
        let box = RecordingPanel.windowSize
        let margin = RecordingPanel.shadowMargin
        let cardTop: CGFloat
        switch settings.panelPosition.cardAlignment.vertical {
        case .top: cardTop = margin
        case .bottom: cardTop = box.height - margin - cardSize.height
        default: cardTop = (box.height - cardSize.height) / 2
        }
        let ringY = cardTop + 11 * (RecordingPanel.panelWidth / 380) + 18
        return UnitPoint(x: 0.5, y: min(max(ringY / box.height, 0), 1))
    }

    /// Mirror the demo's stage onto the preview controller: the panel view then shows the
    /// genuine recording, transcribing, and closing states.
    private func applyDemoPhase() {
        guard let preview, let demoPhase else { return }
        switch demoPhase {
        case .listening:
            preview.panelIsClosing = false
            preview.setPreviewPhase(.recording)
        case .processing:
            preview.setPreviewPhase(.transcribing)
        case .closing:
            preview.panelIsClosing = true       // the view fades its transport and pulls the wave in
        case .idle:
            preview.panelIsClosing = false
            preview.setPreviewPhase(.recording)   // ready for the next take, hidden meanwhile
            preview.setPreviewLiveText("")
        }
    }

    private func start() {
        if preview == nil {
            let c = DictationController(settings: settings, modeStore: state.modeStore, vocabulary: state.vocabulary,
                                        commands: state.commands, history: state.history,
                                        permissions: state.permissions, models: state.models)
            c.configureForPreview(liveText: "")
            preview = c
            applyDemoPhase()
        }
        driver?.cancel()
        driver = Task { @MainActor in
            var t = 0.0
            var i = 0
            let words = Self.script.split(separator: " ").map(String.init)
            var shown = 0
            while !Task.isCancelled {
                guard let preview else { return }
                i += 1
                // Under a demo, speech and typing happen only while "listening"; the driven
                // stage is read live off the controller so a stage change takes effect at once.
                let speaking = preview.isRecording && (preview.liveText.isEmpty || demoPhaseIsListening(preview))
                if speaking { PreviewSpeech.fill(preview.visualData, t: t) }
                if preview.liveText.isEmpty { shown = 0 }
                // The live transcript types itself a word at a time, rests, then starts over.
                if speaking, i % 9 == 0 {
                    if shown < words.count {
                        shown += 1
                        preview.setPreviewLiveText(words.prefix(shown).joined(separator: " "))
                    } else if demoPhase == nil, i % 90 == 0 {
                        shown = 0
                        preview.setPreviewLiveText("")
                    }
                }
                if settings.panelTintStyle == .rainbow {
                    rgbPhase += 0.033 * settings.panelRGBSpeed / 12
                    if i % 3 == 0 { rgbTick &+= 1 }
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
                t += 0.033
            }
        }
    }
}

extension DictationPopupPreview {
    /// Under a demo the panel "listens" only in the recording stage; on its own it always does.
    fileprivate func demoPhaseIsListening(_ preview: DictationController) -> Bool {
        demoPhase == nil || preview.isRecording
    }
}

/// The Quick Edit page's copy of its card: the real QuickEditPopupView cycling through
/// listening (the request typing itself), applying (the wave winding into the ring), and
/// the sealed result, in the card's own colors.
struct QuickEditPopupPreview: View {
    @Environment(AppState.self) private var state
    let settings: AppSettings
    @State private var model = QuickEditWindow.Model()
    @State private var fake = AudioVisualData(bands: 26)
    @State private var driver: Task<Void, Never>?

    private static let request = "make this sound formal"

    var body: some View {
        QuickEditPopupView(model: model, controller: state.controller, settings: settings, previewData: fake)
            .allowsHitTesting(false)
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .onAppear { start() }
            .onDisappear { driver?.cancel(); driver = nil }
    }

    private func start() {
        driver?.cancel()
        driver = Task { @MainActor in
            var t = 0.0
            var i = 0
            let words = Self.request.split(separator: " ").map(String.init)
            model.stage = .listening
            model.liveCommand = ""
            while !Task.isCancelled {
                i += 1
                PreviewSpeech.fill(fake, t: t)
                // A 7.5 s loop: 0-3.6 s listening while the request types itself, then the
                // condense into the ring, then "Done" holds, then it starts over.
                let cycle = i % 225
                switch cycle {
                case 0:
                    model.stage = .listening; model.liveCommand = ""
                case 1..<110:
                    let n = min(words.count, cycle / 18)
                    let typed = words.prefix(n).joined(separator: " ")
                    if model.liveCommand != typed { model.liveCommand = typed }
                case 110:
                    model.stage = .working(Self.request)
                case 170:
                    model.stage = .result("Done", success: true)
                default:
                    break
                }
                if settings.quickEditTintStyle == .rainbow {
                    model.rgbPhase += 0.033 * settings.quickEditRGBSpeed / 12
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
                t += 0.033
            }
        }
    }
}
