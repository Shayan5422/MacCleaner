import AppKit
import Foundation
import Observation

/// What a port-number search found ("Find a port": typing 3000 answers what listens on :3000, or that it is free).
enum PortLookup: Equatable, Sendable {
    /// One of the scanned groups listens on the port (its rows show the details and Stop).
    case inUse(port: UInt16, groupIDs: [String])
    /// Only the system-wide socket list knows a listener (another user's or a macOS process that isn't scanned).
    case inUseElsewhere(port: UInt16, owners: [PortOtherListener])
    /// Nothing listens on the TCP port, according to the system-wide socket list.
    case free(port: UInt16)
    /// None of this user's processes listens on it; other users' ports couldn't be checked.
    case freeForYou(port: UInt16)
    case checking(port: UInt16)

    var port: UInt16 {
        switch self {
        case .inUse(let port, _), .inUseElsewhere(let port, _), .free(let port), .freeForYou(let port),
             .checking(let port):
            return port
        }
    }
}

/// A process that listens on a port but isn't part of the scanned groups (another user's or a system process).
struct PortOtherListener: Equatable, Sendable, Identifiable {
    let pid: Int32
    let name: String
    let uid: UInt32
    let address: String
    var id: String { "\(pid)|\(address)" }
}

/// State of the Ports tab (ported from PortPilot's AppStore). The UI reads it and calls its actions; nothing in
/// the UI talks to the system.
@MainActor
@Observable
final class PortsModel {
    // MARK: State (read by UI)

    /// Latest scan shown on the page (unfiltered). While the page is hidden newer scans wait in `latest` and are
    /// published when it is shown again, so nothing on the hidden page re-renders in the background.
    private(set) var snapshot: PortScanSnapshot = .empty
    /// Groups after applying settings (category visibility, hidden items), search and sort.
    private(set) var visibleGroups: [PortListenerGroup] = []
    /// Most recent first, at most 20, kept in memory only: the environment may contain secrets.
    private(set) var recentlyStopped: [PortStoppedRecord] = []
    /// Tools whose ports closed while some of their processes kept running ("Still running · no open port").
    private(set) var stillRunning: [PortStillRunningItem] = []
    /// True while a scan runs with the page visible (drives the refresh spinner).
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var lastUpdated: Date?
    /// Group ids with a stop/disable action in flight (UI shows a spinner instead of the Stop button).
    private(set) var busyGroupIDs: Set<String> = []
    /// Recently Stopped records being relaunched.
    private(set) var relaunchingRecordIDs: Set<UUID> = []
    /// Protected folders whose project lookups wait for a macOS folder-access prompt.
    private(set) var foldersAwaitingAccess: [String] = []
    /// Other users' ports were asked for, but macOS didn't provide its system-wide socket list.
    private(set) var otherUsersUnavailable = false
    /// Answer to a port-number search.
    private(set) var portLookup: PortLookup?
    /// Distinct ports of the project groups the person didn't hide (what the menu bar shows). Assigned only when
    /// it changes, so observers re-render only when the number does.
    private(set) var projectPortCount = 0
    /// Distinct ports of the project and background-service groups the person didn't hide.
    private(set) var devPortCount = 0

    /// Transient feedback at the top of the tab.
    var banner: PortBanner? { didSet { scheduleBannerDismissal() } }
    /// "Find a port, process or project": every word must match a port, title, path, command, PID, framework…
    var searchText: String = "" { didSet { searchDidChange() } }
    /// Expanded rows (not persisted). Kill-plan previews are computed for expanded rows only.
    var expandedGroupIDs: Set<String> = [] { didSet { requestMissingPlans() } }
    /// True while someone looks at the list: the page's Ports tab or the menu bar popover (see
    /// `acquireVisibility()`). Becoming visible publishes the newest scan at once and starts a fresh one.
    private(set) var isVisible = false
    /// Keeps scanning (cheaply) while nothing is visible: new-port notifications and the open-port counts.
    var backgroundWatch = false { didSet { if backgroundWatch != oldValue { updatePolling() } } }

    let preferences: NetworkPreferences

    // MARK: Derived (read by UI)

    /// Visible groups bucketed by category, in display order, empty buckets removed.
    var sections: [(category: PortListenerCategory, groups: [PortListenerGroup])] {
        PortListenerCategory.allCases.compactMap { category in
            let groups = visibleGroups.filter { $0.category == category }
            return groups.isEmpty ? nil : (category, groups)
        }
    }

    /// Aggregate usage of project + background service groups.
    var devUsage: PortResourceUsage {
        snapshot.groups.filter { $0.category == .project || $0.category == .service }
            .reduce(.zero) { $0 + $1.usage }
    }

    /// Groups hidden by settings or by the person (not counting search).
    var hiddenCount: Int {
        let ignoredIDs = Set(preferences.hiddenGroupIDs)
        let ignoredPorts = Set(preferences.hiddenPorts)
        return snapshot.groups.filter { group in
            if ignoredIDs.contains(group.id) { return true }
            if !ignoredPorts.isEmpty, group.ports.allSatisfy(ignoredPorts.contains) { return true }
            switch group.category {
            case .project, .service: return false
            case .app: return !preferences.showApps
            case .system: return !preferences.showSystem
            }
        }.count
    }

    func isHeavy(_ group: PortListenerGroup) -> Bool {
        group.usage.cpuPercent >= NetworkPreferences.heavyCPUThreshold
            || group.usage.memoryBytes >= NetworkPreferences.heavyMemoryBytes
    }

    func count(of category: PortListenerCategory) -> Int {
        snapshot.groups.filter { $0.category == category }.count
    }

    func ports(of category: PortListenerCategory) -> Int {
        Set(snapshot.groups.filter { $0.category == category }.flatMap(\.ports)).count
    }

    // MARK: Private state

    @ObservationIgnored let engine: PortScanEngine
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let eventLog: ProtectionEventLog
    @ObservationIgnored private let notifier = PortNewPortNotifier()
    /// Project ports that opened since the previous scan, for the activity feed (its first scan is the baseline,
    /// so launching never floods the feed).
    @ObservationIgnored private let openedPorts = PortNewPortNotifier(categories: [.project])
    @ObservationIgnored private let launchd: PortLaunchdService
    @ObservationIgnored private let pm2: PortPM2Commands
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    /// Kill plans of the expanded rows' listeners (see `killPlanPreview`). Observed: previews appear when they arrive.
    private var plans: [PortProcessIdentity: PortKillPlan] = [:]
    @ObservationIgnored private var recentStops: [RecentStop] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    /// Newest full scan, published or not. Detection and `projectPortCount` use it.
    @ObservationIgnored private var latest: PortScanSnapshot = .empty
    /// `latest` is newer than `snapshot`: publish when the page is shown.
    @ObservationIgnored private var hasUnpublishedScan = false
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var scanInFlightIsFull = false
    /// A full scan was asked for while another scan ran: run one more when it finishes.
    @ObservationIgnored private var fullScanPending = false
    /// `scanOnce` callers waiting for that extra full scan.
    @ObservationIgnored private var fullScanWaiters: [CheckedContinuation<Void, Never>] = []
    /// The "… closed" note on screen, if any: the only banner a newer note may replace.
    @ObservationIgnored private var closedNoteID: UUID?
    @ObservationIgnored private var lastSettingsKey: SettingsKey?
    /// How many views show the list right now (the page's Ports tab, the menu bar popover).
    @ObservationIgnored private var visibilityClaims = 0

