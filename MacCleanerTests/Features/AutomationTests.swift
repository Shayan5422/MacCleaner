import Foundation
import Testing
@testable import MacCleaner

@Suite("Automation schedule")
struct AutomationScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    @Test func dailyScheduleIsDueOncePerDay() {
        var configuration = AutomationConfiguration()
        configuration.frequency = .daily
        configuration.hour = 10
        configuration.minute = 0
        let now = date("2026-10-15T12:00:00Z")
        #expect(AutomationSchedule.isDue(configuration, lastRun: date("2026-10-14T10:30:00Z"), now: now, calendar: calendar))
        #expect(!AutomationSchedule.isDue(configuration, lastRun: date("2026-10-15T10:05:00Z"), now: now, calendar: calendar))
        #expect(!AutomationSchedule.isDue(configuration, lastRun: date("2026-10-15T09:00:00Z"), now: date("2026-10-15T09:30:00Z"), calendar: calendar))
    }

    @Test func weeklyScheduleUsesWeekday() {
        var configuration = AutomationConfiguration()
        configuration.frequency = .weekly
        configuration.weekday = 2 // Monday
        configuration.hour = 9
        let previous = AutomationSchedule.previousSlot(for: configuration, atOrBefore: date("2026-10-15T12:00:00Z"), calendar: calendar)
        #expect(previous == date("2026-10-12T09:00:00Z"))
        let next = AutomationSchedule.nextSlot(for: configuration, after: date("2026-10-15T12:00:00Z"), calendar: calendar)
        #expect(next == date("2026-10-19T09:00:00Z"))
    }

    @Test func monthlyScheduleClampsDay() {
        var configuration = AutomationConfiguration()
        configuration.frequency = .monthly
        configuration.dayOfMonth = 31
        configuration.hour = 8
        let previous = AutomationSchedule.previousSlot(for: configuration, atOrBefore: date("2026-10-15T12:00:00Z"), calendar: calendar)
        #expect(previous == date("2026-09-28T08:00:00Z"))
    }

    @Test func disabledScheduleIsNeverDue() {
        var configuration = AutomationConfiguration()
        configuration.scheduleEnabled = false
        #expect(!AutomationSchedule.isDue(configuration, lastRun: nil, now: Date(), calendar: calendar))
    }
}

@Suite("Automation store & runner")
struct AutomationRunnerTests {
    /// A provider returning fixed candidates.
    private struct FixedProvider: SmartScanProvider {
        var area: SmartScanArea
        var candidates: [CleanupCandidate]
        func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
            SmartScanContribution(area: area, candidates: candidates)
        }
    }

    @Test func storeRoundTrips() throws {
        let tree = try TemporaryTree("Automation")
        let store = AutomationStore(directory: URL(fileURLWithPath: tree.root))
        var configuration = AutomationConfiguration()
        configuration.isEnabled = true
        configuration.mode = .clean
        configuration.categories = ["junk.logs"]
        store.save(configuration)
        #expect(store.loadConfiguration() == configuration)

        store.append(AutomationRunRecord(trigger: .manual, outcome: .dryRun, message: "test"))
        #expect(store.loadHistory().first?.message == "test")
        store.clearHistory()
        #expect(store.loadHistory().isEmpty)
    }

    @Test func onlySafeRegenerableItemsAreEligible() async throws {
        let tree = try TemporaryTree("Automation")
        let files = try TemporaryTree()
        func candidate(_ name: String, safety: CleanupSafety, purpose: DeletionPurpose) throws -> CleanupCandidate {
            let path = try files.makeFile(name)
            var usage = DiskUsage()
            usage.reclaimableBytes = 10
            return CleanupCandidate(path: path, categoryID: "x", categoryTitle: "x", usage: usage, safety: safety, purpose: purpose)
        }
        let provider = FixedProvider(area: .developer, candidates: [
            try candidate("safe-cache", safety: .safe, purpose: .developerData),
            try candidate("review-cache", safety: .review, purpose: .developerData),
            try candidate("document", safety: .safe, purpose: .userFile),
            try candidate("app-data", safety: .safe, purpose: .applicationData),
        ])
        var runner = AutomationRunner(store: AutomationStore(directory: URL(fileURLWithPath: tree.root)))
        runner.extraProviders = [AutomationCategory.developerCachesID: provider]
        var configuration = AutomationConfiguration()
        configuration.categories = [AutomationCategory.developerCachesID]
        let eligible = try await runner.eligibleCandidates(configuration: configuration)
        #expect(eligible.map { ($0.path as NSString).lastPathComponent } == ["safe-cache"])
    }

    @Test func disabledAutomationDoesNothing() async throws {
        let tree = try TemporaryTree("Automation")
        let runner = AutomationRunner(store: AutomationStore(directory: URL(fileURLWithPath: tree.root)))
        let records = await runner.runIfDue()
        #expect(records.isEmpty)
    }

    @Test func skippedAnnouncementIsHonored() async throws {
        let tree = try TemporaryTree("Automation")
        let store = AutomationStore(directory: URL(fileURLWithPath: tree.root))
        var configuration = AutomationConfiguration()
        configuration.isEnabled = true
        configuration.mode = .clean
        configuration.categories = []
        store.save(configuration)
        var state = AutomationState()
        state.lastScheduledRun = Date()
        state.pendingCleanupSince = Date().addingTimeInterval(-7200)
        state.pendingTrigger = .schedule
        state.skipPendingCleanup = true
        store.save(state)

        let records = await AutomationRunner(store: store).runIfDue()
        #expect(records.first?.outcome == .skipped)
        #expect(store.loadState().pendingCleanupSince == nil)
    }
}
