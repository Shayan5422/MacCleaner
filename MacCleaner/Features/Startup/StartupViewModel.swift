import AppKit
import Foundation
import Observation

/// A change to a startup item that needs the person's confirmation first.
enum StartupPendingAction: Identifiable, Sendable {
    case disable(StartupItem)
    case enable(StartupItem)
    case removeLoginItem(StartupItem)

    var id: String {
        switch self {
        case .disable(let item): return "disable|" + item.id
        case .enable(let item): return "enable|" + item.id
        case .removeLoginItem(let item): return "remove|" + item.id
        }
    }

    var item: StartupItem {
        switch self {
        case .disable(let item), .enable(let item), .removeLoginItem(let item): return item
        }
    }

    var title: String {
        switch self {
        case .disable(let item): return "Turn off “\(item.name)”?"
        case .enable(let item): return "Turn on “\(item.name)”?"
        case .removeLoginItem(let item): return "Remove “\(item.name)” from login items?"
        }
    }

    var message: String {
        switch self {
        case .disable(let item):
            return item.consequenceOfDisabling + "\n\nMac Cleaner turns it off with launchctl (disable, then stop) for your account only. You can turn it back on here at any time."
        case .enable(let item):
            return "It starts now and at every login, as its property list describes (\(item.triggerSummary.lowercased()))."
        case .removeLoginItem(let item):
            return item.consequenceOfDisabling + " The app itself isn't removed, and you can add it back in System Settings › General › Login Items & Extensions."
        }
    }

    var confirmTitle: String {
        switch self {
        case .disable: return "Turn Off"
        case .enable: return "Turn On"
        case .removeLoginItem: return "Remove"
        }
    }

    var isDestructive: Bool {
        if case .enable = self { return false }
        return true
    }
}

