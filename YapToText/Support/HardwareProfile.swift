import Foundation

/// What kind of Mac this is: chip, memory, cores, model identifier. Read once at launch
/// and shown on the Energy page. It no longer recommends models - every Mac runs the same
/// bundled default, so a per-machine recommendation had nothing left to decide.
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
    let cpuCores: Int
    let modelIdentifier: String   // "Mac15,3"

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
        let cores = Int(sysctlString("hw.model") != nil ? sysctlInt("hw.ncpu") : 0)
        return HardwareProfile(chipName: chip, memoryGB: memGB, hasBattery: battery, tier: tier,
                               cpuCores: cores, modelIdentifier: sysctlString("hw.model") ?? "Mac")
    }()

    var summaryLine: String {
        "\(chipName) \u{00B7} \(memoryGB)GB memory \u{00B7} \(hasBattery ? "battery powered" : "desktop")"
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
