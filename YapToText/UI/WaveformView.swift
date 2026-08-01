import SwiftUI
import AppKit

/// Siri-style voice visualizer, v12. Design rules learned the hard way:
///
/// - NO scrolling: the wave SWAYS IN PLACE (oscillating carrier phases), it never travels
///   sideways like a conveyor belt.
/// - ALL animation phases are INTEGRATED (phase += rate * dt), never `t * rate` - scaling
///   absolute time makes phases jump when a rate changes (that read as stuttering).
/// - Flame behavior: bands rise instantly and release slowly (the wave burns through a
///   sentence instead of pumping per word), and a field of wandering lobes redistributes
///   energy so the shape is alive; speech feeds the flicker rate.
/// - The voice envelope (verified adaptive-SNR spectrum) is computed ONCE per frame and
///   shared by all ribbons.
/// The wave's colour treatment: which palette, how vivid, and the RGB dials.
/// THE ONE CONDENSE CLOCK: the pill's glass shrink and the wave's winding must flow as
/// one motion, so both read this single timestamp - set exactly once when the condense
/// begins. Two independent stopwatches (SwiftUI's onChange delivery vs a task sleep on
/// the panel side) drifted apart under main-thread load, and the pill visibly led or
/// lagged the line ends on some runs.
@MainActor
enum CondenseClock {
    static var start: Date?
}

/// THE ONE RGB CLOCK. Every wave on screen must show the SAME hue at the same instant, and
/// a layout switch (which remounts the view and its motion state) must never snap the
/// colour back to red. Integrated shared phase: the forward-most frame advances it, every
/// other reader just samples it.
@MainActor
enum WaveRGBClock {
    private(set) static var phase: Double = 0
    private static var last: Double = -1
    static func advance(to now: Double, speed: Double) -> Double {
        if last >= 0, now > last { phase += min(0.1, now - last) * (speed / 6.0) }
        if now > last { last = now }
        return phase
    }
}

struct WaveStyle: Equatable {
    /// nil = the stock accent palette (accent -> cyan -> mint).
    var tint: Color? = nil
    /// The ribbons cycle the spectrum instead of using a fixed palette.
    var rainbow: Bool = false
    /// 0 = washed-out pastel, 1 = full saturation.
    var strength: Double = 1
    /// RGB only: cycle rate, and how far apart the ribbons sit in hue.
    var rgbSpeed: Double = 1
    var rgbSpread: Double = 0.12
    /// Verdict mode: every ribbon takes the tint EXACTLY, no analogous spread - a
    /// success/failure ring must read unmistakably green or red, and the family spread
    /// (which leans warm) was washing red into orange.
    var uniformFamily: Bool = false
    static let plain = WaveStyle()
}

struct WaveformView: View {
    var data: AudioVisualData
    var isActive: Bool
    var scale: CGFloat = 1
    /// Rainbow mode: the ribbons cycle through the spectrum instead of the accent palette.
    /// (The user-requested RGB effect lives HERE, on the wave - never on the glass behind it.)
    /// Everything about how the wave is COLOURED, in one value.
    var style: WaveStyle = .plain
    /// Hold the LAST LIVE shape instead of decaying to the idle wave. Used while the mini
    /// condenses into the spinner: the dancing lines must stay visible so they can be seen
    /// shrinking into the middle - without this the wave snapped to a flat idle frame the
    /// instant recording stopped and the condense had nothing to show.
    var freeze: Bool = false
    /// BLACK-HOLE SUCK: while true, every point of every ribbon is pulled along a spiral
    /// path into the center - the lines visibly WIND INTO the vortex, geometry-level, not a
    /// scale trick. Runs on its own clock from the moment it's switched on.
    var sucking: Bool = false
    /// Panel surfaces share CondenseClock so the wave and the glass pill condense as ONE
    /// motion. Every other surface (menu-bar loader, onboarding demos) must run its own
    /// zero-start clock: adopting the panel's stamp made a demo that happened to start
    /// within 5s of a real dictation pop in already-wound, or rewind mid-animation.
    var usesSharedClock: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = WaveMotion()

    /// Diagnostics kill switch (debug bisection of the macOS 26.5 DesignLibrary crash): freezes
    /// the timeline so the wave renders one static frame and produces ZERO per-frame render
    /// transactions inside the glass card.
    nonisolated(unsafe) static var frozenForDiagnostics = false
    /// MARKETING BOOST (debug hook only): multiplies the drawn amplitude so staged
    /// screenshots show the wave at full theatrical reactivity. Never ships enabled.
    nonisolated(unsafe) static var demoAmpBoost: Double = 1

    /// Horizontal glow bleed: the canvas extends this far past its layout width on each
    /// side so blur is never clipped at the edges (a clipped blur reads as a hard
    /// vertical seam of glow at the line ends).
    static let bleed: CGFloat = 12
    /// Vertical glow bleed - same reason, other axis (the ring's halo reaches past the
    /// 44pt canvas height and was clipping into a hard-edged block).
    static let bleedV: CGFloat = 14
    /// The bleed must never shrink below its canonical size: the condensed ring (and its
    /// halo) render at the mini's full size in EVERY layout now, so a scaled-down canvas
    /// margin (the big menu's 0.73x) hard-cut the glow at the top and bottom edges.
    private var bleedX: CGFloat { Self.bleed * max(scale, 1) }
    private var bleedY: CGFloat { Self.bleedV * max(scale, 1) }

