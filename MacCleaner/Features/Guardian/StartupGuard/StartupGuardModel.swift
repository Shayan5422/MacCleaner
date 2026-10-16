import AppKit
import Foundation
import Observation

/// A change that needs the person's confirmation first.
enum GuardianStartupAction: Identifiable {
    /// Turning a launch agent off or on, or removing a login item: the Startup Items page's own actions.
    case startup(StartupPendingAction)
    case turnOffReopen
    case turnOnReopen

    var id: String {
        switch self {
        case .startup(let action): return action.id
        case .turnOffReopen: return "reopen|off"
        case .turnOnReopen: return "reopen|on"
        }
    }

    var title: String {
        switch self {
        case .startup(let action): return action.title
        case .turnOffReopen: return "Don't reopen apps at login?"
        case .turnOnReopen: return "Reopen apps at login again?"
        }
    }

    var message: String {
        switch self {
        case .startup(let action):
            return action.message
        case .turnOffReopen:
            return "When you log out or restart, macOS remembers which apps are open and opens them again at your next login — that's why some apps seem to open by themselves. "
                + "Mac Cleaner turns that off by unchecking “Reopen windows when logging back in” for you (macOS's TALLogoutSavesState setting, for your account only). "
                + "You can still check the box in the logout dialog whenever you want your apps back, or turn it on again here."
        case .turnOnReopen:
            return "macOS will again remember the apps that are open when you log out or restart, and open them at your next login."
        }
    }

    var confirmTitle: String {
        switch self {
        case .startup(let action): return action.confirmTitle
        case .turnOffReopen: return "Don't Reopen"
        case .turnOnReopen: return "Reopen Apps"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .startup(let action): return action.isDestructive
        case .turnOffReopen, .turnOnReopen: return false
        }
    }
}

/// The Startup Guard card an action was started from: only that card shows its confirmation,
/// error and Move to Trash flow, so several cards can sit on one page.
enum GuardianPresenter: String, CaseIterable, Sendable {
    case changes, openedAtLogin, reopen, moreItems
}

/// What the person can do about an app that opened at login.
enum GuardianLoginItemAction: Hashable {
    case removeLoginItem
    case turnOffAgent
    case stopReopening
    case openLoginItemsSettings
    case openApp(path: String)
    case reveal

    var title: String {
        switch self {
        case .removeLoginItem: return "Remove from Login Items…"
        case .turnOffAgent: return "Turn Off…"
        case .stopReopening: return "Don't Reopen Apps…"
        case .openLoginItemsSettings: return "Login Items Settings"
        case .openApp: return "Open App"
        case .reveal: return "Reveal in Finder"
        }
    }

    var symbolName: String {
        switch self {
        case .removeLoginItem: return "minus.circle"
        case .turnOffAgent: return "power"
        case .stopReopening: return "macwindow.badge.plus"
        case .openLoginItemsSettings: return "gearshape"
        case .openApp: return "arrow.up.forward.app"
        case .reveal: return "folder"
        }
    }
}

