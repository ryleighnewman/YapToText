import SwiftUI

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
struct WaveformView: View {
    var data: AudioVisualData
    var isActive: Bool
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = WaveMotion()

    /// Diagnostics kill switch (debug bisection of the macOS 26.5 DesignLibrary crash): freezes
    /// the timeline so the wave renders one static frame and produces ZERO per-frame render
    /// transactions inside the glass card.
    nonisolated(unsafe) static var frozenForDiagnostics = false

    var body: some View {
        waveContent
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.10),
                                     .init(color: .black, location: 0.90),
                                     .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.22),
                                     .init(color: .black, location: 0.78),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
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
        TimelineView(.animation(paused: !isActive || Self.frozenForDiagnostics)) { timeline in
            Canvas { context, size in
                let live = isActive && !Self.frozenForDiagnostics
                draw(context, size, now: live ? timeline.date.timeIntervalSinceReferenceDate : 0)
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

    private func draw(_ context: GraphicsContext, _ size: CGSize, now: Double) {
        let count = data.spectrum.count
        guard count > 1 else { return }
        motion.step(target: isActive ? data.spectrum : idleSpectrum(now, count: count),
                    level: isActive ? Double(data.level) : 0.05, now: now)

        let midY = Double(size.height) / 2
        let maxAmp = midY - 8 * Double(scale)
        let steps = 130
        let surge = isActive ? motion.smoothSurge : 0
        let energyNow = min(1, max(0, motion.fastE * 3))
        // Height tracks real loudness: quiet stays small, loud swells - the expressiveness.
        let ampScale = isActive ? (0.16 + 1.0 * pow(max(0, motion.loud), 0.55)) : 0.18
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
        }

        // ---- Ribbons: carriers sway in place through the shared envelope ----
        for ribbon in Self.ribbons {
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
            let path = smoothPath(points)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: ribbon.colors),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))

            var glow = context
            glow.addFilter(.blur(radius: 4.5 * scale))
            glow.opacity = (isActive ? 0.55 + 0.2 * surge : 0.3) * ribbon.opacity
            glow.stroke(path, with: shading,
                        style: StrokeStyle(lineWidth: ribbon.lineWidth * 2.5 * scale, lineCap: .round))

            var crisp = context
            crisp.opacity = (isActive ? 1.0 : 0.55) * ribbon.opacity
            crisp.stroke(path, with: shading,
                         style: StrokeStyle(lineWidth: ribbon.lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
    }

    private func smoothPath(_ rawPoints: [CGPoint]) -> Path {
        var path = Path()
        // Defensive second wall: drop any non-finite points before they reach the Path.
        let points = rawPoints.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2,
                              y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
