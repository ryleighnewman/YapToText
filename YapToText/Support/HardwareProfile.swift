import Foundation

/// What kind of Mac this is, and which models it can carry comfortably. Read once at
/// launch; drives the setup recommendation and the Energy page's explanation copy.
struct HardwareProfile {
    enum Tier: String {
        /// Base M1/M2 with 8GB (the M1 MacBook Air case): light models only.
        case light
        /// Base/Pro chips with 16GB: the quantized turbo is the sweet spot.
        case balanced
        /// Max/Ultra chips or 32GB+: everything runs happily.
        case high
    }

    let chipName: String        // "Apple M1", "Apple M3 Max", "Intel"
    let memoryGB: Int
    let hasBattery: Bool
    let tier: Tier

    static let current: HardwareProfile = {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let memGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let battery = sysctlString("hw.model")?.lowercased().contains("book") ?? false
        let lower = chip.lowercased()
        let tier: Tier
        if lower.contains("max") || lower.contains("ultra") || memGB >= 32 {
            tier = .high
        } else if memGB >= 16 {
            tier = .balanced
        } else {
            tier = .light   // 8GB of anything - including the M1 Air - is light
        }
        return HardwareProfile(chipName: chip, memoryGB: memGB, hasBattery: battery, tier: tier)
    }()

    /// The speech-model pair this Mac should start with: (plugged in, on battery).
    var recommendedSpeechModels: (plugged: String, battery: String) {
        switch tier {
        case .high:     return ("whisper-large-v3-turbo", "whisper-large-v3-turbo-q5")
        case .balanced: return ("whisper-large-v3-turbo", "whisper-large-v3-turbo-q5")
        case .light:    return ("whisper-large-v3-turbo-q5", "whisper-large-v3-turbo-q5")
        }
    }

    /// Honest, specific compromise copy for the recommendation. No hand-waving: what is
    /// given up, and what is not.
    var recommendationExplanation: String {
        switch tier {
        case .high:
            return "This Mac can run the full Turbo model without breaking a sweat. On battery it drops to the Q5 version: about a third of the memory and noticeably less energy per dictation, with accuracy that matches the full model on clear speech and gives up only a little in very noisy rooms."
        case .balanced:
            return "The full Turbo model runs well here when plugged in. On battery the Q5 version saves real energy and about 1GB of memory; you give up a small amount of robustness in loud environments, and nothing noticeable on normal speech."
        case .light:
            return "With \(memoryGB)GB of memory, the full 1.6GB Turbo model would squeeze this Mac - the Q5 version is the right choice everywhere. The compromise is modest: on clear speech it matches the full model almost exactly; in very loud rooms it mishears slightly more often. Dictations also start faster because the smaller model loads in a fraction of the time."
        }
    }

    var summaryLine: String {
        "\(chipName) \u{00B7} \(memoryGB)GB memory \u{00B7} \(hasBattery ? "battery powered" : "desktop")"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
