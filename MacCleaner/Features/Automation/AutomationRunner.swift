import Foundation

/// Result of a scheduled security scan, reported by the Security module.
struct AutomationSecurityResult: Sendable {
    var summary: String
    /// Number of threats plus suspicious findings.
    var alertCount: Int
}

/// What the background agent asks the Antivirus module to do.
struct AutomationAntivirusRequest: Sendable, Equatable {
    var updateDefinitions: Bool
    var quickScan: Bool
}

/// Reported by the Antivirus module. It posts its own notifications (threats found or moved to
/// the Virus Chest); the runner only records the run.
struct AutomationAntivirusResult: Sendable {
    var summary: String
    /// Threats found by the quick scan.
    var alertCount: Int
    var definitionsUpdated: Bool
    var failed: Bool
}

/// Performs automatic cleaning. Used both by the background agent (headless,
/// launched by launchd) and by "Run Now" in the app.
///
/// Policy: only `.safe` candidates with a regenerable purpose (`.junk`,
/// `.developerData`, `.privacyData` caches) from categories the person chose are
/// ever removed automatically; personal files and items needing review never are.
struct AutomationRunner: Sendable {
    var store = AutomationStore()
    /// Providers for the non-junk automation categories, keyed by `AutomationCategory` id.
    var extraProviders: [String: any SmartScanProvider] = [:]
    var securityScan: (@Sendable () async -> AutomationSecurityResult?)?
    /// Virus definition updates and scheduled quick virus scans (wired by the app to the Antivirus module).
    var antivirus: (@Sendable (AutomationAntivirusRequest) async -> AutomationAntivirusResult?)?
    var notifications: NotificationService = .shared
    var logger: ActivityLogger = .shared
    var historyStore = HistoryStore()

    /// Minimum time between storage-threshold runs, so a disk that stays full doesn't trigger hourly cleanups.
    static let thresholdCooldown: TimeInterval = 12 * 3600
    /// "Notify before cleaning" waits at least this long before acting.
    static let gracePeriod: TimeInterval = 45 * 60

    // MARK: - Entry points

    /// Called by the background agent about once an hour. Does nothing unless something is due.
    func runIfDue(now: Date = Date()) async -> [AutomationRunRecord] {
        let configuration = store.loadConfiguration()
        guard configuration.isEnabled else { return [] }
        var state = store.loadState()
        var records: [AutomationRunRecord] = []

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            if AutomationSchedule.isDue(configuration, lastRun: state.lastScheduledRun, now: now) || state.pendingCleanupSince != nil {
                let record = AutomationRunRecord(trigger: .schedule, outcome: .deferred, message: "Deferred because Low Power Mode is on.")
                store.append(record)
                records.append(record)
            }
            return records
        }

        // Virus definitions are checked on every agent run; the Antivirus updater itself limits
        // network checks to every 4 hours and never downloads a database more than once a day.
        if configuration.updatesVirusDefinitions,
           let record = await runAntivirus(AutomationAntivirusRequest(updateDefinitions: true, quickScan: false)) {
            records.append(record)
        }

        // 1. A cleanup announced earlier is due once the grace period has passed.
        if let pending = state.pendingCleanupSince {
            if state.skipPendingCleanup {
                let record = AutomationRunRecord(trigger: state.pendingTrigger ?? .schedule, outcome: .skipped, message: "Skipped at your request.")
                store.append(record)
                records.append(record)
                state.pendingCleanupSince = nil
                state.pendingTrigger = nil
                state.skipPendingCleanup = false
                store.save(state)
            } else if now.timeIntervalSince(pending) >= Self.gracePeriod {
                let trigger = state.pendingTrigger ?? .schedule
                state.pendingCleanupSince = nil
                state.pendingTrigger = nil
                store.save(state)
                let record = await performCleanup(configuration: configuration, trigger: trigger, announce: false)
                records.append(record)
            }
            return records
        }

        // 2. Schedule.
        if AutomationSchedule.isDue(configuration, lastRun: state.lastScheduledRun, now: now) {
            state.lastScheduledRun = now
            store.save(state)
            records.append(await execute(configuration: configuration, trigger: .schedule))
            if configuration.securityScanEnabled, let result = await runSecurityScan() {
                state = store.loadState()
                state.lastSecurityScan = now
                store.save(state)
                records.append(result)
            }
            if configuration.runsVirusScan,
               let result = await runAntivirus(AutomationAntivirusRequest(updateDefinitions: false, quickScan: true)) {
                state = store.loadState()
                state.lastVirusScan = now
                store.save(state)
                records.append(result)
            }
            return records
        }

