import Foundation

/// Finds and measures browser data, recent-items lists and the system download
/// history. Reading is limited to directory listings, file metadata, two small
/// profile lists and read-only row counts; nothing is changed.
struct PrivacyScanner: Sendable {
    var home: String
    var fileScanner: FileSystemScanner
    var exclusions: ExclusionList
    var browsers: [PrivacyBrowser]
    /// Include macOS recent-items lists and the system download history.
    var includesSystemData: Bool
    /// Count Firefox visits and downloads (read-only) for browsers that aren't running.
    var readsFirefoxHistory: Bool

    init(
        home: String = PrivacyScanner.currentHome,
        fileScanner: FileSystemScanner = FileSystemScanner(),
        exclusions: ExclusionList = ExclusionList(),
        browsers: [PrivacyBrowser] = PrivacyBrowser.all,
        includesSystemData: Bool = true,
        readsFirefoxHistory: Bool = true
    ) {
        self.home = home
        self.fileScanner = fileScanner
        self.exclusions = exclusions
        self.browsers = browsers
        self.includesSystemData = includesSystemData
        self.readsFirefoxHistory = readsFirefoxHistory
    }

    /// The home folder with symbolic links resolved, matching `SafetyPolicy`.
    static var currentHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PathUtilities.resolvedPath(home) ?? home
    }

    private struct Inventory: Sendable {
        var browsers: [PrivacyBrowserInventory]
        var recentSpecs: [PrivacyItemSpec]
        var recentsBlocked: Bool
    }

    func scan(
        applicationPaths: [String: String],
        runningBrowserIDs: Set<String>,
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async -> PrivacyScanResult {
        progress?(0.02, "Looking for browsers…")
        let inventory = await BackgroundWork.run(qos: .userInitiated) { [self] in collectInventory() }
        if Task.isCancelled { return PrivacyScanResult() }

        let specs = inventory.browsers.flatMap(\.specs) + inventory.recentSpecs
        let paths = Array(Set(specs.flatMap(\.paths)))
        progress?(0.2, "Measuring browser data…")
        let usages = await fileScanner.measure(paths: paths, concurrency: 4)
        if Task.isCancelled { return PrivacyScanResult() }

        progress?(0.85, "Checking history databases…")
        let result = await BackgroundWork.run(qos: .userInitiated) { [self] in
            assemble(inventory, usages: usages, applicationPaths: applicationPaths, runningBrowserIDs: runningBrowserIDs)
        }
        progress?(1, "Done")
        return result
    }

    // MARK: - Steps

    private func collectInventory() -> Inventory {
        var collector = PrivacyInventoryCollector(home: home, exclusions: exclusions)
        let browserInventories = browsers.map { collector.inventory(for: $0) }
        let recents = includesSystemData ? collector.recentItems() : (specs: [], blocked: false)
        return Inventory(browsers: browserInventories, recentSpecs: recents.specs, recentsBlocked: recents.blocked)
    }

    private func assemble(
        _ inventory: Inventory,
        usages: [String: DiskUsage],
        applicationPaths: [String: String],
        runningBrowserIDs: Set<String>
    ) -> PrivacyScanResult {
        var result = PrivacyScanResult()
        for browserInventory in inventory.browsers {
            let browser = browserInventory.browser
            let items = browserInventory.specs.flatMap { makeItems($0, usages: usages, blocked: browserInventory.blockedLocations) }
            let isRunning = runningBrowserIDs.contains(browser.id)
            let history = browserInventory.firefoxPlaces.map { firefoxStatus($0, isRunning: isRunning) }
            let report = PrivacyBrowserReport(
                browser: browser,
                applicationPath: applicationPaths[browser.id],
                profiles: browserInventory.profiles,
                items: items,
                blockedLocations: browserInventory.blockedLocations,
                firefoxHistory: history,
                dataFolder: browserInventory.dataFolder
            )
            if report.isInstalled || report.hasData || report.isBlocked {
                result.browsers.append(report)
            }
        }
        result.browsers.sort { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.browser.name < rhs.browser.name
        }
        result.systemItems = inventory.recentSpecs.compactMap { makeItem($0, usages: usages) }
        result.recentItemsBlocked = inventory.recentsBlocked
        if includesSystemData {
            result.quarantine = PrivacyQuarantineEvents.status(home: home)
        }
        result.date = Date()
        return result
    }

    /// Splits a row into the part Mac Cleaner may change and the part inside
    /// locations macOS protects (listing them was refused, so changing them would be too).
    private func makeItems(_ spec: PrivacyItemSpec, usages: [String: DiskUsage], blocked: [String]) -> [PrivacyDataItem] {
        let isBlocked: (String) -> Bool = { path in blocked.contains { PathUtilities.isDescendant(path, of: $0) } }
        let open = spec.paths.filter { !isBlocked($0) }
        let protected = spec.paths.filter(isBlocked)
        var items: [PrivacyDataItem] = []
        if !open.isEmpty {
            var openSpec = spec
            openSpec.paths = open
            if !open.contains(openSpec.primaryPath) && isBlocked(openSpec.primaryPath) { openSpec.primaryPath = open[0] }
            if let item = makeItem(openSpec, usages: usages) { items.append(item) }
        }
        if !protected.isEmpty {
            var protectedSpec = spec
            protectedSpec.paths = protected
            protectedSpec.key += "|protected"
            if !protected.contains(protectedSpec.primaryPath) { protectedSpec.primaryPath = protected[0] }
            if var item = makeItem(protectedSpec, usages: usages) {
                item.isProtected = true
                items.append(item)
            }
        }
        return items
    }

    private func makeItem(_ spec: PrivacyItemSpec, usages: [String: DiskUsage]) -> PrivacyDataItem? {
        let targets = spec.paths.compactMap { path -> PrivacyCleanupTarget? in
            guard let usage = usages[path] else { return nil }
            return PrivacyCleanupTarget(path: path, label: spec.labels[path], snapshot: FileSnapshot.capture(path: path), usage: usage)
        }
        let usage = targets.reduce(DiskUsage.zero) { $0 + $1.usage }
        // Empty folders aren't worth a row.
        guard !targets.isEmpty, usage.fileCount > 0 || usage.allocatedBytes > 0 else { return nil }
        var candidate = CleanupCandidate(
            path: spec.primaryPath,
            title: spec.title,
            detail: spec.detail,
            categoryID: "privacy." + spec.category.rawValue,
            categoryTitle: spec.category.title,
            usage: usage,
            snapshot: targets.first { $0.path == spec.primaryPath }?.snapshot,
            safety: spec.category.safety,
            purpose: .privacyData,
            ownerBundleIdentifier: spec.ownerBundleIdentifier
        )
        candidate.id = spec.key
        return PrivacyDataItem(
            id: spec.key,
            category: spec.category,
            browserID: spec.browserID,
            ownerName: spec.ownerName,
            profileName: spec.profileName,
            targets: targets,
            candidate: candidate
        )
    }

    private func firefoxStatus(_ places: PrivacyFirefoxPlaces, isRunning: Bool) -> PrivacyFirefoxHistoryStatus {
        let bytes = PrivacyFileAccess.databaseFiles(places.path).reduce(Int64(0)) { $0 + PrivacyFileAccess.allocatedSize(of: $1) }
        var status = PrivacyFirefoxHistoryStatus(profile: places.profile, placesPath: places.path, databaseBytes: bytes)
        if isRunning {
            status.problem = "Quit Firefox to see and clear its history."
            return status
        }
        guard readsFirefoxHistory else { return status }
        do {
            let counts = try PrivacyFirefoxHistory.counts(placesPath: places.path)
            status.visitCount = counts.visits
            status.downloadCount = counts.downloads
        } catch let error as PrivacySQLiteError where error.isBusy {
            status.problem = "Firefox seems to be using this profile. Quit Firefox to clear its history."
        } catch {
            status.problem = error.localizedDescription
        }
        return status
    }
}