    var body: some View {
        waveContent
        .padding(.horizontal, -bleedX)
        .padding(.vertical, -bleedY)
        // The edge-fade masks are for the WIDE live wave; on the tiny condensed canvas
        // they chop straight into the ring's glow, so they relax to full-open while
        // sucking (the ring lives in the center - it needs no edge fade).
        .mask {
            // The horizontal edge fade stays on even while condensed: it is what
            // dissolves the wave's line ends (dropping it mid-collapse made the tips
            // end raw - "cut off"), and it never reaches the centered ring anyway.
            // The fade must still complete INSIDE the layout bounds even though the
            // canvas now extends `bleed` past them - stops are computed against the
            // expanded width so glow never spills past the pill edge.
            //
            // BOTH masks carry the same negative padding as the canvas: a mask renders
            // only over its own bounds, so left at layout size it multiplied everything
            // the bleed had un-clipped by zero - a hard glow cut at the frame edge (the
            // visible top/bottom seams on the big menu's condensed ring, whose halo is
            // taller than that layout's wave band).
            GeometryReader { g in
                    let f = min(0.3, bleedX / max(1, g.size.width))
                    let inner = 1 - 2 * f
                    // One smooth ramp from the EXPANDED edge to the old 10% line: the
                    // wave still fades out before the pill edge, but the glow's tail is
                    // never hard-cut (pinning clear at the layout bound re-clipped
                    // everything the bleed had just un-clipped).
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: f + 0.10 * inner),
                                           .init(color: .black, location: 1 - f - 0.10 * inner),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
            }
            .padding(.horizontal, -bleedX)
            .padding(.vertical, -bleedY)
        }
        .mask {
            Group {
                if sucking {
                    Rectangle()
                } else {
                    GeometryReader { g in
                        let f = min(0.3, bleedY / max(1, g.size.height))
                        let inner = 1 - 2 * f
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black, location: f + 0.22 * inner),
                                               .init(color: .black, location: 1 - f - 0.22 * inner),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
            }
            .padding(.horizontal, -bleedX)
            .padding(.vertical, -bleedY)
        }
        .frame(height: 44 * scale)
        .accessibilityHidden(true)
    }

    /// Only run the display-linked animation while actually recording. The recording panel's
    /// hosting view is kept alive for the whole app session, so an unconditional
    /// `TimelineView(.animation)` would animate the waveform at 60fps FOREVER - even while the
    /// panel is hidden and the app is idle - pegging the CPU. When not recording, draw one static
    /// frame (no timer), which costs nothing.
    private var waveContent: some View {
        // ONE stable view structure whether active or not, running at the FULL display refresh
        // (120Hz on ProMotion). Full rate is safe again: since the panel's two-graph split, this
        // view renders in the glass-free content graph, so its frames never run macOS 26.5's
        // crash-prone glass renderer - the old 40fps cap existed only to protect that path, not
        // because the drawing is expensive (the per-frame math is light).
        //
        // `paused:` instead of an if/else structure swap: structurally replacing the subtree at
        // the moment recording stopped was itself a confirmed crash trigger. A paused timeline
        // costs nothing while idle and changes no structure when recording starts/stops.
        // Native refresh while RECORDING (the live wave deserves 120Hz); the processing
        // spinner caps at 40fps - a 120Hz canvas running concurrently with whisper
        // inference was pure heat exactly when the CPU is busiest.
        TimelineView(.animation(minimumInterval: isActive ? nil : 1.0 / 40.0,
                                paused: (!isActive && !sucking) || Self.frozenForDiagnostics)) { timeline in
            Canvas { context, size in
                let live = isActive && !Self.frozenForDiagnostics
                // Suck progress: ease-in over 0.65s - slow grip, then the plunge.
                let suckF: Double
                let suckSpin: Double
                if sucking {
                    // Frame-accurate clock adoption: prefer the shared condense clock,
                    // and if a NEWER condense stamped it (spam faster than a render
                    // cycle, onChange coalesced away), adopt it mid-flight.
                    if usesSharedClock, let shared = CondenseClock.start {
                        if motion.suckStart == nil || shared > (motion.suckStart ?? .distantPast).addingTimeInterval(0.05) {
                            if timeline.date.timeIntervalSince(shared) < 5 {
                                motion.suckStart = shared
                                motion.suckElapsed = 0   // fresh condense, fresh integration
                                motion.suckLastFrame = nil
                            }
                        }
                    }
                    if motion.suckStart == nil { motion.suckStart = timeline.date }
                }
                if sucking, let start = motion.suckStart {
                    let wall = timeline.date.timeIntervalSince(start)
                    let frameDT = motion.suckLastFrame.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                    motion.suckLastFrame = timeline.date
                    if motion.suckElapsed <= 0 {
                        motion.suckElapsed = max(0.001, min(wall, 0.15))   // trigger latency, bounded
                    } else {
                        motion.suckElapsed = min(wall, motion.suckElapsed + min(frameDT, 0.05))
                    }
                    let elapsed = motion.suckElapsed
                    let raw = min(1, max(0, elapsed / 0.8))
                    suckF = raw * raw * (3 - 2 * raw)   // smooth-step morph into the spiral
                    suckSpin = elapsed                  // the spiral's endless rotation clock
                } else { suckF = 0; suckSpin = 0 }
                var ctx = context
                ctx.translateBy(x: bleedX, y: bleedY)
                let inner = CGSize(width: size.width - 2 * bleedX,
                                   height: size.height - 2 * bleedY)
                draw(ctx, inner, now: (live || sucking) ? timeline.date.timeIntervalSinceReferenceDate : 0,
                     suck: suckF, suckSpin: suckSpin)
            }
        }
        .onChange(of: sucking) { _, on in
            if !on {
                motion.suckStart = nil   // clock (re)acquired per-frame while on
                motion.suckElapsed = 0
                motion.suckLastFrame = nil
            }
        }
    }

