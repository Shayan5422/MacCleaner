import Foundation
import Observation

/// State of the Ports & Network page: the Ports tab (PortPilot inside Mac Cleaner), the Connections monitor with the
/// Network Shield, and the Network Check. Also feeds the menu bar's Ports section.
///
/// Lifecycle:
/// - `start()` at launch: background work the settings ask for while Mac Cleaner runs — the Network Shield (every
///   ~20 s, only once threat feeds are loaded) and a cheap port watch (every ~10 s) that keeps
///   `openProjectPortCount` / `openPortCount` current and drives new-port notifications and activity events.
/// - The page and the menu bar popover call `acquire()` / `release()` (the views do it themselves): while either
///   shows the Ports list, it rescans at the refresh interval from Settings.
@MainActor
@Observable
final class NetworkViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case ports = "Ports"
        case connections = "Connections"
        case check = "Network Check"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .ports: return "point.3.connected.trianglepath.dotted"
            case .connections: return "arrow.left.arrow.right"
            case .check: return "checkmark.shield"
            }
        }
    }

    let services: AppServices
    /// Opens another section (set by `AppEnvironment.connectNavigation`).
    var navigate: ((AppSection) -> Void)?

    let preferences: NetworkPreferences
    let ports: PortsModel
    let connections: ConnectionsModel
    let check: NetworkCheckModel
    let shield: NetShield

    var tab: Tab = .ports { didSet { if tab != oldValue { updateTabVisibility() } } }

    /// Focus request for the search field of the current tab (⌘F).
    var searchFocusRequest = 0

    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var holdsPortsClaim = false
    @ObservationIgnored private var holdsConnectionsClaim = false
    @ObservationIgnored private var isStarted = false

    init(services: AppServices) {
        self.services = services
        let preferences = NetworkPreferences.shared
        self.preferences = preferences
        let ports = PortsModel(preferences: preferences, notifications: services.notifications)
        self.ports = ports
        let shield = NetShield(notifications: services.notifications)
        self.shield = shield
        connections = ConnectionsModel(preferences: preferences, shield: shield, ports: ports)
        check = NetworkCheckModel(preferences: preferences)
        shield.isEnabled = { [weak preferences] in preferences?.shieldEnabled ?? false }
    }

    /// For tests: injected models (no polling, nothing posted outside the test).
    init(services: AppServices, preferences: NetworkPreferences, ports: PortsModel, shield: NetShield) {
        self.services = services
        self.preferences = preferences
        self.ports = ports
        self.shield = shield
        connections = ConnectionsModel(preferences: preferences, shield: shield, ports: ports)
        check = NetworkCheckModel(preferences: preferences)
        shield.isEnabled = { [weak preferences] in preferences?.shieldEnabled ?? false }
    }

    // MARK: - App lifecycle (coordinator)

    /// Starts the background work while Mac Cleaner runs (idempotent): the Network Shield and the cheap port watch
    /// behind the open-port counts, new-port notifications and activity events.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        shield.start()
        ports.backgroundWatch = true
    }

    /// Stops all background work (the page and the popover still scan while they are visible).
    func stop() {
        isStarted = false
        shield.stop()
        ports.backgroundWatch = false
    }

    /// The menu bar popover (or anything else that shows the Ports list) appeared. Balance with `release()`.
    func acquire() {
        ports.acquireVisibility()
    }

    func release() {
        ports.releaseVisibility()
    }

    // MARK: - Counts (menu bar label, status tiles)

    /// Distinct ports open in projects (git or package folders) that the person didn't hide.
    var openProjectPortCount: Int { ports.projectPortCount }
    /// Distinct ports open in projects and background services (Homebrew services, tunnels, launchd agents) that
    /// the person didn't hide. Apps' and macOS's ports aren't counted.
    var openPortCount: Int { ports.devPortCount }
    /// Connections to known malicious servers seen since launch whose process still runs.
    var activeThreatCount: Int { shield.activeHits.count }

    // MARK: - Page lifecycle

    func pageAppeared() {
        pageVisible = true
        updateTabVisibility()
    }

    func pageDisappeared() {
        pageVisible = false
        updateTabVisibility()
    }

    private func updateTabVisibility() {
        let wantsPorts = pageVisible && tab == .ports
        if wantsPorts != holdsPortsClaim {
            holdsPortsClaim = wantsPorts
            wantsPorts ? ports.acquireVisibility() : ports.releaseVisibility()
        }
        let wantsConnections = pageVisible && tab == .connections
        if wantsConnections != holdsConnectionsClaim {
            holdsConnectionsClaim = wantsConnections
            wantsConnections ? connections.acquireVisibility() : connections.releaseVisibility()
        }
        if pageVisible && tab == .check { check.appeared() }
    }

    /// ⌘R on the page.
    func refreshCurrentTab() {
        switch tab {
        case .ports: ports.refreshNow()
        case .connections: connections.refreshNow()
        case .check: check.check()
        }
    }

    /// ⌘F on the page.
    func focusSearch() {
        if tab == .check { tab = .ports }
        searchFocusRequest += 1
    }
}
