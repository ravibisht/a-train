import Foundation
import ServiceManagement

/// User-facing preferences (Settings card in the dashboard). All live in UserDefaults so SwiftUI's
/// @AppStorage and the AppKit side read the same values.
enum AppPrefs {
    enum DockMode: String, CaseIterable {
        case whileOpen, always, never
        var title: String {
            switch self {
            case .whileOpen: return "While dashboard is open"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    static let dockModeKey = "dockMode"
    static let openAtLaunchKey = "openDashboardAtLaunch"
    static let windowFrameName = "ATrainDashboard"

    static var dockMode: DockMode {
        DockMode(rawValue: UserDefaults.standard.string(forKey: dockModeKey) ?? "") ?? .whileOpen
    }

    static var openDashboardAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: openAtLaunchKey)
    }

    static var startAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// (toggle on?, note). `requiresApproval` means the item is registered but macOS wants the user to
    /// allow it in System Settings; show it as on with that hint rather than as a toggle that "doesn't stick".
    static func loginItemState() -> (Bool, String?) {
        switch SMAppService.mainApp.status {
        case .enabled: return (true, nil)
        case .requiresApproval: return (true, "Waiting for your approval in System Settings > General > Login Items.")
        default: return (false, nil)
        }
    }

    /// Returns an error message on failure.
    static func setStartAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Could not \(on ? "enable" : "disable") Start at login: \(error.localizedDescription)\n\nSystem Settings > General > Login Items controls this too."
        }
    }
}
