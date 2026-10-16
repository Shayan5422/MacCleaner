import Darwin
import Foundation

/// Result of one background scan, handed to the main actor.
struct PortScanOutput: Sendable {
    let snapshot: PortScanSnapshot
    /// Kill plan per listener identity of the groups the scan was asked to plan (all of them for full scans; the
    /// expanded rows for the page), so the UI can preview what Stop will do. Stop computes fresh plans.
    let plans: [PortProcessIdentity: PortKillPlan]
    /// Protected folders (e.g. ~/Downloads) whose project lookups are blocked right now, most likely behind a macOS
    /// folder-access prompt. Projects there show provisionally (by folder name) until access is granted.
    let foldersAwaitingAccess: [String]
    /// Other users' ports were asked for, but macOS provided no system-wide socket list.
    let otherUsersUnavailable: Bool

    init(snapshot: PortScanSnapshot, plans: [PortProcessIdentity: PortKillPlan], foldersAwaitingAccess: [String] = [],
         otherUsersUnavailable: Bool = false) {
        self.snapshot = snapshot
        self.plans = plans
        self.foldersAwaitingAccess = foldersAwaitingAccess
        self.otherUsersUnavailable = otherUsersUnavailable
    }
}

/// Owns every non-UI service of the Ports tab and runs all scanning and process control off the main thread.
/// Ported from PortPilot's ScanEngine; its subprocesses (launchctl, pm2, docker, netstat) now run through
/// `ProcessRunner`, so a scan is an async pipeline:
///
/// 1. on `queue` (blocking syscalls): the process table and the socket walk;
/// 2. awaited between the two: launchd / pm2 / Docker state, each only when a listener needs it;
/// 3. on `queue`: CPU and memory, grouping, project lookups and kill plans.
///
/// Scans never overlap (`scanGate`), so the change-detection and manager caches are only touched inside it. Work
/// behind a button (fresh kill plans for Stop, plan previews, leftovers) runs on `controlQueue` and never waits for
/// a scan. What both read (`recentScans`) is guarded by `stateLock`.
final class PortScanEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.maccleaner.MacCleaner.network.scan", qos: .utility)
    /// Stop and plan previews: never queued behind a scan, nor behind each other.
    let controlQueue = DispatchQueue(label: "com.maccleaner.MacCleaner.network.control", qos: .userInitiated,
                                     attributes: .concurrent)

    let scanner = PortProcessScanner()
    let resolver: PortProjectResolver
    let launchd = PortLaunchdService()
    let pm2 = PortPM2Service()
    let docker = PortDockerService()
    let killer = PortProcessKiller()
    let currentUID = PortSysProc.currentUID
    /// Per-process classification memo shared by every tick (pruned with the process table).
    let traits = PortProcessTraitsCache()

    /// One scan at a time (what PortPilot's serial scan queue guaranteed).
    private let scanGate = AsyncLimiter(limit: 1)

    // `launchctl list` is a subprocess. A process's job never changes while it runs, so the pid → label map is only
    // read again when a launchd-started process in some listener's lineage is newer than the last read
    // (see `launchdLabelsNeedRefresh`). Scan-gate only.
    private var launchdLabels: [Int32: String] = [:]
    /// When `launchdLabels` was read, µs since 1970 (like `PortProcessBasic.startTime`); 0 = read again.
    private var launchdLabelsReadAt: UInt64 = 0
    /// Job details per label for the pid that runs it, so unchanged jobs cost no plist reads or `launchctl print`.
    private var launchdJobCache: [String: PortLaunchdJob] = [:]
    // `pm2 jlist` starts node (~0.1 s CPU): reused while the daemon and its children are the same processes.
    private var pm2Map: [Int32: (id: Int, name: String)] = [:]
    private var pm2MapKey: Set<PortProcessIdentity>?

    // Change detection for `scan(_:)`. Scan-gate only.
    private var lastFingerprint: PortListenerFingerprint?
    /// The last full scan left no project lookup pending, so its rows were final.
    private var lastBuildSettled = false
    /// Set after a control action: the next scan rebuilds even if no listener changed.
    private let rebuildFlag = PortFlag(true)

    /// Guards `recentScans`: written by scans, read by Stop and plan previews on `controlQueue`.
    private let stateLock = NSLock()
    /// Process tables and sockets of the latest scans (newest last). Kept for a couple of scans so a Stop clicked on a
    /// row whose listener was just replaced by a watcher restart can still find the server's launch tree.
    private var recentScans: [(table: PortProcessTable, sockets: [Int32: [PortListeningSocket]])] = []
    /// How many scans an exited listener's launch tree can still be found from (the latest scan plus two).
    private static let recentScanRetention = 3

    /// Keeps only some listeners in every scan. Tests use it so they never see, let alone stop, anything that isn't
    /// theirs; nil (the app) keeps everything.
    private let listenerFilter: (@Sendable (PortProcessBasic) -> Bool)?

    /// - Parameters:
    ///   - resolver: injectable so tests can scan without touching the person's folders.
    ///   - listenerFilter: see `listenerFilter` (tests only).
    init(resolver: PortProjectResolver = PortProjectResolver(),
         listenerFilter: (@Sendable (PortProcessBasic) -> Bool)? = nil) {
        self.resolver = resolver
        self.listenerFilter = listenerFilter
    }

    /// Forces the next scan to re-read launchd/pm2/docker state and rebuild every row (call after a control action).
    func invalidateManagerCaches() {
        rebuildFlag.set(true)
        launchd.invalidateCaches()
        pm2.invalidateCache()
        docker.invalidateCache()
        Task { await scanGate.run { self.resetManagerState() } }
    }

    private func resetManagerState() {
        launchdLabelsReadAt = 0
        launchdJobCache = [:]
        pm2MapKey = nil
    }

    // MARK: Scanning

    /// What one tick of the page's poll loop asks for.
    struct ScanRequest: Sendable {
        var includeOtherUsers: Bool
        /// Groups whose listeners get kill plans (the rows expanded on screen); nil = every listener.
        var planGroupIDs: Set<String>? = nil
        /// Return nil right after the socket walk when no listener changed since the last full scan (and that scan
        /// was final). For background ticks: the rows would come out the same, and CPU/memory aren't on screen.
        var skipIfUnchanged = false
    }

    /// A full scan with a kill plan for every listener (Stop's rescan before "already exited", tests and tools).
    func scan(includeOtherUsers: Bool) async -> PortScanOutput {
        let output = await scan(ScanRequest(includeOtherUsers: includeOtherUsers))
        // A request without `skipIfUnchanged` always builds.
        return output ?? PortScanOutput(snapshot: .empty, plans: [:])
    }

    /// One poll tick: nil when `request.skipIfUnchanged` and nothing changed. Unchanged ticks cost the process
    /// table and the socket walk only (no usage sampling, project lookups, manager subprocesses or kill plans).
    func scan(_ request: ScanRequest) async -> PortScanOutput? {
        await scanGate.run { await self.performScan(request) }
    }

    private struct RawPhase: Sendable {
        let raw: PortRawScan
        let fingerprint: PortListenerFingerprint
        let needs: ManagerNeeds
        let otherUsersUnavailable: Bool
    }

    /// Which manager lookups the listeners need (gathered on the scan queue, performed asynchronously).
    private struct ManagerNeeds: Sendable {
        /// Every listener plus its ancestors (nearest first).
        var lineages: [[PortProcessBasic]] = []
        /// Processes in those lineages started by launchd directly.
        var startedByLaunchd: [PortProcessBasic] = []
        /// Identities of the running PM2 daemons in those lineages and their children; nil when there is none.
        var pm2Key: Set<PortProcessIdentity>?
        /// A Docker / OrbStack / Colima backend owns a listening port.
        var dockerOwned = false
    }

    private func performScan(_ request: ScanRequest) async -> PortScanOutput? {
        let started = Date()
        // Other users' sockets come from the kernel PCB list; only when it is unavailable is netstat run.
        var otherUsers: [PortListeningSocket]?
        if request.includeOtherUsers {
            otherUsers = await onQueue { PortSysProc.systemTCPListeners() }
            if otherUsers == nil,
               let result = try? await ProcessRunner.run(PortProcessScanner.netstatPath,
                                                         arguments: PortProcessScanner.netstatArguments, timeout: 3),
               result.succeeded {
                let parsed = PortProcessScanner.parseNetstatListeners(result.standardOutput)
                otherUsers = parsed.isEmpty ? nil : parsed
            }
        }
        let candidates = otherUsers
        let otherUsersUnavailable = request.includeOtherUsers && otherUsers == nil
        let skipAllowed = request.skipIfUnchanged && !rebuildFlag.value && lastBuildSettled
        let previousFingerprint = lastFingerprint
        let phase: RawPhase? = await onQueue {
            let raw = self.rawScan(includeOtherUsers: request.includeOtherUsers, otherUserListeners: candidates)
            let fingerprint = PortListenerFingerprint(raw: raw, includeOtherUsers: request.includeOtherUsers)
            if skipAllowed, self.resolver.pendingProbeCount == 0, fingerprint == previousFingerprint {
                return nil
            }
            return RawPhase(raw: raw, fingerprint: fingerprint, needs: self.managerNeeds(raw),
                            otherUsersUnavailable: otherUsersUnavailable)
        }
        guard let phase else { return nil }
        let maps = await managerMaps(phase.needs)
        let planGroupIDs = request.planGroupIDs
        let output = await onQueue {
            self.build(phase.raw, maps: maps, planGroupIDs: planGroupIDs, started: started,
                       otherUsersUnavailable: phase.otherUsersUnavailable)
        }
        lastFingerprint = phase.fingerprint
        lastBuildSettled = output.foldersAwaitingAccess.isEmpty && resolver.pendingProbeCount == 0
        rebuildFlag.set(false)
        return output
    }

    /// Runs blocking work on the scan queue.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Process table + listening sockets, remembered for Stop. Scan-queue only.
    private func rawScan(includeOtherUsers: Bool, otherUserListeners: [PortListeningSocket]?) -> PortRawScan {
        var raw = scanner.scan(includeOtherUsers: includeOtherUsers, otherUserListeners: otherUserListeners)
        if let listenerFilter {
            let table = raw.table
            let kept = raw.socketsByPID.filter { pid, _ in table[pid].map(listenerFilter) ?? false }
            raw = PortRawScan(table: table, socketsByPID: kept, restrictedPIDs: raw.restrictedPIDs.intersection(kept.keys))
        }
        traits.prune(keepingAliveIn: raw.table)
        stateLock.withLock {
            recentScans.append((raw.table, raw.socketsByPID))
            if recentScans.count > Self.recentScanRetention {
                recentScans.removeFirst(recentScans.count - Self.recentScanRetention)
            }
        }
        return raw
    }

    /// Builds the rows (and the requested kill plans) from a raw scan. Scan-queue only.
    private func build(_ raw: PortRawScan, maps: PortManagerMaps, planGroupIDs: Set<String>?, started: Date,
                       otherUsersUnavailable: Bool) -> PortScanOutput {
        let table = raw.table
        let detailsFor: (PortProcessBasic) -> PortProcessDetails? = { [scanner] basic in scanner.details(for: basic) }

        let listenerBasics = raw.socketsByPID.keys.compactMap { table[$0] }

        // Every listener plus its descendants, for tree CPU/memory. PortListenerBuilder samples the rest of each
        // launch tree (npm, `sh -c`, sibling workers) itself through `sampleUsage`.
        var usageBasics: [Int32: PortProcessBasic] = [:]
        for basic in listenerBasics {
            usageBasics[basic.pid] = basic
            // launchd (pid 1) "owns" every process; other users' trees can't be sampled anyway.
            guard basic.pid > 1, basic.uid == currentUID else { continue }
            for child in table.descendants(of: basic.pid) { usageBasics[child.pid] = child }
        }
        let usage = scanner.usage(for: Array(usageBasics.values))

        let groups = PortListenerBuilder.build(raw: raw, details: detailsFor, usage: usage, resolver: resolver,
                                               maps: maps, currentUID: currentUID, traits: traits,
                                               sampleUsage: { [scanner] in scanner.usage(for: $0) })

        let planned = planGroupIDs.map { ids in groups.filter { ids.contains($0.id) } } ?? groups
        let plans = Self.plans(for: planned, table: table, socketsByPID: raw.socketsByPID, details: detailsFor,
                               currentUID: currentUID)

        let foldersAwaitingAccess = resolver.foldersAwaitingAccess()
        let snapshot = PortScanSnapshot(date: Date(), groups: groups, table: table,
                                        duration: Date().timeIntervalSince(started),
                                        restrictedCount: raw.restrictedPIDs.count)
        return PortScanOutput(snapshot: snapshot, plans: plans, foldersAwaitingAccess: foldersAwaitingAccess,
                              otherUsersUnavailable: otherUsersUnavailable)
    }

    /// Kill plans for every plannable listener of `groups`.
    static func plans(for groups: [PortListenerGroup], table: PortProcessTable,
                      socketsByPID: [Int32: [PortListeningSocket]],
                      details: (PortProcessBasic) -> PortProcessDetails?,
                      currentUID: UInt32) -> [PortProcessIdentity: PortKillPlan] {
        var plans: [PortProcessIdentity: PortKillPlan] = [:]
        for group in groups {
            for listener in group.processes where !listener.isRestricted {
                // Docker / PM2 cluster rows share their backend's identity with its own row (if any); that row's
                // plan is the one Stop and the preview use, so it wins.
                let routed = isSplitFromSharedProcess(listener)
                if routed, plans[listener.id] != nil { continue }
                plans[listener.id] = clusterAppPlan(for: listener)
                    ?? PortKillPlanner.plan(for: listener, table: table, details: details, currentUID: currentUID,
                                            socketsByPID: socketsByPID)
            }
        }
        return plans
    }

    /// Kill plans for the listeners of `groups` (rows just expanded), against the latest scan's process table.
    /// Runs on `controlQueue`.
    func plans(for groups: [PortListenerGroup]) async -> [PortProcessIdentity: PortKillPlan] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                let latest = self.stateLock.withLock { self.recentScans.last }
                guard let latest else { return continuation.resume(returning: [:]) }
                let detailsFor: (PortProcessBasic) -> PortProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                let alive = groups.map { group in
                    var copy = group
                    copy.processes = group.processes.filter { latest.table.isAlive($0.id) }
                    return copy
                }
                continuation.resume(returning: Self.plans(for: alive, table: latest.table, socketsByPID: latest.sockets,
                                                          details: detailsFor, currentUID: self.currentUID))
            }
        }
    }

    /// Rows that PortListenerBuilder split off a shared process (Docker backend per container, PM2 daemon per
    /// cluster app). They are stopped through their manager.
    private static func isSplitFromSharedProcess(_ listener: PortListenerProcess) -> Bool {
        switch listener.manager {
        case .docker, .pm2: return true
        case .none, .watcher, .launchd: return false
        }
    }

    /// The plan of a PM2 cluster-mode app row: nothing to signal. Its process is the God Daemon, which holds the
    /// app's port (it is the Node cluster primary) and runs every other pm2 app too, so the app is only ever stopped
    /// through pm2 — also for "Stop Only This Process". nil for every other row.
    static func clusterAppPlan(for listener: PortListenerProcess) -> PortKillPlan? {
        guard case .pm2(_, let name) = listener.manager,
              PortPM2Service.isDaemon(listener.basic, details: listener.details) else { return nil }
        return PortKillPlan(root: listener.basic, targets: [], summary: [], requiresAdmin: false,
                            warnings: ["pm2 runs \(name) in cluster mode, so only pm2 can stop it"])
    }

    // MARK: Manager maps

    /// What manager lookups this scan needs. Scan-queue only (reads process details).
    private func managerNeeds(_ raw: PortRawScan) -> ManagerNeeds {
        let table = raw.table
        let listeners = raw.socketsByPID.keys.compactMap { table[$0] }
        var needs = ManagerNeeds()
        needs.lineages = listeners.map { [$0] + table.ancestors(of: $0.pid) }
        // launchd: only relevant when some listener (or an ancestor) was started by launchd directly.
        needs.startedByLaunchd = needs.lineages.flatMap { $0.filter { $0.ppid == 1 && $0.pid > 1 } }

        // pm2: only query when a running PM2 God Daemon is a listener or one of its ancestors (pm2 jlist would
        // spawn a daemon otherwise). In cluster mode the daemon itself holds the apps' sockets.
        var daemons: [Int32: PortProcessBasic] = [:]
        for lineage in needs.lineages {
            for process in lineage where PortPM2Service.isDaemon(process, details: scanner.details(for: process)) {
                daemons[process.pid] = process
            }
        }
        if !daemons.isEmpty {
            // pm2's pid → app map only changes when the daemon starts or stops a process.
            var key = Set<PortProcessIdentity>()
            for daemon in daemons.values {
                key.insert(daemon.identity)
                for child in table.childrenByPID[daemon.pid] ?? [] {
                    if let process = table[child] { key.insert(process.identity) }
                }
            }
            needs.pm2Key = key
        }

        // Docker: only when a Docker/OrbStack/Colima backend process owns a listening port.
        needs.dockerOwned = listeners.contains { PortDockerService.isDockerBackend($0, details: scanner.details(for: $0)) }
        return needs
    }

    /// launchd labels, pm2 apps and Docker containers, each read only when `needs` says so. Scan-gate only.
    private func managerMaps(_ needs: ManagerNeeds) async -> PortManagerMaps {
        var maps = PortManagerMaps()

        if !needs.startedByLaunchd.isEmpty {
            let now = Self.microsecondsSince1970()
            if Self.launchdLabelsNeedRefresh(candidates: needs.startedByLaunchd, readAt: launchdLabelsReadAt, now: now) {
                launchdLabels = await launchd.runningJobLabels()
                // An empty list means launchctl failed: try again on the next full scan.
                launchdLabelsReadAt = launchdLabels.isEmpty ? 0 : now
            }
            maps.launchdLabelsByPID = launchdLabels
            var jobs: [String: PortLaunchdJob] = [:]
            for lineage in needs.lineages {
                // Nearest real job wins; GUI app instances ("application.*") and Apple jobs are skipped so a job
                // further up the tree is still found.
                for candidate in lineage where candidate.pid > 1 {
                    guard let label = launchdLabels[candidate.pid],
                          !PortLaunchdService.isAppInstanceLabel(label), !label.hasPrefix("com.apple.") else { continue }
                    if jobs[label] == nil {
                        if let cached = launchdJobCache[label], cached.pid == candidate.pid {
                            jobs[label] = cached
                        } else if let job = await launchd.job(label: label, pid: candidate.pid) {
                            jobs[label] = job
                        }
                    }
                    break
                }
            }
            maps.launchdJobs = jobs
            launchdJobCache = jobs
        }

        if let key = needs.pm2Key {
            if key != pm2MapKey {
                pm2Map = await pm2.processesByPID()
                pm2MapKey = pm2Map.isEmpty ? nil : key
            }
            maps.pm2ByPID = pm2Map
        }

        if needs.dockerOwned {
            maps.dockerByPort = await docker.containersByHostPort()
        }
        return maps
    }

    /// True when `launchctl list` must be read again: never read, read over `maxAge` ago, or a launchd-started
    /// process in a listener's lineage is not clearly older than the last read (it may be a job the read missed).
    /// All times in µs since 1970.
    static func launchdLabelsNeedRefresh(candidates: [PortProcessBasic], readAt: UInt64, now: UInt64,
                                         maxAge: UInt64 = launchdLabelsMaxAge) -> Bool {
        guard readAt > 0, now >= readAt, now - readAt <= maxAge else { return true }
        return candidates.contains { $0.startTime + launchdStartMargin >= readAt }
    }

    /// Safety net against clock changes: `launchctl list` is read at least this often while scans need it (µs).
    static let launchdLabelsMaxAge: UInt64 = 300_000_000
    /// A process started this close to a read may have been missed by it (µs).
    private static let launchdStartMargin: UInt64 = 1_000_000

    private static func microsecondsSince1970() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
    }

    // MARK: Control

    /// Fresh kill plans for the given listeners, computed against a brand-new process table so that
    /// children spawned since the last scan are included.
    ///
    /// A listener that exited since the scan was usually replaced by its watcher or runner (nodemon,
    /// `node --watch` and uvicorn --reload start a new server process on every save). Its plan then targets the
    /// process that holds its port again inside the same launch tree or, while the new server is still starting,
    /// the launch root the scan-time plan had. Only a listener whose whole tree is gone gets no plan.
    func freshPlans(for listeners: [PortListenerProcess], onlyThisProcess: Bool) async -> [PortKillPlan] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                if onlyThisProcess {
                    continuation.resume(returning: listeners.map {
                        Self.clusterAppPlan(for: $0) ?? PortKillPlanner.singleProcessPlan(for: $0)
                    })
                    return
                }
                let table = PortProcessTable(processes: PortSysProc.allProcesses())
                let detailsFor: (PortProcessBasic) -> PortProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                let lastSockets = self.stateLock.withLock { self.recentScans.last?.sockets ?? [:] }
                var seenRoots = Set<PortProcessIdentity>()
                var plans: [PortKillPlan] = []
                for listener in listeners {
                    if let plan = Self.clusterAppPlan(for: listener) {
                        if seenRoots.insert(plan.root.identity).inserted { plans.append(plan) }
                        continue
                    }
                    let target: PortListenerProcess
                    if table.isAlive(listener.id) {
                        target = listener
                    } else if let successor = self.successor(of: listener, in: table, details: detailsFor) {
                        target = successor
                    } else {
                        continue
                    }
                    let plan = PortKillPlanner.plan(for: target, table: table, details: detailsFor,
                                                    currentUID: self.currentUID, socketsByPID: lastSockets)
                    if seenRoots.insert(plan.root.identity).inserted { plans.append(plan) }
                }
                continuation.resume(returning: plans)
            }
        }
    }

    /// A fresh plan for any process (not only a listener), e.g. one that talks to a known malicious server: its
    /// launch root and descendants under the same safety rules as Stop on the Ports tab. Runs on `controlQueue`.
    func freshPlan(forProcess pid: Int32, startTime: UInt64?) async -> PortKillPlan? {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                let table = PortProcessTable(processes: PortSysProc.allProcesses())
                guard let basic = table[pid], startTime.map({ $0 == basic.startTime }) ?? true else {
                    return continuation.resume(returning: nil)
                }
                let details = self.scanner.details(for: basic)
                let traits = self.traits.traits(for: basic, details: details)
                let process = PortListenerProcess(
                    basic: basic, details: details, sockets: [], usage: .zero, treeUsage: .zero,
                    category: PortClassifier.category(basic: basic, details: details, project: nil, manager: .none,
                                                      currentUID: self.currentUID),
                    project: nil, displayName: traits.displayName, frameworks: traits.frameworks, origin: nil,
                    manager: .none, appName: nil, isRestricted: details == nil)
                let plan = PortKillPlanner.plan(for: process, table: table,
                                                details: { [scanner = self.scanner] in scanner.details(for: $0) },
                                                currentUID: self.currentUID)
                continuation.resume(returning: plan)
            }
        }
    }

    /// What Stop should act on for a listener whose process is gone (see `freshPlans`). Control-queue only.
    ///
    /// Looks inside the launch tree the listener belonged to: below the scan-time plan root when that is an
    /// ancestor that is still the same process, else below the listener's parent when a watcher supervised it
    /// (and that parent is still running, plausibly its parent, and not protected). Returns a copy of the listener
    /// pointing at the process that listens on one of its ports now, or — only for a scan-time plan root — at that
    /// root, which is what the original Stop would have signalled. nil when nothing of the tree is left.
    private func successor(of listener: PortListenerProcess, in table: PortProcessTable,
                           details: (PortProcessBasic) -> PortProcessDetails?) -> PortListenerProcess? {
        guard listener.basic.uid == currentUID, !listener.isRestricted, !listener.ports.isEmpty else { return nil }

        let anchor: PortProcessBasic
        let anchorIsPlanRoot: Bool
        if let root = scanTimeRoot(of: listener, details: details), root.identity != listener.id,
           let live = table[root.pid], live.startTime == root.startTime {
            anchor = live
            anchorIsPlanRoot = true
        } else if case .watcher = listener.manager, let parent = table[listener.basic.ppid], parent.pid > 1,
                  parent.uid == currentUID, parent.startTime <= listener.basic.startTime,
                  !PortKillPlanner.isProtected(parent, details: details(parent)) {
            anchor = parent
            anchorIsPlanRoot = false
        } else {
            return nil
        }

        let ports = Set(listener.ports)
        var fdBuffer: [proc_fdinfo] = []
        let candidates = [anchor] + table.descendants(of: anchor.pid).prefix(Self.maxSuccessorCandidates)
        for candidate in candidates where candidate.pid > 1 && candidate.uid == currentUID {
            guard let sockets = PortSysProc.listeningTCPSockets(pid: candidate.pid, fdBuffer: &fdBuffer),
                  sockets.contains(where: { ports.contains($0.port) }),
                  PortSysProc.basic(pid: candidate.pid)?.startTime == candidate.startTime   // not recycled meanwhile
            else { continue }
            return listener.replacingProcess(candidate, details: details(candidate), sockets: sockets)
        }
        guard anchorIsPlanRoot else { return nil }
        return listener.replacingProcess(anchor, details: details(anchor), sockets: [])
    }

    /// Bound on processes inspected when looking for a restarted server.
    private static let maxSuccessorCandidates = 256

    /// The kill-plan root a listener had at scan time, worked out in the newest of the recent scans' process tables
    /// in which it was still alive. nil when it exited before all of them.
    private func scanTimeRoot(of listener: PortListenerProcess,
                              details: (PortProcessBasic) -> PortProcessDetails?) -> PortProcessBasic? {
        let tables = stateLock.withLock { recentScans.map(\.table) }
        guard let table = tables.last(where: { $0.isAlive(listener.id) }) else { return nil }
        return PortKillPlanner.plan(for: listener, table: table, details: details, currentUID: currentUID).root
    }

    // MARK: Still running without a port

    /// What still runs of groups whose ports all closed since the previous full scan: for each listener, the launch
    /// tree it had then (worked out in `previousTable`, where it still listened) as far as it is alive now. Groups
    /// with nothing left, or whose tree listens again elsewhere, are left out. Runs on `controlQueue`.
    func leftovers(of groups: [PortListenerGroup], previousTable: PortProcessTable,
                   closedAt: Date = Date()) async -> [PortStillRunningItem] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                let latest = self.stateLock.withLock { self.recentScans.last }
                guard let latest else { return continuation.resume(returning: []) }
                let detailsFor: (PortProcessBasic) -> PortProcessDetails? = { [scanner = self.scanner] in scanner.details(for: $0) }
                var items: [PortStillRunningItem] = []
                for group in groups {
                    if let item = self.leftover(of: group, previousTable: previousTable, table: latest.table,
                                                details: detailsFor, closedAt: closedAt) {
                        items.append(item)
                    }
                }
                let serving = PortStillRunning.servingPIDs(listenerPIDs: Set(latest.sockets.keys), table: latest.table)
                items = PortStillRunning.refreshed(items, table: latest.table, servingPIDs: serving,
                                                   usage: self.usage(of: items))
                continuation.resume(returning: items)
            }
        }
    }

    /// `items` against the latest scan: exited processes dropped, items that exited or listen again removed, and
    /// (when `sampleUsage`) fresh CPU/memory. Runs on `controlQueue`.
    func refreshLeftovers(_ items: [PortStillRunningItem], sampleUsage: Bool) async -> [PortStillRunningItem] {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                guard let latest = self.stateLock.withLock({ self.recentScans.last }) else {
                    return continuation.resume(returning: items)
                }
                let serving = PortStillRunning.servingPIDs(listenerPIDs: Set(latest.sockets.keys), table: latest.table)
                var alive = PortStillRunning.refreshed(items, table: latest.table, servingPIDs: serving, usage: nil)
                if sampleUsage {
                    alive = PortStillRunning.refreshed(alive, table: latest.table, servingPIDs: serving,
                                                       usage: self.usage(of: alive))
                }
                continuation.resume(returning: alive)
            }
        }
    }

    private func leftover(of group: PortListenerGroup, previousTable: PortProcessTable, table: PortProcessTable,
                          details: (PortProcessBasic) -> PortProcessDetails?, closedAt: Date) -> PortStillRunningItem? {
        var root: PortProcessBasic?
        var processes: [PortProcessBasic] = []
        var labels: [Int32: String] = [:]
        for listener in group.processes where listener.basic.uid == currentUID && !listener.isRestricted {
            let anchor: PortListenerProcess
            if let live = table[listener.basic.pid], live.startTime == listener.basic.startTime {
                anchor = listener   // closed its socket but still runs
            } else if previousTable.isAlive(listener.id) {
                let launchRoot = PortKillPlanner.plan(for: listener, table: previousTable, details: details,
                                                      currentUID: currentUID).root
                guard launchRoot.identity != listener.id, let live = table[launchRoot.pid],
                      live.startTime == launchRoot.startTime else { continue }
                anchor = listener.replacingProcess(live, details: details(live), sockets: [])
            } else {
                continue
            }
            let plan = PortKillPlanner.plan(for: anchor, table: table, details: details, currentUID: currentUID)
            for target in plan.targets where target.uid == currentUID && !processes.contains(where: { $0.pid == target.pid }) {
                processes.append(target)
                labels[target.pid] = PortKillPlanner.label(for: target, details: details(target))
            }
            if root == nil, !plan.targets.isEmpty { root = plan.root }
        }
        guard let root, !processes.isEmpty else { return nil }
        return PortStillRunningItem(id: group.id, title: group.title, path: group.path, formerPorts: group.ports,
                                    closedAt: closedAt, root: root, processes: processes, labels: labels, usage: .zero)
    }

    private func usage(of items: [PortStillRunningItem]) -> [Int32: PortResourceUsage] {
        let processes = items.flatMap(\.processes)
        return processes.isEmpty ? [:] : scanner.usage(for: processes)
    }

    /// Details of a process for a Stop's Recently Stopped record, read off the main thread before it is stopped.
    func relaunchInfo(for plan: PortKillPlan) async -> (command: PortRelaunchCommand?, root: PortProcessDetails?) {
        let scanner = self.scanner
        return await BackgroundWork.run(qos: .userInitiated) {
            let details: (PortProcessBasic) -> PortProcessDetails? = { scanner.details(for: $0) }
            return (PortRelauncher.relaunchCommand(for: plan, details: details), details(plan.root))
        }
    }
}

