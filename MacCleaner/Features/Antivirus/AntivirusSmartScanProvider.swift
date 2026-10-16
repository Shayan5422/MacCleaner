import Foundation

/// Smart Scan's "Virus Scan" area: a Quick Scan with the installed definitions. Reports
/// findings only (threats, potentially unwanted apps, and a recommendation when definitions
/// aren't installed); nothing is removed from Smart Scan.
struct AntivirusSmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .malware
    var paths: AVPaths
    /// `UserDefaults` suite with the antivirus settings; nil for the standard defaults.
    var defaultsSuite: String?

    init(paths: AVPaths = .standard, defaultsSuite: String? = nil) {
        self.paths = paths
        self.defaultsSuite = defaultsSuite
    }

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        context.reportProgress(0.02, "Loading virus definitions…")
        let settings = AVSettingsSnapshot(defaults: defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard)
        let service = AVScanService(paths: paths, settings: settings, globalExclusions: context.preferences.exclusions)
        let plan = await AVScanPlanner.quickScan(sources: .live(includesPrivacyProtectedFolders: true, readsLoginItems: true), kind: .smartScan)
        try Task.checkCancellation()
        let report = await service.run(plan) { progress in
            let fraction = progress.fraction ?? min(0.6, Double(progress.filesScanned) / 40_000)
            context.reportProgress(0.05 + 0.93 * fraction, "Scanning \(NumberFormatting.count(progress.filesScanned)) files…")
        }
        try Task.checkCancellation()
        context.reportProgress(1, "Virus scan finished")
        return Self.contribution(from: report)
    }

    static func contribution(from report: AVScanReport) -> SmartScanContribution {
        var findings = report.threats.map { threat -> Finding in
            let severity: FindingSeverity
            switch threat.category {
            case .malware: severity = .threat
            case .pua, .maliciousDownload: severity = .suspicious
            case .testFile: severity = .info
            }
            var detail = "\(threat.category.explanation) Detected as \(threat.name) by \(threat.sourceTitle)."
            if let member = threat.memberPath { detail += " Found inside the archive at \(member)." }
            return Finding(id: "antivirus|" + threat.id, area: .malware, severity: severity,
                           title: "\(threat.category.badgeTitle): \(threat.fileName)", detail: detail, path: threat.path,
                           recommendation: "Open Antivirus to move it to the Virus Chest, where it can't run and can be restored if needed.",
                           destination: .antivirus)
        }
        if !report.usedDefinitions {
            findings.append(Finding(
                id: "antivirus|definitions-missing", area: .malware, severity: .recommendation,
                title: "Virus definitions aren't installed",
                detail: "This scan used only the built-in test signature and Mac Cleaner's adware rules, so it can't detect most malware.",
                recommendation: "Download the free virus definitions (ClamAV signatures and abuse.ch feeds) on the Antivirus page.",
                destination: .antivirus
            ))
        }
        let summary = report.threats.isEmpty
            ? (report.usedDefinitions ? "No threats found in \(NumberFormatting.count(report.filesScanned)) files" : "Definitions not installed")
            : report.summary.resultLine
        return SmartScanContribution(area: .malware, candidates: [], findings: findings, summary: summary)
    }
}
