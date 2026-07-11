import SwiftUI

/// Renders a live transcription preview that inks in smoothly, one letter at a time, so partials
/// arriving in batches READ as continuous real-time writing.
///
/// - FRAME-SYNCED at the FULL display refresh (no fps cap): the reveal is a pure function of
///   elapsed time, so the cadence is locked to vsync and stays perfectly even. This view lives in
///   the panel's glass-FREE content layer (the two-graph architecture), so running at display rate
///   doesn't pressure the macOS 26.5 glass renderer the way an animated glass view would.
/// - SUB-CHARACTER smoothing: the reveal position is fractional. The character currently being
///   written fades in by its fractional progress (a smoothstep on its alpha), and a short trail
///   behind it eases from dim to full - so letters don't pop in, they ink in.
/// - When the engine REVISES earlier words, the revealed prefix mirrors the CURRENT target, so a
///   corrected word swaps in place instead of retyping.
/// - The cadence spreads each chunk across the typical gap between partials, so the writing is
///   still flowing when the next chunk lands (no type-burst-then-idle stutter). Once caught up it
///   settles to full opacity and the timeline pauses (no idle CPU).
struct TypewriterText: View {
    let target: String
    var fontSize: CGFloat = 15

    /// Diagnostics kill switch (debug bisection of the macOS 26.5 DesignLibrary crash): shows the
    /// full target instantly - no reveal timeline, no per-frame render transactions.
    nonisolated(unsafe) static var frozenForDiagnostics = false

    /// Trailing characters that carry the ease-in fade behind the writing edge.
    private let trail = 6

    // The reveal clock. `revealF(at:) = anchorCount + elapsed * rate`, clamped to the target.
    // anchorCount is fractional and re-based whenever a new partial arrives, so the rate can adapt
    // per chunk while the motion within a chunk stays constant and even.
    @State private var anchorDate = Date()
    @State private var anchorCount: Double = 0
    @State private var rate: Double = 42          // chars/sec for the current chunk
    @State private var isAnimating = true         // false = caught up, timeline paused
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        // Full display-rate schedule (no minimumInterval): the reveal is time-derived and lives in
        // the glass-free layer, so it stays smooth at 120/165Hz without touching the glass renderer.
        TimelineView(.animation(paused: !isAnimating || Self.frozenForDiagnostics)) { timeline in
            let revealF = (isAnimating && !Self.frozenForDiagnostics)
                ? revealedF(at: timeline.date) : Double(target.count)
            composited(revealF).font(.system(size: fontSize))
        }
        .onAppear { retarget() }
        .onChange(of: target) { retarget() }
        .onDisappear { settleTask?.cancel() }
        .accessibilityLabel(target)
    }

    /// The revealed prefix of the CURRENT target with a smooth writing edge: full-opacity body, a
    /// short easing trail, and the currently-inking character faded by its fractional progress.
    private func composited(_ revealF: Double) -> Text {
        let chars = Array(target)
        let n = chars.count
        let full = Color.primary.opacity(0.9)
        guard n > 0 else { return Text("") }

        let clamped = min(Double(n), max(0, revealF))
        let solid = Int(clamped.rounded(.down))     // characters fully (or nearly) written
        if solid >= n { return Text(target).foregroundColor(full) }

        // Stable body at full opacity, up to where the easing trail begins.
        let stable = max(0, solid - trail)
        var text = Text(String(chars[0..<stable])).foregroundColor(full)

        // Trailing few: ease from dim (near the edge) up to full (further back).
        if solid > stable {
            for i in stable..<solid {
                let dist = solid - i                 // 1 = closest to the writing edge
                let ramp = Double(trail - dist + 1) / Double(trail + 1)   // 0..1 (back -> edge)
                let a = 0.9 * (0.30 + 0.70 * ramp)
                text = text + Text(String(chars[i])).foregroundColor(.primary.opacity(a))
            }
        }

        // The character being written right now: alpha = smoothstep(fractional progress).
        let frac = clamped - Double(solid)
        let eased = frac * frac * (3 - 2 * frac)
        text = text + Text(String(chars[solid])).foregroundColor(.primary.opacity(0.9 * eased))
        return text
    }

    /// Fractional characters visible at `date`, from the current anchor. Pure function of time, so
    /// the reveal is even and self-correcting even if a frame is dropped.
    private func revealedF(at date: Date) -> Double {
        guard rate > 0 else { return anchorCount }
        let secs = max(0, date.timeIntervalSince(anchorDate))
        return min(Double(target.count), max(anchorCount, anchorCount + secs * rate))
    }

    /// Re-base the reveal clock on the current target. Keeps whatever has inked in, picks a cadence
    /// for the remaining backlog, and schedules a single settle when the reveal will finish.
    /// IMPORTANT: while NOT animating the clock is frozen at anchorCount - the panel's view lives
    /// for the whole app session (two-graph crash architecture), so a time-derived read here would
    /// keep "earning" reveal budget between dictations and make every new partial appear instantly.
    private func retarget() {
        let now = Date()
        let current = min(Double(target.count), isAnimating ? revealedF(at: now) : anchorCount)
        settleTask?.cancel()
        anchorCount = current
        anchorDate = now

        let remaining = Double(target.count) - current
        guard remaining > 0.5 else {
            anchorCount = Double(target.count)
            isAnimating = false
            return
        }
        rate = cadence(forRemaining: remaining)
        isAnimating = true
        let duration = (remaining + 1) / rate
        let goalCount = Double(target.count)
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            anchorCount = goalCount
            anchorDate = Date()
            isAnimating = false
        }
    }

    /// chars/sec, paced so the writing NEVER stops between partials. Spread the backlog across the
    /// typical gap between partials (~1.4s) so the reveal is still flowing when the next chunk lands,
    /// then clamp to a sane range so a big backlog catches up fast but a tiny one still reads letter
    /// by letter.
    private func cadence(forRemaining remaining: Double) -> Double {
        let expectedGap = 1.4
        return min(200, max(16, remaining / expectedGap))
    }
}
