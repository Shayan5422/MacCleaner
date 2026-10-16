import AppKit
import Foundation
import Observation

/// State of the Network Check tab.
@MainActor
@Observable
final class NetworkCheckModel {
    private(set) var report: NetCheckReport?
    private(set) var isChecking = false
    /// Device address → host name (reverse DNS, only when turned on in Settings).
    private(set) var deviceNames: [String: String] = [:]

    let preferences: NetworkPreferences
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    /// A report older than this is refreshed when the tab is shown again.
    static let freshness: TimeInterval = 60

    init(preferences: NetworkPreferences) {
        self.preferences = preferences
    }

    /// Runs the check when there is no recent report.
    func appeared() {
        if let report, Date().timeIntervalSince(report.date) < Self.freshness { return }
        check()
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        checkTask = Task {
            let result = await NetChecker.run()
            report = result
            isChecking = false
            if preferences.reverseDNS { await resolveDeviceNames(result.devices) }
        }
    }

    private func resolveDeviceNames(_ devices: [NetDevice]) async {
        let addresses = devices.filter { !$0.isThisMac }.map(\.address)
        guard !addresses.isEmpty else { return }
        let names = await NetReverseDNS.shared.names(for: addresses)
        guard preferences.reverseDNS else { return }
        deviceNames.merge(names) { _, new in new }
    }

    var attentionCount: Int { report?.attentionCount ?? 0 }

    func open(_ action: NetCheckAction) {
        NSWorkspace.shared.open(action.url)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
