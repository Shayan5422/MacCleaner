import AppKit
import Foundation
import Observation

/// A message shown at the top of the Privacy page after an action.
struct PrivacyNotice: Identifiable, Equatable {
    enum Style: Equatable {
        case success, failure, info
    }

    let id = UUID()
    var style: Style
    var title: String
    var message: String
    /// A file or folder the person can reveal in Finder (for example a backup).
    var revealPath: String?
}

@MainActor
@Observable
final class PrivacyViewModel {
    enum Phase: Equatable {
        case idle, scanning, ready
    }

    let services: AppServices
    let selection = CandidateSelection()
    let cleanupFlow = CleanupFlow()

    private(set) var phase: Phase = .idle
    private(set) var progressFraction: Double = 0
    private(set) var progressMessage = ""
    private(set) var browsers: [PrivacyBrowserReport] = []
    private(set) var systemItems: [PrivacyDataItem] = []
    private(set) var recentItemsBlocked = false
    private(set) var quarantine: PrivacyQuarantineStatus?
    private(set) var lastScanDate: Date?
    private(set) var runningBrowserIDs: Set<String> = []
    private(set) var quittingBrowserIDs: Set<String> = []
    private(set) var isClearingDatabase = false
    private(set) var excludedPaths: Set<String> = []

    /// Show only one browser's data (browser id), or everything when nil.
    var browserFilter: String?
    var searchText = ""
    var pendingFirefoxClear: PrivacyFirefoxHistoryStatus?
    var isConfirmingQuarantineClear = false
    var notice: PrivacyNotice?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let home = PrivacyScanner.currentHome

    init(services: AppServices) {
        self.services = services
        runningBrowserIDs = PrivacyBrowserApps.runningBrowserIDs()
    }

    // MARK: - Derived state

    var hasScanned: Bool { lastScanDate != nil }
    var isScanning: Bool { phase == .scanning }

    /// Items that can be cleaned now: browsers that are closed, matching the browser filter.
    var cleanableItems: [PrivacyDataItem] {
        let browserItems = browsers
            .filter { browserFilter == nil || $0.id == browserFilter }
            .filter { !runningBrowserIDs.contains($0.id) }
            .flatMap(\.items)
        let system = browserFilter == nil ? systemItems : []
        return (browserItems + system).filter { !$0.isProtected && !excludedPaths.contains($0.candidate.path) }
    }

    var groups: [CandidateGroup] {
        let items = cleanableItems
        return PrivacyCategory.allCases.compactMap { category in
            let candidates = items.filter { $0.category == category }.map(\.candidate)
            guard !candidates.isEmpty else { return nil }
            return CandidateGroup(
                id: category.rawValue,
                title: category.title,
                symbol: category.symbol,
                explanation: category.explanation,
                consequence: category.consequence,
                candidates: candidates
            )
        }
    }

