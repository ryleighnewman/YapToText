import AppKit

/// One-click diagnostics: everything a bug report needs, gathered locally and copied to the
/// clipboard - Mac model/chip, macOS and app versions, model setup, and latency statistics
/// from the user's own history (cold start vs repeat). Contains NO transcript text.
@MainActor
enum Diagnostics {
    static func report(state: AppState) -> String {
        var lines: [String] = []
        lines.append("YapToText \(Changelog.currentVersion)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Mac: \(sysctlString("hw.model") ?? "?") | \(sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon") | \(Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)) GB")
        lines.append("")
        lines.append("Engine: \(state.settings.engine.rawValue)")
        lines.append("Speech model: \(state.settings.selectedSpeechModelID)")
        lines.append("Language model: \(state.settings.selectedLanguageModelID)")
        lines.append("AI cleanup: \(state.settings.aiCleanupEnabled), Apple Intelligence: \(FoundationModelsTransformer.isAvailable)")
        lines.append("Insertion: \(state.settings.insertionMethod.rawValue), auto-insert: \(state.settings.autoInsert), review: \(state.settings.reviewBeforeInsert) (long-only: \(state.settings.reviewLongTextOnly))")
        lines.append("Mic: gain \(String(format: "%.1f", state.settings.inputGain))x, auto-amplify \(state.settings.autoAmplifyInput), noise reduction \(state.settings.reduceBackgroundNoise), keep warm \(state.settings.keepMicWarm)")
        lines.append("Model cooldown: \(state.settings.modelCooldownSeconds)s")
        lines.append("Accessibility: \(state.permissions.accessibilityGranted), Microphone: \(state.permissions.microphoneGranted)")
        lines.append("")

        // Latency from history: processSeconds is stop-to-delivery. The slowest value is
        // usually the cold start; the median is the everyday feel.
        let latencies = state.history.records.compactMap(\.processSeconds).prefix(50).sorted()
        if !latencies.isEmpty {
            let median = latencies[latencies.count / 2]
            lines.append(String(format: "Stop-to-text latency (last %d): median %.1fs, fastest %.1fs, slowest %.1fs",
                                latencies.count, median, latencies.first!, latencies.last!))
        }
        let outcomes = state.history.records.prefix(50).compactMap(\.outcome)
        if !outcomes.isEmpty {
            let counts = Dictionary(grouping: outcomes, by: { $0 }).mapValues(\.count)
                .sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            lines.append("Outcomes (last 50): \(counts)")
        }
        lines.append("Dictations recorded: \(state.history.records.count)")
        lines.append("")
        // Stability breadcrumbs. The sandbox cannot read macOS's crash logs, so these are
        // the app's own counts; the real reports live in Console.app > Crash Reports.
        let ud = UserDefaults.standard
        let unclean = ud.integer(forKey: "diag.uncleanExits")
        if unclean > 0 {
            let when = Date(timeIntervalSince1970: ud.double(forKey: "diag.lastUncleanExit"))
            let mid = ud.bool(forKey: "diag.lastUncleanMidDictation") ? ", last one mid-dictation (recovered)" : ""
            lines.append("Unclean exits: \(unclean) (last \(when.formatted(.dateTime.month().day().hour().minute()))\(mid))")
        } else {
            lines.append("Unclean exits: none recorded")
        }
        let errs = ud.integer(forKey: "diag.errorCount")
        if errs > 0 {
            let when = Date(timeIntervalSince1970: ud.double(forKey: "diag.lastErrorAt"))
            lines.append("Errors shown: \(errs) (last \(when.formatted(.dateTime.month().day().hour().minute())))")
        }
        lines.append("Full crash reports (if any): Console.app > Crash Reports > YapToText")
        return lines.joined(separator: "\n")
    }

    static func copyToClipboard(state: AppState) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report(state: state), forType: .string)
    }

    /// The app's current real memory footprint (what Activity Monitor's "Memory" shows).
    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// Total CPU seconds this process has used (user + system). Sampled twice over an
    /// interval, the delta gives a live CPU%.
    static func cpuSecondsUsed() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}
