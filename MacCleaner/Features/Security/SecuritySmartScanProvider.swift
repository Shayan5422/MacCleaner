import Foundation

/// Smart Scan contribution for security: protection recommendations plus
/// suspicious and rule-matched persistence (findings only; nothing is removed).
struct SecuritySmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .security

    init() {}

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        context.reportProgress(0, "Checking macOS protections…")
        let posture = await SecurityPostureChecker.check()
        try Task.checkCancellation()

        context.reportProgress(0.15, "Reviewing startup items…")
        let records = await StartupLoginItemsService.recordsIfAuthorized()
        let inventory = await StartupInventoryScanner().scan(loginItems: records) { fraction, message in
            context.reportProgress(0.15 + fraction * 0.8, message)
        }
        try Task.checkCancellation()

        let ignored = SecurityStore.ignoredFindingIDs()
        var findings = posture.recommendations().filter { !ignored.contains($0.id) }.map(\.finding)
        for item in inventory.items {
            let assessment = SecurityPersistenceAnalyzer.assess(item)
            guard let finding = SecurityPersistenceAnalyzer.finding(for: item, reasons: assessment.reasons, match: assessment.match),
                  finding.severity >= .suspicious, !ignored.contains(finding.id) else { continue }
            findings.append(finding.finding)
        }
        findings.sort { $0.severity > $1.severity }

        let threats = findings.filter { $0.severity == .threat }.count
        let suspicious = findings.filter { $0.severity == .suspicious }.count
        context.reportProgress(1, "Security checked")
        return SmartScanContribution(
            area: area,
            findings: findings,
            summary: threats + suspicious == 0
                ? posture.summary
                : SecurityReport.summaryLine(threats: threats, suspicious: suspicious, recommendations: 0)
        )
    }
}
