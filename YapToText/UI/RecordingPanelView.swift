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
    /// Begin a slow, matched glass shrink to `size` over `duration` seconds (the pill
    /// condensing in the same ratio as the line being consumed).
    var onCondenseShrink: ((CGSize, Double, CGSize) -> Void)? = nil   // target, duration, final offset

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
            // The mini layout only draws its transport on hover, so pointer-free input
            // (VoiceOver, Switch Control, Voice Control) had NO way to stop or pause a
            // dictation from the panel - only Escape, which discards it. These card-level
            // actions give every layout the same reachable transport; each one is already
            // phase-guarded in the controller, so they are safe no-ops when inapplicable.
            .accessibilityAction(named: "Stop and insert") { controller.stop() }
            .accessibilityAction(named: "Cancel and discard") { controller.cancel() }
            .accessibilityAction(named: controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }
    }

    /// Loading state seen by the mini layout: dictation ended, transcription/cleanup running.
    /// Processing latch, used by EVERY layout (name is historic): true from stop until the
    /// NEXT recording begins, so the condensed ring holds through the panel's deferred
    /// close instead of flashing back to the idle menu for the final frames.
    private var miniProcessing: Bool { controller.isBusy && !controller.isRecording }
    /// Latched: once the mini condenses into the spinner, it STAYS condensed until the panel
    /// leaves (or a new recording starts) - never a flash of the big wave on the way out.
    @State private var miniStayCondensed = false
    private var miniCondensed: Bool { miniProcessing || miniStayCondensed }
    /// Size-bridge debounce state (see onGeometryChange in `card`).
    @State private var pendingCardSize: CGSize?
    @State private var cardSizeDebounce: Task<Void, Never>?
    /// Last measured height of the expanded layout, so a grow-to-expanded transition can
    /// predict the glass size accurately instead of guessing.
    @State private var lastExpandedHeight: CGFloat = 118

    private var cardAlignment: Alignment {
        settings.panelPosition.cardAlignment
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
            // SEQUENCED crossfade: the outgoing layout is FULLY GONE (fast 0.1s fade)
            // before the incoming one appears (0.16s fade after a 0.12s beat). The old
            // symmetric crossfade had BOTH layouts' waveforms on screen mid-morph, at
            // different heights - the "chaotic" double-wave during size cycles. Now the
            // glass carries the morph alone for a beat, then the new content breathes in.
            switch settings.panelStyle {
            case .compact: compactLayout
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96))
                        .animation(.easeIn(duration: 0.16).delay(0.12)),
                    removal: .opacity.animation(.easeOut(duration: 0.10))))
            case .mini: miniLayout
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94))
                        .animation(.easeIn(duration: 0.16).delay(0.12)),
                    removal: .opacity.animation(.easeOut(duration: 0.10))))
            case .expanded: expandedLayout
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.97))
                        .animation(.easeIn(duration: 0.16).delay(0.12)),
                    removal: .opacity.animation(.easeOut(duration: 0.10))))
            }
        }
        .padding(settings.panelStyle == .expanded ? 11 * scale : settings.panelStyle == .mini ? 7 * scale : 10 * scale)
        .frame(width: settings.panelStyle == .mini ? width * 0.42 : width)
        // The CONTENT never narrows during the condense: the canvas is invisible, and
        // shrinking it raced the material (clipping wave tips early in the collapse and
        // the ring's halo at the end). Only the GLASS shrinks - it tracks the material's
        // true extent frame-by-frame in RecordingPanel.
        // Clean transitions: the CONTENT animates between sizes (this graph has zero glass);
        // the glass chrome follows once at the END via the debounced size bridge below.
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: settings.panelStyle)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: miniCondensed)
        .animation(wavePulledIn ? .easeIn(duration: 0.5) : .spring(response: 0.38, dampingFraction: 0.8),
                   value: wavePulledIn)
        // THE WAVE LEAVES WITH THE CARD: on any close that isn't the condensed ring
        // (cancel from the big or medium layout), the full-width wave pulls back into
        // the center on the same spring as the mini's cancel - it was staying MASSIVE,
        // dwarfing the collapsing card around it.
        .onChange(of: controller.panelIsClosing) { _, closing in
            guard closing, !miniCondensed else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { waveShot = false }
        }
        .onChange(of: miniProcessing) {
            if miniProcessing {
                CondenseClock.start = Date()   // one clock for wave AND glass
                miniStayCondensed = true
            }
        }
        .onChange(of: controller.isRecording) { if controller.isRecording { miniStayCondensed = false } }
        // Shoot-out trigger for COMPACT and EXPANDED (the mini fires its own, along with
        // its cancel choreography - the style guard prevents double-firing there).
        // ONE owner, STATE-tracked rather than event-observed: onChange missed session
        // starts where "recording AND presented" was already true before this view
        // re-evaluated (window reused back-to-back, or a ring-close leaving waveShot
        // stuck true) - timing decided whether the shoot played. task(id:) re-runs on
        // every value change AND at mount, and lastLive says which kind of arrival this is.
        // The FIRST visible frame must never show a stale full-width wave: when the reset
        // inside replayShoot ran a few frames after the window surfaced, the user saw
        // full wave -> snap to sliver -> spring, which reads as a different animation
        // entirely. Resetting at ORDER-OUT means every show starts from the sliver by
        // construction - the shoot can only ever play forward.
        .onChange(of: controller.panelIsPresented) { _, presented in
            guard !presented else { return }
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { waveShot = false }
        }
        .task(id: controller.isRecording && controller.panelIsPresented) {
            let live = controller.isRecording && controller.panelIsPresented
            let previous = lastLive
            lastLive = live
            guard live, settings.panelStyle != .mini else { return }
            if previous == false || previous == nil && !waveShot {
                replayShoot()   // a genuine session start (or mounted pre-shoot): play it
            } else {
            }
            // previous == true: remounted mid-session (style switch) - leave the wave alone.
        }
        // Release the latch once the panel is long closed (1.2s after busy ends): the
        // latch only exists to hold the ring through the close animation. Left set, the
        // suck timeline never paused between dictations (idle CPU) and the next show
        // could flash a stale ring.
        .onChange(of: controller.isBusy) { _, busy in
            guard !busy else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                // NEVER release while the panel is still on screen: a slow insert,
                // clipboard fallback, or error card keeps it visible past this timer,
                // and the release snapped the ring back into a full-width wave right in
                // front of the user. Wait for the actual orderOut (or a new session).
                while controller.panelIsPresented {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !controller.isBusy, !controller.isRecording else { return }
                }
                guard !controller.isBusy, !controller.isRecording else { return }
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { miniStayCondensed = false }
            }
        }
        // GLASS LEADS ON EXPANSION: the debounced bridge below reports the size only after
        // the content spring settles - fine when shrinking (content pulls in, glass follows),
        // but when GROWING the wave was spilling past the still-small glass. So the moment a
        // growing transition starts, push a predicted size immediately: the glass springs
        // out first and the content grows into it; the settled measurement then trues it up.
        .onChange(of: miniCondensed) { _, condensed in
            if !condensed, settings.panelStyle == .mini {
                pendingCardSize = nil
                onCardSize?(CGSize(width: width * 0.42, height: 40))
            }
            // COMPACT and EXPANDED both condense through the same display-link glass
            // shrink the mini uses - the glass hugs the winding material down to the
            // mini's own 44x40 ring pill. (The mini triggers this from its own layout.)
            if condensed, settings.panelStyle == .compact {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard miniCondensed, settings.panelStyle == .compact else { return }
                    // The ring STAYS where the wave is; the pill's right side sweeps in
                    // to meet it. The wave keeps its width (controls only fade), so the
                    // ring's spot is left of the pill center by half the trailing block.
                    let slide = CGSize(width: -(compactTrailingWidth + 8) / 2, height: 0)
                    onCondenseShrink?(CGSize(width: 44, height: 40), 0.5, slide)
                }
            }
            // EXPANDED: the whole card collapses UPWARD onto the ring as the wave winds
            // in - transcript and controls fade first, then the glass rides the same
            // consumption curve up to a pill centered exactly on the ring.
            if condensed, settings.panelStyle == .expanded {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard miniCondensed, settings.panelStyle == .expanded else { return }
                    onCondenseShrink?(CGSize(width: 44, height: 40), 0.5, expandedRingSlide)
                }
            }
        }
        .onChange(of: settings.panelStyle) { old, new in
            // Predicted push in EVERY direction: shrinking transitions used to wait for
            // the debounced geometry settle, so the glass lagged the content and then
            // bounced to catch up - the "chaotic" big->medium and "jumpy" big->small.
            // With the target pushed up front, glass and content ride the same spring.
            pendingCardSize = nil
            let predicted: CGSize
            switch new {
            case .mini:     predicted = CGSize(width: width * 0.42, height: 40)
            case .compact:  predicted = CGSize(width: width, height: 54)
            case .expanded: predicted = CGSize(width: width, height: lastExpandedHeight)
            }
            onCardSize?(predicted)
        }
        .yapAccent(settings)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            // DEBOUNCE the chrome hand-off: during an animated resize this fires every frame,
            // and pushing each one would re-render the glass per frame - the crash path the
            // two-graph split exists to avoid. Only the settled size reaches the chrome.
            pendingCardSize = size
            if settings.panelStyle == .expanded { lastExpandedHeight = size.height }
            cardSizeDebounce?.cancel()
            cardSizeDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled, let settled = pendingCardSize else { return }
                onCardSize?(settled)
            }
        }
    }

    // MARK: Layouts

    /// Dictation over, results pending: transcription/cleanup/insert in flight.
    private var isProcessing: Bool { controller.isBusy && !controller.isRecording }

    /// The three pipeline stages, for the processing meter. Cleaning only counts as a stage
    /// when this mode actually runs AI cleanup.
    private var meterSteps: [(phase: DictationController.Phase, label: String)] {
        var steps: [(DictationController.Phase, String)] = [(.transcribing, "Transcribing")]
        if controller.activeMode.usesAI { steps.append((.transforming, "Cleaning")) }
        steps.append((.inserting, "Inserting"))
        return steps
    }

    /// Fills the dead air after Stop: a stage meter where finished stages are solid accent,
    /// the current one shimmers, and upcoming ones wait dim. Always mounted, opacity-gated
    /// (GLASS RULE: no structural swaps inside the card).
    private func processingMeter(showLabels: Bool) -> some View {
        let steps = meterSteps
        let current = steps.firstIndex { $0.phase == controller.phase } ?? 0
        return HStack(spacing: 8 * scale) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                VStack(spacing: 3 * scale) {
                    ZStack {
                        Capsule()
                            .fill(i <= current ? AnyShapeStyle(Color.accentColor.opacity(i == current ? 0.35 : 1))
                                               : AnyShapeStyle(Color.secondary.opacity(0.18)))
                            .frame(height: 4 * scale)
                        ProgressView().progressViewStyle(.linear).tint(Color.accentColor)
                            .frame(height: 4 * scale)
                            .opacity(i == current ? 1 : 0)
                    }
                    if showLabels {
                        Text(step.label)
                            .font(.system(size: 9 * scale, weight: i == current ? .semibold : .regular))
                            .foregroundStyle(i <= current ? Color.accentColor : Color.secondary)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
    }

    /// Big layout: the wave is the hero, full width at the top; live transcript beneath; ONE
    /// compact bottom bar with everything else (no separate header row = no wasted space).
    private var expandedLayout: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            // The wave condenses into the spinning ring (same gate choreography as the
            // mini); the current pipeline stage rides quietly in the corner.
            // The ring IS the status - no side captions competing with it. Waveform sits
            // higher (36pt band, was 44) so the text below gets the room.
            WaveformView(data: controller.visualData,
                         isActive: controller.isRecording && !controller.isPaused,
                         scale: scale * 0.82,
                         style: settings.waveStyle,
                         freeze: miniCondensed,
                         sucking: miniCondensed,
                         birthAt: waveBirthAt)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: !waveShot ? 0.03 : 1)
            transcript(lines: 1.7)
                .frame(maxWidth: .infinity, alignment: miniCondensed ? .center : .leading)
                .multilineTextAlignment(miniCondensed ? .center : .leading)
                .animation(.easeInOut(duration: 0.25), value: miniCondensed)
                // The card condenses onto the ring DURING processing now - everything
                // below the wave fades as the collapse begins (same 0.12s the close uses).
                .opacity(controller.panelIsClosing || miniCondensed ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: controller.panelIsClosing)
                .animation(.easeOut(duration: 0.12), value: miniCondensed)
            // One condensed bottom row: transport controls, the mode selectors (scrollable),
            // then the panel options - no separate mode row.
            HStack(spacing: 8 * scale) {
                controls
                // Modes do nothing while post-transcription analysis is off (everything is raw),
                // so gray the chips out and make them inert - no misleading "pick a mode" here.
                modeChips
                    .opacity(controller.analysisEnabled ? 1 : 0.35)
                    .disabled(!controller.analysisEnabled)
                    .help(controller.analysisEnabled ? "Switch how your words get formatted"
                                                     : "Post-transcription analysis is off - modes won't run")
                optionsMenu
                jumpToAppButton
            }
            .opacity(controller.panelIsClosing || miniCondensed ? 0 : 1)
            // Invisible is not inert: for the whole 0.66s close these buttons still took
            // clicks - a second reflexive click flipped the panel style mid-close or
            // yanked the app to the front, stealing focus from the app just inserted into.
            .allowsHitTesting(!controller.panelIsClosing && !miniCondensed)
            .animation(.easeOut(duration: 0.12), value: controller.panelIsClosing)
            .animation(.easeOut(duration: 0.12), value: miniCondensed)
        }
        // Style switched INTO expanded while already condensed: re-run the condense so
        // the glass hugs the ring instead of stranding a full card (mirror of compact).
        .onAppear {
            guard miniCondensed else { return }
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { waveShot = true }   // never a sliver around the ring
            CondenseClock.start = Date()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard miniCondensed, settings.panelStyle == .expanded else { return }
                onCondenseShrink?(CGSize(width: 44, height: 40), 0.5, expandedRingSlide)
            }
        }
    }

    /// Where the expanded card's ring lives relative to the card CENTER: the wave band
    /// sits at the top (layout padding + half the band), so the condensed pill must slide
    /// up there instead of settling at mid-card - that offset is exactly why the pill and
    /// the ring used to land misaligned.
    private var expandedRingSlide: CGSize {
        let ringFromTop = 11 * scale + (44 * scale * 0.82) / 2
        return CGSize(width: 0, height: ringFromTop - lastExpandedHeight / 2)
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

    /// Mini: NOTHING but the waveform - the quietest possible presence. Hovering the mouse
    /// reveals the transport (cancel on the left, pause/play and stop on the right) as an
    /// overlay; moving away hides it again so the wave is all you ever see while talking.
    @State private var miniHovering = false
    /// False until the current dictation's wave has shot out from the center (the classic
    /// open: a line that starts in the middle and fires left and right). Starts false so
    /// the very first appearance plays the same shoot-out as every later one.
    @State private var waveShot = false
    @State private var shootGeneration = 0
    /// Last observed "recording AND presented" value - nil until the first task run.
    @State private var lastLive: Bool?
    /// Birth stamp of the current shoot: WaveformView holds the wave flat until the
    /// lines have shot out, then blooms the live amplitude in (see birthAt there).
    @State private var waveBirthAt: Date?
    /// Cancel choreography: the wave FLATTENS to a straight line first, then pulls into the
    /// center - the opening in exact reverse (dance -> flat line -> gone into the middle).
    @State private var waveFlat = false
    /// Cancel fade: the line dissolves IN SYNC with the glass pill as both condense.
    @State private var waveGone = false
    /// Processing choreography stage 2: after the flatten, the flat line pulls into the
    /// middle (with the clockwise tilt) - only THEN does the pill condense and the spinner
    /// bloom. Staged exactly like cancel, but feeding the vortex instead of fading out.
    @State private var wavePulledIn = false
    /// Drives the cancel X's glide to center - explicit withAnimation state, because
    /// frame-alignment/conditional-position changes do not reliably animate.
    @State private var xAtCenter = false
    /// Width of the compact layout's trailing control block - the distance the pill
    /// slides left when it condenses onto the wave.
    @State private var compactTrailingWidth: CGFloat = 120
    /// The wave has been fully consumed by the vortex - drives its OWN fade, on its own
    /// Stage 3 of the break-apart: after lifting apart, the halves ARC DOWN and CONVERGE at

    /// One canonical shoot-out, used by EVERY open (first launch and repeats alike): snap
    /// to the center point without animating, wait a breath so the panel window is actually
    /// on screen (replays used to start while it was still ordering in, which made repeated
    /// opens look different), then fire the lines outward on the same spring every time.
    private func replayShoot() {
        // Re-entrant by design: the recording-start and panel-shown triggers can both fire,
        // and the LAST one must own the spring (the earlier one may have run against a
        // still-hidden window). The reset is genuinely instant now (no standing .animation
        // modifiers re-injecting springs), so restarting mid-flight cannot flip the wave.
        shootGeneration += 1
        let gen = shootGeneration
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            waveShot = false; waveFlat = false; waveGone = false; wavePulledIn = false
            waveBirthAt = Date()   // amplitude is born flat and blooms after the shoot
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard gen == shootGeneration else { return }   // a newer shoot owns the wave
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { waveShot = true }
        }
    }

    private var miniLayout: some View {
        WaveformView(data: controller.visualData,
                     isActive: controller.isRecording && !controller.isPaused,
                     style: settings.waveStyle,
                     freeze: miniCondensed,
                     sucking: miniCondensed,
                     birthAt: waveBirthAt)
            // Hover: the wave steps WAY back so the revealed buttons own the stage.
            // Processing: the wave SHRINKS toward the center as it fades, so the pill collapse
            // reads as one morph - the wave folds inward while the whirlwind spins up in its
            // place, all riding the same spring that narrows the frame.
            // The wave never fades during processing: it morphs into the spinning
            // spiral and stays as the loader.
            .opacity(miniHovering ? (miniCondensed ? 0.3 : 0.12) : 1)
            // THE SEQUENCE, both directions through the same center point:
            //  open:     the lines SHOOT out from the middle to the left and right
            //  condense: the lines pull back INTO the middle first (fast x-collapse)...
            //  ...then:  the whirlwind spins up from that point, a beat later (see the
            //            delayed animation on the overlay below).
            // Processing exit = the startup EXACTLY in reverse: the full-height wave
            // squeezes horizontally into the THICK center line it was born from (no
            // flattening - the compressed ribbons ARE the thick line), tilting as it
            // arrives - left end dipping, right end rising - and the whirlwind blooms
            // straight out of that tilted line. Cancel is the thin story instead:
            // flatten, then pull in and fade (waveFlat only ever fires on cancel).
            // The suck is GEOMETRY now (see WaveformView.sucking): the renderer spirals
            // every ribbon point into the center. Only the open shoot-out (waveShot) and
            // cancel flatten (waveFlat) remain as view transforms.
            .scaleEffect(x: !waveShot ? 0.03 : 1,
                         y: waveFlat ? 0.05 : 1)
            // ONE animation per value, no duplicates: a second `.animation(value:
            // miniCondensed)` here was hijacking the opacity's delayed fade above and
            // vanishing the wave 0.3s into the pour (caught with a canary stroke).
            .animation(.easeOut(duration: 0.14), value: waveFlat)
            .opacity(waveGone ? 0 : 1)
            .animation(.easeIn(duration: 0.28), value: waveGone)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .onChange(of: miniCondensed) { _, condensed in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { xAtCenter = condensed }
                if condensed {
                    // The pill shrinks CONTINUOUSLY, matching the consumption ratio. The
                    // final choreography feeds from ~0.45s (after the split) for ~4.0s.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard miniCondensed else { return }
                        wavePulledIn = true
                        onCondenseShrink?(CGSize(width: 44, height: 40), 0.5, .zero)
                    }
                } else {
                    // Reset for the next entrance AFTER the fade has finished - never on screen.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !miniCondensed else { return }
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { wavePulledIn = false; waveFlat = false }
                    }
                }
            }
            .task(id: controller.isRecording) {
                if controller.isRecording && !waveShot { replayShoot() }
            }
            .onChange(of: controller.isRecording) { _, recording in
                if recording {
                    replayShoot()
                    // A hover that ended with the last session (mouse moved away while the
                    // panel closed) leaves this true, so the next dictation would open as a
                    // button cluster over a 12%-opacity wave. Reset it with the shoot-out.
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { miniHovering = false }
                }
                // Cancelled (recording ended with nothing to process): the opening in
                // exact reverse - the wave FLATTENS into a straight line, then the line
                // pulls back into the center point before the panel slips away. A
                // stop-with-results goes condensed instead, so this only fires on cancel.
                // The durations here MUST match the .animation(value:) modifiers above
                // (which win): flatten 0.14s, pull-in spring 0.5/0.8, fade 0.28s.
                else if !controller.isBusy {
                    // One clock for the wave AND the glass (RecordingPanel's cancel collapse
                    // reads it): a stamp from the last few hundred ms is the panel's, reuse it.
                    if let stamp = CondenseClock.start, Date().timeIntervalSince(stamp) < 1 {} else { CondenseClock.start = Date() }
                    withAnimation(.easeOut(duration: 0.14)) { waveFlat = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 110_000_000)
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { waveShot = false }
                        withAnimation(.easeIn(duration: 0.28)) { waveGone = true }
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) { waveFlat = false; waveGone = false; wavePulledIn = false }   // reset off-screen
                    }
                }
            }
            .onAppear {
                if controller.isRecording { replayShoot() }
                // Style switched INTO mini while already condensed: this layout's own
                // onChange never fires (the value was true before it mounted), so the
                // condense must be re-triggered here or a full-width pill strands around
                // the tiny ring. Everything the onChange path sets has to be set here too:
                //  - xAtCenter, or the hover X strands at the left edge (or, stuck true
                //    from a previous session, sits invisibly over the size button and
                //    swallows the click as a CANCEL)
                //  - waveShot, or the wave is still squeezed to a 3% sliver and the pill
                //    condenses around nothing
                //  - the shared clock, RESTAMPED: this wave begins winding now, and the
                //    glass reads the same clock - against a stamp from minutes ago it
                //    would snap shut in one frame while the wave played the full 4s.
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { xAtCenter = miniCondensed }
                if miniCondensed {
                    withTransaction(tx) { waveShot = true }
                    wavePulledIn = true
                    CondenseClock.start = Date()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard miniCondensed, settings.panelStyle == .mini else { return }
                        onCondenseShrink?(CGSize(width: 44, height: 40), 0.5, .zero)
                    }
                }
            }
            .onDisappear { miniHovering = false }
            .overlay {
                // Gated on a LIVE session: after a cancel the buttons used to hang at full
                // opacity over the dissolving wave (the only part of the close that never
                // faded), and a reflexive second click still flipped the panel style.
                if miniHovering, controller.isRecording || controller.isBusy {
                    // Recording: individual floating buttons, NO shared pill - the wave
                    // stays visible between them. Cancel left, size-cycle center,
                    // transport right.
                    // Condensing/condensed: ONLY the X remains, gliding to the center of
                    // the shrinking pill on the same spring - one quiet escape hatch.
                    ZStack {
                        if !miniCondensed {
                            HStack {
                                Spacer().frame(width: 26)
                                Spacer()
                                controlButton("arrow.up.left.and.arrow.down.right", "Bigger layout", .secondary) { cyclePanelStyle() }
                                Spacer()
                                controlButton(controller.isPaused ? "play.fill" : "pause.fill",
                                              controller.isPaused ? "Resume" : "Pause", .accentColor) { controller.togglePause() }
                                controlButton("stop.fill", "Stop and insert", .red) { controller.stop() }
                            }
                            .transition(.opacity)
                        }
                        GeometryReader { geo in
                            controlButton("xmark", "Cancel and discard", .secondary) { controller.cancel() }
                                .position(x: xAtCenter ? geo.size.width / 2 : 13,
                                          y: geo.size.height / 2)
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: miniCondensed)
                    .transition(.opacity)
                }
            }
            .onHover { inside in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { miniHovering = inside }
            }
    }

    /// The mini's loading state: the LIVE VISUALIZER'S OWN ribbons - same four (accent-cyan,
    /// cyan-mint, mint-accent, and the white highlight), same gradient shading, same
    /// glow-under-crisp double stroke, same smoothed paths - bent into closed rings and spun
    /// fast around the center. Each ribbon's radius undulates on its own carrier wave while
    /// the whole ring rotates at a slightly different speed, so the ribbons shear against
    /// each other like a whirlwind. Canvas + TimelineView, paused whenever invisible.
    /// Minimal, buttery processing spinner: a faint circular track with one accent arc
    /// sweeping around it at constant speed. Canvas + TimelineView (paused when hidden),
    /// no glass, no springs - it cannot be choppy.
    /// The size carousel: big -> medium -> small -> big, reachable from every layout.
    private func cyclePanelStyle() {
        let next: PanelStyle
        switch settings.panelStyle {
        case .expanded: next = .compact
        case .compact: next = .mini
        case .mini: next = .expanded
        }
        settings.panelStyle = next
        AppDelegate.shared?.refreshPanelSize()
    }

    /// Compact: a single row - waveform + transport, and NO transcript. The mini player is meant to
    /// stay one clean line; the live text belongs to the expanded layout only.
    private var compactLayout: some View {
        HStack(spacing: 8) {
            // The wave itself condenses into the spinning ring - the same gate
            // choreography as the mini, here as the in-place loader.
            WaveformView(data: controller.visualData,
                         isActive: controller.isRecording && !controller.isPaused,
                         scale: scale,
                         style: settings.waveStyle,
                         freeze: miniCondensed,
                         sucking: miniCondensed,
                         birthAt: waveBirthAt)
                .frame(maxWidth: .infinity)
                // The signature open: the lines fire outward from the center - the same
                // shoot-out the mini has always had, now on every layout.
                .scaleEffect(x: !waveShot ? 0.03 : 1)
            // On stop the right side FADES fast but KEEPS ITS SPACE: the wave must not
            // re-center (the ring stays exactly where the wave was), and the glass then
            // slides left over it - the right edge travels the long way in.
            HStack(spacing: 8) {
                controls
                optionsMenu
                jumpToAppButton
            }
            // Fade on the CLOSE too, not just the processing condense - on cancel these
            // buttons (expand, open app) hung on screen after everything else had gone,
            // caught only by the glass's late fade. Same 0.12s lead the expanded row uses.
            .opacity(controller.panelIsClosing || miniCondensed ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: controller.panelIsClosing)
            .animation(.easeOut(duration: 0.16), value: miniCondensed)
            .allowsHitTesting(!controller.panelIsClosing && !miniCondensed)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { compactTrailingWidth = $0; controller.compactTrailingWidth = $0 }
        }
        .frame(height: 34)
        // Style switched INTO compact while already condensed - the exact mirror of the
        // mini's onAppear. Without it the card-level onChange never fires (the value was
        // already true) and the full-width pill strands around the tiny ring for the rest
        // of the dictation. Restamping the shared clock keeps the glass and this freshly
        // mounted wave on ONE timeline.
        .onAppear {
            guard miniCondensed else { return }
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { waveShot = true }   // never a sliver around the ring
            CondenseClock.start = Date()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard miniCondensed, settings.panelStyle == .compact else { return }
                onCondenseShrink?(CGSize(width: 44, height: 40), 0.5,
                                  CGSize(width: -(compactTrailingWidth + 8) / 2, height: 0))
            }
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
                            // While condensed the box shows a STATUS ("Transcribing…",
                            // "Loading the speech model…"), not a transcript - one clean
                            // centered line, never a wrap.
                            Text(displayText)
                                .font(.system(size: 15 * scale))
                                .foregroundStyle(.secondary)
                                .lineLimit(miniCondensed ? 1 : nil)
                                .truncationMode(.tail)
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
                // GENTLE multi-stop fade so there's no visible cut-off line: the older line
                // dissolves into the waveform above it. The ramp is long and shallow -
                // barely-there through the top half, fully solid only in the bottom third -
                // because the earlier, steeper curve read as a hard edge chopping the text.
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0.0),
                                           .init(color: .black.opacity(0.05), location: 0.28),
                                           .init(color: .black.opacity(0.30), location: 0.52),
                                           .init(color: .black.opacity(0.75), location: 0.72),
                                           .init(color: .black, location: 0.88)],
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
        if let detail = controller.statusDetail { return detail }
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
        // Cycles the full big -> medium -> tiny carousel (it used to toggle only big/medium,
        // which made the tiny layout unreachable from here).
        panelButton("rectangle.compress.vertical",
                    settings.panelStyle == .expanded ? "Medium layout" : "Tiny layout") {
            cyclePanelStyle()
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
                // Cancel lives on the LEFT: discard is the escape hatch, kept away from the
                // stop/insert side so a hurried click can't throw a dictation away.
                controlButton("xmark", "Cancel and discard", .secondary) { controller.cancel() }
                controlButton(controller.isPaused ? "play.fill" : "pause.fill",
                              controller.isPaused ? "Resume" : "Pause", .accentColor) { controller.togglePause() }
                controlButton("stop.fill", "Stop and insert", .red) { controller.stop() }
                // No size button here: the single cycle control lives in optionsMenu (big ->
                // medium -> tiny), so the panel never shows two competing resize buttons.
            }
            .opacity(controller.isRecording ? 1 : 0)
            .allowsHitTesting(controller.isRecording)
            // No stock spinner here anymore: the wave winding into the spinning ring IS
            // the processing indicator - a second spinner beside it was redundant.
        }
        .animation(.easeInOut(duration: 0.3), value: controller.isRecording)
        .animation(.easeInOut(duration: 0.3), value: controller.isBusy)
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
    /// Plain positional nudge (never observed): lets the condense slide the pill toward
    /// the wave, and the close keep the card's top edge pinned while height collapses.
    var offset: CGSize = .zero
    /// User's custom panel tint, passed as PLAIN values (never observed) so the chrome graph
    /// keeps its never-re-renders-during-dictation guarantee.
    var tint: Color? = nil
    var tintStrength: Double = 0

    var body: some View {
        Color.clear
            .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
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
            // Soft grounding, not a black halo: the old 0.32/13 read as a giant dark
            // blob behind the big card.
            .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .offset(x: offset.width, y: offset.height)
            .padding(margin)
    }
}
