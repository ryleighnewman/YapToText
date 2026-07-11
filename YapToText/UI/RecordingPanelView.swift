import SwiftUI
import AppKit

/// The floating dictation panel. Two layouts, switchable live from its own options menu:
/// - Expanded: header (state + live waveform + mode) over an upward-scrolling live transcript
///   and a controls row.
/// - Compact: everything in a single row with a one-line transcript tail.
/// The mode chip is a menu (switching applies to the in-flight dictation), and the arrow
/// button jumps into the app, straight to the current mode's editor.
struct RecordingPanelView: View {
    let controller: DictationController
    let settings: AppSettings
    var width: CGFloat = 336
    var margin: CGFloat = 20
    /// Reports the card's rendered size so RecordingPanel can size the SEPARATE glass chrome
    /// graph underneath (see PanelChrome). Plain callback, not SwiftUI state - the two graphs
    /// must stay independent.
    var onCardSize: ((CGSize) -> Void)? = nil

    /// Everything scales off the medium (380 pt) baseline.
    private var scale: CGFloat { width / 380 }

    var body: some View {
        card
            // Fill the fixed-size window and pin the card to its anchored edge, so as the card
            // springs between forms it grows/shrinks IN PLACE. `margin` leaves room for its shadow.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cardAlignment)
            .padding(margin)
            .symbolRenderingMode(.hierarchical)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("YapToText dictation, mode \(controller.activeMode.name)")
            .accessibilityValue(controller.isPaused ? "Paused" : controller.phase.userFacingLabel)
    }

    private var cardAlignment: Alignment {
        settings.panelPosition == .bottomCenter ? .bottom : .top
    }

    /// The card CONTENT only - deliberately NO glass here. The Liquid Glass chrome (glass, rim,
    /// shadow) lives in a SEPARATE SwiftUI graph (PanelChrome, its own NSHostingView underneath)
    /// that reads nothing from the dictation controller. Splitting the graphs means the per-frame
    /// dictation re-renders in THIS graph contain zero DesignLibrary attributes, so macOS 26.5's
    /// glass renderer never runs during dictation - it was segfaulting mid-transaction (spam
    /// press-crashes and long-dictation crashes both traced to it via the stress rig).
    /// The style change is a plain snap, not a spring: animating the card size re-rendered the
    /// glass chrome every frame of the spring, which is exactly the animated-glass path we're
    /// eliminating.
    private var card: some View {
        Group {
            if settings.panelStyle == .compact {
                compactLayout
            } else {
                expandedLayout
            }
        }
        .padding(settings.panelStyle == .compact ? 10 * scale : 11 * scale)
        .frame(width: width)
        .onGeometryChange(for: CGSize.self, of: \.size) { onCardSize?($0) }
    }

    // MARK: Layouts

