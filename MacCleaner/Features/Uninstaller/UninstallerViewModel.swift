import AppKit
import Foundation
import Observation

/// Drives the Uninstaller: installed apps, their related files, batch uninstall,
/// app reset and leftovers of apps that were already removed.
@MainActor
@Observable
final class UninstallerViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, unused, large, appStore, leftovers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All Apps"
            case .unused: return "Unused 90+ Days"
            case .large: return "Large"
            case .appStore: return "App Store"
            case .leftovers: return "Leftovers of Removed Apps"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .unused: return "moon.zzz"
            case .large: return "externaldrive.fill"
            case .appStore: return "bag"
            case .leftovers: return "shippingbox"
            }
        }
    }

    enum DetailState {
        case loading
        case loaded(UninstallerLocateResult)
    }

    enum OrphanState {
        case notScanned
        case scanning(fraction: Double, message: String)
        case loaded(UninstallerOrphanScanResult)
        case failed(String)
    }

    static let unusedInterval = UninstallerApp.unusedInterval
    static let largeAppBytes = UninstallerApp.largeAppBytes

    let services: AppServices
    let flow = CleanupFlow()
    let orphanSelection = CandidateSelection()
    /// Set by the app shell to open another section (optional).
    @ObservationIgnored var navigate: ((AppSection) -> Void)?

    private(set) var apps: [UninstallerApp] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// The person stopped the first listing of apps.
    private(set) var loadCancelled = false
    private(set) var isEnriching = false
    private(set) var isMeasuringSizes = false
    private(set) var runningBundleIdentifiers: Set<String> = []

    var filter: Filter = .all
    var searchText = ""
    var sortOrder: [KeyPathComparator<UninstallerApp>] = [KeyPathComparator(\UninstallerApp.sortName)]
    var selection: Set<UninstallerApp.ID> = [] {
        didSet { selectionDidChange() }
    }
    var quickLookURL: URL?

    private(set) var details: [String: DetailState] = [:]
    var preview: UninstallerPreviewModel?
    private(set) var orphanState: OrphanState = .notScanned
    private(set) var orphanGroups: [CandidateGroup] = []

    /// Shown after macOS refused to move an app to the Trash.
    var appManagementMessage: String?
    var errorMessage: String?

    @ObservationIgnored private var pendingCleanup: PendingCleanup?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var enrichTask: Task<Void, Never>?
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var orphanTask: Task<Void, Never>?

    private struct PendingCleanup {
        var title: String
        var items: [CleanupItem]
        var warning: String?
        var mode: UninstallerPreviewModel.Mode
        /// Apps the preview was about (uninstalled or reset).
        var targets: [UninstallerApp]
        /// App bundles being removed (uninstall only).
        var apps: [UninstallerApp]
        var agentLabels: [(path: String, label: String)]
    }

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Sorting

    enum SortKey: String, CaseIterable, Identifiable {
        case name, size, lastUsed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size (Largest First)"
            case .lastUsed: return "Last Used (Oldest First)"
            }
        }
    }

    /// The sort menu's view of `sortOrder` (column headers can set other orders too).
    var sortKey: SortKey {
        get {
            switch sortOrder.first?.keyPath {
            case \UninstallerApp.sortSize: return .size
            case \UninstallerApp.sortLastUsed: return .lastUsed
            default: return .name
            }
        }
        set {
            switch newValue {
            case .name: sortOrder = [KeyPathComparator(\UninstallerApp.sortName)]
            case .size: sortOrder = [KeyPathComparator(\UninstallerApp.sortSize, order: .reverse)]
            case .lastUsed: sortOrder = [KeyPathComparator(\UninstallerApp.sortLastUsed), KeyPathComparator(\UninstallerApp.sortName)]
            }
        }
    }

    // MARK: - Derived data

    /// Apps shown in lists (hidden helper components are left out).
    var listedApps: [UninstallerApp] { apps.filter { !$0.isHiddenComponent } }

    var visibleApps: [UninstallerApp] {
        var list = listedApps
        switch filter {
        case .all, .leftovers: break
        case .unused: list = list.filter(isUnused)
        case .large: list = list.filter { ($0.usage?.allocatedBytes ?? 0) >= Self.largeAppBytes }
        case .appStore: list = list.filter { $0.info.isAppStoreApp || $0.isWrappediOSApp }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { app in
                app.name.localizedCaseInsensitiveContains(query)
                    || (app.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                    || (app.developer?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list.sorted(using: sortOrder)
    }

    var selectedApps: [UninstallerApp] { apps.filter { selection.contains($0.id) } }

    var singleSelection: UninstallerApp? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return apps.first { $0.id == id }
    }

    /// Spotlight records app launches; without that data "unused" can't be judged.
    var hasUsageData: Bool { listedApps.contains { $0.lastUsed != nil } }

    func isUnused(_ app: UninstallerApp) -> Bool {
        let now = Date()
        if let lastUsed = app.lastUsed { return now.timeIntervalSince(lastUsed) > Self.unusedInterval }
        // No launch on record: count it only when Spotlight has data for other apps and the app isn't new.
        guard hasUsageData, let installed = app.info.installedDate ?? app.info.modificationDate else { return false }
        return now.timeIntervalSince(installed) > Self.unusedInterval
    }

    func isRunning(_ app: UninstallerApp) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return runningBundleIdentifiers.contains(id)
    }

    var totalAppBytes: Int64 { listedApps.reduce(0) { $0 + ($1.usage?.allocatedBytes ?? 0) } }
    var measuredCount: Int { listedApps.filter { $0.usage != nil }.count }
    var unusedApps: [UninstallerApp] { listedApps.filter(isUnused) }

    var selectedRemovableApps: [UninstallerApp] { selectedApps.filter(\.canUninstall) }

    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + ($1.usage?.allocatedBytes ?? 0) } }

    var orphanResult: UninstallerOrphanScanResult? {
        if case .loaded(let result) = orphanState { return result }
        return nil
    }

    var orphanCandidates: [CleanupCandidate] { orphanGroups.flatMap(\.candidates) }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        enrichTask?.cancel()
        sizeTask?.cancel()
        detailTask?.cancel()
        isLoading = true
        loadCancelled = false
        details = [:]
        let policy = services.policy
        loadTask = Task {
            let loaded = await BackgroundWork.run(qos: .userInitiated) { UninstallerInventory.loadApplications(policy: policy) }
            guard !Task.isCancelled else { return }
            apps = loaded
            selection = selection.filter { id in loaded.contains { $0.id == id } }
            hasLoaded = true
            isLoading = false
            refreshRunningApps()
            startEnrichment()
            startSizing()
            services.logger.info("Listed \(loaded.count) installed apps", category: .uninstall)
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        isLoading = false
        loadCancelled = true
    }

    private func startEnrichment() {
        enrichTask?.cancel()
        let snapshot = apps.filter { !$0.isEnriched }
        guard !snapshot.isEmpty else { return }
        isEnriching = true
        enrichTask = Task {
            for await enriched in UninstallerInventory.enrichmentUpdates(for: snapshot) {
                update(enriched.path) { app in
                    app.signature = enriched.signature
                    app.identity = enriched.identity
                    app.isEnriched = true
                }
            }
            if !Task.isCancelled { isEnriching = false }
        }
    }

    private func startSizing() {
        sizeTask?.cancel()
        let snapshot = apps.filter { $0.usage == nil && !$0.isHiddenComponent }
        guard !snapshot.isEmpty else { return }
        isMeasuringSizes = true
        let scanner = services.scanner
        sizeTask = Task {
            for await (path, usage) in UninstallerInventory.sizeUpdates(for: snapshot, scanner: scanner) {
                update(path) { $0.usage = usage }
            }
            if !Task.isCancelled { isMeasuringSizes = false }
        }
    }

    private func update(_ path: String, _ change: (inout UninstallerApp) -> Void) {
        guard let index = apps.firstIndex(where: { $0.path == path }) else { return }
        change(&apps[index])
    }

    /// Waits until signatures and helpers of all apps are known; leftover matching needs them.
    func waitForInventory() async {
        while isLoading, let task = loadTask { await task.value }
        while isEnriching, let task = enrichTask {
            await task.value
            if task.isCancelled { break }
        }
    }

    func refreshRunningApps() {
        runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // MARK: - Details

    private func selectionDidChange() {
        guard let app = singleSelection, details[app.path] == nil else { return }
        loadDetails(for: app)
    }

    func details(for app: UninstallerApp) -> DetailState? {
        details[app.path]
    }

    func loadDetails(for app: UninstallerApp) {
        detailTask?.cancel()
        details[app.path] = .loading
        let canRead = services.permissions.fullDiskAccess == .granted
        let policy = services.policy
        let scanner = services.scanner
        detailTask = Task {
            await waitForInventory()
            guard !Task.isCancelled, let current = apps.first(where: { $0.path == app.path }) else {
                details[app.path] = nil
                return
            }
            let others = apps.filter { $0.path != current.path }.map(\.identity)
            // Viewing details never triggers macOS permission prompts: protected app data is
            // only measured with Full Disk Access (the uninstall preview measures it on request).
            let results = await UninstallerLeftoverService.locateAndMeasure(
                targets: [current], otherApps: others, canReadProtectedAppData: canRead, policy: policy, scanner: scanner
            )
            guard !Task.isCancelled else {
                details[app.path] = nil
                return
            }
            details[app.path] = .loaded(results.first ?? UninstallerLocateResult())
        }
    }

    // MARK: - Uninstall and reset

    func beginUninstall(_ targets: [UninstallerApp]) {
        let removable = targets.filter(\.canUninstall)
        guard !removable.isEmpty else {
            if let protected = targets.first?.protection { errorMessage = protected.explanation }
            return
        }
        openPreview(UninstallerPreviewModel(mode: .uninstall, apps: removable))
    }

    func beginReset(_ app: UninstallerApp) {
        guard app.protection != .macCleanerItself, app.protection != .partOfMacOS else { return }
        openPreview(UninstallerPreviewModel(mode: .reset, apps: [app]))
    }

    private func openPreview(_ model: UninstallerPreviewModel) {
        preview = model
        let targets = model.apps
        let targetPaths = Set(targets.map(\.path))
        let policy = services.policy
        let scanner = services.scanner
        let task = Task {
            await waitForInventory()
            if Task.isCancelled { return }
            // Use the latest (enriched, measured) data for the apps.
            let current = targets.map { target in apps.first { $0.path == target.path } ?? target }
            let others = apps.filter { !targetPaths.contains($0.path) }.map(\.identity)
            let results = await UninstallerLeftoverService.locateAndMeasure(
                targets: current, otherApps: others, canReadProtectedAppData: true, policy: policy, scanner: scanner
            ) { fraction, message in
                Task { @MainActor in model.setProgress(fraction, message: message) }
            }
            if Task.isCancelled { return }
            let running = await BackgroundWork.run { UninstallerProcessControl.runningProcesses(inside: Array(targetPaths)) }
            model.setRunningProcesses(running)
            model.finishPreparing(results: results)
        }
        model.attach(task)
    }

    /// Called by the preview's primary button: hands the selection to the cleanup flow.
    func confirmPreview() {
        guard let model = preview, model.canConfirm else { return }
        let items = model.cleanupItems()
        guard !items.isEmpty else { return }
        let agents = model.selectedLeftovers.filter { $0.kind == .launchAgents }.compactMap { leftover in
            leftover.launchLabel.map { (path: leftover.path, label: $0) }
        }
        var warnings: [String] = []
        switch model.mode {
        case .uninstall:
            warnings.append("Everything is moved to the Trash, so you can restore it until you empty the Trash.")
        case .reset:
            warnings.append("\(model.apps.first?.name ?? "The app") will start as if newly installed: its settings are lost and you may need to sign in again.")
        }
        if model.selectedSystemWideCount > 0 {
            warnings.append("\(model.selectedSystemWideCount) system-wide item\(model.selectedSystemWideCount == 1 ? " needs" : "s need") an administrator. If they can't be moved, reveal them in Finder and move them to the Trash there (Finder asks for your password).")
        }
        pendingCleanup = PendingCleanup(
            title: model.title,
            items: items,
            warning: warnings.joined(separator: " "),
            mode: model.mode,
            targets: model.apps,
            apps: model.mode == .uninstall ? model.apps : [],
            agentLabels: agents
        )
        model.cancel()
        preview = nil
    }

    /// The preview sheet closed; start the cleanup it confirmed (if any).
    func previewDismissed() {
        preview?.cancel()
        preview = nil
        guard let pending = pendingCleanup else { return }
        pendingCleanup = nil
        flow.requestCleanup(
            title: pending.title,
            items: pending.items,
            services: services,
            regenerableData: false,
            source: .uninstaller,
            warning: pending.warning
        ) { [weak self] report in
            self?.handleReport(report, pending: pending)
        }
    }

    func cancelPreview() {
        pendingCleanup = nil
        preview?.cancel()
        preview = nil
    }

    private func handleReport(_ report: CleanupReport, pending: PendingCleanup) {
        let removed = Set(report.removed.map(\.path))
        let removedApps = pending.apps.filter { removed.contains(PathUtilities.normalize($0.path)) }
        let removedAppPaths = Set(removedApps.map(\.path))
        let leftoversRemoved = report.removed.count - removedApps.count

        if !removedAppPaths.isEmpty {
            apps.removeAll { removedAppPaths.contains($0.path) }
            selection.subtract(removedAppPaths)
            Task {
                for path in removedAppPaths { await UninstallerInventoryCache.shared.invalidate(path: path) }
            }
        }
        for app in pending.targets { details[app.path] = nil }
        if let single = singleSelection, details[single.path] == nil { loadDetails(for: single) }

        // macOS's App Management protection shows up as a permission failure on the app bundle.
        let blockedApps = report.failed.filter { failure in
            pending.apps.contains { PathUtilities.normalize($0.path) == failure.path }
                && (failure.message.localizedCaseInsensitiveContains("permission") || failure.suggestion?.contains("App Management") == true)
        }
        if let blocked = blockedApps.first {
            let name = pending.apps.first { PathUtilities.normalize($0.path) == blocked.path }?.name ?? "the app"
            appManagementMessage = "macOS didn't allow Mac Cleaner to move \(name) to the Trash. Allow Mac Cleaner under Privacy & Security › App Management, then try again — or drag the app to the Trash in Finder."
        }

        // Housekeeping for removed items: stop launch agents that are still loaded and
        // drop cached preferences, so nothing of the removed app keeps running or reappears.
        let labels = pending.agentLabels.filter { removed.contains(PathUtilities.normalize($0.path)) }.map(\.label)
        let removedPaths = Array(removed)
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.path + "/Library"
        if !report.dryRun, !(labels.isEmpty && removedPaths.isEmpty) {
            Task.detached(priority: .utility) {
                await UninstallerProcessControl.bootOut(labels: labels)
                await UninstallerProcessControl.flushPreferenceCaches(removedPaths: removedPaths, homeLibrary: homeLibrary)
            }
        }

        switch pending.mode {
        case .uninstall:
            services.logger.info(
                "Uninstalled \(removedApps.count) of \(pending.apps.count) app(s) and \(max(0, leftoversRemoved)) related item(s), \(ByteFormatting.string(report.bytesRemoved)); \(report.skipped.count) skipped, \(report.failed.count) failed",
                category: .uninstall
            )
        case .reset:
            services.logger.info(
                "Reset an app: \(report.removed.count) item(s), \(ByteFormatting.string(report.bytesRemoved)); \(report.skipped.count) skipped, \(report.failed.count) failed",
                category: .uninstall
            )
        }
        refreshRunningApps()
    }

    // MARK: - Other locations

    /// Lets the person pick an app outside the Applications folders (Downloads, external drives).
    func chooseOtherApp() {
        let urls = services.permissions.chooseItems(message: "Choose an app to uninstall.", allowFiles: true, allowMultiple: false)
        guard let url = urls.first else { return }
        guard url.pathExtension.lowercased() == "app" else {
            errorMessage = "“\(url.lastPathComponent)” isn't an app. Choose an item whose name ends in .app."
            return
        }
        let path = PathUtilities.normalize(url.path)
        if let existing = apps.first(where: { $0.path == path }) {
            filter = .all
            selection = [existing.id]
            return
        }
        let policy = services.policy
        Task {
            guard let app = await BackgroundWork.run(qos: .userInitiated, { UninstallerInventory.loadApplication(at: path, policy: policy) }) else {
                errorMessage = "“\(url.lastPathComponent)” couldn't be read as an app."
                return
            }
            if app.info.isSystemApp {
                errorMessage = UninstallerProtection.partOfMacOS.explanation
                return
            }
            apps.append(app)
            filter = .all
            selection = [app.id]
            startEnrichment()
            startSizing()
        }
    }

    // MARK: - Leftovers of removed apps

    func scanOrphans() {
        orphanTask?.cancel()
        services.permissions.refresh()
        let canRead = services.permissions.fullDiskAccess == .granted
        let exclusions = services.settings.exclusions
        let policy = services.policy
        let scanner = services.scanner
        orphanState = .scanning(fraction: 0, message: "Preparing…")
        orphanTask = Task {
            if !hasLoaded { loadIfNeeded() }
            await waitForInventory()
            guard !Task.isCancelled else { return }
            let snapshot = apps
            do {
                let result = try await UninstallerOrphanService.scan(
                    apps: snapshot, canReadProtectedAppData: canRead, exclusions: exclusions, policy: policy, scanner: scanner
                ) { fraction, message in
                    Task { @MainActor in
                        guard case .scanning = self.orphanState else { return }
                        self.orphanState = .scanning(fraction: fraction, message: message)
                    }
                }
                guard !Task.isCancelled else { return }
                setOrphanResult(result)
                services.logger.info("Found \(result.itemCount) leftover item(s) of \(result.groups.count) removed app(s), \(ByteFormatting.string(result.totalBytes))", category: .uninstall)
            } catch is CancellationError {
                orphanState = .notScanned
            } catch {
                orphanState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelOrphanScan() {
        orphanTask?.cancel()
        orphanState = .notScanned
    }

    private func setOrphanResult(_ result: UninstallerOrphanScanResult) {
        orphanState = .loaded(result)
        orphanGroups = result.groups.map { group in
            let changed = group.newestModification.map { "last changed \(DateFormatting.relative($0))" }
            let explanation = [group.identifier, changed].compactMap { $0 }.joined(separator: " · ")
            var consequence = "No installed app uses these items. They may still belong to a command-line tool or plug-in, so check them before removing."
            if let sibling = group.sameDeveloperAs {
                consequence += " \(sibling), from the same developer, is still installed and might share some of them."
            }
            return CandidateGroup(
                id: group.id,
                title: group.displayName,
                symbol: "shippingbox",
                explanation: explanation,
                consequence: consequence,
                candidates: group.items.map { $0.cleanupCandidate(identifier: group.identifier) }
            )
        }
        orphanSelection.reset(to: orphanCandidates)
    }

    var selectedOrphanBytes: Int64 { orphanSelection.selectedBytes(in: orphanCandidates) }

    func removeSelectedOrphans() {
        let selected = orphanSelection.selected(in: orphanCandidates)
        guard !selected.isEmpty else { return }
        flow.requestCleanup(
            title: "Remove Leftovers of Removed Apps",
            items: selected.map(\.cleanupItem),
            services: services,
            regenerableData: false,
            source: .uninstaller,
            warning: "No installed app uses these items. If one belongs to a command-line tool or plug-in, that tool loses its settings. Everything goes to the Trash first."
        ) { [weak self] report in
            self?.handleOrphanReport(report)
        }
    }

    private func handleOrphanReport(_ report: CleanupReport) {
        let removed = Set(report.removed.map(\.path))
        let removedPaths = Array(removed)
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.path + "/Library"
        if !report.dryRun, !removedPaths.isEmpty {
            Task.detached(priority: .utility) {
                await UninstallerProcessControl.flushPreferenceCaches(removedPaths: removedPaths, homeLibrary: homeLibrary)
            }
        }
        if var result = orphanResult {
            result.groups = result.groups.compactMap { group in
                var copy = group
                copy.items.removeAll { removed.contains(PathUtilities.normalize($0.path)) }
                return copy.items.isEmpty ? nil : copy
            }
            setOrphanResult(result)
        }
        services.logger.info("Removed \(report.removed.count) leftover item(s) of removed apps, \(ByteFormatting.string(report.bytesRemoved)); \(report.skipped.count) skipped, \(report.failed.count) failed", category: .uninstall)
    }

    /// Excludes a leftover from future scans (Settings › Exclusions).
    func exclude(_ candidate: CleanupCandidate) {
        services.settings.addExclusion(candidate.path)
        if var result = orphanResult {
            result.groups = result.groups.compactMap { group in
                var copy = group
                copy.items.removeAll { $0.path == candidate.path }
                return copy.items.isEmpty ? nil : copy
            }
            setOrphanResult(result)
        }
    }
}
