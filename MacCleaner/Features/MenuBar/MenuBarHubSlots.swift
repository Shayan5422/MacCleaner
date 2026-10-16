import SwiftUI

// Integration points for parts of the menu bar hub that other features own.
//
// The coordinator replaces these placeholders at integration:
// • `MenuBarProtectionSlot`'s body with `AntivirusMenuBarSection(model: environment.antivirus)`
// • `MenuBarPortsSlot`'s body with `NetworkMenuBarSection(model: environment.network)`
// • `MenuBarActivitySlot`'s body with Guardian's `ProtectionActivityFeedView(log:onOpen:)`
// • `MenuBarStatus.current(_:)` with values read from `environment.antivirus` and `environment.network`
//
// Each slot gets the full width of the popover (332 pt inside its padding). Wrap
// content in `MenuBarCard` so it matches the hub's other sections; use
// `MenuBarHubRow` for list rows (ports with a stop button, activity events).

/// Values the hub shows from features other parts of the app own. Every field is
/// optional: nil means "not available", and the hub says so instead of guessing.
struct MenuBarStatus: Equatable, Sendable {
    /// Ports opened by your projects (the label can show the count).
    var openPortCount: Int?
    var protectionState: MenuBarProtectionState?

    init(openPortCount: Int? = nil, protectionState: MenuBarProtectionState? = nil) {
        self.openPortCount = openPortCount
        self.protectionState = protectionState
    }
}

/// The antivirus' state, as the hub's Protection tile and header show it.
enum MenuBarProtectionState: Equatable, Sendable {
    /// Real-time protection is on and nothing needs attention.
    case protected
    /// Protection is on but something needs a look (for example outdated signatures).
    case attention(String)
    /// Threats were found and not handled yet. Turns the menu bar dot red.
    case threats(Int)
    /// Real-time protection is turned off.
    case off
    /// A scan is running.
    case scanning
}

extension MenuBarStatus {
    /// The current values. Placeholder until integration: fill it from
    /// `environment.network` (open project ports) and `environment.antivirus` (protection).
    @MainActor
    static func current(_ environment: AppEnvironment) -> MenuBarStatus {
        MenuBarStatus()
    }
}

/// Real-time protection, threats and Quick Scan. Placeholder until integration.
struct MenuBarProtectionSlot: View {
    let environment: AppEnvironment

    var body: some View {
        MenuBarCard(title: "Protection", symbol: "shield.lefthalf.filled", tint: AppSection.antivirus.tint) {
            MenuBarOpenSectionRow(text: "Scan for viruses and check what's protected.", section: .antivirus, environment: environment)
        }
    }
}

/// Open ports with Stop buttons. Placeholder until integration.
struct MenuBarPortsSlot: View {
    let environment: AppEnvironment

    var body: some View {
        MenuBarCard(title: "Open Ports", symbol: "point.3.connected.trianglepath.dotted", tint: AppSection.network.tint) {
            MenuBarOpenSectionRow(text: "See which ports your projects opened and stop them.", section: .network, environment: environment)
        }
    }
}

/// Recent protection events. Placeholder until integration (Guardian's activity feed);
/// until then it lists the newest events of `ProtectionEventLog`.
struct MenuBarActivitySlot: View {
    let environment: AppEnvironment

    var body: some View {
        MenuBarCard(title: "Activity", symbol: "list.bullet.rectangle", tint: AppSection.security.tint) {
            MenuBarEventList(log: .shared, limit: 8, environment: environment)
        }
    }
}
