import Foundation

/// Antivirus work for the background agent (`--run-automation`): definition updates and
/// scheduled quick scans, without any interface. It never shows privacy prompts (Downloads,
/// Desktop and login items are skipped) and moves threats to the Virus Chest only when the
/// person turned on automatic quarantine; otherwise it notifies.
enum AntivirusHeadless {
    struct Result: Sendable {
        var definitionsUpdated = false
        var scanned = false
        var threatCount = 0
        var quarantinedCount = 0
        var failed = false
        var summary = ""
    }

    static func run(
        updateDefinitions: Bool,
        quickScan: Bool,
        paths: AVPaths = .standard,
        defaults: UserDefaults = .standard,
        notifications: NotificationService = .shared,
        logger: ActivityLogger = .shared
    ) async -> Result {
        var result = Result()
        var lines: [String] = []
        let settings = AVSettingsSnapshot(defaults: defaults)

        if updateDefinitions {
            if settings.automaticUpdates {
                let updater = AVDefinitionsUpdater(environment: .live(paths: paths))
                let outcome = await updater.update(trigger: .automatic, settings: settings)
                if let engine = outcome.engine { AVEngineHolder.shared.install(engine, compiledAt: outcome.state.installed?.compiledAt) }
                if outcome.intelChanged { AVIntelHolder.shared.install(outcome.intel) }
                result.definitionsUpdated = outcome.installedNewDatabase
                if let skipped = outcome.skippedReason {
                    lines.append(skipped)
                } else if let problem = outcome.problem {
                    result.failed = true
                    lines.append(problem)
                } else if outcome.installedNewDatabase {
                    lines.append("Virus definitions updated.")
                }
                logger.info("Antivirus: background definitions check \(outcome.installedNewDatabase ? "installed new definitions" : "finished")\(outcome.problem.map { " (\($0))" } ?? "")", category: AVLog.category)
            } else {
                lines.append("Automatic updates are turned off in Antivirus settings.")
            }
        }

        if quickScan {
            let service = AVScanService(paths: paths, settings: settings, globalExclusions: PreferencesSnapshot(defaults: defaults).scan.exclusions)
            let plan = await AVScanPlanner.quickScan(sources: .live(includesPrivacyProtectedFolders: false, readsLoginItems: false), kind: .scheduled)
            let report = await service.run(plan, qos: .utility)
            result.scanned = true
            result.threatCount = report.threats.count
            var remaining = report.threats
            let chest = AVVirusChest(paths: paths, logger: logger)
            for threat in report.threats where AVAutoQuarantine.applies(to: threat, settings: settings) {
                if (try? await chest.quarantine(AVQuarantineRequest(threat: threat))) != nil {
                    result.quarantinedCount += 1
                    remaining.removeAll { $0.id == threat.id }
                }
            }
            AVOpenThreats(kind: report.kind, date: report.finishedAt, threats: remaining).save(to: paths.lastThreatsFile)
            if result.quarantinedCount > 0 {
                var summary = report.summary
                summary.quarantinedCount = result.quarantinedCount
                AVScanHistoryStore(url: paths.historyFile).update(summary)
            }
            lines.append(report.summary.resultLine)
            if !report.usedDefinitions { lines.append("Only the built-in test signatures were available.") }
            await notify(report: report, quarantined: result.quarantinedCount, remaining: remaining.count, notifications: notifications)
            logger.info("Antivirus: scheduled quick scan finished: \(report.filesScanned) files, \(report.threats.count) threats, \(result.quarantinedCount) moved to the Virus Chest", category: AVLog.category)
        }
        result.summary = lines.joined(separator: " ")
        return result
    }

    private static func notify(report: AVScanReport, quarantined: Int, remaining: Int, notifications: NotificationService) async {
        guard !report.threats.isEmpty else { return }
        let title: String
        var body: String
        if remaining == 0 {
            title = quarantined == 1 ? "A threat was moved to the Virus Chest" : "\(quarantined) threats were moved to the Virus Chest"
            body = "The scheduled virus scan found \(report.threats.first?.name ?? "a threat")."
        } else {
            title = remaining == 1 ? "The virus scan found a threat" : "The virus scan found \(remaining) threats"
            body = "Open Mac Cleaner to review \(remaining == 1 ? "it" : "them")."
            if quarantined > 0 { body += " \(quarantined) more \(quarantined == 1 ? "was" : "were") moved to the Virus Chest." }
        }
        await notifications.post(title: title, body: body, identifier: "antivirus.scheduled", section: .antivirus)
    }

    /// The closure for `AutomationRunner.antivirus`.
    static func automationHook(paths: AVPaths = .standard) -> @Sendable (AutomationAntivirusRequest) async -> AutomationAntivirusResult? {
        { request in
            let result = await run(updateDefinitions: request.updateDefinitions, quickScan: request.quickScan, paths: paths)
            return AutomationAntivirusResult(summary: result.summary, alertCount: result.threatCount - result.quarantinedCount,
                                             definitionsUpdated: result.definitionsUpdated, failed: result.failed)
        }
    }
}