    // MARK: Control seams (replaced in tests)

    /// Asks the GUI app running as a pid to quit like ⌘Q does; nil when that pid isn't an app with a UI.
    @ObservationIgnored var askAppToQuit: @MainActor (Int32) -> Bool? = { PortsModel.askRunningAppToQuit(pid: $0) }
    /// Where relaunched servers write their output.
    @ObservationIgnored var relaunchLogDirectory: URL = PortRelauncher.logDirectory
    /// How long a relaunched server gets to open one of its ports before the banner says it isn't listening.
    @ObservationIgnored var relaunchPortTimeout: TimeInterval = 15
    /// Background ticks while the page is hidden.
    @ObservationIgnored var backgroundInterval: TimeInterval = 10
    /// Off in tests, which drive `pollOnce` themselves (and never in the XCTest host, so it doesn't scan the
    /// person's folders).
    @ObservationIgnored var allowsAutomaticPolling = !PortsModel.isTesting

    /// Ports a Stop just closed: if they come back within `respawnWindow` the person learns who restarted them.
    private struct RecentStop {
        let date: Date
        let ports: Set<UInt16>
        let groupTitle: String
    }

    /// Settings that change what a scan returns.
    private struct SettingsKey: Equatable {
        let includeOtherUsers: Bool
    }

    private static let respawnWindow: TimeInterval = 20
    private static let maxRecentlyStopped = 20

    /// - Parameters:
    ///   - launchd / pm2: stand-ins for tests, so nothing reaches the person's own launchd jobs or pm2 daemon.
    ///   - initial: a scan to show right away (tests and previews), before the first own scan.
    init(preferences: NetworkPreferences, notifications: NotificationService = .shared,
         eventLog: ProtectionEventLog = .shared, engine: PortScanEngine = PortScanEngine(),
         launchd: PortLaunchdService? = nil, pm2: PortPM2Commands? = nil, initial: PortScanOutput? = nil) {
        self.preferences = preferences
        self.notifications = notifications
        self.eventLog = eventLog
        self.engine = engine
        self.launchd = launchd ?? engine.launchd
        self.pm2 = pm2 ?? .live(engine.pm2)
        if let initial {
            latest = initial.snapshot
            snapshot = initial.snapshot
            plans = initial.plans
            lastUpdated = initial.snapshot.date
            hasScanned = true
        }
        lastSettingsKey = SettingsKey(includeOtherUsers: preferences.includeOtherUsers)
        recomputeVisible()
        updateProjectPortCount()
        observePreferences()
    }

    // MARK: Visibility

    /// A view that shows the list appeared (the Ports tab, the menu bar popover). Balance with
    /// `releaseVisibility()`. While any claim is held, scans run at the refresh interval set in Settings.
    func acquireVisibility() {
        visibilityClaims += 1
        if visibilityClaims == 1 { setVisible(true) }
    }

