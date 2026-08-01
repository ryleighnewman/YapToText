import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistorySettingsView: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var dateFilter: DateFilter = .all
    @State private var modeFilter: String?
    @State private var aiOnly = false
    @State private var showStats = false
    @State private var rawExpanded: Set<UUID> = []

    enum DateFilter: String, CaseIterable, Identifiable {
        case all = "All", today = "Today", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var cutoff: Date? {
            let cal = Calendar.current
            switch self {
            case .all: return nil
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            }
        }
    }

    var body: some View {
        // ONE search+filter pass per render: `results` used to be a computed property read by the
        // filter bar, the list, and the action bar, so the full history scan ran 3-4x per update.
        let results = computeResults()
        return VStack(spacing: 0) {
            filterBar(results: results)
            Divider()
            content(results: results)
            Divider()
            actionBar(results: results)
        }
        .navigationTitle("History")
        .sheet(isPresented: $showStats) { StatsView().environment(state) }
    }

    // MARK: Filter bar

    private func filterBar(results: [DictationRecord]) -> some View {
        // Even vertical rhythm: edge -> search bar -> filter chips -> divider all share one gap.
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search text, mode, or app", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
                Spacer()
                Text("\(results.count) of \(state.history.records.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { showStats = true } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .iconTint(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.secondary.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Statistics and insights")
            }
            HStack(spacing: 8) {
                // Modern capsule chips (the panel's mode-chip language), not the legacy
                // segmented Picker / button-toggle.
                CapsuleSegments(options: DateFilter.allCases.map { ($0, $0.rawValue) },
                                selection: $dateFilter)

                Menu {
                    Button("All modes") { modeFilter = nil }
                    Divider()
                    ForEach(distinctModes, id: \.self) { name in
                        Button { modeFilter = name } label: {
                            Label(name, systemImage: modeFilter == name ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label(modeFilter ?? "All modes", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()

                CapsuleToggleChip(label: "AI only", isOn: $aiOnly)

                Spacer()

                if hasActiveFilters {
                    Button("Clear filters") { clearFilters() }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private func content(results: [DictationRecord]) -> some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: state.history.records.isEmpty ? "clock" : "magnifyingglass")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text(state.history.records.isEmpty ? "Your dictations will appear here." : "No matches for these filters.")
                    .foregroundStyle(.secondary)
                if !state.history.records.isEmpty && hasActiveFilters {
                    Button("Clear filters") { clearFilters() }.buttonStyle(.solidSecondary).controlSize(.small)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(results) { record in
                    recordRow(record)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
        }
    }

    private func recordRow(_ record: DictationRecord) -> some View {
        let isRegenerating = state.controller.regeneratingIDs.contains(record.id)
        let justUpdated = state.controller.lastRegeneratedID == record.id
        let isPlaying = HistoryAudioPlayer.shared.playingID == record.id
        let showRaw = rawExpanded.contains(record.id)
        return VStack(alignment: .leading, spacing: 7) {
            Text(record.finalText).lineLimit(3).textSelection(.enabled)
            // Pipeline forensics: one click opens the full three-stage breakdown - what the
            // speech model heard, what cleanup made of it, and what actually landed - plus the
            // delivery status. The fastest way to blame the right stage for a bad output.
            Button {
                // Smooth, explicit animation: the disclosure grew/snapped in one heavy layout
                // pass before, which read as lag. One eased transaction opens it cleanly.
                withAnimation(.easeOut(duration: 0.22)) {
                    if showRaw { rawExpanded.remove(record.id) } else { rawExpanded.insert(record.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showRaw ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    Text(showRaw ? "Pipeline details" : "Show pipeline details").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showRaw {
                VStack(alignment: .leading, spacing: 10) {
                    // 1. The recording itself, first-class: play/scrub/skip, reveal, share.
                    if record.hasAudio {
                        RecordMediaPlayer(record: record)
                    }
                    // 2. The three pipeline stages, in order.
                    pipelineField("Raw transcript (what the speech model heard)", record.rawText)
                    if record.finalText != record.rawText {
                        pipelineField(record.usedAI ? "Cleaned transcript (after AI + dictionaries + commands)"
                                                    : "Processed transcript (after dictionaries + commands)",
                                      record.finalText)
                    }
                    if let delivered = record.deliveredText,
                       delivered.trimmingCharacters(in: .whitespaces) != record.finalText.trimmingCharacters(in: .whitespaces) {
                        pipelineField("Final delivered text", delivered)
                    }
                    // 3. Everything that happened, as a plain bullet list (no pills - they fought
                    //    with the row's own chips below). Timestamp leads.
                    VStack(alignment: .leading, spacing: 3) {
                        detailBullet("Timestamp", record.date.formatted(.dateTime.year().month().day().hour().minute().second()))
                        detailBullet("Mode", record.modeName + (record.usedAI ? " (AI cleanup)" : " (verbatim)"))
                        if let verdict = record.autoVerdict { detailBullet("Auto detected", verdict) }
                        if let model = record.cleanupModel { detailBullet("Cleanup model", model) }
                        if let outcome = record.outcome { detailBullet("Delivery", outcome) }
                        if let app = record.appName { detailBullet("Target app", app) }
                        detailBullet("Spoken for", String(format: "%.1fs", record.durationSeconds))
                        if let secs = record.processSeconds { detailBullet("Stop to text", String(format: "%.1fs", secs)) }
                        detailBullet("Language", record.localeIdentifier)
                        detailBullet("Audio", record.hasAudio ? "saved with this entry" : "not kept")
                    }
                    .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // Built-in player: a thin progress bar appears under the text while this row plays.
            if isPlaying {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.caption2).iconTint(.accentColor)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(Color.accentColor.opacity(0.8))
                                .frame(width: max(3, geo.size.width * HistoryAudioPlayer.shared.progress))
                        }
                    }
                    .frame(height: 4)
                }
            }
            HStack(spacing: 8) {
                chip(record.modeName, "square.stack.3d.up")
                if let app = record.appName { chip(app, "app") }
                chip(record.date.formatted(.dateTime.month().day().hour().minute()), "clock")
                if record.usedAI { chip("AI", "sparkles") }
                Spacer()
                if isRegenerating {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Regenerating…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    // EVERY row shows the same controls in the same order, whatever combination of
                    // text and audio the entry has - audio-dependent ones gray out instead of
                    // vanishing, so rows always read consistent.
                    rowButton(isPlaying ? "stop.circle.fill" : "play.circle",
                              record.hasAudio ? (isPlaying ? "Stop playback" : "Play recording")
                                              : "No audio saved for this entry",
                              tint: isPlaying ? .accentColor : .secondary) {
                        HistoryAudioPlayer.shared.toggle(record)
                    }
                    .disabled(!record.hasAudio)
                    .opacity(record.hasAudio ? 1 : 0.35)
                    if canRegenerate(record) { rowButton("arrow.clockwise", "Regenerate with AI") { state.controller.regenerate(record) } }
                    rowButton("doc.on.doc", "Copy") { TextInserter.setClipboard(record.finalText) }
                    rowButton("text.insert", "Insert into the previous app") { insert(record) }
                    exportMenu(record)
                    rowButton("trash", "Delete", tint: .red) { state.history.delete(record) }
                }
            }
        }
        .padding(10)
        .background(justUpdated ? AnyShapeStyle(Color.green.opacity(0.18)) : AnyShapeStyle(Color.secondary.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(justUpdated ? Color.green.opacity(0.6) : Color.secondary.opacity(0.12), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.3), value: justUpdated)
        .animation(.easeInOut(duration: 0.2), value: isRegenerating)
    }

    private func actionBar(results: [DictationRecord]) -> some View {
        HStack {
            Button {
                NotificationCenter.default.post(name: .yapTranscribeFile, object: nil)
            } label: { Label("Transcribe File", systemImage: "waveform.badge.magnifyingglass") }
                .buttonStyle(.solid).controlSize(.small)
            Spacer()
            Button("Export…") { export() }.buttonStyle(.solidSecondary).disabled(results.isEmpty).controlSize(.small)
            Button("Clear All", role: .destructive) { state.history.clear() }
                .buttonStyle(SolidButton(tint: .red, prominent: false))
                .disabled(state.history.records.isEmpty).controlSize(.small)
        }
        .padding(10)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FolderCaption(prefix: "History lives on your Mac in the app's ",
                          linkText: "data folder",
                          url: Persistence.url("history.json"),
                          suffix: ".")
                .padding(.horizontal, 10).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Filtering

    private func computeResults() -> [DictationRecord] {
        var r = state.history.search(query)
        if let cutoff = dateFilter.cutoff { r = r.filter { $0.date >= cutoff } }
        if let mode = modeFilter { r = r.filter { $0.modeName == mode } }
        if aiOnly { r = r.filter { $0.usedAI } }
        return r
    }

    private var distinctModes: [String] {
        Array(Set(state.history.records.map(\.modeName))).sorted()
    }

    private var hasActiveFilters: Bool {
        !query.isEmpty || dateFilter != .all || modeFilter != nil || aiOnly
    }

    private func clearFilters() {
        query = ""; dateFilter = .all; modeFilter = nil; aiOnly = false
    }

    // MARK: Row pieces

    /// One "label: value" line of the details bullet list.
    private func detailBullet(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\u{2022}").foregroundStyle(.tertiary)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .frame(width: 82, alignment: .leading)
            Text(value).font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// The pipeline-details media player: transport on the LEFT (skip back, play/pause, skip
    /// forward), a draggable scrubber with elapsed/total time, then Reveal and Share.
    private struct RecordMediaPlayer: View {
        let record: DictationRecord
        private var player: HistoryAudioPlayer { HistoryAudioPlayer.shared }
        private var isCurrent: Bool { player.playingID == record.id }

        private func fmt(_ t: TimeInterval) -> String {
            String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
        }

        var body: some View {
            HStack(spacing: 8) {
                Button { player.skip(record, by: -5) } label: { Image(systemName: "gobackward.5") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(!isCurrent)
                Button { player.playPause(record) } label: {
                    Image(systemName: isCurrent && !player.isPaused ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { player.skip(record, by: 5) } label: { Image(systemName: "goforward.5") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(!isCurrent)

                Text(isCurrent ? fmt(player.currentTime) : "0:00")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { isCurrent ? player.progress : 0 },
                    set: { player.seek(record, toFraction: $0) }
                ))
                .controlSize(.mini)
                Text(fmt(isCurrent ? player.duration : record.durationSeconds))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)

                if let name = record.audioFileName {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([AudioStore.url(for: name)])
                    } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Show the recording in Finder")
                    ShareLink(item: AudioStore.url(for: name)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Share the recording")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// One labeled stage of the pipeline breakdown - selectable so any line can be copied.
    private func pipelineField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(value).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    private func rowButton(_ symbol: String, _ help: String, tint: Color = .secondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.06), in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func canRegenerate(_ record: DictationRecord) -> Bool {
        state.controller.regenerationMode(for: record) != nil
    }

    private func insert(_ record: DictationRecord) {
        let text = record.finalText
        let method = state.settings.insertionMethod
        let restore = state.settings.restoreClipboard
        NSApp.hide(nil)
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier { break }
            }
            TextInserter.deliver(text, target: .insertAtCursor, method: method, restoreClipboard: restore)
        }
    }

    /// Per-row export: the text, the raw (pre-AI) transcript, or the audio recording.
    private func exportMenu(_ record: DictationRecord) -> some View {
        Menu {
            Button("Export Text…") { exportText(record) }
            Button("Export Audio…") { exportAudio(record) }
                .disabled(!record.hasAudio)
            Divider()
            Button("Copy Raw Transcript") { TextInserter.setClipboard(record.rawText) }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.06), in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden).fixedSize()
        .help("Export this dictation")
    }

    private static let exportNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    private func exportText(_ record: DictationRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Dictation \(Self.exportNameFormatter.string(from: record.date)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModalInFront() == .OK, let url = panel.url else { return }
        try? record.finalText.data(using: .utf8)?.write(to: url)
    }

    private func exportAudio(_ record: DictationRecord) {
        guard let name = record.audioFileName else { return }
        let source = AudioStore.url(for: name)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Dictation \(Self.exportNameFormatter.string(from: record.date)).caf"
        panel.allowedContentTypes = [UTType(filenameExtension: "caf") ?? .audio]
        guard panel.runModalInFront() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "yaptotext-history.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModalInFront() == .OK, let url = panel.url else { return }
        let results = computeResults()
        let markdown = results.map { record in
            "### \(record.modeName) (\(record.date.formatted()))\n\n\(record.finalText)\n"
        }.joined(separator: "\n")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
