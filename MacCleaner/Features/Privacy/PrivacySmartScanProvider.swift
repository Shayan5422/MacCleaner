import Foundation

/// Privacy's part of Smart Scan: browser caches as cleanup candidates (safe,
/// selected by default) and recommendations about history, cookies and website
/// data, which are never selected automatically.
struct PrivacySmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .privacy
    var home: String

    init(home: String = PrivacyScanner.currentHome) {
        self.home = home
    }

    /// Thresholds above which history and site data are worth a recommendation.
    static let historyRecommendationBytes: Int64 = 50 * 1_000_000
    static let websiteDataRecommendationBytes: Int64 = 200 * 1_000_000
    static let downloadRecordsRecommendation = 500

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        context.reportProgress(0, "Checking browsers…")
        let running = PrivacyBrowserApps.runningBrowserIDs()
        let applicationPaths = PrivacyBrowserApps.applicationPaths()
        let scanner = PrivacyScanner(
            home: home,
            fileScanner: FileSystemScanner(),
            exclusions: context.preferences.exclusions,
            includesSystemData: true,
            readsFirefoxHistory: false
        )
        let result = await scanner.scan(applicationPaths: applicationPaths, runningBrowserIDs: running) { fraction, message in
            context.reportProgress(min(0.98, fraction), message)
        }
        try Task.checkCancellation()

        var contribution = SmartScanContribution(area: .privacy)
        var cacheBytes: Int64 = 0
        var browsersWithCache = Set<String>()

        for report in result.browsers {
            let name = report.browser.name
            let caches = report.items.filter { $0.category == .cache }
            let cacheTotal = caches.reduce(0) { $0 + $1.bytes }

            if running.contains(report.id) {
                if cacheTotal > 0 {
                    contribution.findings.append(Finding(
                        id: "privacy|running|\(report.id)",
                        area: .privacy,
                        severity: .info,
                        title: "\(name) is open",
                        detail: "\(name) has \(ByteFormatting.string(cacheTotal)) of cache, but a browser’s cache can only be cleaned while it’s closed.",
                        recommendation: "Quit \(name), then clean its cache in Privacy."
                    ))
                }
            } else {
                for item in caches where !item.isProtected {
                    let candidates = Self.candidates(for: item, browserName: name)
                    contribution.candidates += candidates
                    if !candidates.isEmpty {
                        cacheBytes += candidates.reduce(0) { $0 + $1.usage.reclaimableBytes }
                        browsersWithCache.insert(report.id)
                    }
                }
            }

            // Protected data is covered by the Full Disk Access finding below.
            func openBytes(_ category: PrivacyCategory) -> Int64 {
                report.items.filter { $0.category == category && !$0.isProtected }.reduce(0) { $0 + $1.bytes }
            }
            let history = openBytes(.history)
            if history >= Self.historyRecommendationBytes {
                contribution.findings.append(Finding(
                    id: "privacy|history|\(report.id)",
                    area: .privacy,
                    severity: .recommendation,
                    title: "\(name) keeps \(ByteFormatting.string(history)) of browsing history",
                    detail: "Browsing history records every site you visit. It isn’t removed automatically.",
                    path: report.dataFolder,
                    recommendation: "Review it in Privacy if you’d like to clear it."
                ))
            }
            let siteData = openBytes(.cookies) + openBytes(.websiteData)
            if siteData >= Self.websiteDataRecommendationBytes {
                contribution.findings.append(Finding(
                    id: "privacy|sitedata|\(report.id)",
                    area: .privacy,
                    severity: .recommendation,
                    title: "Websites store \(ByteFormatting.string(siteData)) in \(name)",
                    detail: "Cookies and website data keep you signed in and hold offline content. Removing them signs you out of websites, so they’re never selected automatically.",
                    path: report.dataFolder,
                    recommendation: "Review cookies and website data in Privacy."
                ))
            }
        }

        let protectedBrowsers = result.browsers
            .filter { $0.isBlocked && ($0.isInstalled || $0.hasData) }
            .map(\.browser.name)
        if !protectedBrowsers.isEmpty {
            contribution.findings.append(Finding(
                id: "privacy|protected",
                area: .privacy,
                severity: .info,
                title: "Some browser data is protected by macOS",
                detail: "Mac Cleaner can’t read or clean parts of \(ListFormatter.localizedString(byJoining: protectedBrowsers)) without Full Disk Access.",
                recommendation: "Grant Full Disk Access in System Settings › Privacy & Security to include it."
            ))
        }

        if let quarantine = result.quarantine, let count = quarantine.eventCount, count >= Self.downloadRecordsRecommendation {
            contribution.findings.append(Finding(
                id: "privacy|quarantine",
                area: .privacy,
                severity: .recommendation,
                title: "macOS remembers \(NumberFormatting.count(count)) downloads",
                detail: "macOS keeps a list of every file you downloaded and where it came from. Clearing it doesn’t affect Gatekeeper.",
                recommendation: "Clear the download history in Privacy if you don’t need it."
            ))
        }

        if cacheBytes > 0 {
            let count = browsersWithCache.count
            contribution.summary = "\(ByteFormatting.string(cacheBytes)) of browser cache in \(count) browser\(count == 1 ? "" : "s")"
        } else if !contribution.findings.isEmpty {
            contribution.summary = "No browser cache to clean right now"
        }
        context.reportProgress(1, "Done")
        return contribution
    }

    /// One Smart Scan candidate per cache folder. SQLite files with companions
    /// are left to the Privacy page, which always removes them together.
    static func candidates(for item: PrivacyDataItem, browserName: String) -> [CleanupCandidate] {
        let names = Set(item.targets.map { ($0.path as NSString).lastPathComponent })
        return item.targets.compactMap { target in
            let name = (target.path as NSString).lastPathComponent
            let isCompanion = PrivacyFileAccess.sqliteCompanionSuffixes.contains { name.hasSuffix($0) }
            let hasCompanion = PrivacyFileAccess.sqliteCompanionSuffixes.contains { names.contains(name + $0) }
            guard !isCompanion, !hasCompanion, target.usage.reclaimableBytes > 0 else { return nil }
            return CleanupCandidate(
                path: target.path,
                title: "\(browserName) — \(target.label ?? name)",
                detail: item.profileName ?? (item.candidate.title == browserName ? nil : item.candidate.title),
                categoryID: "privacy.browserCache",
                categoryTitle: "Browser caches",
                usage: target.usage,
                snapshot: target.snapshot,
                safety: .safe,
                purpose: .privacyData,
                ownerBundleIdentifier: item.candidate.ownerBundleIdentifier
            )
        }
    }
}
