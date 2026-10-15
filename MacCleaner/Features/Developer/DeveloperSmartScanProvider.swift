import Foundation

/// Developer caches for Smart Scan. File-based caches that rebuild themselves
/// (DerivedData, simulator caches, previews, SwiftPM, CocoaPods and package
/// manager caches) become candidates; cleanups that need an official command
/// (Homebrew, Docker, simctl) become recommendations that link to Developer Tools.
struct DeveloperSmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .developer
    var home: String

    init(home: String = DeveloperToolsScanner.currentHome) {
        self.home = home
    }

    /// Commands that free less than this aren't worth a recommendation.
    static let findingThreshold: Int64 = 100 * 1_000_000

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        context.reportProgress(0, "Checking developer tools…")
        let scanner = DeveloperToolsScanner(home: home, exclusions: context.preferences.exclusions, mode: .smartScan)
        let result = await scanner.scan(tools: DeveloperToolsScanner.smartScanTools) { fraction, message in
            context.reportProgress(min(0.98, fraction), message)
        }
        try Task.checkCancellation()

        var contribution = SmartScanContribution(area: .developer)
        var candidateBytes: Int64 = 0
        for report in result.reports {
            for item in report.items {
                if item.isFileItem {
                    if item.safety == .safe, let candidate = item.candidate {
                        contribution.candidates.append(candidate)
                        candidateBytes += candidate.usage.reclaimableBytes
                    } else if item.safety == .safe, item.bytes >= Self.findingThreshold {
                        contribution.findings.append(finding(for: item, in: report, recommendation: "Review it in Developer Tools."))
                    }
                } else if let command = item.command {
                    let isCountBased = item.id == DeveloperToolKind.simulators.rawValue + ".unavailable"
                    guard item.bytes >= Self.findingThreshold || isCountBased else { continue }
                    contribution.findings.append(finding(for: item, in: report, recommendation: "Run “\(command.commandLine)” from Developer Tools after reviewing it."))
                }
            }
        }

        if result.isXcodeRunning, contribution.candidates.contains(where: { $0.categoryID == "developer." + DeveloperToolKind.xcode.rawValue }) {
            contribution.findings.append(Finding(
                id: "developer|xcode-running",
                area: .developer,
                severity: .info,
                title: "Xcode is open",
                detail: "Build folders of projects open in Xcode are skipped during cleanup.",
                recommendation: "Quit Xcode before cleaning to include them."
            ))
        }

        if candidateBytes > 0 {
            let tools = Set(contribution.candidates.map(\.categoryTitle)).count
            contribution.summary = "\(ByteFormatting.string(candidateBytes)) of caches in \(tools) developer tool\(tools == 1 ? "" : "s")"
        } else if !contribution.findings.isEmpty {
            contribution.summary = "Developer tools can free space with their own cleanup commands"
        }
        context.reportProgress(1, "Done")
        return contribution
    }

    private func finding(for item: DeveloperItem, in report: DeveloperToolReport, recommendation: String) -> Finding {
        let size = item.bytes > 0 ? "\(item.sizeIsUpperBound ? "Up to" : "About") \(ByteFormatting.string(item.bytes)) can be recovered. " : ""
        return Finding(
            id: "developer|" + item.id,
            area: .developer,
            severity: .recommendation,
            title: "\(report.tool.title): \(item.title)",
            detail: size + item.explanation,
            path: item.path,
            recommendation: recommendation
        )
    }
}