    // MARK: Motion model

    final class WaveMotion {
        var x: [Double] = []
        var v: [Double] = []
        var last: Double = -1
        var history: [(t: Double, vals: [Double])] = []
        var fastE: Double = 0
        var slowE: Double = 0
        var smoothSurge: Double = 0
        var body: Double = 0          // slow-burning energy: how "fed" the flame is
        var flamePhase: Double = 0    // INTEGRATED flicker clock (speech speeds it up smoothly)
        var swayPhase: Double = 0     // integrated carrier sway clock
        var ripplePhase: Double = 0   // integrated traveling-ripple clock (right -> left)

        var loud: Double = 0          // smoothed overall loudness -> drives HEIGHT (expressive)

        /// Whether the last drawn frame was live - lets draw() detect a session starting.
        var wasLive = false
        /// Amplitude scale of the last LIVE frame, so the condense transition starts at
        /// exactly the height the wave had - no snap at the handoff.
        var lastLiveAmp: Double = 0.5
        /// The active suck's start time (shared-clock aware; see body).
        var suckStart: Date?
        /// FRAME-INTEGRATED choreography clock: advances by real frame time, capped at
        /// 50ms per frame and never past wall time. Pure wall-clock elapsed TELEPORTED
        /// the animation whenever rendering starved (the whisper cold load on a first
        /// run) - frames stopped, the clock didn't, and the resume snapped mid-wind.
        var suckElapsed: Double = 0
        var suckLastFrame: Date?
        /// The live spectrum + level at the moment of stop: the transition steps from
        /// THESE toward idle instead of snapping targets in one frame.
        var lastLiveSpectrum: [Float] = []
        var lastLiveLevel: Double = 0.3

        /// Fresh session, canonical pose: every recording opens with the SAME wave
        /// orientation. Without this the integrated phase clocks resumed wherever they froze
        /// last time, so the first visible lobe sometimes pointed DOWN - which read as the
        /// whole wave randomly flipping on open.
        func reset() {
            x = []; v = []; history = []
            last = -1
            fastE = 0; slowE = 0; smoothSurge = 0; body = 0; loud = 0
            flamePhase = 0; swayPhase = 0; ripplePhase = 0
        }

        func step(target rawTarget: [Float], level rawLevel: Double, now: Double) {
            // NaN/Inf wall: a single non-finite audio sample must never enter the motion model.
            // Swift's min/max do NOT sanitize NaN, so every downstream clamp would pass it through
            // and it would eventually reach a CGFloat the renderer reads as a bogus pointer.
            let level = rawLevel.isFinite ? max(0, rawLevel) : 0
            let target = rawTarget.map { $0.isFinite ? $0 : 0 }
            if x.count != target.count {
                x = target.map(Double.init)
                v = Array(repeating: 0, count: target.count)
            }
            var dt = last < 0 ? 1.0 / 60 : min(max(now - last, 0), 0.05)
            let dtWhole = dt
            last = now
            let omega = 32.0
            let zeta = 0.85
            while dt > 0 {
                let h = min(dt, 1.0 / 120)
                dt -= h
                let release = exp(-h / 0.4)
                for i in x.indices {
                    // Instant rise, slow release: gaps dim the wave gently instead of closing it.
                    let sustained = max(Double(target[i]), x[i] * release)
                    let a = omega * omega * (sustained - x[i]) - 2 * zeta * omega * v[i]
                    v[i] += a * h
                    x[i] += v[i] * h
                }
            }
            history.append((now, x))
            while history.count > 2, now - history[1].t > 0.35 { history.removeFirst() }

            // Energy signals come from REAL loudness now (the spectrum is whitened per-band for
            // full-width shape, so its mean no longer carries loudness). Height, surge, flame and
            // ripple speed all track the actual voice level.
            fastE += (level - fastE) * min(1, dtWhole / 0.03)
            slowE += (level - slowE) * min(1, dtWhole / 0.30)
            smoothSurge += (surge - smoothSurge) * min(1, dtWhole / 0.09)
            body += (level - body) * min(1, dtWhole / (level > body ? 0.25 : 0.8))
            loud += (level - loud) * min(1, dtWhole / (level > loud ? 0.05 : 0.22))
            // Integrated clocks: rates can change every frame without any phase jump.
            flamePhase += (0.6 + 2.6 * body) * dtWhole
            swayPhase += dtWhole
            ripplePhase += WaveMath.rippleRate(body: body) * dtWhole
        }

        var surge: Double { min(1, max(0, (fastE - slowE) * 6)) }

        /// Envelope at position `p`, `delay` seconds back, Gaussian-smoothed across bands
        /// (sigma 2.6) so only broad swells survive, and time-interpolated between frames.
        func delayed(_ p: Double, delay: Double, now: Double) -> Double {
            guard let newest = history.last else { return 0 }
            let want = now - delay
            var older = newest, newer = newest
            for entry in history.reversed() {
                if entry.t <= want { older = entry; break }
                newer = entry
            }
            let span = newer.t - older.t
            let mix = span > 0 ? min(max((want - older.t) / span, 0), 1) : 1
            func sample(_ frame: [Double]) -> Double {
                let n = frame.count
                guard n > 1 else { return 0 }
                let center = p * Double(n - 1)
                let sigma = 2.3   // a touch wider smoothing so crests bend gently, never sharply
                let lo = max(0, Int(center - 3 * sigma))
                let hi = min(n - 1, Int(center + 3 * sigma) + 1)
                var sum = 0.0, wsum = 0.0
                for j in lo...hi {
                    let d = (Double(j) - center) / sigma
                    let w = exp(-0.5 * d * d)
                    sum += frame[j] * w
                    wsum += w
                }
                return wsum > 0 ? sum / wsum : 0
            }
            return max(0, sample(older.vals) * (1 - mix) + sample(newer.vals) * mix)
        }
    }

