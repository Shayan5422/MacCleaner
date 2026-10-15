import Foundation

/// Smart Scan's "App Leftovers" area: files left behind by apps that are no longer
/// installed, plus a recommendation about apps that haven't been used for a long time.
///
/// Leftovers are always `.review` (never preselected) and removed with the
/// `.applicationData` purpose.
struct LeftoversSmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .leftovers
    var policy: SafetyPolicy

    init(policy: SafetyPolicy = .current) {
        self.policy = policy
    }

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        context.reportProgress(0, "Finding installed apps…")
        let policy = policy
        let listed = await BackgroundWork.run(qos: .userInitiated) { UninstallerInventory.loadApplications(policy: policy) }
        try Task.checkCancellation()

        // Helpers and app groups of installed apps decide what's still in use (cached after the first run).
        var apps: [UninstallerApp] = []
        apps.reserveCapacity(listed.count)
        for await app in UninstallerInventory.enrichmentUpdates(for: listed) {
            apps.append(app)
            context.reportProgress(0.3 * Double(apps.count) / Double(max(1, listed.count)), "Reading installed apps (\(apps.count) of \(listed.count))…")
        }
        try Task.checkCancellation()
        guard apps.count == listed.count else { throw CancellationError() }

        // Without Full Disk Access, protected containers are reported instead of opened,
        // so a background scan never triggers macOS permission prompts.
        let canReadProtected = FullDiskAccessProbe.status() == .granted
        let result = try await UninstallerOrphanService.scan(
            apps: apps,
            canReadProtectedAppData: canReadProtected,
            exclusions: context.preferences.exclusions,
            policy: policy
        ) { fraction, message in
            context.reportProgress(0.3 + 0.7 * fraction, message)
        }

        var contribution = SmartScanContribution(area: .leftovers)
        contribution.candidates = result.groups.flatMap { group in
            group.items.map { $0.cleanupCandidate(identifier: group.identifier) }
        }
        if result.groups.isEmpty {
            contribution.summary = "No leftovers of removed apps"
        } else {
            contribution.summary = "\(result.groups.count) removed app\(result.groups.count == 1 ? "" : "s") left \(ByteFormatting.string(result.totalBytes)) behind"
        }

        if !result.unmeasuredProtected.isEmpty {
            let count = result.unmeasuredProtected.count
            contribution.findings.append(Finding(
                id: "leftovers.protectedContainers",
                area: .leftovers,
                severity: .recommendation,
                title: "\(count) app container\(count == 1 ? "" : "s") couldn't be checked",
                detail: "macOS protects the data inside app containers. \(count) container\(count == 1 ? " seems" : "s seem") to belong to apps that are no longer installed.",
                recommendation: "Grant Full Disk Access to Mac Cleaner in System Settings › Privacy & Security, then scan again.",
                destination: .uninstaller
            ))
        }

        let unused = Self.unusedApps(apps)
        if !unused.isEmpty {
            let names = ListFormatter.localizedString(byJoining: unused.prefix(3).map(\.name))
            contribution.findings.append(Finding(
                id: "leftovers.unusedApps",
                area: .leftovers,
                severity: .info,
                title: "\(unused.count) app\(unused.count == 1 ? " hasn't" : "s haven't") been opened in 90 days",
                detail: unused.count > 3 ? "Including \(names)." : "\(names).",
                recommendation: "Review them in the Uninstaller and remove the ones you no longer need.",
                destination: .uninstaller
            ))
        }
        context.reportProgress(1, contribution.summary ?? "Done")
        return contribution
    }

    /// Apps with a Spotlight launch record older than 90 days (only when Spotlight has usage data).
    static func unusedApps(_ apps: [UninstallerApp], now: Date = Date()) -> [UninstallerApp] {
        guard apps.contains(where: { $0.lastUsed != nil }) else { return [] }
        return apps.filter { app in
            guard app.canUninstall, !app.isHiddenComponent, let lastUsed = app.lastUsed else { return false }
            return now.timeIntervalSince(lastUsed) > UninstallerApp.unusedInterval
        }
        .sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
    }
}
