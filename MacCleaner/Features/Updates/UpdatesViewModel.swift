import AppKit
import Foundation
import Observation

/// Drives the Updates page: installed apps with their versions, update checks from the
/// App Store, developers' Sparkle feeds and Homebrew, and Mac Cleaner's own releases.
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
            case .unknown: return "Other Apps"
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

        var help: String {
            switch self {
            case .all: return "Every app Mac Cleaner found, and Mac Cleaner itself"
            case .updates: return "Apps with a newer version"
            case .appStore: return "Apps installed from the App Store"
            case .sparkle: return "Apps that publish a developer update feed"
            case .homebrew: return "Apps installed with Homebrew"
            case .unknown: return "Apps that update themselves or have no update information"
            }
        }
    }

    /// The sections of the list.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case updates, notChecked, upToDate, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .updates: return "Updates Available"
            case .notChecked: return "Not Checked Yet"
            case .upToDate: return "Up to Date"
            case .other: return "Other Apps"
            }
        }

        var subtitle: String {
            switch self {
            case .updates: return "Newer versions from the App Store, developers' update feeds, Homebrew and GitHub."
            case .notChecked: return "Apps whose source of updates can be checked. Click Check for Updates."
            case .upToDate: return "You have the latest version these sources offer."
            case .other: return "These apps update themselves, or don't publish update information Mac Cleaner can read."
            }
        }

        var symbol: String {
            switch self {
            case .updates: return "arrow.down.circle.fill"
            case .notChecked: return "circle.dashed"
            case .upToDate: return "checkmark.circle.fill"
            case .other: return "questionmark.circle.fill"
            }
        }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case name, size, lastUsed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size (Largest First)"
            case .lastUsed: return "Last Used (Recent First)"
            }
        }
    }

    struct Section: Identifiable, Equatable {
        var group: Group
        var rows: [UpdatesAppRow]
        var id: Group { group }
    }

    /// What a row's main button does when an update is available.
    enum UpdateAction: Equatable {
        /// Opens the app's page in the App Store, which installs the update.
        case appStore(URL)
        /// Runs `brew upgrade --cask` after confirmation.
        case homebrew
        /// Opens the app, whose own updater installs the update.
        case openApp
        /// Mac Cleaner's verified download and install.
        case macCleaner
        case none
    }

    /// Inline release notes of a row.
    enum NotesState: Equatable {
        case loading
        case loaded(ReleaseNotesDocument)
        case failed(String)
    }

    /// What "Update All" does, by kind of update.
    struct UpdateAllPlan: Equatable {
        var appStore: [UpdatesAppRow] = []
        var homebrew: [UpdatesHomebrewRun.Item] = []
        /// Apps whose own updater installs the update (they can't be updated from Mac Cleaner).
        var selfUpdating: [UpdatesAppRow] = []
        var macCleaner: UpdatesAppRow?

        var canRun: Bool { !appStore.isEmpty || !homebrew.isEmpty }
        var isEmpty: Bool { appStore.isEmpty && homebrew.isEmpty && selfUpdating.isEmpty && macCleaner == nil }
    }

    let services: AppServices
    let appUpdates: AppUpdateController
    /// Set by the app shell to open another section (optional).
    @ObservationIgnored var navigate: ((AppSection) -> Void)?
    /// Receives an event when a check finds app updates (the menu bar's Activity feed).
    @ObservationIgnored var eventLog: ProtectionEventLog?

    /// Installed apps, without Mac Cleaner itself (see `allRows`).
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
    private(set) var appData: [String: UninstallerLocateResult] = [:]
    private(set) var appDataLoading: Set<String> = []
    /// The running copy of Mac Cleaner, shown as its own row.
    private(set) var selfApp: UninstallerApp?

    var filter: Filter = .all
    var searchText = ""
    var sortKey: SortKey = .name
    var expandedGroups: Set<Group> = [.updates, .notChecked]
    /// The row shown in the inspector.
    var inspectedRowID: UpdatesAppRow.ID? {
        didSet { inspectedRowChanged() }
    }
    private(set) var expandedNotes: Set<UpdatesAppRow.ID> = []
    private(set) var notes: [UpdatesAppRow.ID: NotesState] = [:]
    var isShowingUpdateAll = false
    var homebrewRun: UpdatesHomebrewRun?
    /// Waiting for the person to confirm `brew upgrade` for these apps.
    var pendingHomebrewItems: [UpdatesHomebrewRun.Item]?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var enrichTask: Task<Void, Never>?
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var appDataTask: Task<Void, Never>?
    @ObservationIgnored private var isEnriching = false
    /// Mac Cleaner itself and hidden helper components: not listed, but installed, so
    /// their data is never mistaken for leftovers.
    @ObservationIgnored private var componentApps: [UninstallerApp] = []

    init(services: AppServices, appUpdates: AppUpdateController? = nil, includesMacCleaner: Bool = true) {
        self.services = services
        let controller = appUpdates ?? .shared
        self.appUpdates = controller
        if appUpdates == nil { eventLog = .shared }
        if includesMacCleaner { selfApp = Self.runningApp(version: controller.isSimulated ? controller.currentVersion : nil) }
    }

    /// The running bundle as an app row's app.
    private static func runningApp(version: String?) -> UninstallerApp? {
        guard var info = ApplicationCatalog.read(path: Bundle.main.bundlePath) else { return nil }
        if let version {
            info.shortVersion = version
            info.buildVersion = nil
        }
        return UninstallerApp(
            info: info,
            identity: UninstallerAppIdentity(path: info.path, bundleIdentifier: info.bundleIdentifier, names: [info.name], executableName: info.executableName),
            lastUsed: Date(),
            protection: .macCleanerItself
        )
    }

    // MARK: - Rows

    /// Mac Cleaner's own row: its state comes from `AppUpdateController`.
    var macCleanerRow: UpdatesAppRow? {
        guard let selfApp else { return nil }
        var row = UpdatesAppRow(app: selfApp, mechanism: .github)
        row.isChecking = appUpdates.isChecking
        row.result = macCleanerResult(installed: selfApp.info.displayVersion)
        if let release = appUpdates.latestRelease { row.isSkipped = appUpdates.isSkipped(release) }
        return row
    }

    private func macCleanerResult(installed: String) -> UpdatesCheckResult? {
        if let release = appUpdates.latestRelease {
            var result = UpdatesCheckResult(
                status: .updateAvailable,
                source: .github,
                latestVersion: release.version,
                detail: "Version \(release.version) is available on GitHub. The download is verified (checksum, Developer ID signature and notarization) before it replaces this copy."
                    + (appUpdates.isSkipped(release) ? " You chose to skip this version." : ""),
                checkedAt: appUpdates.lastCheckDate ?? Date(),
                installedVersionAtCheck: installed
            )
            result.releaseNotesURL = release.pageURL
            result.releaseDate = release.publishedAt
            return result
        }
        if let date = appUpdates.lastCheckDate {
            return UpdatesCheckResult(status: .upToDate, source: .github, latestVersion: appUpdates.currentVersion,
                                      detail: "You have the newest release on GitHub.", checkedAt: date, installedVersionAtCheck: installed)
        }
        if let failure = appUpdates.lastFailure {
            return UpdatesCheckResult(status: .failed, source: .github, detail: failure, checkedAt: Date(), installedVersionAtCheck: installed)
        }
        return nil
    }

    /// Every row: installed apps and Mac Cleaner itself.
    var allRows: [UpdatesAppRow] {
        guard let macCleanerRow else { return rows }
        return [macCleanerRow] + rows
    }

    /// Replaces the rows (tests and previews).
    func replaceRows(_ newRows: [UpdatesAppRow], checkedAt: Date? = nil) {
        rows = newRows
        lastCheckDate = checkedAt
        hasLoaded = true
    }

    // MARK: - Derived data

    /// Updates waiting to be installed (a skipped Mac Cleaner version doesn't count).
    var availableUpdateCount: Int {
        rows.filter { $0.status == .updateAvailable }.count + (appUpdates.availableUpdate == nil ? 0 : 1)
    }

    var upToDateCount: Int { allRows.filter { $0.status == .upToDate }.count }
    /// Apps that update themselves or have no reliable information (or couldn't be checked).
    var otherCount: Int { allRows.filter { Self.group(of: $0) == .other }.count }
    var appStoreUpdateCount: Int { rows.filter { $0.status == .updateAvailable && $0.displaySource == .appStore }.count }
    var hasChecked: Bool { lastCheckDate != nil }

    var visibleRows: [UpdatesAppRow] {
        var list = allRows
        switch filter {
        case .all: break
        case .updates: list = list.filter { Self.group(of: $0) == .updates }
        case .appStore: list = list.filter { $0.mechanism == .appStore }
        case .sparkle: list = list.filter { $0.displaySource == .sparkle || $0.checkableSource == .sparkle }
        case .homebrew: list = list.filter { homebrewCasks[$0.id] != nil }
        case .unknown: list = list.filter { Self.group(of: $0) == .other }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { row in
                row.name.localizedCaseInsensitiveContains(query) || (row.app.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return allRows.count
        case .updates: return allRows.filter { Self.group(of: $0) == .updates }.count
        case .appStore: return rows.filter { $0.mechanism == .appStore }.count
        case .sparkle: return rows.filter { $0.displaySource == .sparkle || $0.checkableSource == .sparkle }.count
        case .homebrew: return homebrewCasks.count
        case .unknown: return otherCount
        }
    }

    /// Visible rows grouped into sections, each sorted by `sortKey`.
    var sections: [Section] {
        Self.sections(for: visibleRows, sortedBy: sortKey)
    }

    nonisolated static func sections(for rows: [UpdatesAppRow], sortedBy key: SortKey) -> [Section] {
        let grouped = Dictionary(grouping: rows, by: group(of:))
        return Group.allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            return Section(group: group, rows: sorted(members, by: key))
        }
    }

    /// The section a row belongs in. A row keeps its section while it's being checked.
    nonisolated static func group(of row: UpdatesAppRow) -> Group {
        switch row.result?.status ?? .notChecked {
        case .updateAvailable, .incompatible: return .updates
        case .upToDate: return .upToDate
        case .notChecked, .checking: return .notChecked
        case .unknown, .failed: return .other
        }
    }

    /// Mac Cleaner first, then important updates, installable before incompatible ones,
    /// then by `key` (name breaks ties).
    nonisolated static func sorted(_ rows: [UpdatesAppRow], by key: SortKey) -> [UpdatesAppRow] {
        rows.sorted { lhs, rhs in
            if lhs.isMacCleaner != rhs.isMacCleaner { return lhs.isMacCleaner }
            let lhsImportant = lhs.result?.isCritical == true && lhs.result?.status == .updateAvailable
            let rhsImportant = rhs.result?.isCritical == true && rhs.result?.status == .updateAvailable
            if lhsImportant != rhsImportant { return lhsImportant }
            let lhsIncompatible = lhs.result?.status == .incompatible
            let rhsIncompatible = rhs.result?.status == .incompatible
            if lhsIncompatible != rhsIncompatible { return rhsIncompatible }
            switch key {
            case .name:
                break
            case .size:
                if lhs.sortSize != rhs.sortSize { return lhs.sortSize > rhs.sortSize }
            case .lastUsed:
                if lhs.sortLastUsed != rhs.sortLastUsed { return lhs.sortLastUsed > rhs.sortLastUsed }
            }
            let order = lhs.sortName.localizedStandardCompare(rhs.sortName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    func isExpanded(_ group: Group) -> Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all || expandedGroups.contains(group)
    }

    func toggle(_ group: Group) {
        if expandedGroups.contains(group) { expandedGroups.remove(group) } else { expandedGroups.insert(group) }
    }

    var inspectedRow: UpdatesAppRow? {
        guard let id = inspectedRowID else { return nil }
        return allRows.first { $0.id == id }
    }

    var isInspectorPresented: Bool {
        get { inspectedRowID != nil }
        set { if !newValue { inspectedRowID = nil } }
    }

    func inspect(_ row: UpdatesAppRow) {
        inspectedRowID = inspectedRowID == row.id ? nil : row.id
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
            if let id = inspectedRowID, !allRows.contains(where: { $0.id == id }) { inspectedRowID = nil }
            startSizing()
            startEnrichment()
        }
    }

    /// Measures apps with updates first, so the sizes people look at appear soonest.
    private func startSizing() {
        sizeTask?.cancel()
        var apps = rows.sorted { lhs, rhs in
            let lhsFirst = Self.group(of: lhs) == .updates
            let rhsFirst = Self.group(of: rhs) == .updates
            return lhsFirst != rhsFirst ? lhsFirst : lhs.sortName < rhs.sortName
        }.map(\.app)
        if let selfApp { apps.insert(selfApp, at: 0) }
        let scanner = services.scanner
        sizeTask = Task {
            for await (path, usage) in UninstallerInventory.sizeUpdates(for: apps, scanner: scanner, concurrency: 4) {
                if path == selfApp?.path { selfApp?.usage = usage }
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
            if let row = inspectedRow, appData[row.id] == nil { loadAppData(for: row) }
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
        if online, selfApp != nil {
            Task { await appUpdates.performCheck(manual: true) }
        }
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
            notes[path] = nil
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
        let updates = rows.filter { $0.status == .updateAvailable }
        let duration = String(format: "%.1f", now.timeIntervalSince(started))
        services.logger.info(
            "Update check: \(updates.count) update(s) available, \(upToDateCount) up to date, \(otherCount) without information; \(sparkle.count) feed(s), \(store.count) App Store app(s), Homebrew \(brew == nil ? "not used" : "checked"); \(duration)s",
            category: .updates
        )
        postUpdatesEvent(updates)
    }

    /// "3 app updates available" in the Activity feed, once per change: checking again
    /// and finding the same updates isn't news.
    func postUpdatesEvent(_ updates: [UpdatesAppRow]) {
        guard !updates.isEmpty, let eventLog else { return }
        let names = Self.sorted(updates, by: .name).map(\.name)
        let listed = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        let title = "\(updates.count) app update\(updates.count == 1 ? "" : "s") available"
        let previous = eventLog.events.first { $0.kind == .appUpdateAvailable && $0.title.hasSuffix(" available") && !$0.title.hasPrefix("Mac Cleaner") }
        if previous?.title == title, previous?.detail == listed { return }
        eventLog.post(ProtectionEvent(
            kind: .appUpdateAvailable,
            severity: .recommendation,
            title: title,
            detail: listed,
            section: .updates
        ))
    }

    /// Lets people turn on online checks from the page (the setting lives in Settings).
    func allowOnlineChecks() {
        services.settings.checkUpdatesOnline = true
        checkNotice = nil
    }

    // MARK: - Updating

    func updateAction(for row: UpdatesAppRow) -> UpdateAction {
        guard row.status == .updateAvailable || (row.isChecking && row.result?.status == .updateAvailable) else { return .none }
        if row.isMacCleaner { return .macCleaner }
        if row.displaySource == .appStore, let url = row.result?.storeURL { return .appStore(url) }
        if row.displaySource == .homebrew, canUpgradeWithHomebrew(row) { return .homebrew }
        return .openApp
    }

    func canUpgradeWithHomebrew(_ row: UpdatesAppRow) -> Bool {
        guard brewPath != nil, let cask = homebrewCasks[row.id], cask.hasSafeToken else { return false }
        return row.status == .updateAvailable && (row.displaySource == .homebrew || row.result?.homebrewToken != nil)
    }

    /// Runs the row's update action (Mac Cleaner's own update is opened by the view).
    func performUpdate(_ row: UpdatesAppRow) {
        switch updateAction(for: row) {
        case .appStore(let url): NSWorkspace.shared.open(url)
        case .homebrew: requestHomebrewUpgrade(row)
        case .openApp: openApp(row)
        case .macCleaner, .none: break
        }
    }

    var updateAllPlan: UpdateAllPlan {
        var plan = UpdateAllPlan()
        for row in Self.sorted(allRows.filter { $0.status == .updateAvailable && !$0.isSkipped }, by: .name) {
            switch updateAction(for: row) {
            case .appStore: plan.appStore.append(row)
            case .homebrew:
                if let cask = homebrewCasks[row.id] { plan.homebrew.append(UpdatesHomebrewRun.Item(appName: row.name, appPath: row.id, cask: cask)) }
            case .openApp: plan.selfUpdating.append(row)
            case .macCleaner: plan.macCleaner = row
            case .none: break
            }
        }
        return plan
    }

    /// "Update All": opens the App Store's Updates page and runs one `brew upgrade --cask`
    /// for the Homebrew apps. Apps with their own updater are listed for the person.
    func runUpdateAll(openAppStore: Bool, runHomebrew: Bool) {
        let plan = updateAllPlan
        isShowingUpdateAll = false
        if openAppStore, !plan.appStore.isEmpty { openAppStoreUpdates() }
        if runHomebrew, !plan.homebrew.isEmpty { startHomebrew(plan.homebrew) }
    }

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
                checkNotice = "\(row.name) couldn't be opened: \(error.localizedDescription)"
            }
        }
    }

    /// The developer's release notes page or the cask's homepage, in the browser.
    func openReleaseNotesPage(_ row: UpdatesAppRow) {
        guard let url = row.result?.releaseNotesURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func homebrewCask(for row: UpdatesAppRow) -> UpdatesHomebrewCask? {
        homebrewCasks[row.id]
    }

    /// Asks for confirmation before `brew upgrade --cask`.
    func requestHomebrewUpgrade(_ row: UpdatesAppRow) {
        guard canUpgradeWithHomebrew(row), let cask = homebrewCasks[row.id] else { return }
        pendingHomebrewItems = [UpdatesHomebrewRun.Item(appName: row.name, appPath: row.id, cask: cask)]
    }

    func confirmHomebrewUpgrade() {
        guard let items = pendingHomebrewItems else { return }
        pendingHomebrewItems = nil
        startHomebrew(items)
    }

    private func startHomebrew(_ items: [UpdatesHomebrewRun.Item]) {
        guard let brew = brewPath, homebrewRun?.isRunning != true else { return }
        let run = UpdatesHomebrewRun(items: items, brewPath: brew)
        homebrewRun = run
        run.start(logger: services.logger) { [weak self] succeeded in
            guard succeeded else { return }
            for item in items {
                let latest = self?.rows.first { $0.id == item.appPath }?.result?.latestVersion
                self?.refreshAfterUpgrade(path: item.appPath, latest: latest)
            }
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

    // MARK: - Release notes

    /// Whether the row can show release notes inline (or at least link to them).
    func hasReleaseNotes(_ row: UpdatesAppRow) -> Bool {
        if row.isMacCleaner { return appUpdates.latestRelease?.notes?.isEmpty == false }
        if row.hasEmbeddedReleaseNotes { return true }
        return row.displaySource == .sparkle && row.result?.releaseNotesURL?.scheme?.lowercased() == "https"
    }

    func isShowingNotes(_ row: UpdatesAppRow) -> Bool {
        expandedNotes.contains(row.id)
    }

    func toggleReleaseNotes(_ row: UpdatesAppRow) {
        if expandedNotes.remove(row.id) != nil { return }
        expandedNotes.insert(row.id)
        loadReleaseNotes(row)
    }

    /// Notes the check returned are shown right away; a feed's release-notes page is
    /// read on request (HTTPS only, as text: no scripts or images are loaded).
    func loadReleaseNotes(_ row: UpdatesAppRow) {
        if case .loaded? = notes[row.id] { return }
        if case .loading? = notes[row.id] { return }
        if row.isMacCleaner, let text = appUpdates.latestRelease?.notes {
            notes[row.id] = Self.notesState(.markdown(text))
        } else if let html = row.result?.releaseNotesHTML, !html.isEmpty {
            notes[row.id] = Self.notesState(.detect(html))
        } else if let text = row.result?.releaseNotesText, !text.isEmpty {
            notes[row.id] = Self.notesState(.plainText(text))
        } else if let url = row.result?.releaseNotesURL, url.scheme?.lowercased() == "https" {
            guard services.settings.checkUpdatesOnline else {
                notes[row.id] = .failed("Online update checks are off, so the release notes page wasn't loaded.")
                return
            }
            notes[row.id] = .loading
            let id = row.id
            Task {
                do {
                    let data = try await UpdatesHTTPClient.shared.fetch(url, accept: "text/html, text/markdown, text/plain;q=0.9, */*;q=0.5", maxBytes: 2 * 1024 * 1024)
                    let text = String(decoding: data, as: UTF8.self)
                    notes[id] = Self.notesState(.detect(text))
                } catch {
                    notes[id] = .failed(UpdatesCheckError.wrap(error).localizedDescription)
                }
            }
        } else {
            notes[row.id] = .failed("The developer doesn't publish release notes for this version.")
        }
    }

    private static func notesState(_ document: ReleaseNotesDocument) -> NotesState {
        document.isEmpty ? .failed("The release notes are empty.") : .loaded(document)
    }

    // MARK: - App data

    private func inspectedRowChanged() {
        guard let row = inspectedRow, appData[row.id] == nil, !isEnriching, !row.isMacCleaner else { return }
        loadAppData(for: row)
    }

    /// Finds the inspected app's files in Library folders (without permission prompts).
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
}
