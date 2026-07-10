import Foundation

/// Pure math for the visualizer's traveling ripple - kept free of SwiftUI so its behavior is
/// verifiable in a standalone harness (direction, speed, smoothness, and depth law).
///
/// The ripple is a MODULATION WAVEFRONT that runs right-to-left across the standing wave (the
/// structure itself never scrolls): `1 + depth(u) * sin(2pi*cycles*u + phase)`, where phase is
/// an INTEGRATED clock (phase += rate * dt) so speed can follow the voice without ever jumping,
/// and depth varies with the LOCAL band energy - ranges where your voice is hot ripple deeper.
enum WaveMath {
    /// Ripple wavelengths across the width. Low = broad, silky undulation (never noise).
    static let rippleCycles = 2.2

    /// Ripple phase advance per second: idles slowly, runs fast while speaking.
    /// With sin(k*u + phase), increasing phase moves crests toward smaller u (right -> left).
    static func rippleRate(body: Double) -> Double {
        3.0 + 6.5 * min(1, max(0, body * 3))
    }

    /// Ripple depth at a point: a floor so the surface always shimmers faintly, plus a share
    /// that grows where the local spectrum runs hotter than the average (variable depth by
    /// frequency range), boosted briefly on word onsets, and gated by overall energy so
    /// silence stays calm. Clamped so the envelope can never invert.
    static func rippleDepth(local: Double, mean: Double, surge: Double, energy: Double) -> Double {
        let excess = mean > 0.001 ? min(2, max(0, local / mean - 0.4)) : 0
        let raw = (0.06 + 0.16 * excess) * (1 + 0.8 * surge) * min(1, max(0, energy * 2.5))
        return min(0.4, raw)
    }

    /// The multiplicative ripple factor applied to the envelope at position u.
    static func rippleFactor(u: Double, phase: Double, depth: Double) -> Double {
        1 + depth * sin(2 * .pi * rippleCycles * u + phase)
    }
}

/// Spectral whitening: each frequency band gets its own slow-adapting gain so that ALL ranges
/// reach visual parity - a quiet high-frequency sibilant lights the right side as strongly as a
/// loud vowel lights the left. Without this the wave is lopsided toward the low (left) bands,
/// because that's where voice energy concentrates. A gentle high-frequency tilt lifts the top
/// end further. Overall loudness is applied SEPARATELY (as height), so this shapes WHERE the
/// wave reacts across its width, not how big it gets.
final class SpectralWhitener {
    private var peak: [Float] = []
    private let tilt: Float
    private let decay: Float
    private let floor: Float

    init(tilt: Float = 0.7, decay: Float = 0.990, floor: Float = 0.30) {
        self.tilt = tilt; self.decay = decay; self.floor = floor
    }

    func reset() { peak = [] }

    func process(_ bands: [Float]) -> [Float] {
        if peak.count != bands.count { peak = bands }
        let n = Float(max(bands.count - 1, 1))
        var out = [Float](repeating: 0, count: bands.count)
        for b in bands.indices {
            let tilted = min(1, bands[b] * (1 + tilt * Float(b) / n))   // lift highs
            peak[b] = max(tilted, peak[b] * decay)                       // slow-decaying per-band peak
            out[b] = min(1, tilted / max(peak[b], floor))               // each band uses its full range
        }
        return out
    }
}