    // MARK: Ribbons (in-place swaying - no lateral travel)

    private struct Ribbon {
        let cycles: Double
        let basePhase: Double
        let swayAmp: Double       // radians of back-and-forth phase sway
        let swayRate: Double      // sway oscillation rate (multiplies the integrated clock)
        let lowBias: Double
        let colors: [Color]
        let lineWidth: CGFloat
        let opacity: Double
    }

    /// Scale a colour's vividness. Fading saturation alone goes grey and muddy, so the
    /// brightness lifts as saturation drops - the wave turns pastel, never dirty.
    static func vivid(_ c: Color, _ strength: Double) -> Color {
        let k = max(0, min(1, strength))
        guard let ns = NSColor(c).usingColorSpace(.deviceRGB) else { return c }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(sat) * k,
                     brightness: Double(min(1, b + (1 - CGFloat(k)) * 0.25)))
            .opacity(Double(a))
    }

    /// Three analogous steps from one colour: the chosen hue, then +0.06 and +0.12 turns,
    /// with saturation/brightness floored so the wave always glows against the dark glass.
    static func family(_ tint: Color) -> (Color, Color, Color) {
        let ns = NSColor(tint).usingColorSpace(.deviceRGB) ?? .systemBlue
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        let s2 = max(0.5, min(1, sat)), b2 = max(0.85, min(1, b))
        func step(_ d: CGFloat) -> Color {
            Color(hue: Double((h + d).truncatingRemainder(dividingBy: 1)),
                  saturation: Double(s2), brightness: Double(b2))
        }
        return (step(0), step(0.06), step(0.12))
    }

    private static let ribbons: [Ribbon] = [
        Ribbon(cycles: 1.7, basePhase: 0.0,  swayAmp: 0.9, swayRate: 0.65, lowBias: 0.75,
               colors: [.accentColor, .cyan], lineWidth: 2.4, opacity: 0.95),
        Ribbon(cycles: 1.9, basePhase: 0.85, swayAmp: 1.1, swayRate: 0.5,  lowBias: 0.55,
               colors: [.cyan, .mint], lineWidth: 1.9, opacity: 0.6),
        Ribbon(cycles: 2.2, basePhase: 1.7,  swayAmp: 0.8, swayRate: 0.85, lowBias: 0.35,
               colors: [.mint, .accentColor.opacity(0.8)], lineWidth: 1.5, opacity: 0.42),
        Ribbon(cycles: 1.7, basePhase: 0.28, swayAmp: 0.9, swayRate: 0.65, lowBias: 0.75,
               colors: [.white.opacity(0.9), .white.opacity(0.5)], lineWidth: 0.9, opacity: 0.75),
    ]

    private func idleSpectrum(_ now: Double, count: Int) -> [Float] {
        (0..<count).map { i in
            let u = Double(i) / Double(max(count - 1, 1))
            return Float(0.07 * sin(u * .pi) * (0.6 + 0.4 * sin(now * 1.3 + u * 4.5)))
        }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, now: Double, suck: Double = 0, suckSpin: Double = 0) {
        let count = data.spectrum.count
        guard count > 1 else { return }
        // A session just started: reset to the canonical pose so the wave always opens the
        // same way up (see WaveMotion.reset).
        if isActive && !motion.wasLive { motion.reset() }
        // Frozen: hold the exact last live state - no stepping toward idle, and all
        // time-based reads use the moment it froze. CRUCIAL: wasLive must still drop to
        // false here - leaving it true skipped the canonical reset on the next session,
        // which brought back the random 180-degree flip on open (caught live).
        let now = (freeze && !isActive && !sucking) ? motion.last : now
        if freeze && !isActive && !sucking {
            motion.wasLive = false
        } else {
            if isActive && !motion.wasLive { motion.reset() }
            motion.wasLive = isActive
            // While sucking, the un-swallowed material keeps DANCING (idle sway + the
            // env floor below) instead of freezing - the line is alive until consumed.
            if isActive {
                motion.lastLiveSpectrum = data.spectrum
                motion.lastLiveLevel = Double(data.level)
                motion.step(target: data.spectrum, level: Double(data.level), now: now)
            } else if sucking, motion.lastLiveSpectrum.count == count {
                // Transition: ease the TARGET from the last live spectrum toward idle,
                // instead of snapping it in one frame (that snap was the visible blip).
                let mixRaw = min(1, suckSpin / 0.7)
                let mix = Float(mixRaw * mixRaw * (3 - 2 * mixRaw))
                let idle = idleSpectrum(now, count: count)
                let blended = zip(motion.lastLiveSpectrum, idle).map { live, id in
                    live * (1 - mix) + id * mix
                }
                let level = motion.lastLiveLevel * Double(1 - mix) + 0.08 * Double(mix)
                motion.step(target: blended, level: level, now: now)
            } else {
                motion.step(target: idleSpectrum(now, count: count), level: 0.08, now: now)
            }
        }

        let midY = Double(size.height) / 2
        let maxAmp = midY - 8 * Double(scale)
        let steps = 130
        let surge = (isActive || sucking) ? motion.smoothSurge : 0
        let energyNow = min(1, max(0, motion.fastE * 3))
        // Height tracks real loudness: quiet stays small, loud swells - the expressiveness.
        var ampScale = (isActive ? (0.16 + 1.0 * pow(max(0, motion.loud), 0.55)) : 0.18) * Self.demoAmpBoost
        if isActive { motion.lastLiveAmp = ampScale }
        if sucking {
            // NO chunk at the handoff: start from the amplitude the live wave actually
            // had at the moment of stop, and ease toward the transition's working level -
            // the lines never jolt between "recording" and "condensing".
            let blend = min(1, suckSpin / 0.6)
            let eased = blend * blend * (3 - 2 * blend)
            ampScale = motion.lastLiveAmp + (max(0.55, motion.lastLiveAmp * 0.8) - motion.lastLiveAmp) * eased
        }
        let fp = motion.flamePhase
        let sp = reduceMotion ? 0 : motion.swayPhase

        // ---- Shared envelope, computed ONCE per frame ----
        // Flame lobes: centers wander, widths breathe, weights flicker - all on the integrated
        // flame clock, so changing flicker speed can never jump the shape.
        func flame(_ u: Double) -> Double {
            var f = 0.0
            let lobes: [(Double, Double, Double, Double)] = [
                (0.30, 0.0, 1.1, 2.3), (0.55, 2.1, 3.6, 0.7), (0.74, 4.2, 0.4, 4.9),
            ]
            for (base, dp, wp, ap) in lobes {
                let center = base + 0.13 * sin(fp * 0.9 + dp) + 0.05 * sin(fp * 2.3 + wp)
                let width = 0.17 + 0.05 * sin(fp * 1.4 + wp)
                let weight = 0.65 + 0.35 * sin(fp * 1.9 + ap)
                let d = (u - center) / width
                f += weight * exp(-d * d)
            }
            return min(1.35, f / 1.5)
        }

        // Pass 1: base envelope (voice spectrum x flame), no ripple yet.
        var base = [Double](repeating: 0, count: steps + 1)
        var baseSum = 0.0
        for s in 0...steps {
            let u = Double(s) / Double(steps)
            let delay = abs(u - 0.5) * 0.14
            let e = motion.delayed(u, delay: delay, now: now)
            base[s] = max(0, pow(max(0, e), 0.72) * (1 + 0.25 * surge) * (0.30 + 0.70 * flame(u)))
            baseSum += base[s]
        }
        let baseMean = baseSum / Double(steps + 1)

        // Pass 2: the VERIFIED traveling ripple (WaveMath: right -> left wavefront on an
        // integrated clock, depth proportional to how hot each range runs vs the average).
        var env = [Double](repeating: 0, count: steps + 1)
        for s in 0...steps {
            let u = Double(s) / Double(steps)
            let depth = WaveMath.rippleDepth(local: base[s], mean: baseMean,
                                             surge: surge, energy: energyNow)
            let ripple = WaveMath.rippleFactor(u: u, phase: motion.ripplePhase, depth: depth)
            let taper = pow(max(0, sin(u * .pi)), 0.55)
            env[s] = base[s] * ripple * taper
            // Sucking: floor the envelope at a resting-line strength so the intake always
            // has visible ribbons to pour, no matter how far the voice had decayed.
            if suck > 0 { env[s] = max(env[s], 0.4 * taper) }
        }

        // Advance the SHARED integrated RGB clock (base cycle 6s at speed 1). Shared, not
        // per-view: a per-view phase restarted at red on every layout switch, and two waves
        // visible at once (panel + settings preview) drifted to different colours.
        let rgbPhase = now > 0 ? WaveRGBClock.advance(to: now, speed: style.rgbSpeed) : WaveRGBClock.phase

        // Stroke weight follows the same canonical rule as the geometry above: while the
        // wave winds into the ring it eases from this view's own scale to the mini's 1.0,
        // so the finished spinner has identical line weight and glow in every layout.
        let ds = CGFloat(Double(scale) + (1 - Double(scale)) * suck)

        // ---- Ribbons: carriers sway in place through the shared envelope ----
        for (index, ribbon) in Self.ribbons.enumerated() {
            // Rainbow: hue-cycle the three colored ribbons (staggered so they shimmer against
            // each other); the white highlight ribbon stays white for definition.
            let ribbonColors: [Color]
            if style.rainbow, index < 3 {
                // RGB: the ribbons ride a shared spectrum sweep. Speed sets the cycle rate,
                // spread sets how far apart the ribbons sit in hue - 0 pulses the whole wave
                // as one colour, high fans a full rainbow across it.
                let hue = (rgbPhase + Double(index) * style.rgbSpread).truncatingRemainder(dividingBy: 1)
                let hue2 = (hue + max(0.04, style.rgbSpread * 1.5)).truncatingRemainder(dividingBy: 1)
                ribbonColors = [Color(hue: hue < 0 ? hue + 1 : hue, saturation: 0.85, brightness: 1),
                                Color(hue: hue2 < 0 ? hue2 + 1 : hue2, saturation: 0.85, brightness: 1)]
            } else if let tint = style.tint, index < 3 {
                if style.uniformFamily {
                    // Verdict ring: the exact colour, every ribbon - no spread.
                    ribbonColors = [tint, tint]
                } else {
                    // A custom wave colour spreads into the same three-step analogous family the
                    // stock palette uses (accent -> cyan -> mint), so the ribbons keep their
                    // depth instead of collapsing into one flat colour.
                    let fam = Self.family(tint)
                    ribbonColors = [[fam.0, fam.1], [fam.1, fam.2], [fam.2, fam.0.opacity(0.8)]][index]
                }
            } else {
                ribbonColors = ribbon.colors
            }
            // STRENGTH: one dial over every style. Below 1 the colours ease toward a soft
            // pastel (saturation down, brightness up) instead of turning grey; the white
            // highlight ribbon is left alone so the wave keeps its definition.
            let shaded = style.strength >= 0.999 || index >= 3
                ? ribbonColors : ribbonColors.map { Self.vivid($0, style.strength) }
            let phase = ribbon.basePhase + ribbon.swayAmp * sin(sp * ribbon.swayRate)
                        + 0.35 * surge * sin(sp * 2.2 + ribbon.basePhase)
            var points: [CGPoint] = []
            points.reserveCapacity(steps + 1)
            for s in 0...steps {
                let u = Double(s) / Double(steps)
                let x = u * Double(size.width)
                let carrier = sin(u * 2 * .pi * ribbon.cycles + phase)
                // Flatter per-ribbon tilt: whitening already balances the spectrum across the
                // width, so a strong lowBias here would re-lopside it toward the left.
                let listen = ribbon.lowBias * (1 - u) + (1 - ribbon.lowBias) * u
                let yRaw = midY + carrier * env[s] * (0.85 + 0.3 * listen) * maxAmp * ampScale
                // Hard NaN/Inf boundary: SwiftUI must never receive a non-finite coordinate. A NaN
                // CGFloat here is the quiet-NaN (0x7ff8...) the runtime later misreads as an object
                // pointer during a graph flush - collapse it to the centerline instead.
                let y = yRaw.isFinite ? yRaw : midY
                points.append(CGPoint(x: x.isFinite ? x : 0, y: y))
            }
            // THE FINAL CHOREOGRAPHY (ported 1:1 from the approved browser demo):
            //  stop -> short beat -> the line BREAKS at the middle on a clean ease, the
            //  halves retreating while their freed heads already CURL toward their poles
            //  (left up, right down) -> feeding overlaps the retreat (no stop anywhere) ->
            //  material tapers to the ring's own width and slides through the fixed,
            //  INVISIBLE entry points onto the tangent runway, winding clockwise into the
            //  living ring. Constant feed velocity, magnetic-pole attraction curve.
            let warped: [CGPoint]
            var breakIndices: Set<Int> = []
            if suck > 0 {
                let cx = Double(size.width) / 2, cy = midY
                // CANONICAL CHOREOGRAPHY: every layout plays the mini's EXACT animation at
                // the mini's EXACT size. The reference width is the mini's own 126pt no
                // matter how wide - or how scaled - this canvas is, so rope length, runway,
                // split gap, curl, feed AND the finished ring are pixel-identical in every
                // menu. (Scaling this by the view scale gave three different spinner sizes
                // for the same processing state: 21pt tiny, 18.6 medium, 15.2 big.) A wider
                // live wave GATHERS into this canonical span over the first beat (see px
                // below), then the one true animation plays.
                let refW = 126.0
                // QUICK, not frantic: the whole break-in choreography (gates, split,
                // feed) runs on a 2.6x clock - snappy with a touch more grace.
                let t = suckSpin * 2.6
                let halfLen = refW * 0.43
                // Longer runway = the gates' guidance reaches deeper, so approaching
                // material is on rails earlier and can't bulge outward near the circle.
                let runway = refW * 0.11
                // Less backward, more upward: a shorter retreat that overlaps the feed
                // almost immediately - the split flows upward AS it opens.
                let gapMax = refW * 0.05
                let gateT = 0.2, retractT = 0.55
                let rt = min(1, max(0, (t - gateT) / retractT))
                let gap = gapMax * (rt * rt * (3 - 2 * rt))
                let suckT = max(0, t - gateT - retractT * 0.15)
                // 0.5: consumption completes ~0.5s; the pill's width TRACKS this same
                // consumption curve (RecordingPanel), so the glass hugs the material the
                // whole way down and tails can never outlive the shrinking pill.
                let headBaseRaw = suckT > 0 ? refW * 0.5 * (suckT * suckT / (suckT + 0.22)) : 0
                // SMOOTH BREATHING SPIN: the raw feed accelerates without bound - left
                // uncapped, the settled ring spun ever faster (~2.5 rev/s and climbing),
                // which flickered the ripple and read as chop. Once everything is wound,
                // the feed CAPS and the leftover advance becomes a gentle rigid rotation.
                let cs = 1.0   // choreography scale: an exact copy of the mini, at the mini's size
                let windCap = halfLen + gap + 6 * cs
                let headBase = min(headBaseRaw, windCap)
                // LEAD RIBBON: one strand (pseudo-random per dictation) runs slightly ahead
                // of the pack, the rest staggered behind - silky, never a clump moving as
                // one block. The seed is stable for the whole suck, different every session.
                let seed = Int((now - suckSpin) * 13.7).magnitude % 4
                let staggerTable = [0.06, 0.02, -0.02, -0.05]
                let headS = headBase + staggerTable[(index + Int(seed)) % 4] * halfLen * min(1, suckT / 0.5)
                let consumed = min(1, max(0, (headBase - gap) / halfLen))
                // Per-ribbon consumption: a lagging (staggered) ribbon must slide its
                // waiting material by ITS OWN progress, not the pack average - sliding
                // by the average carried a lagging tail past its gate and across the
                // circle interior (the occasional outward flick at entry).
                let consumedR = min(1, max(0, (headS - gap) / halfLen))
                let bowF = { let b = min(1, suckT / 0.4); return b * b * (3 - 2 * b) }()
                // The runway's outward bow SHEDS as the rope runs out: by the time the
                // tail is whipping through the gate there is nothing left to hold clear
                // of the surface, and the lingering bow read as a concave-outward flare.
                let bowAmp = 1.4 * cs * max(0, 1 - consumed * 1.35)
                let rBase = (10.5 - Double(index) * 0.7) * cs
                // The settled rotation: a quarter of the excess feed, so the ring turns a
                // calm ~0.6 rev/s. ONE shared angular rate for every lane (a fixed
                // reference radius, not the lane's own): dividing by each lane's radius
                // spun the inner lanes faster, so after a few seconds the four lanes sat
                // at unrelated angles and their ripple crests fought each other - the
                // composite outline read as lumpy. As a rigid body the ring breathes as
                // one coherent shape.
                let spinExtra = headBaseRaw > windCap ? (headBaseRaw - windCap) / (10.5 * cs) * 0.25 : 0
                func track(_ sv: Double, _ left: Bool) -> (Double, Double) {
                    let attach = left ? -Double.pi / 2 : Double.pi / 2
                    if sv >= 0 {
                        let arc = sv / rBase
                        let th = attach + arc + spinExtra
                        // VORTEX BREATH: two soft counter-drifting waves let the wound
                        // material swim slightly in and out of the circle as it spins.
                        //
                        // THE FREQUENCIES MUST BE EVEN INTEGERS. Both halves wind onto the
                        // same lane and overlap over ~230 degrees, and the long ribbons
                        // wrap past a full turn onto themselves - so the same world angle
                        // is drawn two or three times. A half's arc coordinate differs from
                        // the other's by exactly pi (opposite gates), and a wrap differs by
                        // 2*pi. An even frequency makes both offsets whole multiples of
                        // 2*pi, so every overlapping copy computes the IDENTICAL radius and
                        // they land exactly on top of each other. The old 4.7 put the
                        // copies 126 degrees out of phase - a 0.56px radial split on a
                        // ~1.5px stroke, which is precisely the doubled, wobbly, faintly
                        // jagged edge (and the little end-cap blobs) on the ring.
                        // The BIG term is a UNIFORM pulse (no arc dependence at all): the
                        // ring swells and settles as a whole, so it stays a mathematically
                        // perfect circle at every instant while still visibly breathing.
                        // The old low-frequency arc term was a 2-lobe deformation - 6.8% of
                        // the radius - which is exactly what read as "not a circle". Only a
                        // small even-frequency undulation remains for the vortex life, so
                        // out-of-roundness at any instant is now ~2% (0.2px).
                        // VORTEX LIFE: a uniform pulse (whole ring breathes, stays exactly
                        // circular) plus three EVEN-frequency harmonics that drift at
                        // different rates and carry a different phase per lane. Because each
                        // lane gets its own phase, the strands swim in and out past each
                        // other - one pokes proud of the band, another tucks inside, then
                        // they trade - while the ring as a whole still reads perfectly
                        // round. Even frequencies are mandatory: they keep both halves and
                        // the self-wrap exactly coincident, so nothing ever doubles or jags.
                        let breathe = 0.035 * sin(now * 1.5 - Double(index) * 0.9)
                                    + 0.020 * sin(arc * 4.0 + now * 2.3 - Double(index) * 1.3)
                                    + 0.016 * sin(arc * 2.0 - now * 1.15 + Double(index) * 2.1)
                                    + 0.010 * sin(arc * 6.0 + now * 3.1 - Double(index) * 0.7)
                        // The entry ramp keeps the mouths dead-round WHILE winding, but it
                        // is also arc-dependent, so it too would desync the copies. Once
                        // the rope is fully wound it relaxes to 1 everywhere - uniform,
                        // perfectly coherent breathing.
                        let entryEase = min(1.0, arc / 0.9)
                        let ripple = 1 + (entryEase + (1 - entryEase) * consumed) * breathe
                        let rr = rBase * ripple
                        return (cx + cos(th) * rr, cy + sin(th) * rr)
                    }
                    // Backward tangent runway through the invisible entry point, bowed a
                    // few px OUTWARD along its length (easing to exactly tangent at the
                    // mouth) so approaching material always sits clear of the surface -
                    // it can never read as bending inward into the circle.
                    let ax = cx + cos(attach) * rBase, ay = cy + sin(attach) * rBase
                    let tx = -sin(attach), ty = cos(attach)
                    // The bow is a gentle BELL peaked well back along the runway (away
                    // from the mouth), fading to zero at both the mouth and the far end -
                    // no hump sitting right at the gate.
                    let q = min(1.0, abs(sv) / (refW * 0.11))
                    let out = sin(pow(q, 1.5) * .pi) * bowAmp
                    return (ax - tx * abs(sv) + cos(attach) * out,
                            ay - ty * abs(sv) + sin(attach) * out)
                }
                warped = points.enumerated().map { i, pt in
                    let u = Double(i) / Double(steps)
                    let left = u < 0.5
                    let a = left ? (0.5 - u) * 2 : (u - 0.5) * 2
                    let d = a * halfLen + gap        // the head must TRAVEL the gap to the mouth
                    let sOn = headS - d
                    if sOn > -0.001, suckT > 0 {
                        let (x, y) = track(sOn, left)
                        return CGPoint(x: x.isFinite ? x : cx, y: y.isFinite ? y : cy)
                    }
                    // Waiting material: taper toward the travel line as it nears its entry,
                    // retreat + curl during the split, slide inward as rope is consumed.
                    let nearRaw = min(1, max(0, 1 + sOn / (runway * 1.6)))
                    let near = nearRaw * nearRaw * (3 - 2 * nearRaw)
                    // Waiting material lives in the CANONICAL reference space, centered
                    // on the ring (max slide < half the reference, so a sliding tail can
                    // never cross the circle interior). A canvas wider than the canonical
                    // span eases in over the first 0.35s - the wave visibly gathers, then
                    // the exact mini choreography takes over. On the mini itself the two
                    // spaces coincide, so this blend is invisible there.
                    let pxCanon = cx + (u - 0.5) * refW
                    let gatherRaw = min(1.0, t / 0.35)
                    let gather = gatherRaw * gatherRaw * (3 - 2 * gatherRaw)
                    let px = Double(pt.x) + (pxCanon - Double(pt.x)) * gather
                    var py = midY + (Double(pt.y) - midY) * (1 - 0.85 * near)
                    // STRAIGHT TO THE GATE: as material slides inward it RISES toward its
                    // gate's height at the same time (left up, right down) - a diagonal
                    // path. Without this the halves converged at wave height first, which
                    // read as re-merging in the center before climbing.
                    let attachAngle = left ? -Double.pi / 2 : Double.pi / 2
                    let gateY = cy + sin(attachAngle) * rBase
                    let rise = min(1.0, consumedR * 2.2) * pow(1 - a, 0.9)
                    py += (gateY - py) * rise * 0.85
                    let slide = consumedR * (left ? 1.0 : -1.0) * halfLen
                    // The retreat SHEDS as material nears its gate: without this, the
                    // lingering outward offset read as the lines bulging away from the
                    // circle right before entry.
                    let retreat = (left ? -1.0 : 1.0) * gap * (1 - a * 0.35) * (1 - near)
                    let curlAmt = gapMax > 0 ? (gap / gapMax) : 0
                    // Stronger, earlier curl: the upward flow happens WITH the split.
                    let curl = (left ? -1.0 : 1.0) * curlAmt * refW * 0.05 * pow(1 - a, 1.8)
                    let bx = px + slide + retreat
                    let by = py + curl
                    let (qx, qy) = track(max(sOn, -runway * 3), left)
                    let closeRaw = min(1, max(0, 1 + sOn / runway))
                    let close = closeRaw * closeRaw * (3 - 2 * closeRaw)
                    let w = bowF * pow(close, 1.6)   // magnet: gentle far, gripping near
                    let x = bx + (qx - bx) * w
                    let y = by + (qy - by) * w
                    return CGPoint(x: x.isFinite ? x : cx, y: y.isFinite ? y : cy)
                }
                breakIndices.insert(steps / 2)
                for i in 1..<warped.count {
                    let jump = hypot(warped[i].x - warped[i - 1].x, warped[i].y - warped[i - 1].y)
                    if jump > 18 * cs { breakIndices.insert(i) }
                }
            } else {
                warped = points
            }
            let path = smoothPath(warped, breakingAt: breakIndices)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: shaded),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))

            var glow = context
            glow.addFilter(.blur(radius: 4.5 * ds))
            glow.opacity = ((isActive || sucking) ? 0.55 + 0.2 * surge : 0.3) * ribbon.opacity
            // Expand the blur layer's raster bounds: the filter rasterizes only the
            // drawing's bounds + radius, truncating the Gaussian tail while it is still
            // visibly non-zero - which painted a faint HARD-EDGED block around the glow
            // (the "chopped" halo around the ring, the seam at the wave's ends). An
            // imperceptible fill pushes the boundary out to where the tail is truly gone.
            // Filters rasterize PER OPERATION (bounds + one blur radius), so a stroked
            // glow gets its Gaussian tail truncated at a hard rectangle while still
            // visibly bright. Fix: fill the stroke's outline and two far-corner 1px dots
            // as ONE path - the dots stretch the operation's raster bounds out to where
            // the tail has truly decayed, and their own blurred energy is imperceptible.
            let gpad = 26 * ds
            var glowShape = path.strokedPath(StrokeStyle(lineWidth: ribbon.lineWidth * 2.5 * ds, lineCap: .round))
            glowShape.addRect(CGRect(x: -gpad, y: -gpad, width: 1, height: 1))
            glowShape.addRect(CGRect(x: size.width + gpad, y: size.height + gpad, width: 1, height: 1))
            glow.fill(glowShape, with: shading)

            var crisp = context
            crisp.opacity = ((isActive || sucking) ? 1.0 : 0.55) * ribbon.opacity
            crisp.stroke(path, with: shading,
                         style: StrokeStyle(lineWidth: ribbon.lineWidth * ds, lineCap: .round, lineJoin: .round))
        }
    }

    private func smoothPath(_ rawPoints: [CGPoint], breakingAt breaks: Set<Int> = []) -> Path {
        var path = Path()
        // Defensive second wall: drop any non-finite points before they reach the Path.
        let points = rawPoints.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 1..<points.count {
            if breaks.contains(i) { path.move(to: points[i]); continue }
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2,
                              y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

private extension Double {
    func let2(_ f: (Double) -> Double) -> Double { f(self) }
}
