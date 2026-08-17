import Foundation
import IOKit.ps
import Observation

/// Live AC-vs-battery state, driving the adaptive model system: plugged in gets the heavy
/// models, on battery gets the light ones. Desktops (no battery) always read as plugged in.
@Observable
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    /// True when running from wall power (or on a Mac with no battery at all).
    private(set) var onACPower: Bool = true
    /// Battery percentage 0-100, nil on desktops.
    private(set) var batteryPercent: Int?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    private init() {
        refresh()
        // IOKit fires this on every power-source change: plug, unplug, percentage ticks.
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            // No power sources reported = desktop Mac: always mains.
            onACPower = true
            batteryPercent = nil
            return
        }
        var plugged = true
        var percent: Int?
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                plugged = (state == kIOPSACPowerValue)
            }
            if let cap = info[kIOPSCurrentCapacityKey] as? Int,
               let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(cap) / Double(max) * 100).rounded())
            }
        }
        onACPower = plugged
        batteryPercent = percent
    }
}
