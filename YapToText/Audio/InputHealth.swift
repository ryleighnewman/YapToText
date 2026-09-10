import Foundation

/// Watches how good the microphone signal actually is, session over session, and says so when
/// it gets worse.
///
/// The app already adapts to a bad signal: it subtracts stationary noise, lifts a quiet voice,
/// and switches the decoder to beam search when a clip measures noisy. All of that is silent,
/// which is the problem. On this machine the measured signal-to-noise ratio fell from a median
/// of ~17dB to ~6dB over a few hundred dictations while the voice peak drifted from 0.25 down
/// to 0.15, and nothing ever said a word: the app just quietly started mishearing, and the
/// mishearing looked like the transcription getting worse rather than the input.
///
/// Nothing here changes the audio. It measures, compares against the machine's own history,
/// and hands back one plain sentence when the input is meaningfully worse than this user's
/// normal, plus the checks worth making.
enum InputHealth {
    /// One measured dictation. Kept small on purpose: this rides in UserDefaults.
    private struct Sample: Codable { let at: Date; let snr: Double; let peak: Double }

    private static let key = "inputhealth.samples"
    private static let noticeKey = "inputhealth.lastNoticeAt"
    /// Enough sessions to see a trend, few enough that one bad room does not become baseline.
    private static let window = 120
    /// The recent stretch to judge, and the minimum history before judging anything.
    private static let recentCount = 15
    private static let baselineCount = 30
    /// A drop worth mentioning. 6dB is a doubling of noise relative to voice, well past the
    /// point where the decoder starts guessing.
    private static let snrDropDB = 6.0
    /// A quiet-voice drop worth mentioning, as a fraction of the established peak.
    private static let peakDropFraction = 0.65
    /// Say it at most once a day: this is a nudge, not a nag.
    private static let noticeInterval: TimeInterval = 24 * 60 * 60
    /// How fast the baseline forgets. The FIRST version of this compared the last 15 dictations
    /// against the 30 before them, and never fired once: this machine's signal-to-noise fell
    /// from 18dB to 6dB over 600 dictations, and a short rolling baseline simply rode it down.
    /// Boiling frog. The baseline is now a high-water mark that decays slowly, so a real slide
    /// is caught while a permanently changed room still re-baselines: 0.9995 per dictation is a
    /// half-life of about 1,400 of them. Replayed against this machine's own history it first
    /// warns at 9.5dB against a 15.6dB baseline, and stays silent through the healthy stretch.
    private static let baselineDecay = 0.9995

    // MARK: Recording

    /// Called once per dictation, after the clip has been measured. `snr` is the post-denoise
    /// ratio and `peak` the windowed RMS peak of the voice.
    static func record(snrDB: Double, peak: Double) {
        // 100dB is the sentinel for "no noise floor to measure" (a clip with no silence in it),
        // and a peak at the gate is a clip with no speech. Neither says anything about health.
        guard snrDB.isFinite, snrDB < 90, peak.isFinite, peak > 0.01 else { return }
        var s = load()
        s.append(Sample(at: Date(), snr: snrDB, peak: peak))
        if s.count > window { s.removeFirst(s.count - window) }
        save(s)
    }

    // MARK: Diagnosis

    struct Diagnosis {
        let headline: String
        let detail: String
        let recentSNR: Double
        let baselineSNR: Double
    }

    /// A diagnosis when the input is meaningfully worse than this machine's own normal, and the
    /// user has not already been told today. nil the rest of the time.
    static func pendingDiagnosis() -> Diagnosis? {
        guard let d = diagnose() else { return nil }
        let ud = UserDefaults.standard
        if let last = ud.object(forKey: noticeKey) as? Date,
           Date().timeIntervalSince(last) < noticeInterval { return nil }
        ud.set(Date(), forKey: noticeKey)
        return d
    }

    /// The comparison itself, with no once-a-day gate, so Diagnostics and tests can read it.
    static func diagnose() -> Diagnosis? {
        let s = load()
        guard s.count >= recentCount + baselineCount else { return nil }
        let recent = Array(s.suffix(recentCount))
        let rSNR = median(recent.map(\.snr)), rPeak = median(recent.map(\.peak))
        let (bSNR, bPeak) = baseline(from: s)
        guard bSNR > 0 else { return nil }

        let snrFell = bSNR - rSNR >= snrDropDB
        let voiceFell = rPeak < bPeak * peakDropFraction
        guard snrFell || voiceFell else { return nil }

        // Which of the two moved decides what is worth checking. Both moving usually means the
        // microphone is further away than it used to be: the voice arrives quieter AND the room
        // takes up a larger share of what is left.
        let detail: String
        switch (snrFell, voiceFell) {
        case (true, true):
            detail = "Your voice is arriving quieter and the room is louder relative to it. The usual cause is distance: the microphone is further away, at a different angle, or something is resting over it."
        case (true, false):
            detail = "Your voice is coming through at its usual level, but there is more constant sound in the room than there used to be. Anything that runs continuously nearby will do it: a fan, a printer, an air conditioner."
        default:
            detail = "Your voice is arriving quieter than it used to. Check that nothing is covering the microphone, and try speaking from where you normally sit."
        }
        return Diagnosis(
            headline: String(format: "Your microphone signal has dropped: %.0fdB now, %.0fdB before.", rSNR, bSNR),
            detail: detail, recentSNR: rSNR, baselineSNR: bSNR)
    }

    /// The best sustained stretch this machine has managed, decayed a little for every dictation
    /// since, so the yardstick is the user's own good days rather than the last hour.
    private static func baseline(from s: [Sample]) -> (snr: Double, peak: Double) {
        var bestSNR = 0.0, bestPeak = 0.0
        for i in baselineCount...s.count {
            let w = Array(s[(i - baselineCount)..<i])
            bestSNR = max(median(w.map(\.snr)), bestSNR * baselineDecay)
            bestPeak = max(median(w.map(\.peak)), bestPeak * baselineDecay)
        }
        return (bestSNR, bestPeak)
    }

    /// One line for the diagnostics report, whether or not anything is wrong.
    static var summary: String? {
        let s = load()
        guard s.count >= recentCount else { return nil }
        let recent = Array(s.suffix(recentCount))
        return String(format: "input: snr %.1fdB, peak %.3f over the last %d dictations",
                      median(recent.map(\.snr)), median(recent.map(\.peak)), recent.count)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    // MARK: Storage

    private static func load() -> [Sample] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode([Sample].self, from: d) else { return [] }
        return s
    }

    private static func save(_ s: [Sample]) {
        guard !AppSettings.writesSuspended,
              let d = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
