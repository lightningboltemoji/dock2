import Foundation
import ServiceManagement

/// Open at login: the main app registered with `SMAppService`, whose status is the truth — not a setting.
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters dock2; nil on success, else why not. A run from `.build` has no bundle to
    /// register.
    public static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
