import SwiftUI
import Charts

/// "Your dictation story" - a statistics sheet computed entirely from the local history.
/// Opened from the History page. Every number here is derived on-device, on the fly.
struct StatsView: View {
    /// true when shown as a sidebar page (no close button, fills the window);
    /// false when presented as a sheet from History.
    var standalone = false
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDay: Date?
    @State private var selectedHour: Int?

    var body: some View {
        let stats = Stats(records: state.history.records)
        return VStack(spacing: 0) {
            header(stats)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    tiles(stats)
                    EnergyCard(state: state)
                    if stats.count > 0 {
                        activityCard(stats)
                        insightsCard(stats)
                        breakdownCard(stats)
                    } else {
                        emptyCard
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.never)
        }
        .frame(width: standalone ? nil : 620, height: standalone ? nil : 720)
        .navigationTitle("Statistics")
    }

    // MARK: Header

    private func header(_ stats: Stats) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "chart.bar.xaxis", tint: .accentColor, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Your dictation story").font(.headline)
                Text(stats.count == 0 ? "No dictations yet"
                     : "\(stats.count) dictations since \(stats.firstDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !standalone { closeButton }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.secondary.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    // MARK: Stat tiles

    private func tiles(_ s: Stats) -> some View {
        let items: [(String, String, String, Color)] = [
            ("text.bubble", s.count.formatted(), "Dictations", .accentColor),
            ("textformat.abc", s.totalWords.formatted(), "Words spoken", .accentColor),
            ("clock", Stats.duration(s.totalSeconds), "Time speaking", .accentColor),
            ("speedometer", s.wpm > 0 ? "\(s.wpm)" : "-", "Speaking pace", .accentColor),
        ]
        return HStack(spacing: 10) {
            ForEach(items, id: \.2) { item in
                VStack(spacing: 4) {
                    Text(item.1).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(item.2).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .innerWell(radius: Metrics.innerRadius)
            }
        }
        .padding(Metrics.cardPad)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }

    // MARK: Activity (last 30 days)

    private func activityCard(_ s: Stats) -> some View {
        CardSection("Words dictated per day for the last 30 days") {
            Chart(s.dailyWords, id: \.day) { point in
                BarMark(x: .value("Day", point.day, unit: .day),
                        y: .value("Words", point.words))
                    .foregroundStyle(Color.accentColor.opacity(selectedDay != nil && Calendar.current.isDate(selectedDay!, inSameDayAs: point.day) ? 1.0 : 0.6))
                    .cornerRadius(2)
                // The readout rides ON the chart as a tooltip over the selected day - not a
                // caption below it.
                if let day = selectedDay, Calendar.current.isDate(day, inSameDayAs: point.day) {
                    RuleMark(x: .value("Day", point.day, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            Text("\(point.day.formatted(.dateTime.month(.abbreviated).day()))  ·  \(point.words) word\(point.words == 1 ? "" : "s")")
                                .font(.caption.weight(.medium)).monospacedDigit()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                        }
                }
            }
            .chartXSelection(value: $selectedDay)
            .animation(.easeOut(duration: 0.18), value: selectedDay)
            .chartYAxis { AxisMarks(position: .trailing) { AxisGridLine(); AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 130)
        }
    }


    // MARK: Insights

    private func insightsCard(_ s: Stats) -> some View {
        CardSection("Insights") {
            VStack(alignment: .leading, spacing: 8) {
                if s.minutesSaved >= 1 {
                    insight("About \(Stats.duration(s.minutesSaved * 60)) saved versus typing everything at 40 words a minute.")
                }
                insight(s.currentStreak > 1
                        ? "You're on a \(s.currentStreak)-day streak. Your best is \(s.bestStreak) days."
                        : "Your best streak so far is \(max(s.bestStreak, 1)) day\(s.bestStreak == 1 ? "" : "s") in a row.")
                insight("A typical dictation runs about \(s.medianWords) words.")
            }
        }
    }

    private func insight(_ text: String) -> some View {
        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .innerWell(radius: Metrics.innerRadius)
    }

    // MARK: Breakdown (modes + apps)

    private func breakdownCard(_ s: Stats) -> some View {
        CardSection("Top modes and destinations") {
            HStack(alignment: .top, spacing: Metrics.gap) {
                rankList(title: "Modes", rows: s.topModes, tint: .accentColor)
                rankList(title: "Apps", rows: s.topApps, tint: .accentColor)
            }
        }
    }

    private func rankList(title: String, rows: [(String, Int)], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            if rows.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.0) { row in
                let peak = rows.first?.1 ?? 1
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.0).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(row.1)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(tint.opacity(0.55))
                            .frame(width: max(3, geo.size.width * CGFloat(row.1) / CGFloat(max(peak, 1))))
                    }
                    .frame(height: 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyCard: some View {
        CardSection("No data yet") {
            Text("Dictate a few times and this page fills up with charts, streaks, and insights.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

}

/// Live energy & resource readout: memory footprint, CPU right now, and the model-memory
/// story (the 1.5-3.7GB models are the footprint; the cooldown releases them when idle).
private struct EnergyCard: View {
    let state: AppState
    @State private var memMB = 0
    @State private var cpuPercent = 0.0
    @State private var sampler: Task<Void, Never>?

    var body: some View {
        CardSection("Energy & resources") {
            HStack(spacing: 0) {
                StatPill(memMB > 0 ? "\(memMB) MB" : "-", "memory")
                StatPill(String(format: "%.0f%%", cpuPercent), "CPU now")
                StatPill(state.settings.modelCooldownSeconds < 0 ? "kept" :
                         state.settings.modelCooldownSeconds == 0 ? "instant" :
                         "\(Int(state.settings.modelCooldownSeconds))s", "model unload")
            }
            Caption("Memory is mostly the loaded speech/AI models; after the unload delay they're released and the footprint drops. CPU spikes briefly during transcription and cleanup, then returns to ~0% at idle.")
        }
        .onAppear {
            sampler?.cancel()
            sampler = Task { @MainActor in
                var lastCPU = Diagnostics.cpuSecondsUsed()
                var lastAt = Date()
                while !Task.isCancelled {
                    memMB = Diagnostics.memoryFootprintMB()
                    let nowCPU = Diagnostics.cpuSecondsUsed()
                    let dt = Date().timeIntervalSince(lastAt)
                    if dt > 0 { cpuPercent = max(0, (nowCPU - lastCPU) / dt * 100) }
                    lastCPU = nowCPU
                    lastAt = Date()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        .onDisappear { sampler?.cancel(); sampler = nil }
    }
}

// MARK: - Number crunching

/// One pass over the history producing everything the page shows.
private struct Stats {
    struct DayPoint { let day: Date; let words: Int }

    var count = 0
    var totalWords = 0
    var totalSeconds: Double = 0
    var wpm = 0
    var firstDate = Date()
    var dailyWords: [DayPoint] = []
    var byHour = [Int](repeating: 0, count: 24)
    var peakHour = 12
    var peakWeekday = "Monday"
    var currentStreak = 0
    var bestStreak = 0
    var minutesSaved: Double = 0
    var longest: DictationRecord?
    var aiShare = 0
    var medianWords = 0
    var topModes: [(String, Int)] = []
    var topApps: [(String, Int)] = []

    init(records: [DictationRecord]) {
        guard !records.isEmpty else { return }
        let cal = Calendar.current
        count = records.count
        firstDate = records.map(\.date).min() ?? Date()

        var wordCounts: [Int] = []
        var byDay: [Date: Int] = [:]
        var byWeekday = [Int](repeating: 0, count: 7)
        var modes: [String: Int] = [:]
        var apps: [String: Int] = [:]
        var aiCount = 0

        for r in records {
            let words = r.finalText.split(whereSeparator: \.isWhitespace).count
            wordCounts.append(words)
            totalWords += words
            totalSeconds += max(0, r.durationSeconds)
            byDay[cal.startOfDay(for: r.date), default: 0] += words
            byHour[cal.component(.hour, from: r.date)] += 1
            byWeekday[cal.component(.weekday, from: r.date) - 1] += 1
            modes[r.modeName, default: 0] += 1
            if let app = r.appName, !app.isEmpty { apps[app, default: 0] += 1 }
            if r.usedAI { aiCount += 1 }
            if words > (longest.map { $0.finalText.split(whereSeparator: \.isWhitespace).count } ?? 0) { longest = r }
        }

        if totalSeconds > 30 { wpm = Int((Double(totalWords) / (totalSeconds / 60)).rounded()) }
        aiShare = Int((Double(aiCount) / Double(count) * 100).rounded())
        medianWords = wordCounts.sorted(by: <)[wordCounts.count / 2]
        // Typing the same words at ~40wpm would have taken totalWords/40 minutes.
        minutesSaved = max(0, Double(totalWords) / 40.0 - totalSeconds / 60)

        peakHour = byHour.enumerated().max(by: { $0.element < $1.element })?.offset ?? 12
        let weekdayIndex = byWeekday.enumerated().max(by: { $0.element < $1.element })?.offset ?? 1
        peakWeekday = cal.weekdaySymbols[weekdayIndex]

        // Last 30 days, zero-filled so the chart shows quiet days too.
        let today = cal.startOfDay(for: Date())
        dailyWords = (0..<30).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return DayPoint(day: day, words: byDay[day] ?? 0)
        }

        // Streaks: consecutive calendar days with at least one dictation.
        let activeDays = Set(byDay.keys)
        var streak = 0
        var day = today
        if !activeDays.contains(today), let y = cal.date(byAdding: .day, value: -1, to: today) { day = y }
        while activeDays.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        currentStreak = streak
        var best = 0
        for start in activeDays {
            guard let before = cal.date(byAdding: .day, value: -1, to: start), !activeDays.contains(before) else { continue }
            var length = 0, cursor = start
            while activeDays.contains(cursor) {
                length += 1
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            best = max(best, length)
        }
        bestStreak = max(best, currentStreak)

        topModes = modes.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
        topApps = apps.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    static func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return d.formatted(.dateTime.hour())
    }
}