    /// The view that called `acquireVisibility()` went away.
    func releaseVisibility() {
        guard visibilityClaims > 0 else { return }
        visibilityClaims -= 1
        if visibilityClaims == 0 { setVisible(false) }
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if hasUnpublishedScan { publish() }
            refreshNow()
        } else if isScanning {
            isScanning = false
        }
        updatePolling()
    }

    // MARK: Polling

    /// True when this process is the XCTest host: polling must not scan the person's folders there.
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func updatePolling() {
        let wanted = isVisible || backgroundWatch
        if wanted, pollTask == nil, allowsAutomaticPolling {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pollOnce()
                    let interval = self.isVisible ? max(1, self.preferences.refreshInterval) : self.backgroundInterval
                    // The tolerance lets macOS coalesce Mac Cleaner's wakeups with others'.
                    try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.25))
                }
            }
        } else if !wanted {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Immediate full rescan (⌘R). Joins a full scan that is already running.
    func refreshNow() {
        guard allowsAutomaticPolling else { return }
        if scanInFlight && scanInFlightIsFull { return }
        Task { await scanOnce() }
    }

    /// Full rescan after an action: rows are rebuilt even if no port changed. If a scan is running it may predate
    /// the action, so another one follows it; either way this returns once a full scan that started after the call
    /// is done.
    func scanOnce() async {
        guard scanInFlight else { return await pollOnce(full: true) }
        fullScanPending = true
        await withCheckedContinuation { fullScanWaiters.append($0) }
    }

    /// One tick of the poll loop (tests drive it directly). With the page hidden and `full` false, a tick whose
    /// listeners didn't change since the last full scan stops after the socket walk and touches no state.
    func pollOnce(full: Bool = false) async {
        guard !scanInFlight else {
            if full { fullScanPending = true }
            return
        }
        scanInFlight = true
        var full = full
        repeat {
            fullScanPending = false
            await scanPass(full: full)
            full = true
        } while fullScanPending
        scanInFlight = false
        let waiters = fullScanWaiters
        fullScanWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func scanPass(full: Bool) async {
        scanInFlightIsFull = full || isVisible
        if isVisible { isScanning = true }
        let request = PortScanEngine.ScanRequest(includeOtherUsers: preferences.includeOtherUsers,
                                                 planGroupIDs: isVisible ? expandedGroupIDs : [],
                                                 skipIfUnchanged: !full && !isVisible)
        if let output = await engine.scan(request) {
            let previous = latest
            apply(output)
            await updateStillRunning(previous: previous)
        } else if !stillRunning.isEmpty {
            await updateStillRunning(previous: nil)
        }
        if isScanning { isScanning = false }
    }

    private func apply(_ output: PortScanOutput) {
        latest = output.snapshot
        updatePlans(output.plans)
        updateProjectPortCount()
        detectNewPorts()
        postOpenedPorts()
        if foldersAwaitingAccess != output.foldersAwaitingAccess { foldersAwaitingAccess = output.foldersAwaitingAccess }
        if otherUsersUnavailable != output.otherUsersUnavailable { otherUsersUnavailable = output.otherUsersUnavailable }
        if isVisible {
            publish()
        } else {
            hasUnpublishedScan = true
        }
    }

    /// Shows `latest` on the page.
    private func publish() {
        hasUnpublishedScan = false
        snapshot = latest
        lastUpdated = latest.date
        hasScanned = true
        recomputeVisible()
        detectRespawns()
    }

    private func updateProjectPortCount() {
        let count = Self.portCount(for: latest.groups, categories: [.project], hiddenGroupIDs: preferences.hiddenGroupIDs)
        if count != projectPortCount { projectPortCount = count }
        let dev = Self.portCount(for: latest.groups, categories: [.project, .service],
                                 hiddenGroupIDs: preferences.hiddenGroupIDs)
        if dev != devPortCount { devPortCount = dev }
    }

    /// Distinct ports owned by project groups the person didn't hide.
    nonisolated static func projectPortCount(for groups: [PortListenerGroup], hiddenGroupIDs: [String]) -> Int {
        portCount(for: groups, categories: [.project], hiddenGroupIDs: hiddenGroupIDs)
    }

    /// Distinct ports owned by groups of `categories` the person didn't hide.
    nonisolated static func portCount(for groups: [PortListenerGroup], categories: Set<PortListenerCategory>,
                                      hiddenGroupIDs: [String]) -> Int {
        let hidden = Set(hiddenGroupIDs)
        return Set(groups.filter { categories.contains($0.category) && !hidden.contains($0.id) }.flatMap(\.ports)).count
    }

    // MARK: Kill-plan previews

    private func updatePlans(_ fresh: [PortProcessIdentity: PortKillPlan]) {
        if !Self.samePlans(plans, fresh) { plans = fresh }
        requestMissingPlans()
    }

    /// Expanded rows whose listeners have no plan yet (just expanded, or expanded during a scan) get theirs
    /// computed on the engine's control queue.
    private func requestMissingPlans() {
        guard isVisible, !expandedGroupIDs.isEmpty else { return }
        let groups = latest.groups.filter { group in
            expandedGroupIDs.contains(group.id)
                && group.processes.contains { !$0.isRestricted && plans[$0.id] == nil }
        }
        guard !groups.isEmpty else { return }
        let engine = engine
        Task {
            let found = await engine.plans(for: groups)
            guard !found.isEmpty else { return }
            let current = Set(latest.groups.flatMap { $0.processes.map(\.id) })
            var merged = plans.filter { current.contains($0.key) }
            for (identity, plan) in found where current.contains(identity) { merged[identity] = plan }
            if !Self.samePlans(plans, merged) { plans = merged }
        }
    }

    /// Plans compare by content, so previews only re-render on change.
    nonisolated static func samePlans(_ lhs: [PortProcessIdentity: PortKillPlan],
                                      _ rhs: [PortProcessIdentity: PortKillPlan]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (identity, plan) in lhs {
            guard let other = rhs[identity], plan.root == other.root, plan.targets == other.targets,
                  plan.summary == other.summary, plan.warnings == other.warnings,
                  plan.requiresAdmin == other.requiresAdmin else { return false }
        }
        return true
    }

    /// The plan of one listener, when its row is expanded.
    func plan(for process: PortListenerProcess) -> PortKillPlan? {
        plans[process.id]
    }

    // MARK: Still running without a port

    /// Compares a new full scan with the previous one (`previous`; nil for a tick that skipped the rebuild): groups
    /// whose ports all closed without Mac Cleaner stopping them either left processes running (listed under "Still
    /// running · no open port") or closed for good (a short note while the page is visible). Existing entries drop
    /// exited processes and go once nothing is left.
    private func updateStillRunning(previous: PortScanSnapshot?) async {
        let before = stillRunning
        var items = before
        var foundIDs = Set<String>()
        if let previous, previous.date != .distantPast {
            let vanished = PortStillRunning.vanishedGroups(
                previous: previous.groups, current: latest.groups,
                stoppedPorts: Set(recentStops.flatMap(\.ports)), busyGroupIDs: busyGroupIDs,
                ignoredGroupIDs: Set(preferences.hiddenGroupIDs), ignoredPorts: Set(preferences.hiddenPorts),
                currentUID: engine.currentUID)
            if !vanished.isEmpty {
                let found = await engine.leftovers(of: vanished, previousTable: previous.table)
                items = PortStillRunning.merged(found, into: items)
                foundIDs = Set(found.map(\.id))
                showClosedNote(for: vanished.filter { !foundIDs.contains($0.id) })
            }
        }
        if !items.isEmpty {
            items = await engine.refreshLeftovers(items, sampleUsage: isVisible)
        }
        // Entries stopped from the page while this ran stay gone.
        let removedMeanwhile = Set(before.map(\.id)).subtracting(stillRunning.map(\.id))
        items.removeAll { removedMeanwhile.contains($0.id) && !foundIDs.contains($0.id) }
        if items != stillRunning { stillRunning = items }
    }

    /// "my-app closed (:5173)" for tools that exited on their own, only while the page is visible, and never over
    /// other feedback: it only replaces an older note.
    private func showClosedNote(for groups: [PortListenerGroup]) {
        guard isVisible, let message = PortStillRunning.closedMessage(for: groups) else { return }
        if let current = banner, current.id != closedNoteID { return }
        let note = PortBanner(style: .info, message: message)
        closedNoteID = note.id
        banner = note
    }

    /// Stops what still runs of a tool that closed its ports (⌥-click: force). Every process is re-verified by
    /// `PortProcessKiller` before it is signalled.
    @discardableResult
    func stopStillRunning(_ item: PortStillRunningItem, mode: PortStopMode = .graceful) -> Task<Void, Never>? {
        guard !busyGroupIDs.contains(item.busyID) else { return nil }
        busyGroupIDs.insert(item.busyID)
        let timeout = preferences.gracefulTimeout
        let killer = engine.killer
        return Task {
            let result = await killer.stop(item.plan, mode: mode, timeout: timeout, allowAdmin: false)
            busyGroupIDs.remove(item.busyID)
            if !result.stopped.isEmpty { postStopped(title: item.title, ports: [], path: item.path) }
            if result.failures.isEmpty {
                stillRunning.removeAll { $0.id == item.id }
                banner = PortBanner(style: .success, message: "Stopped \(item.title)"
                                    + (result.escalated ? " — had to force-stop" : ""))
            } else {
                let reasons = result.failures.prefix(3).map { "pid \($0.pid): \($0.reason)" }
                banner = PortBanner(style: .error, message: "Couldn't fully stop \(item.title): " + reasons.joined(separator: "; "))
            }
            await scanOnce()
        }
    }

    // MARK: Stop

    /// Stop for a whole group (project / service / app). launchd jobs are booted out (stopped until the next
    /// login); apps are asked to quit (they can ask to save); apps and macOS services are never force-stopped by it.
    @discardableResult
    func stop(_ group: PortListenerGroup, mode: PortStopMode = .graceful) -> Task<Void, Never>? {
        startStop(PortStopRequest(group: group, mode: mode, disableAutoStart: false))
    }

    /// Stop one listener's kill plan (or only its PID when `onlyThisProcess`).
    @discardableResult
    func stop(_ process: PortListenerProcess, mode: PortStopMode = .graceful,
              onlyThisProcess: Bool = false) -> Task<Void, Never>? {
        let group = snapshot.groups.first { $0.processes.contains { $0.id == process.id } }
        return startStop(PortStopRequest(processes: [process], groupID: group?.id ?? "pid:\(process.id)",
                                         title: process.displayName, category: group?.category ?? process.category,
                                         mode: mode, onlyThisProcess: onlyThisProcess, disableAutoStart: false))
    }

    /// Stop now AND prevent restarts: launchctl bootout + disable (only for agents the Startup Items page can switch
    /// back on; others are just stopped, with a note) / pm2 delete (+ removed from pm2's saved list) /
    /// docker update --restart=no + stop.
    @discardableResult
    func stopAndDisableAutoStart(_ group: PortListenerGroup) -> Task<Void, Never>? {
        startStop(PortStopRequest(group: group, mode: .graceful, disableAutoStart: true))
    }

    private func startStop(_ request: PortStopRequest) -> Task<Void, Never>? {
        guard !busyGroupIDs.contains(request.groupID) else { return nil }
        busyGroupIDs.insert(request.groupID)
        return Task {
            let outcome = await performStop(request)
            finishStops([outcome])
            banner = PortStopReport.banner(for: outcome)
            await scanOnce()
        }
    }

    /// Runs one Stop and reports what it did. The caller marks the group busy first and does the bookkeeping
    /// (`finishStops`) and the banner afterwards.
    private func performStop(_ request: PortStopRequest) async -> PortStopOutcome {
        var outcome = PortStopOutcome(groupID: request.groupID, title: request.title,
                                      ports: Array(Set(request.processes.flatMap(\.ports))).sorted())
        var plainProcesses: [PortListenerProcess] = []
        var launchdStopped: [String: Bool] = [:]
        var unloadedByLaunchd: [PortListenerProcess] = []
        var handledPM2 = Set<Int>()
        var handledDocker = Set<String>()

        // 1. Processes owned by a manager are stopped through that manager (a plain kill would respawn).
        for process in request.processes {
            switch process.manager {
            case .launchd(let job) where job.isUserAgent && !request.onlyThisProcess:
                if launchdStopped[job.label] == nil {
                    launchdStopped[job.label] = await stopLaunchdJob(job, disable: request.disableAutoStart,
                                                                     outcome: &outcome)
                }
                if launchdStopped[job.label] == true { unloadedByLaunchd.append(process) }
            case .pm2(let id, let name) where !request.onlyThisProcess:
                guard handledPM2.insert(id).inserted else { continue }
                await stopPM2App(id: id, name: name, delete: request.disableAutoStart, outcome: &outcome)
            case .docker(let container):
                guard handledDocker.insert(container.id).inserted else { continue }
                do {
                    if request.disableAutoStart { try await engine.docker.disableRestart(id: container.id) }
                    try await engine.docker.stop(id: container.id)
                    outcome.notes.append("container \(container.name) stopped")
                    outcome.stoppedCount += 1
                } catch {
                    outcome.errors.append("\(container.name): \(error.localizedDescription)")
                }
            default:
                plainProcesses.append(process)
            }
        }

        // 2. bootout only ends the job's own process group: a listener the job detached (setsid, a daemonizing
        //    fork, Node's `detached: true`) keeps running, orphaned. Check, and stop survivors directly.
        if !unloadedByLaunchd.isEmpty {
            let survivors = Set(await PortProcessWatch.survivors(of: unloadedByLaunchd.map(\.id),
                                                                 waitingUpTo: Self.launchdExitWait))
            for process in unloadedByLaunchd where survivors.contains(process.id) {
                plainProcesses.append(process)
                if case .launchd(let job) = process.manager {
                    outcome.notes.append("\(process.displayName) was detached from \(job.label), so it was stopped directly")
                }
            }
        }

        // 3. Everything else: signal the kill plan (whole dev-server tree), or ask an app to quit.
        if !plainProcesses.isEmpty {
            await stopPlainProcesses(plainProcesses, request: request, outcome: &outcome)
        }
        return outcome
    }

    /// How long a launchd-managed listener gets to exit after its job was unloaded before it counts as detached.
    private static let launchdExitWait: TimeInterval = 1.5

    /// Unloads one launchd job (bootout) or, for Stop & Disable, also turns off its auto-start — but only where the
    /// Startup Items page can turn it back on; any other job is only stopped, with a note saying where to turn it
    /// off. Returns false when launchctl failed.
    private func stopLaunchdJob(_ job: PortLaunchdJob, disable: Bool, outcome: inout PortStopOutcome) async -> Bool {
        let label = job.label
        let launchd = launchd
        do {
            let disabled: Bool
            let reversible: Bool
            if disable {
                disabled = try await launchd.stopAndDisableIfReversible(job: job)
                reversible = disabled
            } else {
                // Reads the plist: before bootout.
                reversible = await BackgroundWork.run(qos: .userInitiated) { launchd.canDisableReversibly(job: job) }
                try await launchd.stop(label: label)
                disabled = false
            }
            outcome.stoppedCount += 1
            let manual = "\(label) may start again at login — turn it off in \(PortStopReport.loginItemsSettings)"
            if disable {
                outcome.notes.append(disabled ? "auto-start turned off for \(label)" : manual)
            } else if job.keepAlive || job.runAtLoad {
                if reversible { outcome.autoStartLabels.append(label) } else { outcome.notes.append(manual) }
            }
            return true
        } catch {
            outcome.errors.append("\(label): \(error.localizedDescription)")
            return false
        }
    }

    /// `pm2 stop`, or for Stop & Disable `pm2 delete` plus removing the app from pm2's saved list. Cluster-mode apps
    /// are addressed as a whole; the PM2 daemon itself is never signalled.
    private func stopPM2App(id: Int, name: String, delete: Bool, outcome: inout PortStopOutcome) async {
        do {
            if delete {
                let update = try await pm2.delete(id, name)
                outcome.notes.append("pm2 \(name) removed" + (update.note.map { " — \($0)" } ?? ""))
            } else {
                try await pm2.stop(id)
                outcome.notes.append("pm2 \(name) stopped")
            }
            outcome.stoppedCount += 1
        } catch {
            outcome.errors.append("pm2 \(name): \(error.localizedDescription)")
        }
    }

    /// Signals the fresh kill plans of `listeners` (an app is asked to quit instead) and records what can be
    /// relaunched.
    private func stopPlainProcesses(_ listeners: [PortListenerProcess], request: PortStopRequest,
                                    outcome: inout PortStopOutcome) async {
        var targets = listeners
        var plans = await engine.freshPlans(for: targets, onlyThisProcess: request.onlyThisProcess)
        if plans.isEmpty {
            // Every listener exited since the last scan, and nothing of its launch tree holds its ports. A watcher or
            // the person may have started the server again in a new tree: look again before saying "already exited".
            let found = await listenersAfterRestart(of: targets, groupID: request.groupID)
            if !found.matching.isEmpty {
                targets = found.matching
                plans = await engine.freshPlans(for: targets, onlyThisProcess: false)
            } else if let holder = found.others.first {
                outcome.errors.append("it had already exited, and \(holder) now uses "
                                      + (outcome.ports.count == 1 ? "its port" : "its ports"))
                return
            } else {
                outcome.alreadyExited = true
                return
            }
        }

        let timeout = preferences.gracefulTimeout
        if request.mode == .graceful, request.category == .app {
            // A GUI app quits through its own Quit (it can ask to save), before any of its helpers is signalled;
            // they usually exit with it. While it is still open (a save dialog), its helpers are left alone too.
            plans = await quitApps(in: plans, timeout: timeout, outcome: &outcome)
            if outcome.stillQuitting { return }
        }
        for plan in plans {
            guard !plan.targets.isEmpty else {
                outcome.errors.append(plan.warnings.first ?? "\(plan.root.comm) is protected and was not stopped")
                continue
            }
            let matched = targets.filter { listener in plan.targets.contains { $0.pid == listener.basic.pid } }
            let planListeners = matched.isEmpty && plans.count == 1 ? targets : matched
            // Read the command before stopping: afterwards the tree's argv, environment and cwd are gone. Apps and
            // macOS services get no Recently Stopped record (relaunching a bare helper argv would be wrong).
            let relaunch = request.isAppOrSystem ? nil : await engine.relaunchInfo(for: plan)

            // App helpers and macOS services get SIGTERM only: no SIGKILL unless the person picks Force Stop.
            let result = await engine.killer.stop(plan, mode: request.mode, timeout: timeout,
                                                  allowAdmin: plan.requiresAdmin, escalate: !request.isAppOrSystem)
            outcome.escalated = outcome.escalated || result.escalated
            for failure in result.failures {
                outcome.errors.append("pid \(failure.pid): \(failure.reason)")
            }
            guard !result.stopped.isEmpty else { continue }
            outcome.stoppedCount += 1
            guard let relaunch else { continue }
            let listener = planListeners.first
            let command = relaunch.command
            let record = PortStoppedRecord(
                id: UUID(), date: Date(),
                title: listener.map { "\(request.title) · \($0.displayName)" } ?? request.title,
                ports: Array(Set(planListeners.flatMap(\.ports))).sorted(),
                cwd: command?.cwd ?? relaunch.root?.cwd,
                arguments: command?.arguments ?? relaunch.root?.arguments ?? [],
                environment: command?.environment ?? relaunch.root?.environment ?? [:],
                // nil on purpose for a rebuilt `npm run dev`: npm is then found on the record's PATH.
                executablePath: command != nil ? command?.executablePath : relaunch.root?.executablePath,
                manager: listener?.manager ?? .none)
            outcome.records.append(record)
            if PortStopReport.canRelaunch(record) { outcome.undoRecordIDs.append(record.id) }
        }
    }

    /// Asks every GUI app among the plans' roots to quit (its own Quit: it can ask to save) and waits up to `timeout`
    /// for them; never force-quits. Sets `quitApp` or `stillQuitting`. Returns the plans still to signal.
    private func quitApps(in plans: [PortKillPlan], timeout: TimeInterval,
                          outcome: inout PortStopOutcome) async -> [PortKillPlan] {
        var asked: [PortProcessIdentity] = []
        var remaining: [PortKillPlan] = []
        for plan in plans {
            if !plan.targets.isEmpty, askAppToQuit(plan.root.pid) == true {
                asked.append(plan.root.identity)
            } else {
                remaining.append(plan)
            }
        }
        guard !asked.isEmpty else { return plans }
        if await PortProcessWatch.survivors(of: asked, waitingUpTo: max(1, timeout)).isEmpty {
            outcome.quitApp = true
            outcome.stoppedCount += asked.count
        } else {
            outcome.stillQuitting = true
        }
        return remaining
    }

    /// ⌘Q for the app running as `pid` (`NSRunningApplication.terminate()`); nil when `pid` isn't an app with a UI or
    /// menu bar item (a helper or a background process). Otherwise whether the request was sent.
    static func askRunningAppToQuit(pid: Int32) -> Bool? {
        guard pid > 1, pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular || app.activationPolicy == .accessory else { return nil }
        return app.terminate()
    }

    /// After a Stop found every listener in `stale` gone: scans again and returns the listeners that hold their
    /// ports now in the same group, or with the same command in the same folder (`matching`: a watcher's or the
    /// person's restart of that server), plus the names of any other process on those ports (`others`, never stopped).
    private func listenersAfterRestart(of stale: [PortListenerProcess], groupID: String) async
        -> (matching: [PortListenerProcess], others: [String]) {
        let ports = Set(stale.flatMap(\.ports))
        guard !ports.isEmpty else { return ([], []) }
        let output = await engine.scan(includeOtherUsers: preferences.includeOtherUsers)
        let staleIDs = Set(stale.map(\.id))
        let launches = Set(stale.map { "\($0.details?.cwd ?? "?")\n\($0.commandLine)" })
        var matching: [PortListenerProcess] = []
        var others: [String] = []
        for group in output.snapshot.groups {
            for process in group.processes
            where !staleIDs.contains(process.id) && !ports.isDisjoint(with: process.ports) {
                let sameLaunch = process.details?.cwd != nil
                    && launches.contains("\(process.details?.cwd ?? "")\n\(process.commandLine)")
                if !process.isRestricted && (group.id == groupID || sameLaunch) {
                    matching.append(process)
                } else {
                    others.append(process.displayName)
                }
            }
        }
        return (matching, others)
    }

    /// Bookkeeping after stops: Recently Stopped, the respawn watch, busy flags, fresh manager state next scan.
    private func finishStops(_ outcomes: [PortStopOutcome]) {
        for outcome in outcomes {
            if outcome.stoppedCount > 0 {
                let path = snapshot.groups.first { $0.id == outcome.groupID }?.path
                postStopped(title: outcome.title, ports: outcome.ports, path: path)
            }
            recentlyStopped.insert(contentsOf: outcome.records, at: 0)
            if !outcome.ports.isEmpty {
                recentStops.append(RecentStop(date: Date(), ports: Set(outcome.ports), groupTitle: outcome.title))
            }
            busyGroupIDs.remove(outcome.groupID)
        }
        if recentlyStopped.count > Self.maxRecentlyStopped {
            recentlyStopped.removeLast(recentlyStopped.count - Self.maxRecentlyStopped)
        }
        engine.invalidateManagerCaches()
    }

    /// Stops a process tree that isn't a port listener (the Connections tab's Stop Process), with the same rules as a
    /// listener's Stop: a GUI app is asked to quit first (never force-quit by a plain Stop), apps and macOS services
    /// never get SIGKILL unless `mode` is `.force`, and every PID is re-verified right before it is signalled.
    func stopProcess(_ plan: PortKillPlan, title: String, category: PortListenerCategory, mode: PortStopMode,
                     path: String?) async -> PortBanner {
        guard !plan.targets.isEmpty else {
            return PortBanner(style: .error, message: plan.warnings.first ?? "\(title) is protected and was not stopped")
        }
        let timeout = preferences.gracefulTimeout
        if mode == .graceful, category == .app, askAppToQuit(plan.root.pid) == true {
            if await PortProcessWatch.survivors(of: [plan.root.identity], waitingUpTo: max(1, timeout)).isEmpty {
                postStopped(title: title, ports: [], path: path)
                return PortBanner(style: .success, message: "Quit \(title)")
            }
            return PortBanner(style: .info, message: "Asked \(title) to quit. It's still open — it may be waiting for you to save something.")
        }
        let escalate = category != .app && category != .system
        let result = await engine.killer.stop(plan, mode: mode, timeout: timeout, allowAdmin: plan.requiresAdmin,
                                              escalate: escalate)
        if !result.stopped.isEmpty { postStopped(title: title, ports: [], path: path) }
        engine.invalidateManagerCaches()
        if result.failures.isEmpty {
            return PortBanner(style: .success, message: "Stopped \(title)" + (result.escalated ? " — had to force-stop" : ""))
        }
        let reasons = result.failures.prefix(3).map { "pid \($0.pid): \($0.reason)" }
        return PortBanner(style: .error, message: "Couldn't fully stop \(title): " + reasons.joined(separator: "; "))
    }

    /// Projects "Stop All Projects" ends: every project group the person hasn't hidden. The count shown next to the
    /// button uses the same list, so it always matches what the button stops.
    var stoppableProjects: [PortListenerGroup] {
        let ignoredIDs = Set(preferences.hiddenGroupIDs)
        let ignoredPorts = Set(preferences.hiddenPorts)
        return snapshot.groups.filter { group in
            group.category == .project && !ignoredIDs.contains(group.id)
                && (ignoredPorts.isEmpty || !group.ports.allSatisfy(ignoredPorts.contains))
        }
    }

    /// Stops every group in `stoppableProjects` at once and reports them in one banner.
    @discardableResult
    func stopAllProjects() -> Task<Void, Never>? {
        let requests = stoppableProjects
            .filter { !busyGroupIDs.contains($0.id) }
            .map { PortStopRequest(group: $0, mode: .graceful, disableAutoStart: false) }
        guard !requests.isEmpty else { return nil }
        requests.forEach { busyGroupIDs.insert($0.groupID) }
        return Task {
            var outcomes: [PortStopOutcome] = []
            await withTaskGroup(of: (Int, PortStopOutcome).self) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask { (index, await self.performStop(request)) }
                }
                var results: [(Int, PortStopOutcome)] = []
                for await result in group { results.append(result) }
                outcomes = results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            finishStops(outcomes)
            banner = PortStopReport.summary(for: outcomes)
            await scanOnce()
        }
    }

    // MARK: Relaunch

    /// Re-runs a stopped command with its original argv, environment and folder (detached; output goes to
    /// ~/Library/Logs/Mac Cleaner/Relaunched).
    @discardableResult
    func relaunch(_ record: PortStoppedRecord) -> Task<Void, Never>? {
        relaunch([record])
    }

    /// Relaunches `records` together (Undo of a Stop that ended several servers). Success is reported only once a
    /// process stayed up and, when it had ports, listens on one of them again; a record that didn't come back stays
    /// in Recently Stopped.
    private func relaunch(_ records: [PortStoppedRecord]) -> Task<Void, Never>? {
        let pending = records.filter { $0.canRelaunch && !relaunchingRecordIDs.contains($0.id) }
        guard !pending.isEmpty else { return nil }
        let ids = pending.map(\.id)
        relaunchingRecordIDs.formUnion(ids)
        banner = PortBanner(style: .info, message: pending.count == 1 ? "Relaunching \(pending[0].title)…"
                                                                      : "Relaunching \(pending.count) servers…")
        let logDirectory = relaunchLogDirectory
        let portTimeout = relaunchPortTimeout
        return Task {
            var results: [PortRelaunchResult] = []
            await withTaskGroup(of: (Int, PortRelaunchResult).self) { group in
                for (index, record) in pending.enumerated() {
                    group.addTask {
                        (index, await PortRelauncher.relaunchAndVerify(record, logDirectory: logDirectory,
                                                                        portTimeout: portTimeout))
                    }
                }
                var collected: [(Int, PortRelaunchResult)] = []
                for await result in group { collected.append(result) }
                results = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            for result in results where result.isRunning {
                recentlyStopped.removeAll { $0.id == result.record.id }
                recentStops.removeAll { !$0.ports.isDisjoint(with: result.record.ports) }
            }
            relaunchingRecordIDs.subtract(ids)
            banner = PortStopReport.relaunchBanner(for: results)
            await scanOnce()
        }
    }

    func clearRecentlyStopped() {
        recentlyStopped.removeAll()
    }

    // MARK: Stop plan preview

    /// Lines describing exactly what Stop will do for this group ("npm run dev (pid 1200)", warnings with "⚠︎").
    func killPlanPreview(for group: PortListenerGroup) -> [String] {
        var lines: [String] = []
        var seenRoots = Set<PortProcessIdentity>()
        for process in group.processes {
            switch process.manager {
            case .launchd(let job) where job.isUserAgent:
                let line = "launchd job \(job.label)"
                if !lines.contains(line) { lines.append(line) }
            case .pm2(_, let name):
                lines.append("pm2 app \(name)")
            case .docker(let container):
                lines.append("Docker container \(container.name)")
            default:
                guard let plan = plans[process.id], seenRoots.insert(plan.root.identity).inserted else { continue }
                lines.append(contentsOf: plan.summary)
                lines.append(contentsOf: plan.warnings.map { "⚠︎ " + $0 })
            }
        }
        return lines
    }

    // MARK: Hiding

    func hide(_ group: PortListenerGroup) {
        guard !preferences.hiddenGroupIDs.contains(group.id) else { return }
        preferences.hiddenGroupIDs.append(group.id)
        banner = PortBanner(style: .info, message: "Hid \(group.title). Show it again from the Hidden menu or Settings.")
    }

    func unhideAll() {
        preferences.unhideAll()
    }

    // MARK: Banners

    @discardableResult
    func performBannerAction(_ banner: PortBanner) -> Task<Void, Never>? {
        guard let action = banner.action else { return nil }
        dismissBanner()
        switch action {
        case .disableAutoStart(let groupID, let launchdLabels):
            if let group = snapshot.groups.first(where: { $0.id == groupID }) {
                return stopAndDisableAutoStart(group)
            } else if !launchdLabels.isEmpty {
                // The Stop that offered this unloaded the jobs, so their group has left the list: act on the labels.
                return disableAutoStart(labels: launchdLabels)
            } else {
                self.banner = PortBanner(style: .info, message: "Already stopped. Turn it off under Startup Items.")
                return nil
            }
        case .relaunch(let recordID, let moreRecordIDs):
            let records = ([recordID] + moreRecordIDs).compactMap { id in recentlyStopped.first { $0.id == id } }
            return relaunch(records)
        }
    }

    /// Turns off auto-start for launchd jobs a Stop already unloaded: `launchctl disable` where the Startup Items
    /// page can switch it back on; for any other job the banner says where to turn it off.
    private func disableAutoStart(labels: [String]) -> Task<Void, Never>? {
        let ids = labels.map { "launchd-label:" + $0 }
        guard !labels.isEmpty, !ids.contains(where: busyGroupIDs.contains) else { return nil }
        busyGroupIDs.formUnion(ids)
        let launchd = launchd
        return Task {
            var disabled: [String] = []
            var manual: [String] = []
            var errors: [String] = []
            for label in labels {
                // Unloaded jobs are found through their plist; one launchd no longer knows can't be managed here.
                guard let job = await launchd.job(label: label, pid: nil) else {
                    manual.append(label)
                    continue
                }
                do {
                    if try await launchd.stopAndDisableIfReversible(job: job) {
                        disabled.append(label)
                    } else {
                        manual.append(label)
                    }
                } catch {
                    errors.append("\(label): \(error.localizedDescription)")
                }
            }
            busyGroupIDs.subtract(ids)
            banner = PortStopReport.autoStartBanner(disabled: disabled, manual: manual, errors: errors)
            engine.invalidateManagerCaches()
            await scanOnce()
        }
    }

    func dismissBanner() {
        banner = nil
    }

    private func scheduleBannerDismissal() {
        bannerTask?.cancel()
        guard let current = banner else { return }
        let seconds: Double = current.action == nil ? (current.style == .error ? 12 : 6) : 20
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.banner?.id == current.id else { return }
            self.banner = nil
        }
    }

    // MARK: Respawn & new-port detection

    private func detectRespawns() {
        let now = Date()
        recentStops.removeAll { now.timeIntervalSince($0.date) > Self.respawnWindow }
        guard !recentStops.isEmpty else { return }
        for stop in recentStops {
            // Give the stop a moment to land before judging.
            guard now.timeIntervalSince(stop.date) > 1.5 else { continue }
            guard let group = snapshot.groups.first(where: { !$0.ports.filter(stop.ports.contains).isEmpty }) else { continue }
            let back = group.ports.filter(stop.ports.contains)
            let portText = back.map { ":\($0)" }.joined(separator: ", ")
            recentStops.removeAll { $0.date == stop.date }
            if group.manager.isAutoRestarting, let badge = group.manager.badge {
                banner = PortBanner(style: .warning,
                                    message: "\(stop.groupTitle) came back on \(portText) — restarted by \(badge).",
                                    action: .disableAutoStart(groupID: group.id), actionTitle: "Stop & Disable")
            } else {
                banner = PortBanner(style: .warning,
                                    message: "Something restarted \(portText) (\(group.title)). Its parent may be a watcher or supervisor.")
            }
            return
        }
    }

    private func detectNewPorts() {
        guard preferences.notifyNewPorts else { return }
        // The notifier diffs against the previous call itself (the first call only records a baseline). `latest`,
        // not the published snapshot: notifications must work while the page is hidden.
        let hidden = Set(preferences.hiddenGroupIDs)
        notifier.notifyNewPorts(latest.groups.filter { !hidden.contains($0.id) }, service: notifications)
    }

    /// "Port 5173 opened — vite in my-app" in the activity feed, for project ports only.
    private func postOpenedPorts() {
        let hidden = Set(preferences.hiddenGroupIDs)
        let visible = latest.groups.filter { !hidden.contains($0.id) }
        for item in openedPorts.pendingNotifications(for: visible) {
            guard let group = visible.first(where: { $0.id == item.groupID }) else { continue }
            eventLog.post(Self.openedEvent(for: group, ports: item.ports))
        }
    }

    nonisolated static func openedEvent(for group: PortListenerGroup, ports: [UInt16]) -> ProtectionEvent {
        let portText = ports.count == 1 ? "Port \(ports[0])" : "Ports " + ports.map(String.init).joined(separator: ", ")
        let listener = group.processes.first { !$0.ports.filter(ports.contains).isEmpty } ?? group.processes.first
        let what = listener.map { $0.displayName == group.title ? group.title : "\($0.displayName) in \(group.title)" }
            ?? group.title
        return ProtectionEvent(kind: .portOpened, severity: .info, title: "\(portText) opened — \(what)",
                               detail: group.path.map(PortFormat.abbreviatePath), path: group.path, section: .network)
    }

    /// "Stopped “npm run dev” (port 3000)" in the activity feed.
    private func postStopped(title: String, ports: [UInt16], path: String?) {
        var text = "Stopped “\(title)”"
        if !ports.isEmpty {
            text += ports.count == 1 ? " (port \(ports[0]))"
                : " (ports " + ports.prefix(4).map(String.init).joined(separator: ", ") + (ports.count > 4 ? "…" : "") + ")"
        }
        eventLog.post(ProtectionEvent(kind: .portClosed, severity: .info, title: text,
                                      detail: path.map(PortFormat.abbreviatePath), path: path, section: .network))
    }

    // MARK: Settings

    /// Re-applies settings whenever one the tab depends on changes.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.includeOtherUsers
            _ = preferences.showApps
            _ = preferences.showSystem
            _ = preferences.hiddenGroupIDs
            _ = preferences.hiddenPorts
            _ = preferences.sortOrder
            _ = preferences.notifyNewPorts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.preferencesDidChange()
                self.observePreferences()
            }
        }
    }

    private func preferencesDidChange() {
        let key = SettingsKey(includeOtherUsers: preferences.includeOtherUsers)
        if let lastSettingsKey, lastSettingsKey != key, isVisible || backgroundWatch {
            // A scan already running uses the old settings, so another one must follow it.
            Task { await scanOnce() }
        }
        lastSettingsKey = key
        if preferences.notifyNewPorts { notifier.resetBaseline() }
        recomputeVisible()
        updateProjectPortCount()
    }

    // MARK: Filtering, sorting and port lookup

    private func searchDidChange() {
        recomputeVisible()
        updatePortLookup()
    }

    private func recomputeVisible() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ignoredIDs = Set(preferences.hiddenGroupIDs)
        let ignoredPorts = Set(preferences.hiddenPorts)
        var groups = snapshot.groups.filter { group in
            switch group.category {
            case .project, .service: break
            // Searching also finds apps and system processes that are hidden by settings.
            case .app: if !preferences.showApps && query.isEmpty { return false }
            case .system: if !preferences.showSystem && query.isEmpty { return false }
            }
            if ignoredIDs.contains(group.id) && query.isEmpty { return false }
            if !ignoredPorts.isEmpty, group.ports.allSatisfy(ignoredPorts.contains), query.isEmpty { return false }
            return query.isEmpty || Self.matches(group, query: query)
        }
        groups.sort(by: Self.sortPredicate(preferences.sortOrder))
        visibleGroups = groups
        refreshPortLookupFromSnapshot()
    }

    nonisolated static func matches(_ group: PortListenerGroup, query: String) -> Bool {
        let tokens = query.split(separator: " ").map(String.init)
        var haystack = [group.title, group.subtitle ?? "", group.path ?? "", group.manager.badge ?? "",
                        group.origin?.name ?? ""]
        haystack += group.frameworks
        haystack += group.ports.map { String($0) }
        for process in group.processes {
            haystack.append(process.displayName)
            haystack.append(process.commandLine)
            haystack.append(String(process.basic.pid))
            if let path = process.details?.executablePath { haystack.append(path) }
            if case .launchd(let job) = process.manager { haystack.append(job.label) }
        }
        let text = haystack.joined(separator: "\n").lowercased()
        return tokens.allSatisfy { token in
            let bare = token.hasPrefix(":") ? String(token.dropFirst()) : token
            return text.contains(bare)
        }
    }

    nonisolated static func sortPredicate(_ order: PortSortOrder) -> (PortListenerGroup, PortListenerGroup) -> Bool {
        switch order {
        case .port:
            return { ($0.ports.first ?? .max, $0.title) < ($1.ports.first ?? .max, $1.title) }
        case .name:
            return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .cpu:
            return { $0.usage.cpuPercent > $1.usage.cpuPercent }
        case .memory:
            return { $0.usage.memoryBytes > $1.usage.memoryBytes }
        case .newest:
            return { ($0.oldestStart ?? .distantPast) > ($1.oldestStart ?? .distantPast) }
        }
    }

    /// The port number a search is about: "3000", ":3000" or "port 3000". nil for any other query.
    nonisolated static func portQuery(_ text: String) -> UInt16? {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.hasPrefix("port ") { query = String(query.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if query.hasPrefix(":") { query.removeFirst() }
        guard !query.isEmpty, query.count <= 5, query.allSatisfy(\.isASCII), query.allSatisfy(\.isNumber),
              let port = UInt16(query), port > 0 else { return nil }
        return port
    }

    /// Groups (all categories, hidden or not) listening on `port`.
    private func groupIDs(listeningOn port: UInt16) -> [String] {
        snapshot.groups.filter { $0.ports.contains(port) }.map(\.id)
    }

    private func refreshPortLookupFromSnapshot() {
        guard let port = Self.portQuery(searchText) else { return }
        let ids = groupIDs(listeningOn: port)
        if !ids.isEmpty {
            let lookup = PortLookup.inUse(port: port, groupIDs: ids)
            if portLookup != lookup { portLookup = lookup }
        } else if case .inUse(let previous, _) = portLookup, previous == port {
            // It just closed: check the system list again.
            updatePortLookup()
        }
    }

    /// Answers a port-number search: from the scanned groups when one listens on it, else from the system-wide
    /// socket list (other users' and macOS's listeners), so "free" is only said when it was really checked.
    private func updatePortLookup() {
        lookupTask?.cancel()
        guard let port = Self.portQuery(searchText) else {
            if portLookup != nil { portLookup = nil }
            return
        }
        let ids = groupIDs(listeningOn: port)
        if !ids.isEmpty {
            portLookup = .inUse(port: port, groupIDs: ids)
            return
        }
        portLookup = .checking(port: port)
        let currentUID = engine.currentUID
        lookupTask = Task { [weak self] in
            let result = await BackgroundWork.run(qos: .userInitiated) { Self.systemLookup(port: port, currentUID: currentUID) }
            guard !Task.isCancelled, let self, Self.portQuery(self.searchText) == port else { return }
            self.portLookup = result
        }
    }

    /// The system-wide socket list (all users) for one port, plus this user's own sockets.
    nonisolated static func systemLookup(port: UInt16, currentUID: UInt32) -> PortLookup {
        var owners: [PortOtherListener] = []
        let system = PortSysProc.systemTCPListeners()
        for socket in system ?? [] where socket.port == port {
            let basic = PortSysProc.basic(pid: socket.pid)
            let name = basic.map { PortSysProc.executablePath(pid: $0.pid).map { ($0 as NSString).lastPathComponent } ?? $0.comm }
                ?? "pid \(socket.pid)"
            let owner = PortOtherListener(pid: socket.pid, name: name, uid: basic?.uid ?? UInt32.max, address: socket.address)
            if !owners.contains(owner) { owners.append(owner) }
        }
        if system == nil {
            // Without the system list, at least this user's own processes can be checked.
            var fdBuffer: [proc_fdinfo] = []
            for process in PortSysProc.allProcesses() where process.uid == currentUID {
                guard let sockets = PortSysProc.listeningTCPSockets(pid: process.pid, fdBuffer: &fdBuffer) else { continue }
                for socket in sockets where socket.port == port {
                    owners.append(PortOtherListener(pid: process.pid, name: process.comm, uid: process.uid, address: socket.address))
                }
            }
            return owners.isEmpty ? .freeForYou(port: port) : .inUseElsewhere(port: port, owners: owners)
        }
        return owners.isEmpty ? .free(port: port) : .inUseElsewhere(port: port, owners: owners)
    }

    // MARK: Convenience actions

    func openInBrowser(port: UInt16) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            banner = PortBanner(style: .error, message: "\(PortFormat.abbreviatePath(path)) no longer exists")
            return
        }
        if isDirectory.boolValue && !path.hasSuffix(".app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            FinderActions.reveal(path)
        }
    }

    /// Opens a terminal (iTerm2, Ghostty, Warp or Terminal) in `path`, or in the folder containing it.
    func openInTerminal(_ path: String) {
        let candidates = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.apple.Terminal"]
        guard let appURL = candidates.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        guard let folder = Self.terminalFolder(for: path) else {
            banner = PortBanner(style: .error, message: "\(PortFormat.abbreviatePath(path)) no longer exists")
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The folder a terminal should open for `path`: the path itself when it is a folder, else its parent folder.
    /// nil when it no longer exists.
    nonisolated static func terminalFolder(for path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    }

    /// Opens the folder in the first installed editor among Cursor, VS Code, Zed and Xcode.
    func openInEditor(_ path: String) {
        guard let editor = Self.preferredEditor else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Name of the editor `openInEditor` uses, nil when none is installed.
    var preferredEditorName: String? { Self.preferredEditor?.name }

    private static let preferredEditor: (name: String, url: URL)? = {
        let editors: [(String, String)] = [
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("VS Code", "com.microsoft.VSCode"),
            ("Zed", "dev.zed.Zed"),
            ("Xcode", "com.apple.dt.Xcode"),
        ]
        for (name, bundleID) in editors {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return (name, url) }
        }
        return nil
    }()

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "id (category: ports)" of the latest scan, for test failure messages.
    var debugGroupsForTesting: String {
        latest.groups.map { "\($0.id) (\($0.category.rawValue): \($0.ports))" }.joined(separator: "; ")
    }
}
