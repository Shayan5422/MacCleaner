import AppKit
import Foundation
import Observation

/// Drives the Updates page: installed apps with their versions and sizes, and update
/// checks from the App Store, developers' Sparkle feeds and Homebrew.
@MainActor
@Observable
final class UpdatesViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, updates, appStore, sparkle, homebrew, unknown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All Apps"
            case .updates: return "Updates Available"
            case .appStore: return "App Store"
            case .sparkle: return "Developer Feeds"
            case .homebrew: return "Homebrew"
            case .unknown: return "No Information"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .updates: return "arrow.down.circle"
            case .appStore: return "bag"
            case .sparkle: return "dot.radiowaves.left.and.right"
            case .homebrew: return "mug"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    let services: AppServices
    /// Set by the app shell to open another section (optional).
    @ObservationIgnored var navigate: ((AppSection) -> Void)?

    private(set) var rows: [UpdatesAppRow] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isChecking = false
    private(set) var checkFraction: Double = 0
    private(set) var checkMessage = ""
    private(set) var lastCheckDate: Date?
    private(set) var brewPath: String?
    /// Casks matched to installed apps, by app path.
    private(set) var homebrewCasks: [String: UpdatesHomebrewCask] = [:]
    /// Casks Homebrew lists as installed whose apps were removed or moved.
    private(set) var homebrewMissingApps: [UpdatesHomebrewCask] = []
    private(set) var homebrewError: String?
    /// Explains what the last check covered (for example when online checks are off).
    private(set) var checkNotice: String?
    private(set) var leftoverSummary: UninstallerOrphanScanResult?
    private(set) var appData: [String: UninstallerLocateResult] = [:]
    private(set) var appDataLoading: Set<String> = []

    var filter: Filter = .all
    var searchText = ""
    var sortOrder: [KeyPathComparator<UpdatesAppRow>] = [
        KeyPathComparator(\UpdatesAppRow.sortStatus),
        KeyPathComparator(\UpdatesAppRow.sortName),
    ]
    var selection: Set<UpdatesAppRow.ID> = [] {
        didSet { selectionDidChange() }
    }
    var homebrewRun: UpdatesHomebrewRun?
    /// Waiting for the person to confirm `brew upgrade` for this app path.
    var homebrewConfirmationPath: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var enrichTask: Task<Void, Never>?
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var appDataTask: Task<Void, Never>?
    @ObservationIgnored private var isEnriching = false
    /// Mac Cleaner itself and hidden helper components: not listed, but installed, so
    /// their data is never mistaken for leftovers.
    @ObservationIgnored private var componentApps: [UninstallerApp] = []

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Derived data

    var availableUpdateCount: Int { rows.filter { $0.status == .updateAvailable }.count }
    var upToDateCount: Int { rows.filter { $0.status == .upToDate }.count }
    /// Apps a check found no reliable information for (or couldn't check).
    var unknownCount: Int { rows.filter { [.unknown, .failed].contains($0.status) }.count }
    var appStoreUpdateCount: Int { rows.filter { $0.status == .updateAvailable && $0.displaySource == .appStore }.count }

    var visibleRows: [UpdatesAppRow] {
        var list = rows
        switch filter {
        case .all: break
        case .updates: list = list.filter { $0.status == .updateAvailable || $0.status == .incompatible }
        case .appStore: list = list.filter { $0.mechanism == .appStore }
        case .sparkle: list = list.filter { $0.displaySource == .sparkle || $0.checkableSource == .sparkle }
        case .homebrew: list = list.filter { homebrewCasks[$0.id] != nil }
        case .unknown: list = list.filter { [.unknown, .failed].contains($0.status) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { row in
                row.name.localizedCaseInsensitiveContains(query) || (row.app.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list.sorted(using: sortOrder)
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return rows.count
        case .updates: return rows.filter { $0.status == .updateAvailable || $0.status == .incompatible }.count
        case .appStore: return rows.filter { $0.mechanism == .appStore }.count
        case .sparkle: return rows.filter { $0.displaySource == .sparkle || $0.checkableSource == .sparkle }.count
        case .homebrew: return homebrewCasks.count
        case .unknown: return unknownCount
        }
    }

    var selectedRow: UpdatesAppRow? {
        guard let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        enrichTask?.cancel()
        sizeTask?.cancel()
        isLoading = true
        let policy = services.policy
        loadTask = Task {
            let (loaded, components) = await BackgroundWork.run(qos: .userInitiated) { () -> ([UpdatesAppRow], [UninstallerApp]) in
                let all = UninstallerInventory.loadApplications(policy: policy)
                let isComponent: (UninstallerApp) -> Bool = { $0.protection == .macCleanerItself || $0.isHiddenComponent }
                let rows = all.filter { !isComponent($0) }.map { UpdatesAppRow(app: $0, mechanism: UpdatesMechanismDetector.detect($0)) }
                return (rows, all.filter(isComponent))
            }
            guard !Task.isCancelled else { return }
            componentApps = components
            let stored = UpdatesResultStore.load()
            rows = loaded.map { row in
                var updated = row
                if let result = stored?.results[row.id], result.installedVersionAtCheck == row.installedVersion {
                    updated.result = result
                }
                return updated
            }
            lastCheckDate = stored?.checkedAt
            brewPath = UpdatesHomebrew.locateBrew()
            hasLoaded = true
            isLoading = false
            selection = selection.filter { id in rows.contains { $0.id == id } }
            startSizing()
            startEnrichment()
        }
    }

    private func startSizing() {
        sizeTask?.cancel()
        let apps = rows.map(\.app)
        let scanner = services.scanner
        sizeTask = Task {
            for await (path, usage) in UninstallerInventory.sizeUpdates(for: apps, scanner: scanner) {
                update(path) { $0.app.usage = usage }
            }
        }
    }

    /// Identities of all apps are needed to tell an app's own data from shared data.
    private func startEnrichment() {
        enrichTask?.cancel()
        let apps = rows.map(\.app) + componentApps
        isEnriching = true
        enrichTask = Task {
            for await enriched in UninstallerInventory.enrichmentUpdates(for: apps) {
                if let index = componentApps.firstIndex(where: { $0.path == enriched.path }) {
                    componentApps[index] = enriched
                    continue
                }
                update(enriched.path) { row in
                    row.app.signature = enriched.signature
                    row.app.identity = enriched.identity
                    row.app.isEnriched = true
                }
            }
            guard !Task.isCancelled else { return }
            isEnriching = false
            scanLeftoverSummary()
            if let row = selectedRow, appData[row.id] == nil { loadAppData(for: row) }
        }
    }

    private func update(_ path: String, _ change: (inout UpdatesAppRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == path }) else { return }
        change(&rows[index])
    }

    // MARK: - Checking

    func checkForUpdates() {
        guard !isChecking, hasLoaded else { return }
        let online = services.settings.checkUpdatesOnline
        let brew = UpdatesHomebrew.locateBrew()
        brewPath = brew
        homebrewError = nil
        guard online || brew != nil else {
            checkNotice = "Online update checks are turned off, and Homebrew isn't installed, so there's nothing to check."
            return
        }
        checkNotice = online ? nil : "Online checks are turned off, so only Homebrew's local catalog was checked."

        let snapshot = rows
        let sparkleTargets: [(path: String, feed: URL, build: String?, version: String?)] = online ? snapshot.compactMap { row in
            if case .sparkleFeed(let feed) = row.mechanism { return (row.id, feed, row.app.info.buildVersion, row.app.info.shortVersion) }
            return nil
        } : []
        let storeTargets: [UpdatesAppStoreTarget] = online ? snapshot.filter { $0.mechanism == .appStore }.map { row in
            UpdatesAppStoreTarget(
                path: row.id,
                trackID: row.app.appStoreItemID,
                bundleIdentifier: row.app.bundleIdentifier,
                installedVersion: row.app.info.shortVersion ?? row.app.info.buildVersion,
                isMacApp: !row.app.isWrappediOSApp,
                storefront: row.app.storefront
            )
        } : []
        let apps = snapshot.map(\.app)
        let checkingPaths = Set(sparkleTargets.map(\.path) + storeTargets.map(\.path))
        for index in rows.indices where checkingPaths.contains(rows[index].id) { rows[index].isChecking = true }

        let total = Double(sparkleTargets.count + (storeTargets.isEmpty ? 0 : 1) + (brew == nil ? 0 : 1))
        var completed = 0.0
        isChecking = true
        checkFraction = 0
        checkMessage = "Contacting update sources…"
        let started = Date()
        let checker = UpdatesChecker()

        var sparkleResults: [String: UpdatesCheckResult] = [:]
        var storeResults: [String: UpdatesCheckResult] = [:]
        var brewOutcome: UpdatesChecker.HomebrewOutcome?

        checkTask = Task {
            await withTaskGroup(of: CheckOutcome.self) { group in
                if let brew {
                    group.addTask {
                        do {
                            return .homebrew(try await checker.checkHomebrew(brew: brew, apps: apps), nil)
                        } catch {
                            return .homebrew(nil, error.localizedDescription)
                        }
                    }
                }
                if !storeTargets.isEmpty {
                    group.addTask { .appStore(await checker.checkAppStore(storeTargets)) }
                }
                let limiter = AsyncLimiter(limit: 4)
                for target in sparkleTargets {
                    group.addTask {
                        let result = await limiter.run {
                            await checker.checkSparkle(feed: target.feed, installedBuild: target.build, installedVersion: target.version)
                        }
                        return .sparkle(target.path, result)
                    }
                }
                for await outcome in group {
                    completed += 1
                    checkFraction = total > 0 ? completed / total : 1
                    switch outcome {
                    case .sparkle(let path, let result):
                        sparkleResults[path] = result
                        checkMessage = "Checked \(rows.first { $0.id == path }?.name ?? "an app")"
                        applyResults(paths: [path], sparkle: sparkleResults, store: storeResults, brew: brewOutcome)
                    case .appStore(let results):
                        storeResults = results
                        checkMessage = "Checked the App Store"
                        applyResults(paths: Array(results.keys), sparkle: sparkleResults, store: storeResults, brew: brewOutcome)
                    case .homebrew(let outcome, let error):
                        brewOutcome = outcome
                        homebrewError = error
                        homebrewCasks = outcome?.matchedCasks ?? [:]
                        homebrewMissingApps = outcome?.missingApps ?? []
                        checkMessage = "Checked Homebrew"
                        applyResults(paths: outcome.map { Array($0.results.keys) } ?? [], sparkle: sparkleResults, store: storeResults, brew: brewOutcome)
                    }
                }
            }
            finishCheck(online: online, cancelled: Task.isCancelled, sparkle: sparkleResults, store: storeResults, brew: brewOutcome, started: started)
        }
    }

    private enum CheckOutcome: Sendable {
        case sparkle(String, UpdatesCheckResult)
        case appStore([String: UpdatesCheckResult])
        case homebrew(UpdatesChecker.HomebrewOutcome?, String?)
    }

    func cancelCheck() {
        checkTask?.cancel()
    }

    /// Picks the most reliable result per app: the App Store for App Store apps, the
    /// developer's feed for Sparkle apps (Homebrew when the feed failed), else Homebrew.
    private func applyResults(paths: [String], sparkle: [String: UpdatesCheckResult], store: [String: UpdatesCheckResult], brew: UpdatesChecker.HomebrewOutcome?) {
        for path in paths {
            guard let index = rows.firstIndex(where: { $0.id == path }) else { continue }
            let row = rows[index]
            let brewResult = brew?.results[path]
            var final: UpdatesCheckResult?
            switch row.mechanism {
            case .appStore:
                final = store[path] ?? brewResult
            case .sparkleFeed:
                if let result = sparkle[path], [.updateAvailable, .upToDate, .incompatible].contains(result.status) {
                    final = result
                } else if let brewResult {
                    final = brewResult
                } else {
                    final = sparkle[path]
                }
            default:
                final = brewResult
            }
            guard var result = final else { continue }
            if result.source != .homebrew, result.status == .updateAvailable, brewResult?.status == .updateAvailable {
                result.homebrewToken = brewResult?.homebrewToken
            }
            result.installedVersionAtCheck = row.installedVersion
            rows[index].result = result
            rows[index].isChecking = false
        }
    }

    private func finishCheck(online: Bool, cancelled: Bool, sparkle: [String: UpdatesCheckResult], store: [String: UpdatesCheckResult], brew: UpdatesChecker.HomebrewOutcome?, started: Date) {
        let now = Date()
        for index in rows.indices {
            rows[index].isChecking = false
            let row = rows[index]
            let checkedNow = (row.result?.checkedAt ?? .distantPast) >= started
            guard !checkedNow else { continue }
            if cancelled {
                continue
            }
            var detail: String
            var status = UpdatesStatus.unknown
            if !online, row.checkableSource != .none {
                status = .notChecked
                detail = "Not checked: online update checks are turned off in Settings."
            } else if let hint = row.mechanism.hint, row.mechanism != .appStore {
                detail = "No update information available. " + hint
            } else {
                detail = "No update information available. The app doesn't publish an update feed Mac Cleaner can check, and it wasn't installed from the App Store or with Homebrew."
            }
            if row.mechanism == .appStore, store[row.id] == nil, online {
                detail = "The App Store couldn't be checked for this app."
                status = .failed
            }
            rows[index].result = UpdatesCheckResult(status: status, source: .none, detail: detail, checkedAt: now, installedVersionAtCheck: row.installedVersion)
        }
        isChecking = false
        checkFraction = 1
        guard !cancelled else {
            checkMessage = "Cancelled"
            return
        }
        lastCheckDate = now
        let results = Dictionary(rows.compactMap { row in row.result.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first })
        UpdatesResultStore.save(UpdatesResultStore.Snapshot(checkedAt: now, results: results))
        let duration = String(format: "%.1f", now.timeIntervalSince(started))
        services.logger.info(
            "Update check: \(availableUpdateCount) update(s) available, \(upToDateCount) up to date, \(unknownCount) without information; \(sparkle.count) feed(s), \(store.count) App Store app(s), Homebrew \(brew == nil ? "not used" : "checked"); \(duration)s",
            category: .updates
        )
    }

    /// Lets people turn on online checks from the page (the setting lives in Settings).
    func allowOnlineChecks() {
        services.settings.checkUpdatesOnline = true
        checkNotice = nil
    }

    // MARK: - Actions

    func openInAppStore(_ row: UpdatesAppRow) {
        guard let url = row.result?.storeURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openAppStoreUpdates() {
        if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
    }

    func openApp(_ row: UpdatesAppRow) {
        let url = row.app.info.url
        Task {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch {
                checkNotice = "The app couldn't be opened: \(error.localizedDescription)"
            }
        }
    }

    func openReleaseNotes(_ row: UpdatesAppRow) {
        guard let url = row.result?.releaseNotesURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func homebrewCask(for row: UpdatesAppRow) -> UpdatesHomebrewCask? {
        homebrewCasks[row.id]
    }

    /// Shows the confirmation for `brew upgrade --cask`.
    func requestHomebrewUpgrade(_ row: UpdatesAppRow) {
        guard brewPath != nil, homebrewCasks[row.id]?.hasSafeToken == true else { return }
        homebrewConfirmationPath = row.id
    }

    func confirmHomebrewUpgrade() {
        guard let path = homebrewConfirmationPath, let brew = brewPath, let cask = homebrewCasks[path],
              let row = rows.first(where: { $0.id == path }) else { return }
        homebrewConfirmationPath = nil
        let run = UpdatesHomebrewRun(appName: row.name, appPath: path, cask: cask, brewPath: brew)
        homebrewRun = run
        run.start(logger: services.logger) { [weak self] succeeded in
            guard succeeded else { return }
            self?.refreshAfterUpgrade(path: path, latest: row.result?.latestVersion)
        }
    }

    /// Re-reads the app after Homebrew replaced it.
    private func refreshAfterUpgrade(path: String, latest: String?) {
        Task {
            guard let info = await BackgroundWork.run(qos: .userInitiated, { ApplicationCatalog.read(path: path) }) else { return }
            await UninstallerInventoryCache.shared.invalidate(path: path)
            update(path) { row in
                row.app.info = info
                row.app.usage = nil
                let installed = info.shortVersion ?? info.buildVersion ?? ""
                let current = latest.map { !UpdatesVersionComparator.isNewer(UpdatesHomebrew.strippingRevision($0), than: installed) } ?? false
                row.result = UpdatesCheckResult(
                    status: current ? .upToDate : .notChecked,
                    source: .homebrew,
                    latestVersion: latest,
                    detail: current ? "Updated with Homebrew." : "Homebrew finished. Check again to confirm the installed version.",
                    checkedAt: Date(),
                    installedVersionAtCheck: info.displayVersion
                )
            }
            startSizing()
        }
    }

    // MARK: - App data and leftovers

    private func selectionDidChange() {
        guard let row = selectedRow, appData[row.id] == nil, !isEnriching else { return }
        loadAppData(for: row)
    }

    /// Finds the selected app's files in Library folders (without permission prompts).
    func loadAppData(for row: UpdatesAppRow) {
        appDataTask?.cancel()
        appDataLoading.insert(row.id)
        let target = row.app
        let others = rows.filter { $0.id != row.id }.map(\.app.identity) + componentApps.map(\.identity)
        let canRead = services.permissions.fullDiskAccess == .granted
        let policy = services.policy
        let scanner = services.scanner
        appDataTask = Task {
            let results = await UninstallerLeftoverService.locateAndMeasure(
                targets: [target], otherApps: others, canReadProtectedAppData: canRead, policy: policy, scanner: scanner
            )
            appDataLoading.remove(row.id)
            guard !Task.isCancelled else { return }
            appData[row.id] = results.first
        }
    }

    /// Size of data left by removed apps, shown as a hint toward the Uninstaller.
    private func scanLeftoverSummary() {
        let apps = rows.map(\.app) + componentApps
        let canRead = services.permissions.fullDiskAccess == .granted
        let exclusions = services.settings.exclusions
        let policy = services.policy
        let scanner = services.scanner
        Task {
            leftoverSummary = try? await UninstallerOrphanService.scan(
                apps: apps, canReadProtectedAppData: canRead, exclusions: exclusions, policy: policy, scanner: scanner
            )
        }
    }
}
