import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService` (macOS 13+). No helper bundle, no
/// deprecated `LSSharedFileList` dance — the OS tracks the state for us, so we
/// query the service rather than persisting a flag of our own.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the main app as a login item. Idempotent and
    /// failure-tolerant — a thrown error is logged, not propagated, so a flaky
    /// toggle never crashes the app.
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("MacSanity: launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}