/// Startup Guard: watches everything that starts automatically and records what changes.
@MainActor
@Observable
final class StartupGuardModel {
    enum ChangeFilter: String, CaseIterable, Identifiable {
        case all, added, removed, changed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .added: return "Added"
            case .removed: return "Removed"
            case .changed: return "Changed"
            }
        }
    }

    enum CheckReason: Sendable {
        case launch, timer, fileChange, manual, afterChange
    }

    // MARK: State

    private(set) var snapshot: GuardianStartupSnapshot?
    private(set) var changes: [GuardianStartupChange] = []
    private(set) var statuses: [GuardianSourceStatus] = []
    private(set) var reopen: GuardianReopenState?
    private(set) var onDemandExtensionCount = 0
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    private(set) var loginAnalysis: GuardianLoginAnalysis?
    private(set) var isAnalyzingLogin = false
    private(set) var backgroundItems: GuardianBackgroundItemsState?
    /// Code signatures of the listed background items' files, by item id.
    private(set) var backgroundItemSignatures: [String: GuardianSignatureSummary] = [:]
    private(set) var isListingBackgroundItems = false
    private(set) var backgroundItemsError: String?
    private(set) var loginItemsAccess: StartupAutomationAccess?
    private(set) var busyIDs: Set<String> = []
    private(set) var isRunning = false

    var changeFilter: ChangeFilter = .all
    var pendingAction: GuardianStartupAction?
    var alertMessage: String?
    /// The card that shows `pendingAction` and `alertMessage`.
    private(set) var presenter: GuardianPresenter?
    var statusMessage: String?
    var navigate: ((AppSection) -> Void)?
    /// Plugged in by the coordinator to scan new startup items' programs with the antivirus engine.
    var scanHook: GuardianStartupScanHook?

    let services: AppServices
    let settings: GuardianSettings
    /// One Move to Trash flow per card (see `GuardianPresenter`).
    let cleanupFlows: [GuardianPresenter: CleanupFlow]

    @ObservationIgnored private let eventLog: ProtectionEventLog
    @ObservationIgnored private let store: GuardianStartupStore
    @ObservationIgnored private let collector: GuardianStartupCollector
    @ObservationIgnored private let signatures: GuardianSignatureCache
    @ObservationIgnored private let commandRunner: GuardianCommandRunner
    @ObservationIgnored private let checkInterval: TimeInterval
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: GuardianFileWatcher?
    @ObservationIgnored private var pendingReason: CheckReason?
    @ObservationIgnored private var lastLoginItemsRead: Date?
    @ObservationIgnored private var hasLoaded = false

    init(
        services: AppServices,
        settings: GuardianSettings,
        eventLog: ProtectionEventLog = .shared,
        storageDirectory: URL? = GuardianStorage.defaultDirectory,
        paths: GuardianStartupCollector.Paths = .live,
        checkInterval: TimeInterval = 600,
        commandRunner: @escaping GuardianCommandRunner = GuardianCommands.live
    ) {
        self.services = services
        self.settings = settings
        self.eventLog = eventLog
        self.store = GuardianStartupStore(directory: storageDirectory)
        let signatures = GuardianSignatureCache()
        self.signatures = signatures
        self.collector = GuardianStartupCollector(paths: paths, signatures: signatures)
        self.checkInterval = checkInterval
        self.commandRunner = commandRunner
        self.cleanupFlows = Dictionary(uniqueKeysWithValues: GuardianPresenter.allCases.map { ($0, CleanupFlow()) })
    }

    func cleanupFlow(for presenter: GuardianPresenter) -> CleanupFlow {
        cleanupFlows[presenter] ?? CleanupFlow()
    }

    // MARK: - Lifecycle

    /// Loads the stored state (once) without starting any background work.
    func loadStoredState() {
        guard !hasLoaded else { return }
        hasLoaded = true
        snapshot = store.loadSnapshot()
        changes = store.loadChanges()
        backgroundItems = store.loadBackgroundItems()
        loginAnalysis = store.loadLoginAnalysis()
        lastCheck = snapshot?.updatedAt
    }

    /// Checks now, then every ~10 minutes and whenever a launch agent folder changes (idempotent).
    func start() {
        loadStoredState()
        guard !isRunning else { return }
        isRunning = true
        // The launch check first, so the login analysis can match what it finds.
        loginTask = Task { [weak self] in
            await self?.check(reason: .launch)
            guard let self, self.settings.analyzeLogin, !Task.isCancelled else { return }
            await self.analyzeLoginIfNeeded()
        }

        let interval = checkInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
                guard !Task.isCancelled else { return }
                if let model = self { await model.check(reason: .timer) } else { return }
            }
        }

        let watched = collector.paths.watchedFolders
        let watcher = GuardianFileWatcher(paths: watched, latency: 3) { [weak self] changed in
            Task { @MainActor in self?.filesChanged(changed) }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        loginTask?.cancel()
        loginTask = nil
        watcher?.stop()
        watcher = nil
    }

    func settingsChanged(_ key: GuardianSettings.Key) {
        // Turned on while running: analyze the current login now (it's done at most once per login).
        if key == .analyzeLogin, settings.analyzeLogin, isRunning, !isAnalyzingLogin {
            Task { [weak self] in await self?.analyzeLoginIfNeeded() }
        }
    }

    /// FSEvents callback: only property lists and the loginwindow preferences matter.
    private func filesChanged(_ paths: [String]) {
        let folders = collector.paths
        let relevant = paths.contains { path in
            if path.contains("/LaunchAgents") || path.contains("/LaunchDaemons") { return path.hasSuffix(".plist") || path.hasSuffix("LaunchAgents") || path.hasSuffix("LaunchDaemons") }
            if path.hasPrefix(folders.byHost) { return path.contains("com.apple.loginwindow.") }
            return path.hasPrefix(folders.backgroundTaskAgentFolder)
        }
        guard relevant, settings.watchStartupItems else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // Installers often write several files in a row: wait until it's quiet.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.check(reason: .fileChange)
        }
    }

    // MARK: - Checking

    /// Reads everything, compares it with the last check, and reports what changed.
    func check(reason: CheckReason) async {
        loadStoredState()
        guard settings.watchStartupItems || reason == .manual || reason == .afterChange else { return }
        if isChecking {
            pendingReason = reason == .manual || pendingReason == .manual ? .manual : reason
            return
        }
        isChecking = true
        defer { isChecking = false }

        var current: CheckReason? = reason
        while let next = current {
            current = nil
            await performCheck(reason: next)
            if let pending = pendingReason {
                pendingReason = nil
                current = pending
            }
        }
    }

    private func performCheck(reason: CheckReason) async {
        let loginItems = await readLoginItems(reason: reason)
        var request = GuardianStartupCollector.Request(loginItems: loginItems.records, loginItemsState: loginItems.state)
        request.includeExtensions = reason != .fileChange && reason != .afterChange
        let collection = await collector.collect(request)
        ingest(collection)
    }

    /// Takes in one check: compares it with the snapshot, records and reports the changes.
    func ingest(_ collection: GuardianStartupCollection) {
        loadStoredState()
        reopen = collection.reopen ?? reopen
        if collection.statuses.contains(where: { $0.source == .appExtensions && $0.isCovered }) {
            onDemandExtensionCount = collection.onDemandExtensionCount
        }
        apply(collection)
        lastCheck = max(lastCheck ?? collection.date, collection.date)
    }

    /// Statuses of this check, keeping the last known status of sources it skipped.
    private func mergedStatuses(_ fresh: [GuardianSourceStatus]) -> [GuardianSourceStatus] {
        var bySource = Dictionary(statuses.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        for status in fresh where status.state != .notChecked || bySource[status.source] == nil {
            bySource[status.source] = status
        }
        return GuardianStartupSource.allCases.compactMap { bySource[$0] }
    }

    /// Merges a collection into the snapshot and reports the changes.
    private func apply(_ collection: GuardianStartupCollection) {
        // Stored state must be in memory before anything is compared or saved.
        loadStoredState()
        statuses = mergedStatuses(collection.statuses)
        let result = GuardianStartupDiff.merge(previous: snapshot, collection: collection)
        snapshot = result.snapshot
        let store = self.store
        let snapshotCopy = result.snapshot
        Task { await store.save(snapshot: snapshotCopy) }
        guard !result.changes.isEmpty else { return }
        record(result.changes)
    }

    private func record(_ newChanges: [GuardianStartupChange]) {
        var newChanges = newChanges
        let canScan = settings.scanNewStartupItems && scanHook != nil
        for index in newChanges.indices where canScan && Self.wantsScan(newChanges[index]) {
            newChanges[index].isScanning = true
        }
        changes = GuardianStartupStore.appending(newChanges, to: changes)
        persistChanges()
        for change in newChanges { postEvent(for: change) }
        notify(about: newChanges)
        services.logger.info("Startup Guard: \(newChanges.count) change(s) since the last check", category: .startup)
        if canScan, let hook = scanHook {
            for change in newChanges where change.isScanning {
                scan(change, hook: hook)
            }
        }
    }

    nonisolated static func wantsScan(_ change: GuardianStartupChange) -> Bool {
        guard change.kind == .added || change.isSecurityRelevantChange, let path = change.record.programPath else { return false }
        return LaunchdPathProbe.status(path) == .exists && change.record.signature?.category != .apple
    }

    private func persistChanges() {
        let store = self.store
        let copy = changes
        Task { await store.save(changes: copy) }
    }

    // MARK: Events and notifications

    private func postEvent(for change: GuardianStartupChange) {
        let record = change.record
        let name = record.displayName
        let kind: ProtectionEvent.Kind
        let title: String
        switch change.kind {
        case .added:
            kind = .startupItemAdded
            title = "New startup item: “\(name)”"
        case .removed:
            kind = .startupItemRemoved
            title = "Startup item removed: “\(name)”"
        case .changed:
            kind = .startupItemChanged
            title = change.isRoutineUpdate ? "Startup item updated: “\(name)”" : "Startup item changed: “\(name)”"
        }
        var parts = [record.kind.title]
        if change.kind != .added || !record.willStartAutomatically { parts.append(change.summary) }
        if change.kind != .removed, let signature = record.signature { parts.append(signature.summary) }
        if name != record.name { parts.append(record.name) }
        eventLog.post(ProtectionEvent(date: change.date, kind: kind, severity: change.severity, title: title,
                                      detail: parts.joined(separator: " · "), path: record.revealPath, section: .startup))
    }

    /// Notification text for a new item: "“X” will start automatically — signed by Y."
    nonisolated static func notificationBody(for record: GuardianStartupRecord) -> String {
        let phrase = record.signature?.notificationPhrase ?? "signature not checked"
        return "“\(record.displayName)” will start automatically — \(phrase)."
    }

    private func notify(about newChanges: [GuardianStartupChange]) {
        var messages: [(title: String, body: String, id: String)] = []
        // A list the person asked for is on screen already: record its changes without notifying.
        for change in newChanges where change.record.source != .registeredItems {
            let record = change.record
            switch change.kind {
            case .added where settings.notifyNewStartupItems && record.willStartAutomatically:
                messages.append(("New Startup Item", Self.notificationBody(for: record), "guardian.startup." + record.id))
            case .changed where settings.notifyNewStartupItems && change.isSecurityRelevantChange:
                let phrase = record.signature?.notificationPhrase ?? "signature not checked"
                messages.append(("Startup Item Changed", "“\(record.displayName)” now runs \(record.programPath.map(PathUtilities.abbreviate) ?? "a different program") — \(phrase).",
                                 "guardian.startup.change." + record.id))
            case .removed where settings.notifyOtherStartupChanges:
                messages.append(("Startup Item Removed", "“\(record.displayName)” no longer starts automatically.", "guardian.startup.removed." + record.id))
            case .changed where settings.notifyOtherStartupChanges && change.fields.contains(.enabled):
                messages.append(("Startup Item \(record.isEnabled == true ? "Turned On" : "Turned Off")",
                                 "“\(record.displayName)” \(record.isEnabled == true ? "will start automatically again" : "won't start automatically any more").",
                                 "guardian.startup.toggle." + record.id))
            default:
                break
            }
        }
        guard !messages.isEmpty else { return }
        let notifications = services.notifications
        if messages.count > 4 {
            let names = newChanges.prefix(3).map { "“\($0.record.displayName)”" }.joined(separator: ", ")
            let body = "\(names) and \(newChanges.count - 3) more. Open Startup Items in Mac Cleaner to review them."
            Task { await notifications.post(title: "\(messages.count) Startup Changes", body: body, identifier: "guardian.startup.summary", section: .startup) }
            return
        }
        for message in messages {
            Task { await notifications.post(title: message.title, body: message.body, identifier: message.id, section: .startup) }
        }
    }

    private func scan(_ change: GuardianStartupChange, hook: @escaping GuardianStartupScanHook) {
        guard let path = change.record.programPath else { return }
        let id = change.id
        Task { [weak self] in
            let verdict = await hook(path)
            guard let self, let index = self.changes.firstIndex(where: { $0.id == id }) else { return }
            self.changes[index].isScanning = false
            self.changes[index].verdict = verdict
            self.persistChanges()
            guard let verdict, !verdict.isClean else { return }
            let record = self.changes[index].record
            self.eventLog.post(ProtectionEvent(kind: .threatFound, severity: .threat,
                                               title: "Threat found in startup item “\(record.displayName)”",
                                               detail: verdict.detections.joined(separator: ", "), path: path, section: .antivirus))
            let notifications = self.services.notifications
            let body = "“\(record.displayName)” starts automatically and its program matches \(verdict.detections.first ?? "a malware signature"). Open Mac Cleaner to deal with it."
            Task { await notifications.post(title: "Threat in a Startup Item", body: body, identifier: "guardian.startup.threat." + record.id, section: .antivirus) }
        }
    }

    // MARK: Login items

    private func readLoginItems(reason: CheckReason) async -> (records: [StartupLoginItemRecord]?, state: GuardianSourceStatus.State) {
        let recentlyRead = lastLoginItemsRead.map { Date().timeIntervalSince($0) < 30 * 60 } ?? false
        switch reason {
        case .manual, .launch, .afterChange:
            break
        case .timer, .fileChange:
            // System Events has to be running to answer; don't start it more than every half hour.
            if recentlyRead && !StartupLoginItemsService.isSystemEventsRunning() { return (nil, .notChecked) }
        }
        let access = await StartupLoginItemsService.automationAccess(promptIfNeeded: false)
        loginItemsAccess = access
        guard access == .granted else {
            return (nil, access == .denied || access == .notDetermined ? .needsAutomation : .failed)
        }
        do {
            let records = try StartupLoginItemsService.readLoginItems()
            lastLoginItemsRead = Date()
            return (records, .read)
        } catch StartupLoginItemsError.notAuthorized {
            loginItemsAccess = .denied
            return (nil, .needsAutomation)
        } catch {
            return (nil, .failed)
        }
    }

    // MARK: - Login analysis

    /// Works out what opened automatically at the last login, once per login.
    func analyzeLoginIfNeeded(force: Bool = false) async {
        guard settings.analyzeLogin || force else { return }
        loadStoredState()
        let processes = await BackgroundWork.run(qos: .utility) { ProcessInspector.allProcesses() }
        let consoleLogin = await BackgroundWork.run(qos: .utility) { GuardianLoginClock.consoleLoginDate() }
        guard let login = GuardianLoginClock.estimate(consoleLogin: consoleLogin, processes: processes) else { return }
        if !force, let stored = loginAnalysis, abs(stored.loginDate.timeIntervalSince(login.date)) < 5 { return }

        // Give apps that open at login a moment to finish launching.
        let ready = login.date.addingTimeInterval(150)
        if ready > Date() {
            try? await Task.sleep(for: .seconds(ready.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
        }
        isAnalyzingLogin = true
        defer { isAnalyzingLogin = false }

        let client = LaunchctlClient()
        async let gui = client.loadedServices(domain: .currentUser)
        async let system = client.loadedServices(domain: .system)
        async let appInfoOutput = try? ProcessRunner.run("/usr/bin/lsappinfo", arguments: ["list"], timeout: 15)
        let freshProcesses = await BackgroundWork.run(qos: .utility) { ProcessInspector.allProcesses() }
        let apps = NSWorkspace.shared.runningApplications.map(GuardianRunningApp.init(app:))
        let appInfo = (await appInfoOutput).map { GuardianLSAppInfoParser.parse($0.standardOutput) } ?? []
        let context = GuardianLoginAnalyzer.Context(
            login: login,
            apps: apps,
            processes: freshProcesses,
            appInfo: appInfo,
            launchd: GuardianStartupCollector.LaunchdState(gui: await gui, system: await system, guiOverrides: [:], systemOverrides: [:]),
            records: snapshot?.records ?? [],
            reopen: reopen ?? GuardianReopenReader.readLive()
        )
        let signatures = self.signatures
        let analysis = await BackgroundWork.run(qos: .utility) { () -> GuardianLoginAnalysis in
            var result = GuardianLoginAnalyzer.analyze(context)
            for index in result.items.indices {
                result.items[index].signature = signatures.summary(for: result.items[index].path)
            }
            return result
        }
        let isNewLogin = loginAnalysis.map { abs($0.loginDate.timeIntervalSince(analysis.loginDate)) >= 5 } ?? true
        loginAnalysis = analysis
        let store = self.store
        Task { await store.save(loginAnalysis: analysis) }
        if isNewLogin { postLoginEvent(analysis) }
        recordAppLoginItems(from: analysis)
    }

    private func postLoginEvent(_ analysis: GuardianLoginAnalysis) {
        let items = analysis.items
        guard !items.isEmpty else { return }
        let apps = analysis.apps
        let title: String
        if items.count == 1 {
            title = "“\(items[0].name)” opened at login"
        } else if apps.count == items.count {
            title = "\(apps.count) apps opened at login"
        } else {
            title = "\(items.count) items opened at login"
        }
        let names = items.prefix(4).map(\.name).joined(separator: ", ") + (items.count > 4 ? " and \(items.count - 4) more" : "")
        eventLog.post(ProtectionEvent(date: analysis.analyzedAt, kind: .openedAtLogin, severity: .info, title: title, detail: names, section: .startup))
    }

    /// Apps macOS opened for the app itself (registered with SMAppService) become startup records.
    private func recordAppLoginItems(from analysis: GuardianLoginAnalysis) {
        var records = GuardianLoginAnalyzer.appLoginRecords(analysis)
        if !analysis.isComplete, let previous = snapshot?.records(of: .appLoginItems) {
            // Started late: apps that quit since login weren't seen, so nothing is treated as removed.
            let seen = Set(records.map(\.id))
            records += previous.filter { !seen.contains($0.id) }
        }
        let collection = GuardianStartupCollection(date: analysis.analyzedAt, records: records,
                                                   statuses: [GuardianSourceStatus(source: .appLoginItems, state: .read, count: records.count)])
        apply(collection)
    }

    // MARK: - Background items (sfltool)

    /// Lists every background item macOS tracks. Only runs when the person asks.
    func listBackgroundItems() async {
        guard !isListingBackgroundItems else { return }
        isListingBackgroundItems = true
        backgroundItemsError = nil
        defer { isListingBackgroundItems = false }
        do {
            let dump = try await GuardianBTMService.dump(runner: GuardianBTMService.liveRunner)
            ingest(dump)
            services.logger.info("Listed \(dump.items.count) background items\(dump.usedAdministrator ? " with administrator rights" : "")", category: .startup)
        } catch GuardianBTMError.cancelled {
            backgroundItemsError = nil
        } catch {
            backgroundItemsError = error.localizedDescription
        }
    }

    /// Takes in a background-item list: marks what's new since the previous list and records the changes.
    func ingest(_ dump: GuardianBTMDump) {
        loadStoredState()
        let state = GuardianBackgroundItemsState.make(dump: dump, previous: backgroundItems)
        backgroundItems = state
        let store = self.store
        Task { await store.save(backgroundItems: state) }
        let records = state.records(now: dump.date)
        apply(GuardianStartupCollection(date: dump.date, records: records,
                                        statuses: [GuardianSourceStatus(source: .registeredItems, state: .read, count: records.count)]))
        Task { await refreshBackgroundItemSignatures() }
    }

    /// Checks the code signatures of the listed items' files (cached by file identity).
    func refreshBackgroundItemSignatures() async {
        guard let items = backgroundItems?.dump.relevantItems() else { return }
        let targets = items.compactMap { item -> (String, String)? in
            guard item.kind.isRunnable, let path = item.executablePath ?? item.path, LaunchdPathProbe.status(path) == .exists else { return nil }
            return (item.id, path)
        }
        let signatures = self.signatures
        let results = await StartupParallel.map(targets, limit: 4) { target in
            (target.0, await BackgroundWork.run(qos: .utility) { signatures.summary(for: target.1) })
        }
        backgroundItemSignatures = Dictionary(results, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Derived state

    var filteredChanges: [GuardianStartupChange] {
        switch changeFilter {
        case .all: return changes
        case .added: return changes.filter { $0.kind == .added }
        case .removed: return changes.filter { $0.kind == .removed }
        case .changed: return changes.filter { $0.kind == .changed }
        }
    }

    func count(of kind: GuardianStartupChange.Kind) -> Int { changes.filter { $0.kind == kind }.count }

    var watchingSince: Date? { snapshot?.createdAt }

    /// Items the Startup Items page doesn't show.
    static let extraSources: [GuardianStartupSource] = [
        .appLoginItems, .cronJobs, .appExtensions, .plugins, .loginHooks, .periodicScripts, .legacyStartupItems, .launchdConf,
    ]

    func records(of source: GuardianStartupSource) -> [GuardianStartupRecord] {
        snapshot?.records(of: source) ?? []
    }

    func status(of source: GuardianStartupSource) -> GuardianSourceStatus? {
        statuses.first { $0.source == source }
    }

    /// The current state of the item a change is about (nil once it's gone).
    func currentRecord(for change: GuardianStartupChange) -> GuardianStartupRecord? {
        snapshot?.records.first { $0.id == change.record.id }
    }

    func isBusy(_ id: String) -> Bool { busyIDs.contains(id) }

    // MARK: - Actions on records

    func canTurnOff(_ record: GuardianStartupRecord) -> Bool {
        guard record.kind == .userAgent, record.isEnabled != false, let label = record.identifier, record.configPath != nil else { return false }
        return LaunchctlClient.isValidLabel(label) && !LaunchctlClient.isProtectedLabel(label)
    }

    func canMoveToTrash(_ record: GuardianStartupRecord) -> Bool {
        guard record.kind == .userAgent, let plist = record.configPath, FileManager.default.fileExists(atPath: plist) else { return false }
        return !(record.identifier.map(LaunchctlClient.isProtectedLabel) ?? false)
    }

    func canRemoveLoginItem(_ record: GuardianStartupRecord) -> Bool { record.kind == .loginItem }

    private func startupItem(for record: GuardianStartupRecord) -> StartupItem? {
        switch record.kind {
        case .userAgent:
            guard let plist = record.configPath else { return nil }
            return StartupInventoryScanner.makeLaunchdItem(path: plist, linkDestination: nil, kind: .userAgent, bundlePath: nil)
        case .loginItem:
            var item = StartupItem(id: "loginItem|\(record.name)|\(record.programPath ?? "")", kind: .loginItem, name: record.name)
            item.targetPath = record.programPath
            if let owner = record.ownerPath { item.owner = StartupOwnerApp(name: record.name, path: owner, bundleIdentifier: record.identifier, lastUsedDate: nil) }
            return item
        default:
            return nil
        }
    }

    func requestTurnOff(_ record: GuardianStartupRecord, from presenter: GuardianPresenter) {
        self.presenter = presenter
        guard canTurnOff(record), let item = startupItem(for: record), item.canToggle else {
            alertMessage = "“\(record.displayName)” can't be turned off from Mac Cleaner. Use System Settings › General › Login Items & Extensions."
            return
        }
        pendingAction = .startup(.disable(item))
    }

    func requestRemoveLoginItem(_ record: GuardianStartupRecord, from presenter: GuardianPresenter) {
        guard let item = startupItem(for: record), item.canRemoveLoginItem else { return }
        self.presenter = presenter
        pendingAction = .startup(.removeLoginItem(item))
    }

    func requestReopenChange(turnOn: Bool, from presenter: GuardianPresenter) {
        self.presenter = presenter
        pendingAction = turnOn ? .turnOnReopen : .turnOffReopen
    }

    /// Performs a confirmed change.
    func perform(_ action: GuardianStartupAction) async {
        if pendingAction?.id == action.id { pendingAction = nil }
        busyIDs.insert(action.id)
        defer { busyIDs.remove(action.id) }
        do {
            switch action {
            case .startup(let startupAction):
                let item = startupAction.item
                switch startupAction {
                case .disable:
                    guard let label = item.label else { throw LaunchctlError.invalidLabel }
                    try await LaunchctlClient().disableUserAgent(label: label)
                    statusMessage = "“\(item.name)” is turned off and won't start at login."
                    services.logger.info("Startup Guard turned off a user launch agent", category: .startup)
                case .enable:
                    guard let label = item.label, let plist = item.plistPath else { throw LaunchctlError.invalidLabel }
                    try await LaunchctlClient().enableUserAgent(label: label, plistPath: plist)
                    statusMessage = "“\(item.name)” is turned on."
                case .removeLoginItem:
                    try StartupLoginItemsService.deleteLoginItem(named: item.name, expectedPath: item.targetPath)
                    statusMessage = "“\(item.name)” no longer opens at login."
                    services.logger.info("Startup Guard removed a login item", category: .startup)
                }
            case .turnOffReopen, .turnOnReopen:
                let turnOn: Bool
                if case .turnOnReopen = action { turnOn = true } else { turnOn = false }
                let state = reopen ?? GuardianReopenReader.readLive()
                guard let state else { throw GuardianReopenError.unreadable }
                try await GuardianReopenCommands.apply(turnOn ? GuardianReopenCommands.turnOn(state) : GuardianReopenCommands.turnOff(state),
                                                       runner: commandRunner)
                reopen?.savesState = turnOn
                statusMessage = turnOn ? "macOS will reopen your open apps at the next login." : "Apps won't reopen by themselves at your next login."
                services.logger.info("Startup Guard changed Reopen windows at login (\(turnOn ? "on" : "off"))", category: .startup)
            }
        } catch StartupLoginItemsError.notAuthorized {
            loginItemsAccess = .denied
            alertMessage = StartupLoginItemsError.notAuthorized.localizedDescription
        } catch {
            alertMessage = error.localizedDescription
        }
        // cfprefsd writes preference files shortly after a change.
        try? await Task.sleep(for: .milliseconds(800))
        await check(reason: .afterChange)
    }

    /// Moves a user launch agent's property list to the Trash through the shared cleanup flow, then stops it.
    func requestMoveToTrash(_ record: GuardianStartupRecord, from presenter: GuardianPresenter) {
        guard canMoveToTrash(record), let plist = record.configPath, let item = startupItem(for: record) else { return }
        self.presenter = presenter
        let size = ((try? FileManager.default.attributesOfItem(atPath: plist))?[.size] as? NSNumber)?.int64Value ?? 0
        let cleanupItem = CleanupItem(path: plist, purpose: .applicationData, snapshot: FileSnapshot.capture(path: plist),
                                      estimatedBytes: size, category: "Launch agents")
        let label = record.identifier
        cleanupFlow(for: presenter).requestCleanup(
            title: "Remove “\(record.displayName)”",
            items: [cleanupItem],
            services: services,
            regenerableData: false,
            warning: "The property list moves to the Trash and the agent stops now. The program it runs stays installed, and the app that created it may add it again the next time it opens. "
                + item.consequenceOfDisabling
        ) { [weak self] report in
            guard let self else { return }
            let removed = report.removed.contains { $0.path == PathUtilities.normalize(plist) }
            Task { @MainActor in
                if removed, let label, LaunchctlClient.isValidLabel(label), !LaunchctlClient.isProtectedLabel(label) {
                    do {
                        try await LaunchctlClient().bootoutUserAgent(label: label)
                    } catch {
                        self.alertMessage = "The property list was moved to the Trash, but the agent couldn't be stopped now: \(error.localizedDescription) It won't start at your next login."
                    }
                    self.services.logger.info("Startup Guard moved a user launch agent to the Trash", category: .startup)
                }
                await self.check(reason: .afterChange)
            }
        }
    }

    // MARK: - Actions for "opened at login"

    func actions(for item: GuardianOpenedAtLoginItem) -> [GuardianLoginItemAction] {
        var result: [GuardianLoginItemAction] = []
        switch item.cause {
        case .loginItem:
            result.append(.removeLoginItem)
        case .appLoginItem:
            result += [.openLoginItemsSettings, .openApp(path: item.path)]
        case .reopened:
            if reopen?.savesState != false { result.append(.stopReopening) }
        case .launchAgent(let label, let plist, let isUserAgent):
            if isUserAgent, plist != nil, !LaunchctlClient.isProtectedLabel(label) {
                result.append(.turnOffAgent)
            } else {
                result.append(.openLoginItemsSettings)
            }
        case .appHelper(_, let appPath):
            result += [.openLoginItemsSettings, .openApp(path: appPath)]
        case .openedByApp, .unknown:
            result.append(.openLoginItemsSettings)
        }
        result.append(.reveal)
        return result
    }

    func perform(_ action: GuardianLoginItemAction, for item: GuardianOpenedAtLoginItem) {
        switch action {
        case .removeLoginItem:
            if let record = records(of: .loginItems).first(where: { $0.programPath == item.path }) {
                requestRemoveLoginItem(record, from: .openedAtLogin)
            } else {
                var login = StartupItem(id: "loginItem|\(item.name)|\(item.path)", kind: .loginItem, name: item.name)
                login.targetPath = item.path
                presenter = .openedAtLogin
                pendingAction = .startup(.removeLoginItem(login))
            }
        case .turnOffAgent:
            guard case .launchAgent(let label, _, _) = item.cause,
                  let record = (records(of: .userLaunchAgents)).first(where: { $0.identifier == label }) else {
                openLoginItemsSettings()
                return
            }
            requestTurnOff(record, from: .openedAtLogin)
        case .stopReopening:
            requestReopenChange(turnOn: false, from: .openedAtLogin)
        case .openLoginItemsSettings:
            openLoginItemsSettings()
        case .openApp(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        case .reveal:
            FinderActions.reveal(item.path)
        }
    }

    // MARK: - Shortcuts

    func openStartupItems() { navigate?(.startup) }
    func openLoginItemsSettings() { services.permissions.open(.loginItems) }
    func openAutomationSettings() { services.permissions.open(.automation) }
    func openFullDiskAccessSettings() { services.permissions.open(.fullDiskAccess) }

    func reveal(_ record: GuardianStartupRecord) {
        guard let path = record.revealPath, FileManager.default.fileExists(atPath: path) else { return }
        FinderActions.reveal(path)
    }

    func clearChanges() {
        changes = []
        persistChanges()
    }
}

enum GuardianReopenError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "The reopen-at-login setting couldn't be read, so it wasn't changed."
    }
}

extension GuardianRunningApp {
    @MainActor
    init(app: NSRunningApplication) {
        let presentation: GuardianAppPresentation
        switch app.activationPolicy {
        case .regular: presentation = .regular
        case .accessory: presentation = .menuBar
        default: presentation = .background
        }
        self.init(pid: app.processIdentifier,
                  name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                  bundleIdentifier: app.bundleIdentifier, bundlePath: app.bundleURL?.path,
                  executablePath: app.executableURL?.path, launchDate: app.launchDate, presentation: presentation)
    }
}
