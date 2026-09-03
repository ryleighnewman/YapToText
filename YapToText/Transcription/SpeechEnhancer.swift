import Foundation
import Accelerate

/// Quiet, behind-the-scenes speech conditioning for the transcription pipeline.
///
/// Whisper's accuracy falls off a cliff when speech sits far below its expected level
/// (whispering, a distant mic, a shy first word). This stage measures how loud the SPEECH
/// actually is - not the clip as a whole - and lifts it carefully to the level the model
/// was trained on, without touching sessions that are already healthy:
///
/// - Levels are measured per 100 ms window; the noise floor is the quiet percentile and the
///   speech level is the loud percentile, so long silences and single pops can't skew either.
/// - Gain brings the speech level to a reference target. It NEVER attenuates, is capped so a
///   silent room can't be amplified into hiss, and runs through a soft-knee limiter so a
///   sudden loud word can never clip and distort.
/// - The analysis also reports how many seconds of the clip contained actual speech, which
///   the engine uses to detect "something was said but the transcript doesn't cover it" and
///   trigger a stronger second pass.
enum SpeechEnhancer {
    struct Analysis {
        /// RMS of each 100 ms window.
        let windowRMS: [Float]
        /// The mic/room's own quiet level (15th percentile of windows).
        let noiseFloor: Float
        /// The level speech actually reached (92nd percentile of windows).
        let speechLevel: Float
        /// Seconds of the clip whose energy clearly rose above the noise floor.
        let activeSeconds: Double
    }

    /// The RMS whisper models are most comfortable with (~-23 dBFS speech level).
    static let targetSpeechRMS: Float = 0.07
    /// A first pass never amplifies more than this (+18 dB) - beyond it, the mic simply
    /// didn't capture usable signal and boosting only manufactures noise.
    static let maxGain: Float = 8
    /// The rescue pass may push further (+21.5 dB) when the transcript missed real speech.
    static let maxRescueGain: Float = 12

