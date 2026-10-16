import Foundation
import Testing
@testable import MacCleaner

/// Records what the background agent asked the Antivirus module to do.
final class AVRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AutomationAntivirusRequest] = []

    func append(_ request: AutomationAntivirusRequest) { lock.withLock { stored.append(request) } }
    var requests: [AutomationAntivirusRequest] { lock.withLock { stored } }
}

@Suite("Antivirus automation hooks")
struct AVAutomationHookTests {
    private func runner(store: AutomationStore, log: AVRequestLog, updated: Bool, threats: Int = 0) -> AutomationRunner {
        var runner = AutomationRunner(store: store)
        runner.antivirus = { request in
            log.append(request)
            return AutomationAntivirusResult(summary: request.quickScan ? "\(threats) threats found" : "Virus definitions updated.",
                                             alertCount: threats, definitionsUpdated: updated, failed: false)
        }
        return runner
    }

    @Test func decodesConfigurationsSavedBeforeTheAntivirusOptions() throws {
        let directory = try AVTestFolder("AVAutomation")
        let store = AutomationStore(directory: directory.url)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AutomationConfiguration())) as! [String: Any]
        legacy.removeValue(forKey: "antivirusDefinitionsUpdate")
        legacy.removeValue(forKey: "antivirusQuickScan")
        legacy["isEnabled"] = true
        legacy["mode"] = "clean"
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.child("Automation.json"))
        let loaded = store.loadConfiguration()
        #expect(loaded.isEnabled)
        #expect(loaded.mode == .clean)
        #expect(!loaded.updatesVirusDefinitions)
        #expect(!loaded.runsVirusScan)
    }

    @Test func updatesDefinitionsOnEveryCheckAndRecordsOnlyChanges() async throws {
        let directory = try AVTestFolder("AVAutomation")
        let store = AutomationStore(directory: directory.url)
        var configuration = AutomationConfiguration()
        configuration.isEnabled = true
        configuration.updatesVirusDefinitions = true
        configuration.scheduleEnabled = false
        store.save(configuration)
        #expect(store.loadConfiguration().updatesVirusDefinitions)

        let log = AVRequestLog()
        let quiet = await runner(store: store, log: log, updated: false).runIfDue()
        #expect(log.requests == [AutomationAntivirusRequest(updateDefinitions: true, quickScan: false)])
        #expect(quiet.isEmpty)
        #expect(store.loadHistory().isEmpty)

        let changed = await runner(store: store, log: log, updated: true).runIfDue()
        #expect(changed.first?.trigger == .virusDefinitions)
        #expect(changed.first?.outcome == .updated)
        #expect(store.loadHistory().count == 1)
    }

    @Test func runsAQuickScanWithScheduledRuns() async throws {
        let directory = try AVTestFolder("AVAutomation")
        let store = AutomationStore(directory: directory.url)
        var configuration = AutomationConfiguration()
        configuration.isEnabled = true
        configuration.runsVirusScan = true
        configuration.frequency = .daily
        configuration.categories = []
        store.save(configuration)
        var state = AutomationState()
        state.lastScheduledRun = Date(timeIntervalSinceNow: -3 * 86_400)
        store.save(state)

        let log = AVRequestLog()
        let records = await runner(store: store, log: log, updated: false, threats: 2).runIfDue()
        #expect(log.requests.contains(AutomationAntivirusRequest(updateDefinitions: false, quickScan: true)))
        #expect(!log.requests.contains(AutomationAntivirusRequest(updateDefinitions: true, quickScan: false)))
        let scan = try #require(records.first { $0.message.hasPrefix("Virus scan:") })
        #expect(scan.itemCount == 2)
        #expect(scan.outcome == .notified)
        #expect(store.loadState().lastVirusScan != nil)
    }

    @Test func doesNothingWhenTurnedOff() async throws {
        let directory = try AVTestFolder("AVAutomation")
        let store = AutomationStore(directory: directory.url)
        var configuration = AutomationConfiguration()
        configuration.isEnabled = true
        configuration.scheduleEnabled = false
        store.save(configuration)
        let log = AVRequestLog()
        _ = await runner(store: store, log: log, updated: true).runIfDue()
        #expect(log.requests.isEmpty)
    }

    @Test func headlessQuickScanNeverTouchesProtectedFoldersOrPrompts() async {
        let plan = await AVScanPlanner.quickScan(sources: .live(includesPrivacyProtectedFolders: false, readsLoginItems: false), kind: .scheduled)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(!plan.targets.contains { $0.path == home + "/Downloads" || $0.path == home + "/Desktop" || $0.path == home + "/Documents" })
        #expect(plan.targets.allSatisfy { !$0.isPrivacyProtected })
        #expect(plan.kind == .scheduled)
    }
}