extension PortListenerProcess {
    /// The same row (project, manager, origin, …) for another process that took over its role.
    func replacingProcess(_ basic: PortProcessBasic, details: PortProcessDetails?,
                          sockets: [PortListeningSocket]) -> PortListenerProcess {
        PortListenerProcess(basic: basic, details: details, sockets: sockets, usage: usage, treeUsage: treeUsage,
                            category: category, project: project, displayName: displayName, frameworks: frameworks,
                            origin: origin, manager: manager, appName: appName, isRestricted: details == nil)
    }
}

/// A thread-safe boolean.
final class PortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool { lock.withLock { stored } }

    func set(_ value: Bool) { lock.withLock { stored = value } }
}

/// What a scan's rows depend on that can change from one tick to the next: every listener (identity, name, parent)
/// with its sockets. Equal fingerprints give the same rows, apart from CPU/memory and project lookups that were
/// still pending (`PortScanEngine` rebuilds while any are).
struct PortListenerFingerprint: Equatable, Sendable {
    struct Listener: Equatable, Sendable {
        let comm: String
        let ppid: Int32
        let sockets: Set<PortListeningSocket>
    }

    let includeOtherUsers: Bool
    let listeners: [PortProcessIdentity: Listener]
    let restrictedPIDs: Set<Int32>

    init(raw: PortRawScan, includeOtherUsers: Bool) {
        var listeners: [PortProcessIdentity: Listener] = [:]
        listeners.reserveCapacity(raw.socketsByPID.count)
        for (pid, sockets) in raw.socketsByPID {
            let basic = raw.table[pid]
            let identity = basic?.identity ?? PortProcessIdentity(pid: pid, startTime: 0)
            listeners[identity] = Listener(comm: basic?.comm ?? "", ppid: basic?.ppid ?? 0, sockets: Set(sockets))
        }
        self.includeOtherUsers = includeOtherUsers
        self.listeners = listeners
        self.restrictedPIDs = raw.restrictedPIDs
    }
}
