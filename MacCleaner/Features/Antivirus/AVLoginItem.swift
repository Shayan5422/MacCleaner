import Foundation
import ServiceManagement

/// "Open Mac Cleaner at login", so real-time protection starts with the Mac. Uses
/// `SMAppService.mainApp`; macOS lists it under System Settings › General › Login Items.
@MainActor
struct AVLoginItemController {
    enum Status: Equatable, Sendable {
        case enabled, requiresApproval, notRegistered, notFound

        var title: String {
            switch self {
            case .enabled: return "On"
            case .requiresApproval: return "Waiting for your approval in System Settings"
            case .notRegistered: return "Off"
            case .notFound: return "Not available for this copy of the app"
            }
        }
    }

    init() {}

    var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    /// Registers or unregisters the app as a login item.
    func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
