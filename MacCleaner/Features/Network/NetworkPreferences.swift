import Foundation
import Observation

/// Settings of the Ports & Network page, stored in `UserDefaults` under keys prefixed `network.`.
/// Pass a separate `UserDefaults` suite in tests.
@MainActor
@Observable
final class NetworkPreferences {
    /// The instance the page, the menu bar section and the Settings window share.
    static let shared = NetworkPreferences()

    enum Key {
        static let refreshInterval = "network.refreshInterval"
        static let gracefulTimeout = "network.gracefulTimeout"
        static let includeOtherUsers = "network.includeOtherUsers"
        static let showApps = "network.showApps"
        static let showSystem = "network.showSystem"
        static let notifyNewPorts = "network.notifyNewPorts"
        static let shieldEnabled = "network.shieldEnabled"
        static let reverseDNS = "network.reverseDNS"
        static let hiddenGroupIDs = "network.hiddenGroupIDs"
        static let hiddenPorts = "network.hiddenPorts"
        static let sortOrder = "network.sortOrder"

        static let all = [refreshInterval, gracefulTimeout, includeOtherUsers, showApps, showSystem, notifyNewPorts,
                          shieldEnabled, reverseDNS, hiddenGroupIDs, hiddenPorts, sortOrder]
    }

    /// Seconds between Ports rescans while the page is visible.
    static let refreshChoices: [Double] = [1, 2, 3, 5, 10, 30]
    /// Seconds Stop waits after SIGTERM before it sends SIGKILL.
    static let gracefulTimeoutRange: ClosedRange<Double> = 1...10
    /// CPU % (of one core) above which a group is highlighted as heavy.
    static let heavyCPUThreshold: Double = 80
    /// Memory above which a group is highlighted as heavy.
    static let heavyMemoryBytes: UInt64 = 1_500_000_000

    static let defaultRefreshInterval: Double = 3
    static let defaultGracefulTimeout: Double = 3

    private let defaults: UserDefaults

    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }
    var gracefulTimeout: Double {
        didSet { defaults.set(gracefulTimeout, forKey: Key.gracefulTimeout) }
    }
    /// Scan other users' and macOS's listening ports too (they land in the System section).
    var includeOtherUsers: Bool {
        didSet { defaults.set(includeOtherUsers, forKey: Key.includeOtherUsers) }
    }
    var showApps: Bool {
        didSet { defaults.set(showApps, forKey: Key.showApps) }
    }
    var showSystem: Bool {
        didSet { defaults.set(showSystem, forKey: Key.showSystem) }
    }
    /// Notify when a project or background service opens a new port (only while Mac Cleaner runs).
    var notifyNewPorts: Bool {
        didSet { defaults.set(notifyNewPorts, forKey: Key.notifyNewPorts) }
    }
    /// Network Shield: check connections against the downloaded threat feeds in the background.
    var shieldEnabled: Bool {
        didSet { defaults.set(shieldEnabled, forKey: Key.shieldEnabled) }
    }
    /// Look up host names of remote addresses and network devices (sends DNS queries).
    var reverseDNS: Bool {
        didSet { defaults.set(reverseDNS, forKey: Key.reverseDNS) }
    }
    /// Rows the person hid ("Hide This Item").
    var hiddenGroupIDs: [String] {
        didSet { defaults.set(hiddenGroupIDs, forKey: Key.hiddenGroupIDs) }
    }
    var hiddenPorts: [UInt16] {
        didSet { defaults.set(hiddenPorts.map(Int.init), forKey: Key.hiddenPorts) }
    }
    var sortOrder: PortSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let refresh = defaults.object(forKey: Key.refreshInterval) as? Double ?? Self.defaultRefreshInterval
        refreshInterval = Self.refreshChoices.contains(refresh) ? refresh : Self.defaultRefreshInterval
        let timeout = defaults.object(forKey: Key.gracefulTimeout) as? Double ?? Self.defaultGracefulTimeout
        gracefulTimeout = min(max(timeout, Self.gracefulTimeoutRange.lowerBound), Self.gracefulTimeoutRange.upperBound)
        includeOtherUsers = defaults.bool(forKey: Key.includeOtherUsers)
        showApps = defaults.bool(forKey: Key.showApps)
        showSystem = defaults.bool(forKey: Key.showSystem)
        notifyNewPorts = defaults.bool(forKey: Key.notifyNewPorts)
        shieldEnabled = defaults.object(forKey: Key.shieldEnabled) as? Bool ?? true
        reverseDNS = defaults.bool(forKey: Key.reverseDNS)
        hiddenGroupIDs = defaults.stringArray(forKey: Key.hiddenGroupIDs) ?? []
        hiddenPorts = (defaults.array(forKey: Key.hiddenPorts) as? [Int] ?? []).compactMap { UInt16(exactly: $0) }
        sortOrder = defaults.string(forKey: Key.sortOrder).flatMap(PortSortOrder.init(rawValue:)) ?? .port
    }

    /// "Include other users' and system ports" on the Ports tab: scans them and shows the System section.
    var includesSystemPorts: Bool {
        get { includeOtherUsers && showSystem }
        set {
            includeOtherUsers = newValue
            showSystem = newValue
        }
    }

    var hiddenItemCount: Int { hiddenGroupIDs.count + hiddenPorts.count }

    func unhideAll() {
        hiddenGroupIDs.removeAll()
        hiddenPorts.removeAll()
    }

    func resetToDefaults() {
        for key in Key.all { defaults.removeObject(forKey: key) }
        let fresh = NetworkPreferences(defaults: defaults)
        refreshInterval = fresh.refreshInterval
        gracefulTimeout = fresh.gracefulTimeout
        includeOtherUsers = fresh.includeOtherUsers
        showApps = fresh.showApps
        showSystem = fresh.showSystem
        notifyNewPorts = fresh.notifyNewPorts
        shieldEnabled = fresh.shieldEnabled
        reverseDNS = fresh.reverseDNS
        hiddenGroupIDs = fresh.hiddenGroupIDs
        hiddenPorts = fresh.hiddenPorts
        sortOrder = fresh.sortOrder
    }
}