        // 3. Low storage.
        if configuration.storageTriggerEnabled, let free = VolumeService.startupVolume()?.effectiveAvailable,
           free < Int64(configuration.storageTriggerGB) * 1_000_000_000,
           now.timeIntervalSince(state.lastThresholdRun ?? .distantPast) >= Self.thresholdCooldown {
            state.lastThresholdRun = now
            store.save(state)
            records.append(await execute(configuration: configuration, trigger: .storageThreshold))
            return records
        }

        // 4. Daily junk check.
        if configuration.junkAlertEnabled, now.timeIntervalSince(state.lastJunkCheck ?? .distantPast) >= 86_400 {
            state.lastJunkCheck = now
            store.save(state)
            if let record = await junkCheck(configuration: configuration) { records.append(record) }
        }
        return records
    }

    /// "Run Now" from the app: no grace period, but dry-run and categories still apply.
    func runNow() async -> AutomationRunRecord {
        let configuration = store.loadConfiguration()
        return await performCleanup(configuration: configuration, trigger: .manual, announce: false, forceClean: true)
    }

    // MARK: - Steps

    private func execute(configuration: AutomationConfiguration, trigger: AutomationRunRecord.Trigger) async -> AutomationRunRecord {
        switch configuration.mode {
        case .notifyOnly:
            return await notifyOnly(configuration: configuration, trigger: trigger)
        case .clean:
            return await performCleanup(configuration: configuration, trigger: trigger, announce: configuration.notifyBeforeCleaning && !configuration.dryRun)
        }
    }

    /// Collects the candidates automation is allowed to remove.
    func eligibleCandidates(configuration: AutomationConfiguration) async throws -> [CleanupCandidate] {
        let preferences = PreferencesSnapshot().scan
        var candidates: [CleanupCandidate] = []
        let junkCategories = configuration.categories.filter { JunkCategory.category(id: $0)?.allowsAutomaticCleaning == true }
        if !junkCategories.isEmpty {
            let scanner = SystemJunkScanner()
            let results = try await scanner.scan(categories: Set(junkCategories), preferences: preferences)
            candidates += results.flatMap(\.candidates)
        }
        for (categoryID, provider) in extraProviders where configuration.categories.contains(categoryID) {
            try Task.checkCancellation()
            let context = SmartScanContext(preferences: preferences) { _, _ in }
            if let contribution = try? await provider.smartScan(context: context) {
                candidates += contribution.candidates
            }
        }
        let allowedPurposes: Set<DeletionPurpose> = [.junk, .developerData, .privacyData]
        let eligible = candidates.filter { $0.safety == .safe && allowedPurposes.contains($0.purpose) }
        // De-duplicate overlapping items reported by several providers.
        let topLevel = Set(PathUtilities.removingNestedPaths(eligible.map(\.path)))
        var seen = Set<String>()
        return eligible.filter { topLevel.contains($0.path) && seen.insert($0.path).inserted }
    }

    private func notifyOnly(configuration: AutomationConfiguration, trigger: AutomationRunRecord.Trigger) async -> AutomationRunRecord {
        do {
            let candidates = try await eligibleCandidates(configuration: configuration)
            let bytes = candidates.reduce(0) { $0 + $1.usage.reclaimableBytes }
            var record = AutomationRunRecord(trigger: trigger, outcome: candidates.isEmpty ? .nothingToDo : .notified,
                                             bytes: bytes, itemCount: candidates.count,
                                             message: candidates.isEmpty ? "Nothing to clean." : "\(ByteFormatting.string(bytes)) can be cleaned.")
            if !candidates.isEmpty {
                await notifications.post(
                    title: "\(ByteFormatting.string(bytes)) of junk can be cleaned",
                    body: "Open Mac Cleaner to review caches, logs and temporary files.",
                    identifier: "automation.notify",
                    section: .systemJunk
                )
            } else {
                record.message = "Nothing to clean."
            }
            store.append(record)
            logger.info("Automation (\(trigger.rawValue)): notify-only, \(candidates.count) items, \(ByteFormatting.string(bytes))", category: .automation)
            return record
        } catch {
            return fail(trigger: trigger, error: error)
        }
    }

    private func performCleanup(
        configuration: AutomationConfiguration,
        trigger: AutomationRunRecord.Trigger,
        announce: Bool,
        forceClean: Bool = false
    ) async -> AutomationRunRecord {
        do {
            let candidates = try await eligibleCandidates(configuration: configuration)
            let bytes = candidates.reduce(0) { $0 + $1.usage.reclaimableBytes }
            guard !candidates.isEmpty else {
                let record = AutomationRunRecord(trigger: trigger, outcome: .nothingToDo, message: "Nothing to clean.")
                store.append(record)
                return record
            }

            if announce {
                var state = store.loadState()
                state.pendingCleanupSince = Date()
                state.pendingTrigger = trigger
                state.skipPendingCleanup = false
                store.save(state)
                await notifications.post(
                    title: "Mac Cleaner will clean \(ByteFormatting.string(bytes)) soon",
                    body: "Caches, logs and temporary files will be removed in about an hour. Open Automation to skip this cleanup.",
                    identifier: "automation.announce",
                    section: .automation
                )
                let record = AutomationRunRecord(trigger: trigger, outcome: .announced, bytes: bytes, itemCount: candidates.count,
                                                 message: "Announced; cleaning on the next check unless skipped.")
                store.append(record)
                return record
            }

            let preferences = PreferencesSnapshot()
            var options = CleanupOptions(
                title: trigger == .manual ? "Automatic Cleanup (Run Now)" : "Automatic Cleanup",
                method: preferences.junkCleanupMethod,
                source: .automation,
                dryRun: configuration.dryRun
            )
            options.skipItemsInUse = true
            let engine = CleanupEngine(policy: .current, history: historyStore, logger: logger)
            let report = await engine.clean(candidates.map(\.cleanupItem), options: options)

            let record = AutomationRunRecord(
                trigger: trigger,
                outcome: configuration.dryRun ? .dryRun : .cleaned,
                bytes: report.bytesRemoved,
                itemCount: report.removed.count,
                skippedCount: report.skipped.count,
                failedCount: report.failed.count,
                message: report.summary
            )
            store.append(record)
            if configuration.notifyAfterCleaning && (report.bytesRemoved > 0 || configuration.dryRun) && !forceClean {
                await notifications.post(
                    title: configuration.dryRun ? "Automatic cleanup (dry run)" : "Automatic cleanup finished",
                    body: report.summary,
                    identifier: "automation.result",
                    section: .automation
                )
            }
            return record
        } catch {
            return fail(trigger: trigger, error: error)
        }
    }

    private func junkCheck(configuration: AutomationConfiguration) async -> AutomationRunRecord? {
        guard let candidates = try? await eligibleCandidates(configuration: configuration) else { return nil }
        let bytes = candidates.reduce(0) { $0 + $1.usage.reclaimableBytes }
        guard bytes >= Int64(configuration.junkAlertGB) * 1_000_000_000 else { return nil }
        await notifications.post(
            title: "Junk is piling up",
            body: "\(ByteFormatting.string(bytes)) of caches and temporary files can be cleaned.",
            identifier: "automation.junkcheck",
            section: .systemJunk
        )
        let record = AutomationRunRecord(trigger: .junkCheck, outcome: .notified, bytes: bytes, itemCount: candidates.count,
                                         message: "Junk reached \(ByteFormatting.string(bytes)).")
        store.append(record)
        return record
    }

    private func runSecurityScan() async -> AutomationRunRecord? {
        guard let securityScan, let result = await securityScan() else { return nil }
        if result.alertCount > 0 {
            await notifications.post(title: "Security scan found items to review", body: result.summary,
                                     identifier: "automation.security", section: .security)
        }
        let record = AutomationRunRecord(trigger: .schedule, outcome: result.alertCount > 0 ? .notified : .nothingToDo,
                                         itemCount: result.alertCount, message: "Security scan: \(result.summary)")
        store.append(record)
        return record
    }

    /// Records definition updates only when something changed or failed, so hourly checks don't fill the history.
    private func runAntivirus(_ request: AutomationAntivirusRequest) async -> AutomationRunRecord? {
        guard let antivirus, let result = await antivirus(request) else { return nil }
        if request.quickScan {
            let record = AutomationRunRecord(trigger: .schedule, outcome: result.failed ? .failed : (result.alertCount > 0 ? .notified : .nothingToDo),
                                             itemCount: result.alertCount, message: "Virus scan: \(result.summary)")
            store.append(record)
            return record
        }
        guard result.definitionsUpdated || result.failed else { return nil }
        let record = AutomationRunRecord(trigger: .virusDefinitions, outcome: result.failed ? .failed : .updated, message: result.summary)
        store.append(record)
        return record
    }

    private func fail(trigger: AutomationRunRecord.Trigger, error: Error) -> AutomationRunRecord {
        let record = AutomationRunRecord(trigger: trigger, outcome: .failed, message: error.localizedDescription)
        store.append(record)
        logger.error("Automation (\(trigger.rawValue)) failed: \(error.localizedDescription)", category: .automation)
        return record
    }
}

/// Entry point for the background agent (`--run-automation`).
enum AutomationHeadless {
    static let launchArgument = "--run-automation"

    static var isRequested: Bool {
        CommandLine.arguments.contains(launchArgument)
    }

    /// Runs whatever is due, then returns the process exit code.
    static func run(runner: AutomationRunner) async -> Int32 {
        ActivityLogger.shared.info("Automation agent check started", category: .automation)
        let records = await runner.runIfDue()
        if records.contains(where: { $0.outcome == .failed }) { return 1 }
        return 0
    }
}
