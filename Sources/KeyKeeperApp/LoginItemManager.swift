import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. A menu bar app that cron jobs depend on must
/// come back after a reboot without the user remembering to open it.
enum LoginItemManager {
    /// `swift run` has no .app bundle; registration only works from /Applications-style bundles.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