    static func analyze(_ audio: [Float], sampleRate: Double) -> Analysis {
        let window = max(1, Int(sampleRate / 10))
        var rms: [Float] = []
        rms.reserveCapacity(audio.count / window + 1)
        var start = 0
        while start < audio.count {
            let end = min(start + window, audio.count)
            var sum: Float = 0
            for i in start..<end { sum += audio[i] * audio[i] }
            rms.append(sqrt(sum / Float(end - start)))
            start = end
        }
        guard !rms.isEmpty else {
            return Analysis(windowRMS: [], noiseFloor: 0, speechLevel: 0, activeSeconds: 0)
        }
        let sorted = rms.sorted()
        func percentile(_ p: Double) -> Float {
            sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let floorLevel = percentile(0.15)
        let speech = percentile(0.92)
        // A window is "active" when it clearly rises above the room: 2.5x the floor, with an
        // absolute minimum so a dead-silent floor doesn't declare every breath active.
        let activeGate = max(floorLevel * 2.5, 0.0025)
        let active = rms.filter { $0 > activeGate }.count
        return Analysis(windowRMS: rms, noiseFloor: floorLevel, speechLevel: speech,
                        activeSeconds: Double(active) * Double(window) / sampleRate)
    }

    /// Returns the conditioned audio and the gain that was applied (1 = untouched).
    /// `boost` scales the target for the rescue pass.
    static func enhance(_ audio: [Float], analysis: Analysis, boost: Float = 1) -> (audio: [Float], gain: Float) {
        guard analysis.speechLevel > 0.0005 else { return (audio, 1) }   // nothing real to lift
        let cap = boost > 1 ? maxRescueGain : maxGain
        let gain = min(cap, max(1, targetSpeechRMS * boost / analysis.speechLevel))
        // TRUE no-op on healthy audio: when speech already sits at a comfortable level,
        // skip conditioning entirely. Running the leveler anyway let its smoothing bleed
        // gain into the silence beside words - audible breath/room pumping on recordings
        // that never needed help.
        if gain <= 1.02, analysis.speechLevel >= targetSpeechRMS * 0.7 { return (audio, 1) }

        // TIME LEVELING: beyond the single global gain, quiet ACTIVE stretches (the AGC's
        // ramp-in at the start of a session, a trailing mumble) are lifted toward the
        // clip's own speech level with a smooth per-window gain curve - so the first words
        // reach whisper at the same level as the rest. Boost only, capped at 4x, silent
        // windows untouched (no noise pumping), gains smoothed and linearly interpolated
        // so nothing ever clicks.
        let activeGate = max(analysis.noiseFloor * 2.5, 0.0025)
        // LEVELING IS CONFINED TO THE FIRST ~2.5s (the AGC ramp-in it exists to fix).
        // Leveling the WHOLE clip flattened the loudness dips between sentences - the
        // exact prosody cue whisper uses to place periods - and long dictations came
        // back as run-on sentences with capitals but no punctuation. Mid-clip dynamics
        // now pass through untouched; only the global gain applies there.
        let rampWindows = 25   // 25 x 100ms
        var wGain = analysis.windowRMS.enumerated().map { i, rms -> Float in
            guard i < rampWindows, rms > activeGate else { return 1 }
            return min(4, max(1, analysis.speechLevel * 0.8 / max(rms, 0.0001)))
        }
        if wGain.count > 2 {
            for _ in 0..<2 {   // two box passes = gentle triangular smoothing
                var sm = wGain
                for i in 1..<(wGain.count - 1) { sm[i] = (wGain[i-1] + wGain[i] + wGain[i+1]) / 3 }
                wGain = sm
            }
        }
        let window = max(1, audio.count / max(1, wGain.count))

        // DC offset removal (some interfaces ride a bias that wastes headroom), then gain
        // through a soft-knee limiter: linear below the knee, smooth compression above it,
        // asymptotically bounded - a shouted word gets louder but can never fold over.
        var mean: Float = 0
        for s in audio { mean += s }
        mean /= Float(max(1, audio.count))
        let knee: Float = 0.85
        let ceilingSpan: Float = 0.14
        var out = [Float](repeating: 0, count: audio.count)
        for i in 0..<audio.count {
            let w = i / window
            let frac = Float(i % window) / Float(window)
            let g0 = wGain[min(w, wGain.count - 1)]
            let g1 = wGain[min(w + 1, wGain.count - 1)]
            let level = g0 + (g1 - g0) * frac
            let y = (audio[i] - mean) * gain * level
            let a = abs(y)
            if a <= knee {
                out[i] = y
            } else {
                out[i] = (y < 0 ? -1 : 1) * (knee + tanh((a - knee) / 0.3) * ceilingSpan)
            }
        }
        return (out, gain)
    }

    /// STATIONARY-NOISE SPECTRAL SUBTRACTION. Built for the measured failure case: a
    /// running machine (printer, fan) parking 70-80% of its energy in a narrow low band,
    /// dragging the whole clip to 8-11dB SNR where whisper starts inventing first words.
    /// The noise's per-frequency fingerprint is estimated from the clip's own quietest
    /// frames (15th percentile per bin - speech can't pollute it), subtracted from every
    /// frame with a spectral floor so speech texture survives, and the clip is rebuilt
    /// with the original phase. Callers gate this on LOW measured SNR: healthy audio
    /// never passes through it, so the clean case carries zero risk.
    /// `strength` scales the over-subtraction: 1 is the everyday setting, larger digs
    /// harder into a noisier floor. The caller picks it from the measured ratio.
    static func denoiseStationary(_ audio: [Float], strength: Float = 1) -> [Float] {
        let n = 512, hop = 128
        guard audio.count > n * 4 else { return audio }
        let bins = n / 2 + 1
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        guard let fwd = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return audio }

        let frameCount = (audio.count - n) / hop + 1
        // Magnitudes for the noise profile come from a capped sample of frames so a very
        // long clip doesn't hold every spectrum in memory at once.
        let profileStride = max(1, frameCount / 2000)
        var profileMags: [[Float]] = []   // [sampledFrame][bin]

        var realIn = [Float](repeating: 0, count: n)
        var imagIn = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: n)
        var imagOut = [Float](repeating: 0, count: n)

