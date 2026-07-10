import Foundation
import ServiceManagement

/// Wraps SMAppService so the app can register itself as a login item.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("YapToText: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