@MainActor
@Observable
final class StartupViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, running, needsReview, turnedOff

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .running: return "Running"
            case .needsReview: return "Needs Review"
            case .turnedOff: return "Turned Off"
            }
        }
    }

    /// A group of items shown as one card.
    struct Section: Identifiable {
        enum ID: String {
            case loginItems, userAgents, appItems, systemItems
        }

        var id: ID
        var title: String
        var subtitle: String
        var symbol: String
        var items: [StartupItem]
        /// Items in the group before filtering and search.
        var totalCount: Int
    }

    let services: AppServices
    let cleanupFlow = CleanupFlow()

    private(set) var inventory: StartupInventory?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var progressMessage = ""
    private(set) var loginItemsAccess: StartupAutomationAccess?
    private(set) var loginItemsError: String?
    private(set) var isRequestingAccess = false
    private(set) var busyItemIDs: Set<String> = []

    var searchText = ""
    var filter: Filter = .all
    var inspectedItem: StartupItem?
    var pendingAction: StartupPendingAction?
    var alertMessage: String?
    var statusMessage: String?

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard inventory == nil, !isLoading else { return }
        await refresh()
    }

    /// Reads everything again. A refresh requested while one is running runs once more afterwards,
    /// so changes made in the meantime are always reflected.
    func refresh() async {
        if isLoading {
            refreshRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshRequested = false
            await load()
        } while refreshRequested
    }

    private var refreshRequested = false

    private func load() async {
        progress = 0
        progressMessage = "Reading startup items…"

        // Login items need Automation access to System Events; never prompt here.
        let access = await StartupLoginItemsService.automationAccess(promptIfNeeded: false)
        loginItemsAccess = access
        var records: [StartupLoginItemRecord]?
        if access == .granted {
            do {
                records = try StartupLoginItemsService.readLoginItems()
                loginItemsError = nil
            } catch StartupLoginItemsError.notAuthorized {
                loginItemsAccess = .denied
            } catch {
                loginItemsError = error.localizedDescription
            }
        }

        let result = await StartupInventoryScanner().scan(loginItems: records) { [weak self] fraction, message in
            Task { @MainActor [weak self] in
                self?.progress = fraction
                self?.progressMessage = message
            }
        }
        inventory = result
        if let inspected = inspectedItem {
            inspectedItem = result.items.first { $0.id == inspected.id }
        }
        services.logger.info(
            "Startup items reviewed: \(result.items.count) items, \(result.potentiallyUnnecessary.count) flagged for review, login items \(result.includesLoginItems ? "included" : "not readable")",
            category: .startup
        )
    }

    /// Asks macOS for Automation access to System Events (shows the system prompt if needed).
    func requestLoginItemsAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        let access = await StartupLoginItemsService.automationAccess(promptIfNeeded: true)
        loginItemsAccess = access
        if access == .granted { await refresh() }
    }

    // MARK: - Derived state

    var items: [StartupItem] { inventory?.items ?? [] }

    func count(of kind: StartupItemKind) -> Int { items.filter { $0.kind == kind }.count }

    var loginItemCount: Int { count(of: .loginItem) }
    var userAgentCount: Int { count(of: .userAgent) }
    var runningUserAgentCount: Int { items.filter { $0.kind == .userAgent && $0.state.isRunning }.count }
    var appItemCount: Int { count(of: .appBackgroundItem) }
    var systemItemCount: Int { items.filter { $0.kind == .systemAgent || $0.kind == .systemDaemon }.count }
    var needsReviewCount: Int { items.filter(\.isPotentiallyUnnecessary).count }
    var runningCount: Int { items.filter { $0.state.isRunning }.count }

    var sections: [Section] {
        let visible = items.filter { matchesFilter($0) && matchesSearch($0) }
        func make(_ id: Section.ID, kinds: Set<StartupItemKind>, title: String, subtitle: String, symbol: String) -> Section {
            Section(id: id, title: title, subtitle: subtitle, symbol: symbol,
                    items: visible.filter { kinds.contains($0.kind) },
                    totalCount: items.filter { kinds.contains($0.kind) }.count)
        }
        return [
            make(.loginItems, kinds: [.loginItem], title: "Open at Login",
                 subtitle: "Apps that open when you log in.", symbol: StartupItemKind.loginItem.symbolName),
            make(.userAgents, kinds: [.userAgent], title: "Your Launch Agents",
                 subtitle: "Background programs that start for your account. You can turn these off.", symbol: StartupItemKind.userAgent.symbolName),
            make(.appItems, kinds: [.appBackgroundItem], title: "App Background Items",
                 subtitle: "Helpers inside apps. Each app manages its own; macOS doesn't let other apps change them.", symbol: StartupItemKind.appBackgroundItem.symbolName),
            make(.systemItems, kinds: [.systemAgent, .systemDaemon], title: "System-wide (read-only)",
                 subtitle: "Installed for all users in /Library. Changing them requires an administrator.", symbol: "lock.fill"),
        ]
    }

    private func matchesFilter(_ item: StartupItem) -> Bool {
        switch filter {
        case .all: return true
        case .running: return item.state.isRunning
        case .needsReview: return item.isPotentiallyUnnecessary
        case .turnedOff: return item.state.isOff || item.isEnabled == false
        }
    }

    private func matchesSearch(_ item: StartupItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || item.searchableText.localizedCaseInsensitiveContains(query)
    }

    func isBusy(_ item: StartupItem) -> Bool { busyItemIDs.contains(item.id) }

    // MARK: - Actions

    func requestToggle(_ item: StartupItem, enable: Bool) {
        guard item.canToggle else { return }
        pendingAction = enable ? .enable(item) : .disable(item)
    }

    func requestRemoveLoginItem(_ item: StartupItem) {
        guard item.canRemoveLoginItem else { return }
        pendingAction = .removeLoginItem(item)
    }

    /// Performs a confirmed change.
    func perform(_ action: StartupPendingAction) async {
        if pendingAction?.id == action.id { pendingAction = nil }
        let item = action.item
        busyItemIDs.insert(item.id)
        let client = LaunchctlClient()
        do {
            switch action {
            case .disable:
                guard let label = item.label else { throw LaunchctlError.invalidLabel }
                try await client.disableUserAgent(label: label)
                statusMessage = "“\(item.name)” is turned off and won't start at login."
                services.logger.info("Turned off a user launch agent", category: .startup)
            case .enable:
                guard let label = item.label, let plist = item.plistPath else { throw LaunchctlError.invalidLabel }
                try await client.enableUserAgent(label: label, plistPath: plist)
                statusMessage = "“\(item.name)” is turned on."
                services.logger.info("Turned on a user launch agent", category: .startup)
            case .removeLoginItem:
                try StartupLoginItemsService.deleteLoginItem(named: item.name, expectedPath: item.targetPath)
                statusMessage = "“\(item.name)” no longer opens at login."
                services.logger.info("Removed a login item", category: .startup)
            }
        } catch StartupLoginItemsError.notAuthorized {
            loginItemsAccess = .denied
            alertMessage = StartupLoginItemsError.notAuthorized.localizedDescription
        } catch {
            alertMessage = error.localizedDescription
            services.logger.warning("Changing a startup item failed: \(String(describing: type(of: error)))", category: .startup)
        }
        busyItemIDs.remove(item.id)
        await refresh()
    }

    /// Moves a user launch agent's property list to the Trash (through the shared cleanup flow),
    /// then stops the agent so it doesn't keep running until logout.
    func requestMoveToTrash(_ item: StartupItem) {
        guard item.canMoveToTrash, let plist = item.plistPath else { return }
        if inspectedItem != nil {
            // Let the detail sheet close before the cleanup confirmation appears.
            inspectedItem = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.startTrash(item, plist: plist)
            }
        } else {
            startTrash(item, plist: plist)
        }
    }

    private func startTrash(_ item: StartupItem, plist: String) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: plist))?[.size] as? NSNumber)?.int64Value ?? 0
        let cleanupItem = CleanupItem(path: plist, purpose: .applicationData, snapshot: FileSnapshot.capture(path: plist),
                                      estimatedBytes: size, category: "Launch agents")
        let label = item.label
        cleanupFlow.requestCleanup(
            title: "Remove “\(item.name)”",
            items: [cleanupItem],
            services: services,
            regenerableData: false,
            warning: "The property list moves to the Trash and the agent stops now. The program it runs stays installed, and the app that created it may add it again the next time it opens. "
                + item.consequenceOfDisabling
        ) { [weak self] report in
            guard let self else { return }
            let removed = report.removed.contains { $0.path == PathUtilities.normalize(plist) }
            Task { @MainActor in
                if removed, let label, LaunchctlClient.isValidLabel(label), !LaunchctlClient.isProtectedLabel(label) {
                    do {
                        try await LaunchctlClient().bootoutUserAgent(label: label)
                    } catch {
                        self.alertMessage = "The property list was moved to the Trash, but the agent couldn't be stopped now: \(error.localizedDescription) It won't start at your next login."
                    }
                    self.services.logger.info("Moved a user launch agent to the Trash", category: .startup)
                }
                await self.refresh()
            }
        }
    }

    // MARK: - Shortcuts

    func openLoginItemsSettings() { services.permissions.open(.loginItems) }

    func openAutomationSettings() { services.permissions.open(.automation) }

    func reveal(_ item: StartupItem) {
        if let path = item.plistPath ?? item.targetPath { FinderActions.reveal(path) }
    }
}
