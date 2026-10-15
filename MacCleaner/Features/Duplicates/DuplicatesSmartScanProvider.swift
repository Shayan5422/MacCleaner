import Foundation

/// Smart Scan's duplicate check: a quick exact-duplicate scan of the person's
/// personal folders (files of 1 MB or more).
///
/// For every group, the oldest copy (ties: shortest path) is kept and the other
/// copies become candidates marked `.review`, so nothing is selected without the
/// person looking first. Protected copies, copies inside app-managed libraries and
/// hard links (which free no space) are never offered.
struct DuplicatesSmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .duplicates
    /// Locations to scan; nil scans the default personal folders.
    var roots: [String]?
    var policy: SafetyPolicy
    var minimumSize: Int64

    static let categoryID = "duplicates"
    static let categoryTitle = "Duplicate files"

    init(roots: [String]? = nil, policy: SafetyPolicy = .current, minimumSize: Int64 = 1_000_000) {
        self.roots = roots
        self.policy = policy
        self.minimumSize = minimumSize
    }

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        let options = DuplicateScanOptions(
            roots: roots ?? DuplicateLocation.defaultPaths(),
            minimumSize: minimumSize,
            kinds: .all,
            includeHiddenFiles: context.preferences.includeHiddenFiles,
            exclusions: context.preferences.exclusions,
            skipDeveloperFolders: true
        )
        let report = context.reportProgress
        let result = try await DuplicateFinder(policy: policy).findDuplicates(options: options) { progress in
            report(progress.overallFraction, progress.message)
        }

        let keepContext = DuplicateKeepContext.standard()
        var candidates: [CleanupCandidate] = []
        for group in result.groups {
            guard let kept = DuplicateKeepRule.oldest.keeper(in: group.files, context: keepContext) else { continue }
            let marked = group.ruleMarkedIDs(rule: .oldest, context: keepContext)
            for file in group.files where marked.contains(file.id) && file.exclusiveSize > 0 {
                candidates.append(CleanupCandidate(
                    path: file.path,
                    title: file.name,
                    detail: "Duplicate of \(kept.name) in \(PathUtilities.abbreviate(kept.folderPath))",
                    categoryID: Self.categoryID,
                    categoryTitle: Self.categoryTitle,
                    usage: DiskUsage(
                        logicalBytes: file.logicalSize,
                        allocatedBytes: file.allocatedSize,
                        reclaimableBytes: file.exclusiveSize,
                        fileCount: 1
                    ),
                    snapshot: file.snapshot,
                    safety: .review,
                    purpose: .userFile,
                    modificationDate: file.modificationDate
                ))
            }
        }

        let bytes = candidates.reduce(Int64(0)) { $0 + $1.usage.reclaimableBytes }
        var findings: [Finding] = []
        if !candidates.isEmpty {
            findings.append(Finding(
                id: "duplicates|review",
                area: .duplicates,
                severity: .recommendation,
                title: "Review duplicate files",
                detail: "\(NumberFormatting.count(candidates.count)) extra cop\(candidates.count == 1 ? "y" : "ies") of files in your personal folders use \(ByteFormatting.string(bytes)).",
                recommendation: "Open Duplicate Finder to compare copies side by side and choose which ones to keep.",
                destination: .duplicates
            ))
        }
        if result.cloudOnlySkipped > 0 {
            findings.append(Finding(
                id: "duplicates|cloud-only",
                area: .duplicates,
                severity: .info,
                title: "Some files are only in the cloud",
                detail: "\(NumberFormatting.count(result.cloudOnlySkipped)) file\(result.cloudOnlySkipped == 1 ? " wasn't" : "s weren't") compared because \(result.cloudOnlySkipped == 1 ? "it isn't" : "they aren't") downloaded. Mac Cleaner never downloads files to compare them.",
                destination: .duplicates
            ))
        }

        ActivityLogger.shared.info(
            "Smart Scan duplicates: \(result.groups.count) groups, \(candidates.count) candidates, \(ByteFormatting.string(bytes)) reclaimable, \(result.filesExamined) files examined in \(String(format: "%.1f", result.duration))s",
            category: .duplicates
        )

        let summary: String
        if candidates.isEmpty {
            summary = "No duplicate files of \(ByteFormatting.string(minimumSize)) or more in your personal folders"
        } else {
            summary = "\(NumberFormatting.count(candidates.count)) duplicate file\(candidates.count == 1 ? "" : "s") · \(ByteFormatting.string(bytes))"
        }
        return SmartScanContribution(area: .duplicates, candidates: candidates, findings: findings, summary: summary)
    }
}