    /// Big layout: the wave is the hero, full width at the top; live transcript beneath; ONE
    /// compact bottom bar with everything else (no separate header row = no wasted space).
    private var expandedLayout: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            WaveformView(data: controller.visualData,
                         isActive: controller.isRecording && !controller.isPaused,
                         scale: scale)
                .frame(maxWidth: .infinity)
            transcript(lines: 1.7)
            // One condensed bottom row: transport controls, the mode selectors (scrollable),
            // then the panel options - no separate mode row.
            HStack(spacing: 8 * scale) {
                controls
                modeChips
                optionsMenu
                jumpToAppButton
            }
        }
    }

    /// Post-processor picker: each engaged mode gets a number; press that digit while dictating
    /// (or click) and the finished transcript is fed through that mode's AI prompt. Fills the space
    /// between the transport controls and the panel options, scrolling horizontally, and glides to
    /// the selected mode whenever it changes (e.g. pressing 6 for a chip that's off-screen).
    private var modeChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5 * scale) {
                    ForEach(Array(controller.switchableModes.prefix(9).enumerated()), id: \.element.id) { index, mode in
                        let isCurrent = mode.id == controller.activeMode.id
                        HStack(spacing: 3) {
                            Text("\(index + 1)")
                                .font(.system(size: 9 * scale, weight: .bold).monospacedDigit())
                                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                                .frame(width: 13 * scale, height: 13 * scale)
                                .background(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Circle())
                            Text(mode.name)
                                .font(.system(size: 10 * scale, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7 * scale).padding(.vertical, 3 * scale)
                        .background(isCurrent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06),
                                    in: Capsule())
                        .overlay(Capsule().stroke(isCurrent ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Capsule())
                        .id(mode.id)   // scroll target
                        .onTapGesture { controller.switchMode(mode) }
                        .help("Press \(index + 1) while dictating")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 1)   // keep the current chip's stroke from clipping at the edge
                .padding(.vertical, 2 * scale)   // capsules were getting their tops/bottoms shaved
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 26 * scale)
            .onChange(of: controller.activeMode.id) { _, id in
                // Elastic glide: a spring with a little overshoot so 5 -> 4 settles with a soft
                // bounce instead of a flat ease.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            // One-line transcript tail: the latest words, shown only while actively dictating so
            // the idle mini player stays a single row.
            if isPreviewing {
                Text(controller.liveText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                WaveformView(data: controller.visualData,
                             isActive: controller.isRecording && !controller.isPaused)
                    .frame(maxWidth: .infinity)
                controls
                optionsMenu
                jumpToAppButton
            }
            .frame(height: 34)
        }
    }

    // MARK: Live transcript (cycles upward; latest words pinned at the bottom)

    private var isPreviewing: Bool {
        controller.isRecording && !controller.isPaused && !controller.liveText.isEmpty
    }

    @ViewBuilder
    private func transcript(lines: Double) -> some View {
        // GLASS RULE (from the crash bisection): never structurally swap subtrees inside this
        // glass card when the phase changes - macOS 26.5's DesignLibrary segfaults on structural
        // ZStack updates mid-transition. Both branches keep BOTH views mounted and cross-fade
        // opacity; TypewriterText gets an empty target when inactive (paused timeline, no cost).
        if lines <= 1 {
            ZStack(alignment: .leading) {
                Text(displayText).foregroundStyle(.secondary)
                    .opacity(isPreviewing ? 0 : 1)
                TypewriterText(target: isPreviewing ? controller.liveText : "", fontSize: 13 * scale)
                    .opacity(isPreviewing ? 1 : 0)
            }
            .font(.system(size: 13 * scale))
            .lineLimit(1)
            .truncationMode(.head)   // one-line tail: always the latest words
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // A touch taller than the text so the newest line can sit low, right above the mode
            // row, with room for the top line to fade out into the waveform.
            let boxHeight = CGFloat(lines) * 20 * scale + 6 * scale
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .bottomLeading) {
                            Text(displayText)
                                .font(.system(size: 15 * scale))
                                .foregroundStyle(.secondary)
                                .opacity(isPreviewing ? 0 : 1)
                            TypewriterText(target: isPreviewing ? controller.liveText : "", fontSize: 15 * scale)
                                .opacity(isPreviewing ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A zero-height anchor at the very bottom to glide to as new words arrive.
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    // Bottom-align short text so the latest line hugs the bottom edge instead of
                    // floating in the middle of the row.
                    .frame(maxWidth: .infinity, minHeight: boxHeight, alignment: .bottomLeading)
                }
                .defaultScrollAnchor(.bottom)   // new words push old ones upward
                .frame(height: boxHeight)
                // GENTLE multi-stop fade so there's no visible cut-off line: the older line eases
                // out gradually toward the top, reaching full solid only past the midline where the
                // newest words stay fully readable.
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0.0),
                                           .init(color: .black.opacity(0.12), location: 0.22),
                                           .init(color: .black.opacity(0.55), location: 0.42),
                                           .init(color: .black, location: 0.66)],
                                   startPoint: .top, endPoint: .bottom)
                )
                // Keep the newest words pinned as lines wrap. Deliberately NOT wrapped in
                // withAnimation: an animated scroll drives an AppKit animated-layout pass through
                // the glass card on every partial, which is a confirmed trigger for the macOS 26.5
                // DesignLibrary crash during long dictations. defaultScrollAnchor keeps the motion
                // acceptable without the animated transaction.
                .onChange(of: controller.liveText) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "yap.transcript.bottom"

    private var displayText: String {
        if controller.isPaused { return "Paused" }
        if controller.isRecording {
            return controller.liveText.isEmpty ? "Listening…" : controller.liveText
        }
        if let detail = controller.transformingDetail { return detail }
        return controller.phase.userFacingLabel
    }

    // MARK: Mode menu (switch mid-dictation)

    private var modeMenu: some View {
        Menu {
            ForEach(controller.switchableModes) { mode in
                Button {
                    controller.switchMode(mode)
                } label: {
                    if mode.id == controller.activeMode.id {
                        Label(mode.name, systemImage: "checkmark")
                    } else {
                        Label(mode.name, systemImage: mode.iconSystemName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.activeMode.iconSystemName)
                if settings.panelStyle == .expanded {
                    Text(controller.activeMode.name).lineLimit(1).frame(maxWidth: 96, alignment: .leading)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8 * scale))
            }
            .font(.system(size: 11 * scale, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch mode. Applies to this dictation")
        .accessibilityLabel("Mode: \(controller.activeMode.name)")
    }

    // MARK: Options menu (customize the panel in place)

    /// Menus glitch inside a non-activating panel, so the option is a direct button that
    /// flips between the two forms (big and small). Position stays in Settings.
    private var optionsMenu: some View {
        panelButton(settings.panelStyle == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                    settings.panelStyle == .compact ? "Big layout" : "Small layout") {
            settings.panelStyle = settings.panelStyle == .compact ? .expanded : .compact
            AppDelegate.shared?.refreshPanelSize()
        }
    }

    private func panelButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10 * scale))
            .foregroundStyle(.secondary)
            .frame(width: 18 * scale, height: 18 * scale)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Jump into the app (deep-links to the current mode's editor)

    private var jumpToAppButton: some View {
        Image(systemName: "arrow.up.forward.app")
            .font(.system(size: 11 * scale))
            .foregroundStyle(.secondary)
            .frame(width: 18 * scale, height: 18 * scale)
            .contentShape(Rectangle())
            .onTapGesture {
                let modeID = controller.activeMode.id
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
                NotificationCenter.default.post(name: .yapShowMode, object: modeID)
            }
            .help("Open \(controller.activeMode.name) in YapToText")
            .accessibilityLabel("Open \(controller.activeMode.name) in YapToText")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Controls

    // No Cancel "X": Stop (during recording) keeps the transcript, and pressing Escape cancels
    // and discards from anywhere - so the panel stays clean with no stray close control.
    // GLASS RULE: one stable structure - the buttons and the spinner are BOTH always mounted and
    // cross-fade, because structurally swapping them at the recording->transcribing instant is a
    // confirmed macOS 26.5 DesignLibrary crash trigger.
    private var controls: some View {
        ZStack {
            HStack(spacing: 7 * scale) {
                controlButton(controller.isPaused ? "play.fill" : "pause.fill",
                              controller.isPaused ? "Resume" : "Pause", .accentColor) { controller.togglePause() }
                controlButton("stop.fill", "Stop and insert", .red) { controller.stop() }
            }
            .opacity(controller.isRecording ? 1 : 0)
            .allowsHitTesting(controller.isRecording)
            ProgressView().controlSize(.small).scaleEffect(scale)
                .opacity(controller.isBusy && !controller.isRecording ? 1 : 0)
        }
    }

    /// Tap-gesture control instead of Button: every crash report fires inside SwiftUI's
    /// _ButtonGesture dispatch hosted in this non-activating panel, so the panel avoids that
    /// code path entirely.
    private func controlButton(_ symbol: String, _ label: String, _ tint: Color,
                               action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26 * scale, height: 26 * scale)
            .background(Circle().fill(Color.secondary.opacity(0.14)))
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

/// The panel's Liquid Glass CHROME - glass card, edge rim, and shadow - in its own isolated
/// SwiftUI graph. It reads NOTHING observable: size and alignment are plain values, re-set by
/// RecordingPanel only when the card's measured size actually changes (a style toggle). So during
/// dictation this graph never re-renders, and DesignLibrary (the crash-prone macOS 26.5 glass
/// renderer) never runs - while the live content above it re-renders freely with zero glass.
struct PanelChrome: View {
    var size: CGSize
    var alignment: Alignment
    var margin: CGFloat

    var body: some View {
        Color.clear
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.32), radius: 13, y: 5)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(margin)
    }
}
