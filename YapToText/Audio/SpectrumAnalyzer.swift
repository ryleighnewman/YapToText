import Accelerate

/// Live audio-visual data the recorder writes (on the main queue) and the visualizer reads every
/// display frame. A plain reference type so the Canvas can pull the latest spectrum each frame
/// without waiting on SwiftUI's re-render cycle - which is what kept the old wave lagging.
final class AudioVisualData: @unchecked Sendable {
    var spectrum: [Float]
    var level: Float = 0
    init(bands: Int) { spectrum = Array(repeating: 0, count: bands) }
}

/// Turns a block of mono audio into a set of frequency-band magnitudes via an FFT, so the
/// visualizer can react to PITCH (which frequencies are present), not just loudness. Log-spaced
/// bands roughly match how we hear, and low bins (voice fundamentals ~85-300 Hz) map to the left,
/// higher harmonics to the right. Pure Accelerate; no app dependencies, so it's unit-testable.
final class SpectrumAnalyzer {
    private let n = 1024
    private let halfN = 512
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    // Preallocated per-analyze scratch: analyze() runs ~23x/sec per recording and used to heap-alloc
    // these five buffers every call. Each is fully overwritten before it is read (windowed has an
    // explicit zero-pad guard for a short input), and the values RETURNED to the UI are always fresh
    // copies (the warmup array and whitener.process().map both allocate), so reuse is safe. Called
    // serially from the single audio-tap thread.
    private var scratchWindowed: [Float]
    private var scratchBandDB: [Float]
    private var scratchMags: [Float]
    private var scratchAmp: [Float]
    private var scratchOut: [Float]
    let bandCount: Int
    private let bandEdges: [Int]   // FFT bin index at each band boundary (log-spaced)
    private let whitener = SpectralWhitener()   // per-band gain -> full-spectrum parity

