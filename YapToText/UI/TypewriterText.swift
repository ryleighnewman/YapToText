import SwiftUI

/// Renders a live transcription preview one character at a time, so partials arriving in
/// batches READ as continuous real-time processing.
///
/// - The reveal is FRAME-SYNCED: a TimelineView(.animation) advances the visible character count
///   as a pure function of elapsed time, so the cadence is locked to the display refresh and stays
///   perfectly even (no scheduler jitter, no stutter). A per-character sleep loop, which we used
///   before, lands characters at random phases vs vsync and reads as choppy - this does not.
/// - The newest few characters fade up from dim to full - a soft "ink" trail that makes it look
///   like the words are being written as you watch.
/// - When the engine REVISES earlier words (whisper re-decodes the window and changes its mind),
///   the revealed prefix always mirrors the CURRENT target, so a corrected word swaps in place
///   instead of retyping from scratch.
/// - When a big partial lands far ahead, the cadence quickens (chars/sec) rather than jumping many
///   characters at once, so catch-up stays smooth. Once caught up it settles to full opacity and
///   the timeline pauses (no idle CPU).
struct TypewriterText: View {
    let target: String
    var fontSize: CGFloat = 15

    /// Diagnostics kill switch (debug bisection of the macOS 26.5 DesignLibrary crash): shows the
    /// full target instantly - no reveal timeline, no per-frame render transactions.
    nonisolated(unsafe) static var frozenForDiagnostics = false

    /// How many trailing characters carry the fade-in trail.
    private let trail = 7

    // The reveal clock. `revealed(at:) = anchorCount + elapsed * rate`, clamped to the target.
    // Anchor is re-based whenever a new partial arrives, so the rate can adapt per chunk while the
    // motion within a chunk stays constant and even.
    @State private var anchorDate = Date()
    @State private var anchorCount = 0
    @State private var rate: Double = 45          // chars/sec for the current chunk
    @State private var isAnimating = true         // false = caught up, timeline paused
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        // Cap at ~60fps rather than every display frame: the reveal is time-derived so it stays
        // smooth, and fewer render transactions ease pressure on macOS 26.5's glass renderer
        // (DesignLibrary), which can segfault under heavy animated redraw.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: !isAnimating || Self.frozenForDiagnostics)) { timeline in
            let revealed = (isAnimating && !Self.frozenForDiagnostics) ? revealedCount(at: timeline.date) : target.count
            composited(revealed)
                .font(.system(size: fontSize))
        }
        .onAppear { retarget() }
        .onChange(of: target) { retarget() }
        .onDisappear { settleTask?.cancel() }
        .accessibilityLabel(target)
    }

    /// The revealed prefix of the CURRENT target, with a graduated-opacity tail so freshly typed
    /// letters visibly ink in. Once caught up (revealed == target.count) everything is full opacity.
    private func composited(_ revealed: Int) -> Text {
        let chars = Array(target.prefix(revealed))
        let full = Color.primary.opacity(0.88)
        guard revealed < target.count, !chars.isEmpty else {
            return Text(String(chars)).foregroundColor(full)
        }
        let stableCount = max(0, chars.count - trail)
        var text = Text(String(chars[0..<stableCount])).foregroundColor(full)
        for i in stableCount..<chars.count {
            let distFromEnd = chars.count - 1 - i               // 0 = newest
            let ramp = Double(min(distFromEnd, trail)) / Double(trail)   // 0 (new) -> 1 (older)
            let opacity = 0.88 * (0.22 + 0.78 * ramp)
            text = text + Text(String(chars[i])).foregroundColor(.primary.opacity(opacity))
        }
        return text
    }

    /// Characters visible at `date`, from the current anchor. Pure function of time, so the reveal
    /// is even and self-correcting even if a frame is dropped.
    private func revealedCount(at date: Date) -> Int {
        guard rate > 0 else { return anchorCount }
        let secs = max(0, date.timeIntervalSince(anchorDate))
        let n = anchorCount + Int(secs * rate)
        return min(target.count, max(anchorCount, n))
    }

    /// Re-base the reveal clock on the current target. Keeps whatever has already inked in, picks a
    /// cadence for the remaining backlog, and schedules a single settle when the reveal will finish.
    /// IMPORTANT: while NOT animating the clock is frozen at anchorCount - the panel's view now
    /// lives for the whole app session (two-graph crash architecture), so a time-derived read here
    /// would keep "earning" reveal budget between dictations and make every new partial appear
    /// instantly (word-by-word chunks instead of the letter-by-letter reveal).
    private func retarget() {
        let now = Date()
        let current = min(target.count, isAnimating ? revealedCount(at: now) : anchorCount)
        settleTask?.cancel()
        anchorCount = current
        anchorDate = now

        let remaining = target.count - current
        guard remaining > 0 else {
            isAnimating = false
            return
        }
        rate = cadence(forRemaining: remaining)
        isAnimating = true
        // A hair of slack (+1 char) so the timeline reveals the final character before it pauses.
        let duration = Double(remaining + 1) / rate
        let goalCount = target.count
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Pin the frozen clock at the fully revealed position before pausing.
            anchorCount = goalCount
            anchorDate = Date()
            isAnimating = false
        }
    }

    /// chars/sec for the reveal. Normal speech leaves a ~1.5s gap between partials, so ~45 c/s reads
    /// as steady live typing; a bigger backlog quickens the cadence to catch up without a chunk jump.
    private func cadence(forRemaining remaining: Int) -> Double {
        switch remaining {
        case ..<40:  return 45
        case ..<90:  return 72
        default:     return 140
        }
    }
}