    var selectedItems: [PrivacyDataItem] {
        cleanableItems.filter { selection.selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    var totalBytes: Int64 {
        browsers.reduce(0) { $0 + $1.totalBytes } + systemItems.reduce(0) { $0 + $1.bytes }
    }

    /// Open browsers whose data is hidden until they quit.
    var runningBrowsersWithData: [PrivacyBrowserReport] {
        browsers.filter { runningBrowserIDs.contains($0.id) && ($0.hasData || $0.isBlocked) }
    }

    var blockedBrowsers: [PrivacyBrowserReport] {
        browsers.filter(\.isBlocked)
    }

    /// Browsers worth a card: installed, or with data Mac Cleaner could see.
    /// Uninstalled browsers whose leftover folders macOS hides are named in the
    /// Full Disk Access explanation instead.
    var visibleBrowsers: [PrivacyBrowserReport] {
        browsers.filter { $0.isInstalled || $0.hasData }
    }

    /// Everything macOS kept private, in words ("Safari, recent-items lists and data left by Brave").
    var protectedThings: [String] {
        var things = blockedBrowsers.filter { $0.isInstalled || $0.hasData }.map(\.browser.name)
        if recentItemsBlocked { things.append("recent-items lists") }
        if quarantine?.isBlocked == true { things.append("download history") }
        let leftovers = blockedBrowsers.filter { !$0.isInstalled && !$0.hasData }.map(\.browser.name)
        if !leftovers.isEmpty {
            things.append("data left by \(ListFormatter.localizedString(byJoining: leftovers))")
        }
        return things
    }

    var firefoxHistory: [PrivacyFirefoxHistoryStatus] {
        browsers.first { $0.browser.engine == .firefox }?.firefoxHistory ?? []
    }

    var isFirefoxRunning: Bool {
        runningBrowserIDs.contains(PrivacyBrowser.firefox.id)
    }

    var filteredBrowserName: String? {
        browserFilter.flatMap { id in browsers.first { $0.id == id }?.browser.name }
    }

    /// Something was hidden by macOS privacy protection.
    var hasProtectedLocations: Bool {
        !blockedBrowsers.isEmpty || recentItemsBlocked || quarantine?.isBlocked == true
    }

    /// What macOS keeps private, for the Full Disk Access banner.
    var protectionSummary: String {
        let things = protectedThings
        guard !things.isEmpty else {
            return "Safari’s data and the recent-items lists are protected by macOS. Grant Full Disk Access to include them."
        }
        return "Protected by macOS: \(ListFormatter.localizedString(byJoining: things)). Grant Full Disk Access to include them."
    }

    // MARK: - Scanning

    func scan() {
        scanTask?.cancel()
        phase = .scanning
        progressFraction = 0
        progressMessage = "Looking for browsers…"
        refreshRunningState()
        services.permissions.refresh()
        let running = runningBrowserIDs
        let applicationPaths = PrivacyBrowserApps.applicationPaths()
        let scanner = PrivacyScanner(home: home, fileScanner: services.scanner, exclusions: services.settings.scanPreferences.exclusions)
        let started = Date()
        scanTask = Task { [weak self] in
            let result = await scanner.scan(applicationPaths: applicationPaths, runningBrowserIDs: running) { [weak self] fraction, message in
                Task { @MainActor in self?.updateProgress(fraction, message) }
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(result, duration: Date().timeIntervalSince(started))
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = hasScanned ? .ready : .idle
    }

    private func updateProgress(_ fraction: Double, _ message: String) {
        guard phase == .scanning else { return }
        progressFraction = fraction
        progressMessage = message
    }

    private func apply(_ result: PrivacyScanResult, duration: TimeInterval) {
        browsers = result.browsers
        systemItems = result.systemItems
        recentItemsBlocked = result.recentItemsBlocked
        quarantine = result.quarantine
        lastScanDate = result.date
        excludedPaths = []
        let all = result.browsers.flatMap(\.items) + result.systemItems
        selection.reset(to: all.map(\.candidate))
        if let filter = browserFilter, !browsers.contains(where: { $0.id == filter }) {
            browserFilter = nil
        }
        phase = .ready
        let blocked = result.browsers.filter(\.isBlocked).count
        services.logger.info(
            "Privacy scan: \(result.browsers.count) browsers, \(all.count) items, \(ByteFormatting.string(totalBytes)), \(blocked) protected by macOS, \(String(format: "%.1f", duration))s",
            category: .privacy
        )
    }

    // MARK: - Browsers

    func refreshRunningState() {
        let running = PrivacyBrowserApps.runningBrowserIDs()
        if running != runningBrowserIDs { runningBrowserIDs = running }
        let stillQuitting = quittingBrowserIDs.intersection(running)
        if stillQuitting != quittingBrowserIDs { quittingBrowserIDs = stillQuitting }
    }

    func toggleFilter(_ browserID: String) {
        browserFilter = browserFilter == browserID ? nil : browserID
    }

    /// Asks the browser to quit like ⌘Q, so it can save open tabs and ask about downloads.
    func quit(_ report: PrivacyBrowserReport) {
        let browser = report.browser
        guard PrivacyBrowserApps.requestQuit(browser) else {
            refreshRunningState()
            return
        }
        quittingBrowserIDs.insert(browser.id)
        services.logger.info("Asked \(browser.name) to quit before cleaning", category: .privacy)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self else { return }
            self.refreshRunningState()
            if self.runningBrowserIDs.contains(browser.id) {
                self.quittingBrowserIDs.remove(browser.id)
                self.notice = PrivacyNotice(
                    style: .info,
                    title: "\(browser.name) is still open",
                    message: "It may be waiting for you to confirm, for example because downloads are in progress. Switch to \(browser.name) and quit it there."
                )
            }
        }
    }

    // MARK: - Cleaning

    func cleanSelected() {
        refreshRunningState()
        let items = selectedItems
        guard !items.isEmpty else { return }

        // Second, independent check right before cleaning: never pass protected data on.
        var cleanupItems: [CleanupItem] = []
        var refused = 0
        for item in items {
            for cleanupItem in item.cleanupItems {
                if PrivacyProtectedData.isProtected(cleanupItem.path) {
                    refused += 1
                } else {
                    cleanupItems.append(cleanupItem)
                }
            }
        }
        if refused > 0 {
            services.logger.warning("Privacy cleanup refused \(refused) protected items", category: .privacy)
        }
        guard !cleanupItems.isEmpty else { return }

        let categories = Set(items.map(\.category))
        cleanupFlow.requestCleanup(
            title: "Privacy Cleanup",
            items: cleanupItems,
            services: services,
            regenerableData: items.allSatisfy { $0.category.isRegenerable },
            warning: cleanupWarning(for: items)
        ) { [weak self] report in
            self?.didClean(report, categories: categories)
        }
    }

    private func cleanupWarning(for items: [PrivacyDataItem]) -> String? {
        var parts: [String] = []
        let signOut = Set(items.filter { $0.category.signsOut }.map(\.ownerName)).sorted()
        if !signOut.isEmpty {
            parts.append("You’ll be signed out of websites in \(ListFormatter.localizedString(byJoining: signOut)).")
        }
        if items.contains(where: { $0.category == .history }) {
            parts.append("History synced through iCloud or a browser account may return from your other devices.")
        }
        if items.contains(where: { $0.category == .recentItems || $0.category == .appRecentDocuments }) {
            parts.append("macOS may keep showing old recent items until you log out.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func didClean(_ report: CleanupReport, categories: Set<PrivacyCategory>) {
        let names = categories.map(\.rawValue).sorted().joined(separator: ", ")
        services.logger.info(
            "Privacy cleanup (\(names)): \(report.removed.count) removed, \(ByteFormatting.string(report.bytesRemoved)), \(report.skipped.count) skipped, \(report.failed.count) failed",
            category: .privacy
        )
        scan()
    }

    func exclude(_ candidate: CleanupCandidate) {
        services.settings.addExclusion(candidate.path)
        excludedPaths.insert(candidate.path)
        selection.set([candidate], selected: false)
    }

    // MARK: - Database cleanups

    func clearFirefoxHistory(_ status: PrivacyFirefoxHistoryStatus) {
        pendingFirefoxClear = nil
        refreshRunningState()
        guard !isFirefoxRunning else {
            notice = PrivacyNotice(style: .failure, title: "Firefox is open", message: "Quit Firefox, then clear its history.")
            return
        }
        isClearingDatabase = true
        let backupRoot = PrivacyFirefoxHistory.backupRoot(home: home)
        let label = "Firefox " + (status.profile.directoryName.isEmpty ? "profile" : status.profile.directoryName)
        let profileName = status.profile.displayName
        Task { [weak self] in
            do {
                let result = try await BackgroundWork.run(qos: .userInitiated) {
                    let directory = try PrivacyFirefoxHistory.makeBackupDirectory(root: backupRoot, label: label)
                    do {
                        return try PrivacyFirefoxHistory.clearHistory(placesPath: status.placesPath, backupDirectory: directory)
                    } catch {
                        // Don't leave an empty backup folder behind when nothing was changed.
                        if (try? FileManager.default.contentsOfDirectory(atPath: directory))?.isEmpty == true {
                            try? FileManager.default.removeItem(atPath: directory)
                        }
                        throw error
                    }
                }
                self?.didClearFirefoxHistory(result, profileName: profileName)
            } catch {
                self?.didFailDatabaseCleanup(title: "Firefox history wasn’t cleared", error: error)
            }
        }
    }

    private func didClearFirefoxHistory(_ result: PrivacyFirefoxHistoryClearResult, profileName: String) {
        isClearingDatabase = false
        services.logger.info(
            "Cleared Firefox history: \(result.visitsRemoved) visits, \(result.pagesRemoved) pages, \(result.inputHistoryRemoved) typed entries, \(result.annotationsRemoved) annotations removed; \(result.pagesKept) bookmarked pages kept",
            category: .privacy
        )
        var message = "Removed \(NumberFormatting.count(result.visitsRemoved)) visits and \(NumberFormatting.count(result.pagesRemoved)) pages from “\(profileName)”. "
        message += "\(NumberFormatting.count(result.pagesKept)) bookmarked pages were kept. A backup of the previous history is in Mac Cleaner’s Backups folder."
        if !result.logCheckpointed {
            message += " Some removed entries stay in Firefox’s log file until Firefox next starts."
        }
        notice = PrivacyNotice(style: .success, title: "Firefox history cleared", message: message, revealPath: (result.backupPath as NSString).deletingLastPathComponent)
        scan()
    }

    func clearDownloadHistory() {
        isConfirmingQuarantineClear = false
        guard let path = quarantine?.path else { return }
        isClearingDatabase = true
        let home = home
        Task { [weak self] in
            do {
                let removed = try await BackgroundWork.run(qos: .userInitiated) { try PrivacyQuarantineEvents.clearAll(at: path) }
                let status = await BackgroundWork.run(qos: .userInitiated) { PrivacyQuarantineEvents.status(home: home) }
                self?.didClearDownloadHistory(removed: removed, status: status)
            } catch {
                self?.didFailDatabaseCleanup(title: "Download history wasn’t cleared", error: error)
            }
        }
    }

    private func didClearDownloadHistory(removed: Int, status: PrivacyQuarantineStatus?) {
        isClearingDatabase = false
        quarantine = status
        services.logger.info("Cleared macOS download history: \(removed) records", category: .privacy)
        notice = PrivacyNotice(
            style: .success,
            title: "Download history cleared",
            message: "Removed \(NumberFormatting.count(removed)) download records. Your downloaded files weren’t touched."
        )
    }

    private func didFailDatabaseCleanup(title: String, error: Error) {
        isClearingDatabase = false
        services.logger.error("\(title): \(String(describing: type(of: error)))", category: .privacy)
        notice = PrivacyNotice(style: .failure, title: title, message: error.localizedDescription)
    }

    // MARK: - Permissions and Finder

    func openFullDiskAccessSettings() {
        services.permissions.open(.fullDiskAccess)
    }

    func revealBackups() {
        let root = PrivacyFirefoxHistory.backupRoot(home: home)
        if FileManager.default.fileExists(atPath: root) {
            FinderActions.reveal(root)
        }
    }
}