    init(bandCount: Int = 26) {
        self.bandCount = bandCount
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        realp = [Float](repeating: 0, count: halfN)
        imagp = [Float](repeating: 0, count: halfN)
        scratchWindowed = [Float](repeating: 0, count: n)
        scratchBandDB = [Float](repeating: -90, count: bandCount)
        scratchMags = [Float](repeating: 0, count: halfN)
        scratchAmp = [Float](repeating: 0, count: halfN)
        scratchOut = [Float](repeating: 0, count: bandCount)

        // Log-spaced band edges over bins 1...halfN. At 16 kHz, each bin ≈ 15.6 Hz, so this
        // covers ~16 Hz to 8 kHz - all of speech and its harmonics.
        var edges: [Int] = []
        let minBin = 1.0, maxBin = Double(halfN)
        for b in 0...bandCount {
            let frac = Double(b) / Double(bandCount)
            edges.append(Int((minBin * pow(maxBin / minBin, frac)).rounded()))
        }
        bandEdges = edges
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    // MARK: Adaptive noise floor (this is what keeps a fan / room hiss from maxing the wave)

    /// Per-band background-noise estimate in dB. Stationary sound (a fan) is CONSTANT per band,
    /// so the floor rises to meet it within a couple of seconds and it displays as ~zero; speech
    /// is transient and spiky, so it stays well above the floor and displays strongly.
    private var noiseFloorDB: [Float] = []
    private var smoothedDB: [Float] = []
    private var warmupFrames = 0
    /// Display shows the signal-to-noise ratio above (floor + margin), mapped over `snrRange` dB.
    /// The margin must exceed the frame-to-frame wobble of steady noise, or fan hiss leaks through.
    private let snrMarginDB: Float = 8
    private let snrRangeDB: Float = 22
    /// Measurement smoothing before the floor comparison - shrinks the random wobble of steady
    /// noise so the floor can hug it instead of its minima.
    private let measureSmoothing: Float = 0.45

    // Windowed-minimum floor (minimum statistics): the floor follows the QUIETEST level each band
    // touched in the last two blocks (~6-13 s). Word gaps and breaths reset the minimum, so long
    // continuous speech can NEVER ratchet the floor upward (earlier rate-based designs crept up
    // through the inter-syllable zone and the wave slowly faded flat over a session). A fan that
    // switches on mid-session raises the minimum of the following blocks, so it's still absorbed
    // within one or two block lengths.
    private var curBlockMin: [Float] = []
    private var prevBlockMin: [Float] = []
    /// The min is tracked on a HEAVILY smoothed series (separate from the snappy display series):
    /// raw noise in dB has deep random nulls, and a minimum over lightly-smoothed values rides
    /// those nulls ever lower, letting the noise's wobble read as signal.
    private var floorTrackDB: [Float] = []
    private let floorTrackSmoothing: Float = 0.12
    private var blockFrame = 0
    private let blockLength = 150            // ~6.4 s of tap callbacks (2048 frames @ 48 kHz)
    private let minBiasDB: Float = 3         // floor sits just above the observed minimum
    private let floorFallRate: Float = 0.25  // follow the min target down quickly
    private let floorRiseRate: Float = 0.06  // ...and up smoothly (target itself is gap-anchored)

    /// Reset adaptation at the start of each recording session.
    func resetNoiseFloor() {
        noiseFloorDB = []
        smoothedDB = []
        floorTrackDB = []
        curBlockMin = []
        prevBlockMin = []
        blockFrame = 0
        warmupFrames = 0
        whitener.reset()
    }

    /// Analyze `count` mono Float samples (uses the first `n`, or zero-pads). Returns `bandCount`
    /// values in 0...1 representing how far each band rises ABOVE the adaptive background - so
    /// steady noise reads ~0 and speech reads dynamically.
    func analyze(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        let m = min(count, n)
        // Short input: zero the tail past m so stale samples from the last call can't leak in.
        // (In practice the tap delivers >= n samples, so m == n and this loop is skipped.)
        if m < n {
            for i in m..<n { scratchWindowed[i] = 0 }
        }
        vDSP_vmul(samples, 1, window, 1, &scratchWindowed, 1, vDSP_Length(m))   // Hann window the input

        scratchWindowed.withUnsafeMutableBufferPointer { buf in
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cplx in
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(halfN))   // pack real signal
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    vDSP_zvmags(&split, 1, &scratchMags, 1, vDSP_Length(halfN))    // |X|^2 per bin
                    var c32 = Int32(halfN)
                    vvsqrtf(&scratchAmp, scratchMags, &c32)                        // -> amplitude

                    for b in 0..<bandCount {
                        let lo = max(1, bandEdges[b])
                        let hi = min(halfN, max(lo + 1, bandEdges[b + 1]))
                        var sum: Float = 0
                        for bin in lo..<hi { sum += scratchAmp[bin] }
                        let mean = sum / Float(hi - lo)                     // mean, calmer than peak
                        // max() does not sanitize NaN; a non-finite mean would yield NaN dB and
                        // propagate all the way into the waveform geometry. Reject it explicitly.
                        scratchBandDB[b] = mean.isFinite && mean > 0 ? 20 * log10(mean) : -90
                    }
                }
            }
        }
        let bandDB = scratchBandDB

        // Smooth the measurement, then track the windowed minimum per band.
        if smoothedDB.count != bandCount { smoothedDB = bandDB }
        if noiseFloorDB.count != bandCount { noiseFloorDB = bandDB }        // seed from first frame
        if floorTrackDB.count != bandCount { floorTrackDB = bandDB }
        if curBlockMin.count != bandCount { curBlockMin = bandDB; prevBlockMin = bandDB }
        for b in 0..<bandCount {
            smoothedDB[b] += (bandDB[b] - smoothedDB[b]) * measureSmoothing
            floorTrackDB[b] += (bandDB[b] - floorTrackDB[b]) * floorTrackSmoothing
            let db = smoothedDB[b]
            curBlockMin[b] = min(curBlockMin[b], floorTrackDB[b])
            let target = min(curBlockMin[b], prevBlockMin[b]) + minBiasDB
            let floor = noiseFloorDB[b]
            noiseFloorDB[b] += (target - floor) * (target < floor ? floorFallRate : floorRiseRate)
            let snr = db - (noiseFloorDB[b] + snrMarginDB)
            // Soft knee instead of a hard clamp: the wave never slams flat against its ceiling
            // at session start, and keeps headroom for louder speech. Every band is written, so the
            // reused buffer carries nothing stale.
            scratchOut[b] = snr <= 0 ? 0 : 1 - exp(-2.0 * snr / snrRangeDB)
        }
        blockFrame += 1
        if blockFrame >= blockLength {
            prevBlockMin = curBlockMin
            curBlockMin = floorTrackDB
            blockFrame = 0
        }

        // Brief warmup so the very first frame (floor still seeding) can't flash the wave full.
        // Just 2 frames: the floor seeds from frame 1 (noiseFloorDB = bandDB), so frame 1's SNR
        // is already ~0 without help - a longer hard-zero window (was 8, ~0.3-0.8s at this tap's
        // buffer size) only made the waveform look DEAD for a third of a second while the mic was
        // already being heard, reading to the user as lag before they could speak. Two frames
        // keeps the anti-flash guard while letting the wave respond almost immediately.
        warmupFrames += 1
        if warmupFrames < 2 { return [Float](repeating: 0, count: bandCount) }
        // Final NaN/Inf boundary before the spectrum leaves for the UI: every band finite in [0,1].
        return whitener.process(scratchOut).map { $0.isFinite ? min(max($0, 0), 1) : 0 }
    }
}
