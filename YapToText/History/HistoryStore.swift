import Foundation
import Observation

/// One completed dictation. The audio recording is stored only when the user opts in.
struct DictationRecord: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var rawText: String
    var finalText: String
    var modeName: String
    var modeID: UUID? = nil
    var durationSeconds: Double
    var appName: String?
    var appBundleID: String?
    var localeIdentifier: String
    var usedAI: Bool
    var audioFileName: String? = nil
    // Pipeline forensics (all optional so old records still decode): exactly what happened
    // at delivery, so a bad output can be blamed on the right stage.
    /// What actually landed in the target (finalText plus trailing space, or a review edit).
    var deliveredText: String? = nil
    /// pasted / typed / copied / live-typed / reviewed / quick-edit / failed / recovered
    var outcome: String? = nil
    /// Seconds from stop to delivery - the transcribe+cleanup latency the user felt.
    var processSeconds: Double? = nil
    /// Which cleanup engine actually ran ("Apple Intelligence", the GGUF's display name) - nil if none.
    var cleanupModel: String? = nil
    /// Auto mode's detected verdict (email / message / note / code / cleanup) - nil outside Auto.
    var autoVerdict: String? = nil

    var hasAudio: Bool { AudioStore.exists(audioFileName) }
}

/// Local, searchable history of dictations, persisted as JSON. Capped so the file
/// stays small; the most recent entries are kept.
@Observable
final class HistoryStore {
    private(set) var records: [DictationRecord]
    @ObservationIgnored private(set) var retention: HistoryRetention = .all

    @ObservationIgnored private static let fileName = "history.json"
    @ObservationIgnored private static let cap = 2000

    init() {
        records = Persistence.load([DictationRecord].self, from: HistoryStore.fileName) ?? []
    }

    /// Apply the user's retention choice: trim, and control whether history is written to disk.
    func applyRetention(_ retention: HistoryRetention) {
        self.retention = retention
        switch retention {
        case .off:
            // History off = the recordings go too. Leaving the .caf files behind while
            // the records vanish kept the user's voice on disk forever with nothing
            // pointing at it - the opposite of what "Off" promises.
            for r in records { AudioStore.delete(r.audioFileName) }
            records.removeAll()
            Persistence.save(records, to: HistoryStore.fileName)
        case .sessionOnly:
            // Keep the in-memory list this session, but leave nothing on disk for next launch.
            Persistence.save([DictationRecord](), to: HistoryStore.fileName)
        case .all, .last100, .last500:
            trim()
            save()
        }
    }

    func add(_ record: DictationRecord) {
        guard retention != .off else { return }
        records.insert(record, at: 0)
        trim()
        if retention.persists { save() }
    }

    /// Replace a record in place (used by regenerate).
    func update(_ record: DictationRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        save()
    }

    private func trim() {
        let limit = min(retention.limit ?? HistoryStore.cap, HistoryStore.cap)
        if records.count > limit {
            for r in records.suffix(records.count - limit) { AudioStore.delete(r.audioFileName) }
            records.removeLast(records.count - limit)
        }
    }

    /// Delete records (and their audio) older than `days`. 0 = never.
    @discardableResult
    func pruneOlderThan(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let removed = records.filter { $0.date < cutoff }
        guard !removed.isEmpty else { return 0 }
        records.removeAll { $0.date < cutoff }
        for r in removed { AudioStore.delete(r.audioFileName) }
        save()
        return removed.count
    }

    func delete(_ record: DictationRecord) {
        records.removeAll { $0.id == record.id }
        AudioStore.delete(record.audioFileName)
        save()
    }

    func clear() {
        records.removeAll()
        AudioStore.deleteAll()
        save()
    }

    /// Case-insensitive substring search across the final and raw text, mode, and app.
    func search(_ query: String) -> [DictationRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.finalText.lowercased().contains(q)
            || $0.rawText.lowercased().contains(q)
            || $0.modeName.lowercased().contains(q)
            || ($0.appName?.lowercased().contains(q) ?? false)
        }
    }

    var totalWords: Int {
        records.reduce(0) { $0 + $1.finalText.split(whereSeparator: { $0.isWhitespace }).count }
    }

    private func save() {
        guard retention.persists else { return }
        Persistence.save(records, to: HistoryStore.fileName)
    }
}
