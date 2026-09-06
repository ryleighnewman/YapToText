import AppKit
import SwiftUI

/// A borderless, non-activating floating panel that shows live dictation state without
/// stealing focus from the app you're typing into. Position, size, and entrance animation
/// are driven by user settings.
/// NSObject trampoline so a CADisplayLink can call back into the panel's closures.
private final class DisplayLinkDriver: NSObject {
    nonisolated(unsafe) var onFrame: (@MainActor () -> Void)?
    @objc func fire(_ link: CADisplayLink) {
        MainActor.assumeIsolated { onFrame?() }
    }
}

@MainActor
final class RecordingPanel {
    private let panel: NSPanel
    /// TWO separate SwiftUI graphs stacked in one window (crash architecture, macOS 26.5):
    /// `chromeHosting` renders ONLY the Liquid Glass card chrome and never re-renders during
    /// dictation; `hosting` renders all the live content with zero glass in its hierarchy. The
    /// DesignLibrary glass renderer therefore never executes inside the high-frequency dictation
    /// transactions that were segfaulting it (spam-press and long-dictation crashes).
    private let chromeHosting: NSHostingView<PanelChrome>
    private let hosting: NSHostingView<RecordingPanelView>
    private let controller: DictationController
    private let settings: AppSettings
    /// Last card size pushed into the chrome graph; only a real change re-renders the chrome.
    private var chromeSize: CGSize = .zero
    /// Tint state last baked into the chrome, so show() re-renders it only on a real change.
    private var lastChromeTintKey = ""
    /// While a slow condense-shrink runs, per-frame geometry reports must not touch the chrome.
    private var suppressGeometryUntil = Date.distantPast
    /// Invalidates in-flight condense-shrink completions: a new dictation must never be
    /// hit by a stale "snap the chrome to 44pt" callback from the previous session.
    private var condenseGeneration = 0
    private var condenseLink: CADisplayLink?
    /// Last known full height of the expanded card, for the show() snap-back.
    private var lastExpandedCardHeight: CGFloat = 170
    private let condenseDriver = DisplayLinkDriver()
    /// RGB glass: integrated hue phase (rate*dt - the speed slider changes pace without
    /// jumping the colour) advanced by a 10Hz timer of DISCRETE single chrome renders
    /// while the panel is visible. Never a per-frame animated glass transaction.
    private var rgbTimer: Timer?
    /// Set when hide() started the close choreography: orderOut waits for it.
    private var closingWithShrink = false
    /// The condense slide currently applied to the chrome (reset on every show).
    private var chromeOffset: CGSize = .zero
    /// Drives the expanded close: discrete chrome renders, height first then width.
    private var closeLink: CADisplayLink?
    /// The card size the expanded close started from, so a show() that interrupts the
    /// close mid-flight can put the glass back instead of stranding a squashed card.
    private var closeFromSize: CGSize = .zero
    /// A cancel collapse is on screen; orderOut waits for its full 0.62 s.
    private var closingWithCancel = false
    private let closeDriver = DisplayLinkDriver()
    private var rgbPhase: Double = 0
    private var rgbLast: Date?
    private var effectivePanelTint: Color? {
        guard settings.panelTintStyle == .rainbow else { return settings.panelTint }
        let h = rgbPhase.truncatingRemainder(dividingBy: 1)
        return Color(hue: h < 0 ? h + 1 : h, saturation: 0.85, brightness: 1)
    }
    /// Whether the last tick was actually cycling, so leaving Rainbow mid-session gets ONE
    /// restoring render instead of a frozen rainbow frame.
    private var rgbWasRainbow = false
    private func startRGBGlassIfNeeded() {
        rgbTimer?.invalidate(); rgbTimer = nil
        // The timer runs for the WHOLE visible session and checks the LIVE style each tick:
        // gating it on the style at show() meant switching to Rainbow while the panel was up
        // (exactly what the appearance settings invite) left the glass frozen until the next
        // dictation, and switching away left a timer re-rendering identical chrome.
        rgbLast = Date()
        rgbWasRainbow = settings.panelTintStyle == .rainbow
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                let nowDate = Date()
                let dt = min(0.5, nowDate.timeIntervalSince(self.rgbLast ?? nowDate))
                self.rgbLast = nowDate
                let rainbow = self.settings.panelTintStyle == .rainbow
                // Base: one full spectrum lap every 12s at speed 1.
                if rainbow { self.rgbPhase += dt * self.settings.panelRGBSpeed / 12.0 }
                guard rainbow || self.rgbWasRainbow else { return }
                self.rgbWasRainbow = rainbow
                guard self.condenseLink == nil, self.styleMorphLink == nil else { return }   // an active size loop renders already
                self.chromeHosting.rootView = PanelChrome(size: self.chromeSize,
                                                          alignment: self.settings.panelPosition.cardAlignment,
                                                          margin: Self.shadowMargin,
                                                          // The condense slide MUST ride along: without it
                                                          // the next rainbow tick teleported the pill back
                                                          // to the card's center, off the spinning ring.
                                                          offset: self.chromeOffset,
                                                          tint: self.effectivePanelTint,
                                                          tintStrength: self.settings.panelTintStrength)
            }
        }
        timer.tolerance = 0.04   // let the system coalesce the wakeups; the hue integrates measured dt, so jitter is invisible
        RunLoop.main.add(timer, forMode: .common)
        rgbTimer = timer
    }

    /// One width for both panel forms; every element inside scales off it, so shrinking this makes
    /// the whole pop-up proportionally smaller.
    static let panelWidth: CGFloat = 336
    /// The window is a FIXED size (big enough for the expanded form). The big<->small change is then
    /// a pure SwiftUI animation of the glass card INSIDE it - the NSPanel frame never resizes, which
    /// on 26.5 would have to animate through NSAnimationContext and crash Liquid Glass. The card
    /// draws its own shadow (margin) so the fixed surround stays invisible.
    static let shadowMargin: CGFloat = 20
    static let cardMaxHeight: CGFloat = 140
    static var windowSize: NSSize { NSSize(width: panelWidth + 2 * shadowMargin, height: cardMaxHeight + 2 * shadowMargin) }

    init(controller: DictationController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        chromeHosting = NSHostingView(rootView: PanelChrome(size: .zero,
                                                            alignment: settings.panelPosition.cardAlignment,
                                                            margin: Self.shadowMargin,
                                                            tint: settings.panelTint,   // init-time: static resolve (self not ready)
                                                            tintStrength: settings.panelTintStrength))
        hosting = NSHostingView(rootView: RecordingPanelView(controller: controller, settings: settings,
                                                             width: Self.panelWidth, margin: Self.shadowMargin))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the chrome graph draws the card's shadow
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true   // the mini style reveals its controls on hover
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        for view in [chromeHosting, hosting] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)   // chrome first (below), content second (above)
        }
        panel.contentView = container

        // Keep the VISIBLE CARD on screen when the user drags the panel. The window is larger
        // than the card (invisible shadow margins), so without this the card could be pushed
        // past the screen edges or under the menu bar and become hard to grab back.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            // Read the flag NOW, on the main thread that posted the notification: show()
            // resets it right after setFrameOrigin, so a deferred read would always see
            // false and record our own preset placement as a drag.
            let programmatic = MainActor.assumeIsolated { self?.isProgrammaticMove ?? true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.clampCardToScreen()
                // A move we didn't make = the user dragged it. Remember where, so "snap back
                // off" can keep the panel exactly there for every future dictation.
                if !programmatic {
                    let o = self.panel.frame.origin
                    // Persist it: the panel stays put across launches, not just dictations.
                    self.settings.panelDraggedX = Double(o.x)
                    self.settings.panelDraggedY = Double(o.y)
                }
            }
        }

        // Content -> chrome size bridge: a plain callback (never SwiftUI state) so the graphs stay
        // independent. Fires on style toggles; ignored while the size is stable.
        hosting.rootView = RecordingPanelView(controller: controller, settings: settings,
                                              width: Self.panelWidth, margin: Self.shadowMargin,
                                              onCardSize: { [weak self] size in
            guard let self, size != self.chromeSize, size.width > 0, size.height > 0 else { return }
            // Near-identical sizes (the settled measurement truing up a prediction): store it
            // and stop - re-rendering AND re-morphing for a 1-2pt correction played a second
            // visible bounce right after the first morph.
            if abs(size.width - self.chromeSize.width) < 2, abs(size.height - self.chromeSize.height) < 2 {
                self.chromeSize = size
                return
            }
            // THE CONDENSED PILL OWNS THE CHROME while processing: a geometry event that
            // slipped past the debounce could land AFTER the condense's suppression
            // window and re-inflate the pill to full width mid-processing - the
            // "sometimes the mini stays wide" variability. Until the session ends (new
            // recording or panel hidden), no push may grow a condensed pill.
            if self.controller.isBusy, !self.controller.isRecording,
               size.width > self.chromeSize.width + 20 {
                return   // EVERY layout condenses now, expanded included
            }
            // During a slow condense-shrink the geometry stream fires every frame of the
            // width animation - those must not re-render/morph the chrome (it is
            // already riding its own slow morph). EXCEPTION: a push much LARGER than the
            // current chrome is a style change (mini/compact -> expanded), never condense
            // noise - it must cancel the shrink and render, or the new layout strands on
            // a ring-sized pill.
            if Date() < self.suppressGeometryUntil {
                if size.width > self.chromeSize.width + 100 {
                    self.condenseLink?.invalidate(); self.condenseLink = nil
                    self.condenseGeneration += 1
                    self.suppressGeometryUntil = .distantPast
                } else {
                    self.chromeSize = size
                    return
                }
            }
            if self.settings.panelStyle == .expanded, size.height > 60 {
                self.lastExpandedCardHeight = size.height
            }
            let oldSize = self.chromeSize
            self.chromeSize = size
            // This path carries NO offset, so the stored slide must die with it -
            // otherwise a later close replays a finished condense's sideways slide and the
            // card jumps ~64pt at the instant it starts closing.
            self.chromeOffset = .zero
            // The morph renders every intermediate size itself (true-size, anchored);
            // rendering the final size first would flash the destination for a frame.
            self.animateChromeMorph(from: oldSize, to: size)
        },
                                              onCondenseShrink: { [weak self] size, duration, slide in
            guard let self else { return }
            // THE REAL PILL SHRINKS: a display link (native refresh rate - 120Hz on
            // ProMotion) re-renders the chrome at its true intermediate size every frame.
            // Every frame is genuine glass with genuine capsule ends - no masks, no
            // transforms. Each render is a discrete, non-animated transaction.
            self.condenseGeneration += 1
            let gen = self.condenseGeneration
            self.suppressGeometryUntil = Date().addingTimeInterval(duration + 0.3)
            let from = self.chromeSize
            guard from.width > 1 else { return }
            // Share the wave's exact clock: zero skew between line ends and glass edge.
            // Same 5s staleness bound the wave applies (WaveformView): if the stamp is
            // ancient the wave starts its own fresh clock, and the glass must not instead
            // snap shut in one frame against a stopwatch from minutes ago.
            let stamp = CondenseClock.start
            let started = (stamp != nil && Date().timeIntervalSince(stamp!) < 5) ? stamp! : Date()
            // VERTICAL CENTERING: the chrome shrinks pinned to the card's anchored edge
            // (top or bottom), but the RING sits at the card's vertical CENTER - so a pill
            // shorter than the card it came from (compact: 54 -> 40) landed ~7pt off the
            // spinner. Nudge the pill toward the old card's center as it shrinks; zero for
            // center-anchored panels and for the mini (whose card is already pill-height).
            let anchored = self.settings.panelPosition.cardAlignment
            let hDrop = (from.height - size.height) / 2
            let vFix: CGFloat = anchored == .top ? hDrop : (anchored == .bottom ? -hDrop : 0)
            let slide = CGSize(width: slide.width, height: slide.height + vFix)
            self.condenseLink?.invalidate()
            self.styleMorphLink?.invalidate(); self.styleMorphLink = nil
            self.chromeHosting.layer?.removeAnimation(forKey: "chromeMorph")
            self.chromeHosting.layer?.removeAnimation(forKey: "chromeCollapse")
            // FRAME-INTEGRATED clock, same rule as the wave's (capped 50ms/frame, never
            // past wall): a starved first run (whisper cold load) used to let wall time
            // race ahead of rendering, so the glass snapped to its final size while the
            // wave was still winding - the frozen, misaligned first condense.
            var teInt = Date().timeIntervalSince(started)
            var lastFrame = Date()
            self.condenseDriver.onFrame = { [weak self] in
                guard let self else { return }
                guard gen == self.condenseGeneration, !self.controller.isRecording else {
                    self.condenseLink?.invalidate(); self.condenseLink = nil; return
                }
                // The pill's width follows the SAME consumption curve as the line feed
                // (WaveformView), +8px breathing room: the glass hugs the retreating
                // material every frame instead of running its own timer curve.
                let nowD = Date()
                teInt = min(nowD.timeIntervalSince(started), teInt + min(max(0, nowD.timeIntervalSince(lastFrame)), 0.05))
                lastFrame = nowD
                let te = teInt
                let t = te * 2.6
                let rt = min(1.0, max(0.0, (t - 0.2) / 0.55))
                let gap = 0.05 * from.width * (rt * rt * (3 - 2 * rt))
                let suckT = max(0.0, t - 0.2 - 0.55 * 0.15)
                let f = suckT > 0 ? suckT * suckT / (suckT + 0.22) : 0
                let consumed = min(1.0, max(0.0, (from.width * 0.5 * f - gap) / (from.width * 0.43)))
                // The glass INTERPOLATES from its start size to the ring pill on that same
                // consumption curve, landing a touch ahead of the last material (the pill
                // must never trail the line ends). The old curve subtracted a fixed
                // fraction OF THE START WIDTH, which only ever reached 44pt from a narrow
                // start: on the wide compact card it bottomed out at 55pt, so the pill
                // never met the ring, the completion test never passed, and this display
                // link kept re-rendering glass at 120Hz for the rest of the dictation.
                // The right edge sweeps in with real ACCELERATION and lands early: a
                // power curve over the first 70% of consumption (gentle grip, then the
                // rush) - the old linear track to 90% read as the pill dragging its feet.
                let wc = min(1.0, pow(min(1.0, consumed / 0.7), 1.35))
                let w = from.width + (size.width - from.width) * CGFloat(wc)
                let h = from.height + (size.height - from.height) * CGFloat(wc)
                // The SLIDE: the pill drifts toward the wave's spot as it shrinks, so
                // the ring never moves - the glass comes to it (compact); zero on mini.
                let off = CGSize(width: slide.width * CGFloat(wc),
                                 height: slide.height * CGFloat(wc))
                self.chromeOffset = off
                self.chromeSize = CGSize(width: w, height: h)
                self.chromeHosting.rootView = PanelChrome(size: self.chromeSize,
                                                          alignment: self.settings.panelPosition.cardAlignment,
                                                          margin: Self.shadowMargin,
                                                          offset: off,
                                                          tint: self.effectivePanelTint,
                                                          tintStrength: self.settings.panelTintStrength)
                // Landed (or ran long - a link that outlives its own choreography by 3s is
                // a leak, never a slow frame).
                if consumed >= 1.0 || Date().timeIntervalSince(started) > 6 {
                    self.chromeSize = size
                    self.chromeOffset = slide
                    self.chromeHosting.rootView = PanelChrome(size: size,
                                                              alignment: self.settings.panelPosition.cardAlignment,
                                                              margin: Self.shadowMargin,
                                                              offset: slide,
                                                              tint: self.effectivePanelTint,
                                                              tintStrength: self.settings.panelTintStrength)
                    self.condenseLink?.invalidate(); self.condenseLink = nil
                }
            }
            let link = self.chromeHosting.displayLink(target: self.condenseDriver,
                                                      selector: #selector(DisplayLinkDriver.fire(_:)))
            link.add(to: .main, forMode: .common)
            self.condenseLink = link
        })
    }

    /// Glide the glass between card sizes at TRUE SIZE: a display link renders the chrome
    /// at its real intermediate dimensions every frame (each render a discrete,
    /// non-animated transaction - the same crash-safe pattern as the condense and the
    /// close). The old approach scaled the finished LAYER, but that layer spans the whole
    /// window, so the scale pivoted around the window's center instead of the card's
    /// anchored edge - which is exactly why big -> medium read as moving the wrong way.
    /// True-size renders inherit PanelChrome's own alignment, so the card stays pinned to
    /// its anchored edge at every step, no transform tricks.
    private var styleMorphLink: CADisplayLink?
    private let styleMorphDriver = DisplayLinkDriver()
    private func animateChromeMorph(from old: CGSize, to new: CGSize) {
        guard old.width > 1, old.height > 1, new.width > 1, new.height > 1, old != new else { return }
        styleMorphLink?.invalidate()
        chromeHosting.layer?.removeAnimation(forKey: "chromeMorph")   // legacy scale, if any
        let started = Date()
        let dur = 0.32
        styleMorphDriver.onFrame = { [weak self] in
            guard let self else { return }
            // A condense or close taking over owns the chrome; this morph yields.
            guard self.condenseLink == nil, self.closeLink == nil else {
                self.styleMorphLink?.invalidate(); self.styleMorphLink = nil; return
            }
            let t = Date().timeIntervalSince(started) / dur
            if t >= 1 {
                self.chromeSize = new
                self.render(size: new)
                self.styleMorphLink?.invalidate(); self.styleMorphLink = nil
                return
            }
            let p = 1 - pow(1 - t, 3)   // easeOutCubic: brisk launch, soft landing
            let size = CGSize(width: old.width + (new.width - old.width) * CGFloat(p),
                              height: old.height + (new.height - old.height) * CGFloat(p))
            self.chromeSize = size
            self.render(size: size)
        }
        let link = chromeHosting.displayLink(target: styleMorphDriver,
                                             selector: #selector(DisplayLinkDriver.fire(_:)))
        link.add(to: .main, forMode: .common)
        styleMorphLink = link
    }

    /// One discrete chrome render at `size` with the current tint (no offset).
    private func render(size: CGSize) {
        chromeHosting.rootView = PanelChrome(size: size,
                                             alignment: settings.panelPosition.cardAlignment,
                                             margin: Self.shadowMargin,
                                             tint: effectivePanelTint,
                                             tintStrength: settings.panelTintStrength)
    }

    // NOTE: panel show/hide sets alpha/origin DIRECTLY - no NSAnimationContext. On macOS 26.5,
    // animating the panel drives a SwiftUI render transaction that crashes inside Apple's Liquid
    // Glass framework (DesignLibrary) - confirmed by AddressSanitizer (100% system frames, no app
    // code, crash under NSAnimationContext.runAnimationGroup). A plain show/hide avoids that path.
    private var shownAt: Date = .distantPast
    /// Bumped by every show/hide so a deferred orderOut can tell whether it's stale (a new
    /// dictation re-showed the panel while the old hide was still waiting).
    private var visibilityGeneration = 0
    /// Generation of the NEWEST hide, so a stale deferred orderOut can tell a newer close
    /// choreography is running and let ITS timer do the orderOut instead.
    private var lastHideGeneration = 0

    func show() {
        visibilityGeneration += 1
        yapdiag("panel.show gen=\(visibilityGeneration) style=\(settings.panelStyle.rawValue) rec=\(controller.isRecording)")
        shownAt = Date()
        chromeHosting.layer?.removeAnimation(forKey: "chromeCollapse")
        chromeHosting.layer?.removeAnimation(forKey: "closeShrink")
        // The cancel pinch holds its end state (scale 0.04, opacity 0) via fillMode -
        // leaving these on the layer made every panel AFTER a big-menu cancel invisible.
        chromeHosting.layer?.removeAnimation(forKey: "cancelPinch")
        hosting.layer?.removeAnimation(forKey: "cancelPinch")
        hosting.layer?.removeAnimation(forKey: "chromeCollapse")
        // HEAL any anchor drift from past closes (this build once mutated anchors; the
        // mini pinch still recenters legitimately): a layer-backed view's frame math
        // assumes anchor (0,0), so every show restores the contract frame-preservingly.
        for l in [chromeHosting.layer, hosting.layer].compactMap({ $0 }) where l.anchorPoint != .zero {
            let f = l.frame
            l.anchorPoint = .zero
            l.position = f.origin
        }
        hosting.layer?.removeAnimation(forKey: "closeShrink")
        hosting.layer?.removeAnimation(forKey: "closeLift")
        for layer in [chromeHosting.layer, hosting.layer].compactMap({ $0 })
        where layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            let f = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: f.midX, y: f.midY)
        }
        // Re-align the chrome only if the position setting changed since the last show, so a
        // routine show never adds a glass render on top of the presentation transaction.
        let alignment: Alignment = settings.panelPosition.cardAlignment
        let tintKey = settings.panelTintStyle.rawValue + "|" + (settings.panelTintHex ?? "") + "|\(settings.panelTintStrength)|\(settings.accentColorHex ?? "")"
        if chromeHosting.rootView.alignment != alignment || tintKey != lastChromeTintKey {
            lastChromeTintKey = tintKey
            chromeHosting.rootView = PanelChrome(size: chromeSize, alignment: alignment, margin: Self.shadowMargin,
                                                 tint: effectivePanelTint, tintStrength: settings.panelTintStrength)
        }
        // A show that interrupts an IN-FLIGHT close (stop -> instant restart) must undo
        // the close's partial shrink: the close collapses HEIGHT first, so the width-only
        // rescues below never fire and the new session sat on a squashed, offset card.
        // One discrete render back at the size the close started from.
        if closeLink != nil, closeFromSize.width > 1 {
            chromeSize = closeFromSize
            chromeHosting.rootView = PanelChrome(size: chromeSize,
                                                 alignment: settings.panelPosition.cardAlignment,
                                                 margin: Self.shadowMargin,
                                                 tint: effectivePanelTint,
                                                 tintStrength: settings.panelTintStrength)
        }
        closeLink?.invalidate(); closeLink = nil
        styleMorphLink?.invalidate(); styleMorphLink = nil
        chromeOffset = .zero
        controller.panelIsClosing = false
        controller.closeIsCancel = false
        // CANONICAL CONDENSE CANCEL - runs on EVERY show, in any state. A new dictation
        // started while the pill was mid-condense (spam-toggling) must always kill the
        // shrink loop, unfreeze the geometry bridge, and drop any leftover layer mask -
        // the old placement inside the hidden-panel branch skipped all of it whenever
        // the panel was still on screen.
        condenseLink?.invalidate(); condenseLink = nil
        condenseGeneration += 1
        suppressGeometryUntil = .distantPast
        chromeHosting.layer?.mask = nil
        // A NEW recording ALWAYS gets a full-size pill - rendered UNCONDITIONALLY. The
        // old rescues only fired when the STORED size looked small, but suppressed
        // geometry events during a condense could store the full size without rendering
        // it: bookkeeping said 141 while the glass on screen was still the 44pt ring, so
        // the rescue skipped and the recording played inside a tiny stuck pill. One
        // discrete render per show is free; never trust the bookkeeping here.
        if controller.isRecording {
            let target: CGSize
            switch settings.panelStyle {
            case .mini:     target = CGSize(width: Self.panelWidth * 0.42, height: 40)
            case .compact:  target = CGSize(width: Self.panelWidth, height: 54)
            case .expanded: target = CGSize(width: Self.panelWidth, height: max(100, lastExpandedCardHeight))
            }
            chromeSize = target
            chromeHosting.layer?.removeAnimation(forKey: "chromeMorph")
            chromeHosting.rootView = PanelChrome(size: target, alignment: alignment,
                                                 margin: Self.shadowMargin,
                                                 tint: effectivePanelTint,
                                                 tintStrength: settings.panelTintStrength)
        }
        // Opening a NEW mini recording from hidden: the LINES are the opening act, alone.
        // The glass starts INVISIBLE and fades in around the lines only after they've
        // fired out from the center. Pure layer alpha + CA fade: no SwiftUI/
        // NSAnimationContext render path.
        if !panel.isVisible, controller.isRecording, settings.panelStyle == .mini {
            chromeHosting.alphaValue = 0
            let gen = visibilityGeneration   // already bumped at the top of show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, self.visibilityGeneration == gen else { return }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.0
                fade.toValue = 1.0
                fade.duration = 0.35
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.chromeHosting.layer?.add(fade, forKey: "chromeFadeIn")
                self.chromeHosting.alphaValue = 1
            }
        } else {
            chromeHosting.alphaValue = 1   // every other path shows the glass normally
        }
        panel.setContentSize(Self.windowSize)
        isProgrammaticMove = true
        if !settings.panelSnapsBack, let stuck = storedDraggedOrigin() {
            panel.setFrameOrigin(stuck)   // stays where the user last dragged it
        } else {
            panel.setFrameOrigin(positionOrigin())
        }
        isProgrammaticMove = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        controller.panelIsPresented = true
        startRGBGlassIfNeeded()
    }

    /// Guard so our own repositioning never masquerades as a user drag. The dragged spot
    /// itself lives only in Settings (panelDraggedX/Y), so Reset position, the Position
    /// picker, and Restore Defaults all clear it in one place.
    private var isProgrammaticMove = false

    /// The drag position saved in Settings, if it is still on a connected screen. A point
    /// from a display that is no longer attached is ignored so the panel never opens
    /// off-screen; the preset position takes over until the next drag.
    private func storedDraggedOrigin() -> NSPoint? {
        guard let x = settings.panelDraggedX, let y = settings.panelDraggedY else { return nil }
        let origin = NSPoint(x: x, y: y)
        let card = NSRect(origin: origin, size: Self.windowSize).insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        for screen in NSScreen.screens where screen.visibleFrame.intersects(card) { return origin }
        return nil
    }

    func hide() {
        rgbTimer?.invalidate(); rgbTimer = nil
        // A LIVE mid-condense keeps running: killing it here froze the pill PARTWAY
        // through its collapse whenever a fast transcription closed the panel before the
        // shrink landed ("the medium player doesn't collapse all the way"). The link
        // finishes its choreography under the close fade and self-terminates; it dies on
        // its own the moment a new recording starts, and show() still resets everything.
        styleMorphLink?.invalidate(); styleMorphLink = nil
        closeLink?.invalidate(); closeLink = nil
        let closeIsCancel = controller.closeIsCancel
        controller.closeIsCancel = false
        guard panel.isVisible else { return }
        // Never tear the window down INSIDE a SwiftUI render transaction, and never within the
        // panel's first moments on screen: a quick push-to-talk tap shows and hides the panel in
        // ~200ms, landing the orderOut while the INITIAL glass presentation/layout transaction is
        // still in flight - a confirmed DesignLibrary crash (segfault under NSWindow layoutIfNeeded
        // + NSAnimationContext). Enforce a short minimum on-screen time so that transaction always
        // settles first; a generation counter keeps a stale deferred hide from killing a NEW show.
        visibilityGeneration += 1
        let gen = visibilityGeneration
        lastHideGeneration = gen
        // A condense trigger sleeping its 50ms beat can land AFTER this hide and raise a
        // FRESH display link on a closing panel - the shrink then fights the close
        // choreography. Bumping the generation makes any such late link die on its first
        // frame - but ONLY when no condense is currently running: a live link must keep
        // its generation so it can finish the collapse under the close fade.
        if condenseLink == nil { condenseGeneration += 1 }
        yapdiag("panel.hide gen=\(gen) style=\(settings.panelStyle.rawValue) rec=\(controller.isRecording) busy=\(controller.isBusy) w=\(Int(chromeSize.width))")
        // Cancel from the mini wave (chrome still full pill width, nothing processing): the
        // glass collapses into the center point alongside the lines - matching flatten
        // beat (0.15s), then a 0.3s pinch to the middle with a fade. Pure Core Animation
        // on the composited layer; fillMode holds the end state until orderOut.
        if closeIsCancel, chromeSize.width > 100,
           let chromeLayer = chromeHosting.layer, let contentLayer = hosting.layer {
            // CANCEL: ONE motion, the opening in reverse. The wave plays its own farewell
            // (flatten 0.14 s, then the line pulls into its center on a 0.5/0.8 spring while
            // it fades over 0.28 s - RecordingPanelView); the glass rides the SAME clock:
            // the contents fade during the flatten, then the WHOLE card scales down in
            // proportion on the line's spring - width and height together, its anchor
            // drifting onto the wave's center - until it is a dot on the line, fading in
            // the wave's envelope. Never height-first (that made a long thin bar), never a
            // layer transform: real sizes every frame, a capsule to the last pixel.
            controller.panelIsClosing = true
            yapdiag("panel.close: cancel collapse (\(settings.panelStyle.rawValue))")
            let stamp = CondenseClock.start
            let started: Date
            if let stamp, Date().timeIntervalSince(stamp) < 1 { started = stamp } else { started = Date(); CondenseClock.start = started }
            let from = chromeSize
            let vScale = Self.panelWidth / 380
            let expanded = settings.panelStyle == .expanded
            let ringY = (11 * vScale) + (44 * 0.82 * vScale) / 2   // wave center below the card's top
            let bandHeight: CGFloat = expanded ? ringY * 2 : from.height
            let waveCenterFromTop: CGFloat = expanded ? ringY : from.height / 2
            // The line the glass hugs: the wave strip is the card minus its side padding
            // (compact keeps its trailing controls out of it). The glass keeps a margin
            // around the line ends that closes as the line does, so both reach the dot.
            let sidePad: CGFloat = expanded ? 11 * vScale : 10 * vScale
            let lineWidth: CGFloat = {
                if settings.panelStyle == .compact {
                    return max(40, from.width - 2 * sidePad - 8 - controller.compactTrailingWidth)
                }
                return from.width - 2 * sidePad
            }()
            let alignment = settings.panelPosition.cardAlignment
            let baseOffset = chromeOffset
            // The compact card's wave sits left of center; the dot must land on it.
            let slideX: CGFloat = {
                guard settings.panelStyle == .compact else { return 0 }
                let pad = 10 * vScale
                let waveW = max(40, from.width - 2 * pad - 8 - controller.compactTrailingWidth)
                return (pad + waveW / 2) - from.width / 2
            }()
            func spring(_ t: Double) -> Double {   // SwiftUI .spring(response: 0.5, dampingFraction: 0.8)
                guard t > 0 else { return 0 }
                let w0 = 2 * Double.pi / 0.5, z = 0.8
                let wd = w0 * (1 - z * z).squareRoot()
                let e = exp(-z * w0 * t)
                return min(1, max(0, 1 - e * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))))
            }
            closeLink?.invalidate()
            condenseLink?.invalidate(); condenseLink = nil
            chromeHosting.layer?.removeAnimation(forKey: "chromeMorph")
            closeDriver.onFrame = { [weak self] in
                guard let self else { return }
                let t = Date().timeIntervalSince(started)
                if t >= 0.62 { self.closeLink?.invalidate(); self.closeLink = nil; return }
                let pull = CGFloat(spring(t - 0.11))               // the line's pull-in
                let dot: CGFloat = 4
                // Proportional: width and height shrink on the same curve the line uses,
                // so the card keeps its shape as it goes (the line, at 3% of its width on
                // this spring, sits inside the glass to the end with the side padding
                // closing around it).
                let w = from.width + (dot - from.width) * pull
                let h = from.height + (dot - from.height) * pull
                // The card shrinks about ITS OWN center, and that center glides onto the
                // wave's center as it goes. PanelChrome lays the chrome against the card's
                // anchored edge (top, bottom, or centered), so first cancel the anchor's
                // pull (half the lost height), then add the glide. Pinning the top edge
                // instead yanked the bottom up before the glide brought it back: the recoil.
                let lost = from.height - h
                let anchorFix: CGFloat = alignment == .top ? lost / 2 : (alignment == .bottom ? -lost / 2 : 0)
                let glide = (waveCenterFromTop - from.height / 2) * pull
                _ = bandHeight; _ = lineWidth
                let off = CGSize(width: baseOffset.width + slideX * pull, height: baseOffset.height + anchorFix + glide)
                self.chromeOffset = off
                self.chromeSize = CGSize(width: w, height: h)
                self.chromeHosting.rootView = PanelChrome(size: self.chromeSize,
                                                          alignment: alignment,
                                                          margin: Self.shadowMargin,
                                                          offset: off,
                                                          tint: self.effectivePanelTint,
                                                          tintStrength: self.settings.panelTintStrength)
            }
            let link = chromeHosting.displayLink(target: closeDriver, selector: #selector(DisplayLinkDriver.fire(_:)))
            link.add(to: .main, forMode: .common)
            closeLink = link
            // The wave fades from 0.11 s over 0.28 s; glass and content take the same envelope.
            for layer in [chromeLayer, contentLayer] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.0
                fade.beginTime = CACurrentMediaTime() + max(0, 0.16 - Date().timeIntervalSince(started))
                fade.duration = 0.30
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                layer.add(fade, forKey: "chromeCollapse")
            }
            closingWithCancel = true
        } else if settings.panelStyle == .expanded,
                  chromeSize.width > 100,   // already condensed to the pill: plain fade below
                  let chromeLayer = chromeHosting.layer, let contentLayer = hosting.layer {
            // THE BIG CARD'S CLOSE - the same one for a finished dictation and a cancel
            // (closeIsCancel=\(closeIsCancel)), so there is exactly one way it leaves.
            // Real sizes throughout: no layer scaling, which squashed the ring into an
            // ellipse and rendered the glass as a flat box. Four beats:
            //  1) 0.00-0.12s  the transcript and buttons fade (panelIsClosing, in the view)
            //  2) 0.14-0.50s  height collapses UPWARD onto the wave band (top pinned)
            //  3) 0.30-0.60s  width collapses into the ring
            //  4) 0.55-0.80s  the remaining pill shrinks to a dot and fades to nothing
            yapdiag("panel.close: big card collapse (cancel=\(closeIsCancel))")
            controller.panelIsClosing = true   // content fades its transcript/bar, keeps the wave
            let from = chromeSize
            closeFromSize = from
            // Ring center measured from the card's top: layout padding + half the wave band.
            let vScale = Self.panelWidth / 380
            let ringY = (11 * vScale) + (44 * 0.82 * vScale) / 2
            let target = CGSize(width: 44, height: ringY * 2)
            let alignment = settings.panelPosition.cardAlignment
            let baseOffset = chromeOffset
            let started = Date()
            closeLink?.invalidate()
            closeDriver.onFrame = { [weak self] in
                guard let self else { return }
                let t = Date().timeIntervalSince(started)   // seconds
                if t >= 0.82 { self.closeLink?.invalidate(); self.closeLink = nil; return }
                func ease(_ x: Double) -> Double { x < 0 ? 0 : x > 1 ? 1 : x * x * (3 - 2 * x) }
                // Sequenced: the bottom row's fade (0.12s, panelIsClosing) LEADS, then the
                // card collapses upward, then the width pulls into the ring, then the pill
                // itself shrinks away - one continuous motion into nothing.
                let hp = ease((t - 0.14) / 0.36)           // height: after the button fade
                let wp = ease((t - 0.30) / 0.30)           // width: a beat later
                let dp = ease((t - 0.55) / 0.25)           // the pill shrinks to a dot
                let lift = CGFloat(ease((t - 0.25) / 0.35)) * 14   // the continuing rise
                let dot: CGFloat = 6
                let h0 = from.height + (target.height - from.height) * CGFloat(hp)
                let w0 = from.width + (target.width - from.width) * CGFloat(wp)
                let h = h0 + (dot - h0) * CGFloat(dp)
                let w = w0 + (dot - w0) * CGFloat(dp)
                // Keep the card's TOP edge (the wave) pinned while the bottom rises.
                let risen = from.height - h
                let pin: CGFloat = alignment == .top ? 0 : (alignment == .bottom ? -risen : -risen / 2)
                // As the pill becomes a dot, slide it down onto the ring's center (the ring
                // sits ringY below the pinned top edge), so the dot and the wave's last
                // speck vanish as one point instead of the dot floating above the speck.
                let ontoRing = (ringY - h / 2) * CGFloat(dp)
                self.chromeSize = CGSize(width: w, height: h)
                self.chromeHosting.rootView = PanelChrome(size: self.chromeSize,
                                                          alignment: alignment,
                                                          margin: Self.shadowMargin,
                                                          offset: CGSize(width: baseOffset.width,
                                                                         height: baseOffset.height + pin - lift + ontoRing),
                                                          tint: self.effectivePanelTint,
                                                          tintStrength: self.settings.panelTintStrength)
            }
            let link = chromeHosting.displayLink(target: closeDriver,
                                                 selector: #selector(DisplayLinkDriver.fire(_:)))
            link.add(to: .main, forMode: .common)
            closeLink = link
            // The content (the ring) rides the SAME continuing rise as the glass -
            // composited CA translation, so the pill and its ring lift as one piece.
            let liftAnim = CABasicAnimation(keyPath: "transform.translation.y")
            liftAnim.fromValue = 0
            // The translation runs in the CONTAINER's (non-flipped AppKit) layer space,
            // where +y is UP - keying it off the hosting view's own flippedness sent the
            // content DOWN while the glass rose (the downward waveform on cancel).
            liftAnim.toValue = 14
            liftAnim.beginTime = CACurrentMediaTime() + 0.25
            liftAnim.duration = 0.35
            liftAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            liftAnim.fillMode = .forwards
            liftAnim.isRemovedOnCompletion = false
            contentLayer.add(liftAnim, forKey: "closeLift")
            // Beat 4: the fade rides Core Animation on both layers while the pill shrinks
            // to its dot, so both reach nothing on the same frame.
            for layer in [chromeLayer, contentLayer] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.0
                fade.beginTime = CACurrentMediaTime() + 0.52
                fade.duration = 0.28
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                layer.add(fade, forKey: "closeShrink")
            }
            closingWithShrink = true
        } else if let chromeLayer = chromeHosting.layer, let contentLayer = hosting.layer {
            controller.panelIsClosing = true   // the wave pulls in + content fades on every exit
            // EVERY OTHER EXIT fades cleanly - no scaling, no distortion, and above all no
            // blink. That covers compact (already condensed to the ring pill), the
            // CONDENSED mini (whose pill is the ring pill too, so the pinch above - which
            // is the full-width mini's cancel - would distort it), and any close that
            // arrives while a session is somehow still live.
            for layer in [chromeLayer, contentLayer] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.0
                fade.duration = 0.22
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                layer.add(fade, forKey: "closeShrink")
            }
        }
        let sinceShow = Date().timeIntervalSince(shownAt)
        let shrinkFloor: TimeInterval = closingWithShrink ? 0.84 : (closingWithCancel ? 0.62 : 0)
        closingWithShrink = false
        closingWithCancel = false
        // Floor of 0.38s: enough for the quickened cancel (flatten 0.10s + pull ~0.22s)
        // to finish on screen instead of being cut off by orderOut.
        let delay = max(max(0.38, shrinkFloor), 0.40 - sinceShow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // A newer show() owns the panel ONLY if a live session is actually running.
            // Otherwise this close must land no matter how the generations raced - a
            // cancelled/idle panel that skips its orderOut is stuck on screen forever.
            if self.visibilityGeneration != gen {
                if self.controller.isRecording || self.controller.isBusy {
                    yapdiag("panel.orderOut deferred to live session (gen \(gen) != \(self.visibilityGeneration))")
                    return
                }
                // A NEWER hide owns the close and scheduled its own orderOut - a stale
                // timer must not cut that choreography short (it also dodged the newer
                // hide's on-screen floor). The newest hide always lands its own orderOut,
                // so skipping here can never strand the panel.
                if self.lastHideGeneration != gen { return }
            }
            self.panel.orderOut(nil)
            self.controller.panelIsPresented = false
        }
    }

    /// The window is a FIXED size, so a big<->small toggle needs NO window change - the SwiftUI card
    /// springs between the two forms IN PLACE. Deliberately a no-op: it must not re-position, so the
    /// panel stays exactly where it is (including where you dragged it) instead of snapping back to
    /// the default spot when it changes size.
    func applySizeIfVisible() { }

    /// Clamp the window so the visible card (inset by the shadow margin) stays inside the
    /// screen's usable area - below the menu bar, above the Dock, never off the sides.
    private func clampCardToScreen() {
        guard panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var origin = panel.frame.origin
        let f = panel.frame
        let m = Self.shadowMargin
        let cardW = Self.panelWidth
        let cardH = chromeSize.height > 0 ? chromeSize.height : Self.cardMaxHeight
        let bottomAligned = settings.panelPosition == .bottomCenter

        // Horizontal: the card is centered in the window.
        let cardMinX = f.midX - cardW / 2
        if cardMinX < vf.minX { origin.x += vf.minX - cardMinX }
        if cardMinX + cardW > vf.maxX { origin.x -= (cardMinX + cardW) - vf.maxX }

        // Vertical: the card hugs the window's anchored edge, inset by the margin.
        let cardMinY = bottomAligned ? f.minY + m : f.maxY - m - cardH
        if cardMinY < vf.minY { origin.y += vf.minY - cardMinY }
        if cardMinY + cardH > vf.maxY { origin.y -= (cardMinY + cardH) - vf.maxY }

        if origin != panel.frame.origin {
            isProgrammaticMove = true
            panel.setFrameOrigin(origin)
            isProgrammaticMove = false
        }
    }

    /// Place the WINDOW so the CARD inside it (horizontally centered, top/bottom-aligned, inset by
    /// the shadow margin) lands at the intended screen spot.
    private func positionOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let w = Self.windowSize.width, h = Self.windowSize.height
        let m = Self.shadowMargin, cardW = Self.panelWidth
        switch settings.panelPosition {
        case .bottomCenter:
            // card centered horizontally, bottom-aligned; its bottom sits `m` above the window bottom.
            return NSPoint(x: vf.midX - w / 2, y: (vf.minY + 140) - m)
        case .center:
            // dead center of the screen.
            return NSPoint(x: vf.midX - w / 2, y: vf.midY - h / 2)
        case .topCenter:
            // card centered, top-aligned; its top sits `m` below the window top.
            return NSPoint(x: vf.midX - w / 2, y: (vf.maxY - 40) - h + m)
        case .nearMenuBar:
            let cardCenterX = vf.maxX - 20 - cardW / 2
            return NSPoint(x: cardCenterX - w / 2, y: (vf.maxY - 8) - h + m)
        }
    }
}
