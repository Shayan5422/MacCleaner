import Foundation
import Observation
import ServiceManagement

/// Registers the background agent with `SMAppService`, the supported way for
/// an app to run work in the background. macOS lists it under System Settings ›
/// General › Login Items & Extensions, where people can turn it off at any time.
@MainActor
struct AutomationAgentController {
    static let plistName = "com.maccleaner.MacCleaner.automation.plist"

    enum Status: Equatable {
        case enabled, requiresApproval, notRegistered, notFound, unavailable(String)

        var title: String {
            switch self {
            case .enabled: return "Active"
            case .requiresApproval: return "Waiting for your approval"
            case .notRegistered: return "Off"
            case .notFound: return "Agent missing from the app bundle"
            case .unavailable(let reason): return reason
            }
        }
    }

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    var status: Status {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unavailable("Unknown status")
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
final class AutomationViewModel {
    let services: AppServices
    private let store: AutomationStore
    private let runnerFactory: () -> AutomationRunner
    private let agent = AutomationAgentController()

    var configuration: AutomationConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            store.save(configuration)
        }
    }
    private(set) var state: AutomationState
    private(set) var history: [AutomationRunRecord] = []
    private(set) var agentStatus: AutomationAgentController.Status = .notRegistered
    private(set) var isRunning = false
    private(set) var lastRunMessage: String?
    var errorMessage: String?
    var showRunNowConfirmation = false
    private(set) var notificationsAuthorized = false

    init(services: AppServices, store: AutomationStore = AutomationStore(), runnerFactory: @escaping () -> AutomationRunner) {
        self.services = services
        self.store = store
        self.runnerFactory = runnerFactory
        configuration = store.loadConfiguration()
        state = store.loadState()
        refresh()
    }

    var availableCategories: [AutomationCategory] {
        let runner = runnerFactory()
        return AutomationCategory.all.filter { category in
            JunkCategory.category(id: category.id) != nil || runner.extraProviders[category.id] != nil
        }
    }

    var nextRunDate: Date? {
        guard configuration.isEnabled, configuration.scheduleEnabled else { return nil }
        if let pending = state.pendingCleanupSince { return pending.addingTimeInterval(AutomationRunner.gracePeriod) }
        return AutomationSchedule.nextSlot(for: configuration, after: Date())
    }

    func refresh() {
        state = store.loadState()
        history = store.loadHistory()
        agentStatus = agent.status
        Task {
            notificationsAuthorized = await services.notifications.isAuthorized()
        }
    }

    /// Turns automation on or off, registering the background agent.
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        if enabled {
            do {
                try agent.register()
                configuration.isEnabled = true
                // The first scheduled run happens at the next slot, not immediately.
                var newState = store.loadState()
                newState.lastScheduledRun = Date()
                store.save(newState)
                Task { await services.notifications.requestAuthorization(); refresh() }
                services.logger.info("Automation turned on (\(configuration.mode.rawValue), \(configuration.frequency.rawValue))", category: .automation)
            } catch {
                configuration.isEnabled = false
                errorMessage = "macOS didn't allow the background agent: \(error.localizedDescription). You can allow Mac Cleaner in System Settings › General › Login Items & Extensions."
            }
        } else {
            configuration.isEnabled = false
            Task {
                try? await agent.unregister()
                refresh()
            }
            services.logger.info("Automation turned off", category: .automation)
        }
        refresh()
    }

    func toggleCategory(_ id: String, on: Bool) {
        if on { configuration.categories.insert(id) } else { configuration.categories.remove(id) }
    }

    func skipPendingCleanup() {
        var newState = store.loadState()
        newState.skipPendingCleanup = true
        store.save(newState)
        refresh()
    }

    func runNow() {
        guard !isRunning else { return }
        isRunning = true
        lastRunMessage = nil
        let runner = runnerFactory()
        Task {
            let record = await runner.runNow()
            isRunning = false
            lastRunMessage = record.message
            refresh()
        }
    }

    func clearHistory() {
        store.clearHistory()
        refresh()
    }

    func openLoginItems() {
        agent.openLoginItemsSettings()
    }

    func requestNotifications() {
        Task {
            _ = await services.notifications.requestAuthorization()
            notificationsAuthorized = await services.notifications.isAuthorized()
            if !notificationsAuthorized { services.permissions.open(.notifications) }
        }
    }
}