        // Pass 1: collect sampled magnitude spectra for the profile.
        for f in stride(from: 0, to: frameCount, by: profileStride) {
            let start = f * hop
            for i in 0..<n { realIn[i] = audio[start + i] * window[i] }
            imagIn = [Float](repeating: 0, count: n)
            fwd.transform(inputReal: realIn, inputImaginary: imagIn,
                          outputReal: &realOut, outputImaginary: &imagOut)
            var mags = [Float](repeating: 0, count: bins)
            for b in 0..<bins { mags[b] = (realOut[b]*realOut[b] + imagOut[b]*imagOut[b]).squareRoot() }
            profileMags.append(mags)
        }
        guard profileMags.count >= 8 else { return audio }
        var noise = [Float](repeating: 0, count: bins)
        let idx = max(0, Int(Double(profileMags.count) * 0.15) - 1)
        for b in 0..<bins {
            var col = profileMags.map { $0[b] }
            col.sort()
            noise[b] = col[idx]
        }

        // Pass 2: subtract and rebuild by weighted overlap-add.
        let alpha: Float = 1.2 * strength   // measured: 1.6 flat ate speech onsets on the worst clips
        let beta: Float = 0.10      // spectral floor (fraction of the ORIGINAL magnitude)
        var out = [Float](repeating: 0, count: audio.count)
        var wsum = [Float](repeating: 0, count: audio.count)
        for f in 0..<frameCount {
            let start = f * hop
            for i in 0..<n { realIn[i] = audio[start + i] * window[i] }
            imagIn = [Float](repeating: 0, count: n)
            fwd.transform(inputReal: realIn, inputImaginary: imagIn,
                          outputReal: &realOut, outputImaginary: &imagOut)
            // Scale each bin's magnitude; mirror bins share their conjugate's factor.
            for b in 0..<bins {
                let mag = (realOut[b]*realOut[b] + imagOut[b]*imagOut[b]).squareRoot()
                let target = max(mag - alpha * noise[b], beta * mag)
                let scale = mag > 1e-9 ? target / mag : 0
                realOut[b] *= scale
                imagOut[b] *= scale
                if b > 0 && b < n - b {   // conjugate mirror
                    realOut[n - b] *= scale
                    imagOut[n - b] *= scale
                }
            }
            inv.transform(inputReal: realOut, inputImaginary: imagOut,
                          outputReal: &realIn, outputImaginary: &imagIn)
            for i in 0..<n {
                out[start + i] += (realIn[i] / Float(n)) * window[i]
                wsum[start + i] += window[i] * window[i]
            }
        }
        for i in 0..<out.count where wsum[i] > 1e-6 { out[i] /= wsum[i] }
        return out
    }

    /// SILENCE COMPRESSION (endpointing): whisper-family models degrade on long dead air -
    /// a 10s pause mid-dictation invites hallucinated pleasantries, dropped sentence
    /// boundaries, and attention drifting off the actual speech. Any silent run longer
    /// than `maxGap` seconds is compressed down to `keepGap`, with the window-boundary
    /// samples crossfaded so no click is introduced. Speech and short natural pauses
    /// (which carry whisper's punctuation cues) pass through untouched.
    static func compressSilences(_ audio: [Float], analysis: Analysis, sampleRate: Double,
                                 maxGap: Double = 3.0, keepGap: Double = 0.8) -> [Float] {
        // ONLY when speech clearly separates from the floor (>= ~12dB). In a noisy room
        // the gate cannot tell quiet speech from the noise bed, and "compressing silence"
        // starts deleting real words (verified on a 6dB clip: two sentences became one
        // clause). Noisy clips already get the beam-search decoder instead.
        guard analysis.speechLevel > analysis.noiseFloor * 4 else { return audio }
        let window = max(1, Int(sampleRate / 10))
        let gate = max(analysis.noiseFloor * 2.5, 0.0025)
        let maxRun = Int(maxGap * 10)          // in 100ms windows
        let keepRun = Int(keepGap * 10)
        // Mark silent windows, find runs > maxRun, and drop their middle.
        let silent = analysis.windowRMS.map { $0 <= gate }
        var keep = [Bool](repeating: true, count: silent.count)
        var i = 0
        var trimmed = 0
        while i < silent.count {
            guard silent[i] else { i += 1; continue }
            var j = i
            while j < silent.count, silent[j] { j += 1 }
            let run = j - i
            if run > maxRun {
                // Keep the head and tail of the pause (endpoint context), drop the middle.
                let head = keepRun / 2, tail = keepRun - head
                for k in (i + head)..<(j - tail) { keep[k] = false }
                trimmed += run - keepRun
            }
            i = j
        }
        guard trimmed > 0 else { return audio }
        var out = [Float]()
        out.reserveCapacity(audio.count - trimmed * window)
        let fade = min(160, window / 2)   // 10ms crossfade at each seam
        var lastKept = -2
        for (w, k) in keep.enumerated() where k {
            let s = w * window, e = min(audio.count, s + window)
            guard s < audio.count else { break }
            if w != lastKept + 1, !out.isEmpty, e - s > fade {
                // Seam: fade the outgoing tail into the incoming head.
                let n = out.count
                for f in 0..<fade {
                    let t = Float(f) / Float(fade)
                    out[n - fade + f] = out[n - fade + f] * (1 - t) + audio[s + f] * t
                }
                out.append(contentsOf: audio[(s + fade)..<e])
            } else {
                out.append(contentsOf: audio[s..<e])
            }
            lastKept = w
        }
        return out
    }

    /// SPEAKING-RATE ESTIMATE on a 40ms envelope (100ms windows saturate above ~5
    /// peaks/s). Approximate by design: it only nominates clips for the stretched
    /// SECOND PASS below - adoption-by-improvement makes a wrong guess free.
    static func fastRate(_ audio: [Float], sampleRate: Double) -> Double {
        let win = max(1, Int(sampleRate * 0.04))
        var rms: [Float] = []
        rms.reserveCapacity(audio.count / win + 1)
        var i = 0
        while i < audio.count {
            let end = min(i + win, audio.count)
            var sum: Float = 0
            for j in i..<end { sum += audio[j] * audio[j] }
            rms.append(sqrt(sum / Float(end - i)))
            i = end
        }
        guard rms.count > 4 else { return 0 }
        let sorted = rms.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let gate = max(floor * 2.5, 0.0025)
        let active = Double(rms.filter { $0 > gate }.count) * 0.04
        guard active >= 1.0 else { return 0 }
        var peaks = 0, last = -10
        for k in 1..<(rms.count - 1) where rms[k] > gate {
            if rms[k] > rms[k-1] * 1.08, rms[k] >= rms[k+1], k - last >= 2 { peaks += 1; last = k }
        }
        return Double(peaks) / active
    }

    /// Gentle time-stretch by linear resampling: a 15-25% slowdown reads as natural
    /// pacing to the model, and the small pitch shift is irrelevant for recognition.
    static func stretch(_ audio: [Float], factor: Double) -> [Float] {
        let outCount = Int(Double(audio.count) * factor)
        guard outCount > audio.count, audio.count > 1 else { return audio }
        var out = [Float](repeating: 0, count: outCount)
        let step = Double(audio.count - 1) / Double(outCount - 1)
        for i in 0..<outCount {
            let x = Double(i) * step
            let j = Int(x)
            let f = Float(x - Double(j))
            out[i] = j + 1 < audio.count ? audio[j] * (1 - f) + audio[j + 1] * f : audio[j]
        }
        return out
    }

    /// Rough transcript-coverage check: given how long the user audibly spoke, is the word
    /// count plausible? Natural speech runs ~2-3 words/second; below 0.5 w/s something the
    /// mic heard never made it into text.
    static func coverageLooksShort(words: Int, activeSeconds: Double) -> Bool {
        guard activeSeconds >= 2.0 else { return false }   // too short to judge fairly
        return Double(words) < activeSeconds * 0.5
    }
}
