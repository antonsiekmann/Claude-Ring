import Foundation
import Observation
import ServiceManagement

/// Wraps the login item of the app itself.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    /// Login items register the path the app runs from. Only offer them for an
    /// installed copy, not for a build in DerivedData that moves on every build.
    let isAvailable = AppEnvironment.isInstalled()

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    init() {
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
