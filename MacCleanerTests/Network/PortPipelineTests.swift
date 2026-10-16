import Darwin
import Foundation
import Observation
import Testing
@testable import MacCleaner

// Tests for the scan pipeline: idle cost with the panel closed (skipped ticks, no observed-state churn, lazy kill
// plans), the control queue and "Still running · no open port".
// Process-level tests only start and signal their own throwaway processes, in a temporary folder.

// MARK: - Pure rules

@Suite struct PortPipelineRuleTests {
    private func basic(_ pid: Int32, ppid: Int32 = 1, start: UInt64 = 1_000, comm: String = "node") -> PortProcessBasic {
        PortProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: 501, comm: comm, startTime: start)
    }

    private func listener(_ pid: Int32, ports: [UInt16], ppid: Int32 = 1, uid: UInt32 = 501) -> PortListenerProcess {
        let process = PortProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: uid, comm: "node", startTime: UInt64(pid))
        return PortListenerProcess(basic: process, details: nil,
                               sockets: ports.map { PortListeningSocket(port: $0, address: "127.0.0.1", family: .ipv4, pid: pid) },
                               usage: .zero, treeUsage: .zero, category: .project, project: nil, displayName: "node",
                               frameworks: [], origin: nil, manager: .none, appName: nil, isRestricted: false)
    }

    private func group(_ id: String, _ processes: [PortListenerProcess], category: PortListenerCategory = .project) -> PortListenerGroup {
        PortListenerGroup(id: id, category: category, title: id, subtitle: nil, path: nil, processes: processes)
    }

    // MARK: Menu bar count and plan comparison

    @Test func menuBarCountCountsDistinctProjectPortsTheUserDidNotHide() {
        let groups = [group("project:/a", [listener(10, ports: [3000, 3001]), listener(11, ports: [3001])]),
                      group("project:/b", [listener(12, ports: [5173])]),
                      group("pid:13", [listener(13, ports: [8080])], category: .service)]
        #expect(PortsModel.projectPortCount(for: groups, hiddenGroupIDs: []) == 3)
        #expect(PortsModel.projectPortCount(for: groups, hiddenGroupIDs: ["project:/b"]) == 2)
        #expect(PortsModel.projectPortCount(for: [], hiddenGroupIDs: []) == 0)
        #expect(PortsModel.portCount(for: groups, categories: [.project, .service], hiddenGroupIDs: []) == 4,
                "the menu bar's \"open ports\" also counts background services")
    }

    @Test func plansCompareByContent() {
        let root = basic(10)
        let plan = PortKillPlan(root: root, targets: [basic(11, ppid: 10), root], summary: ["npm (pid 10)"],
                            requiresAdmin: false, warnings: [])
        let same = PortKillPlan(root: root, targets: [basic(11, ppid: 10), root], summary: ["npm (pid 10)"],
                            requiresAdmin: false, warnings: [])
        let other = PortKillPlan(root: root, targets: [root], summary: ["npm (pid 10)"], requiresAdmin: false, warnings: [])
        let key = root.identity
        #expect(PortsModel.samePlans([key: plan], [key: same]))
        #expect(!(PortsModel.samePlans([key: plan], [key: other])))
        #expect(!(PortsModel.samePlans([key: plan], [:])))
        #expect(PortsModel.samePlans([:], [:]))
    }

    // MARK: launchctl list

    @Test func launchctlListIsOnlyReadAgainForNewLaunchdProcesses() {
        let readAt: UInt64 = 1_000_000_000_000
        let now = readAt + 60_000_000
        let old = basic(500, start: readAt - 3_600_000_000)
        let new = basic(501, start: readAt + 5_000_000)
        let racing = basic(502, start: readAt - 200_000)   // started just before the read
        #expect(PortScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: 0, now: now), "never read")
        #expect(!(PortScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: readAt, now: now)))
        #expect(!(PortScanEngine.launchdLabelsNeedRefresh(candidates: [], readAt: readAt, now: now)))
        #expect(PortScanEngine.launchdLabelsNeedRefresh(candidates: [old, new], readAt: readAt, now: now))
        #expect(PortScanEngine.launchdLabelsNeedRefresh(candidates: [racing], readAt: readAt, now: now))
        #expect(PortScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: readAt,
                                                          now: readAt + PortScanEngine.launchdLabelsMaxAge + 1), "safety net")
        #expect(PortScanEngine.launchdLabelsNeedRefresh(candidates: [old], readAt: readAt, now: readAt - 1), "the clock went back")
    }

    // MARK: Fingerprint

    @Test func fingerprintChangesOnlyWhenAListenerChanges() {
        func raw(_ processes: [PortProcessBasic], _ sockets: [Int32: [UInt16]]) -> PortRawScan {
            PortRawScan(table: PortProcessTable(processes: processes),
                    socketsByPID: sockets.mapValues { $0.map { PortListeningSocket(port: $0, address: "*", family: .ipv4, pid: 0) } },
                    restrictedPIDs: [])
        }
        let server = basic(10, start: 1)
        let helper = basic(11, start: 1)
        let base = PortListenerFingerprint(raw: raw([server, helper], [10: [3000]]), includeOtherUsers: false)
        #expect(base == PortListenerFingerprint(raw: raw([server, helper, basic(12)], [10: [3000]]), includeOtherUsers: false), "a process without sockets doesn't matter")
        #expect(base != PortListenerFingerprint(raw: raw([server], [10: [3000, 3001]]), includeOtherUsers: false))
        #expect(base != PortListenerFingerprint(raw: raw([basic(10, start: 2)], [10: [3000]]), includeOtherUsers: false), "same pid, new process")
        #expect(base != PortListenerFingerprint(raw: raw([basic(10, ppid: 77, start: 1)], [10: [3000]]),
                                                    includeOtherUsers: false), "reparented")
        #expect(base != PortListenerFingerprint(raw: raw([server], [10: [3000]]), includeOtherUsers: true))
    }

    // MARK: Still running · no open port

    @Test func vanishedGroupsAreToolsThatClosedEveryPortOnTheirOwn() {
        let gone = group("project:/gone", [listener(10, ports: [3000])])
        let restarted = group("project:/restarted", [listener(11, ports: [4000])])
        let stopped = group("project:/stopped", [listener(12, ports: [5000])])
        let launchd = PortListenerGroup(id: "launchd:x", category: .service, title: "x", subtitle: nil, path: nil, processes: [
            PortListenerProcess(basic: basic(13), details: nil,
                            sockets: [PortListeningSocket(port: 6000, address: "*", family: .ipv4, pid: 13)],
                            usage: .zero, treeUsage: .zero, category: .service, project: nil, displayName: "x",
                            frameworks: [], origin: nil,
                            manager: .launchd(PortLaunchdJob(label: "x", domain: "gui/501", plistPath: nil, keepAlive: true,
                                                         runAtLoad: true, pid: 13)),
                            appName: nil, isRestricted: false)])
        let app = group("app:/Applications/X.app", [listener(14, ports: [7000])], category: .app)
        let otherUser = group("pid:15", [listener(15, ports: [7100], uid: 0)])
        let busy = group("project:/busy", [listener(16, ports: [7200])])
        let hidden = group("project:/hidden", [listener(17, ports: [7300])])
        let still = group("project:/still", [listener(18, ports: [7400])])
        let previous = [gone, restarted, stopped, launchd, app, otherUser, busy, hidden, still]
        // The restarted server holds its port again under another group; "still" is still there.
        let current = [group("pid:99", [listener(99, ports: [4000])]), still]
        let vanished = PortStillRunning.vanishedGroups(previous: previous, current: current, stoppedPorts: [5000],
                                                   busyGroupIDs: ["project:/busy"],
                                                   ignoredGroupIDs: ["project:/hidden"], ignoredPorts: [],
                                                   currentUID: 501)
        #expect(vanished.map(\.id) == ["project:/gone"])
    }

    @Test func refreshDropsExitedProcessesAndToolsThatListenAgain() {
        let make = basic(20, ppid: 1, start: 5)
        let worker = basic(21, ppid: 20, start: 6)
        let item = PortStillRunningItem(id: "project:/a", title: "a", path: nil, formerPorts: [3000], closedAt: Date(),
                                    root: make, processes: [worker, make], labels: [20: "make serve", 21: "sleep 600"],
                                    usage: .zero)
        #expect(item.processSummary == "make serve, sleep 600")
        #expect(item.plan.targets.map(\.pid) == [21, 20], "children first")
        #expect(item.busyID == "still:project:/a")

        // The worker exited; make still runs and uses memory.
        let table = PortProcessTable(processes: [make])
        let usage = [Int32(20): PortResourceUsage(cpuPercent: 1.5, memoryBytes: 40_000_000)]
        let refreshed = PortStillRunning.refreshed([item], table: table, servingPIDs: [], usage: usage)
        #expect(refreshed.first?.processes.map(\.pid) == [20])
        #expect(refreshed.first?.usage == usage[20])
        #expect(PortStillRunning.refreshed([item], table: table, servingPIDs: [], usage: nil).first?.usage == .zero)

        // Everything exited, or the tree listens again (a new server under make): the entry goes.
        #expect(PortStillRunning.refreshed([item], table: .empty, servingPIDs: [], usage: nil).isEmpty)
        let server = basic(22, ppid: 20, start: 7)
        let withServer = PortProcessTable(processes: [make, worker, server])
        let serving = PortStillRunning.servingPIDs(listenerPIDs: [22], table: withServer)
        #expect(serving.isSuperset(of: [22, 20]))
        #expect(PortStillRunning.refreshed([item], table: withServer, servingPIDs: serving, usage: nil).isEmpty)
    }

    @Test func mergeReplacesEntriesOfTheSameToolAndKeepsTheListShort() {
        func item(_ id: String, root: Int32) -> PortStillRunningItem {
            PortStillRunningItem(id: id, title: id, path: nil, formerPorts: [], closedAt: Date(), root: basic(root),
                             processes: [basic(root)], labels: [:], usage: .zero)
        }
        let existing = (0..<PortStillRunning.maxItems).map { item("old\($0)", root: Int32(100 + $0)) }
        let merged = PortStillRunning.merged([item("old3", root: 300), item("new", root: 101)], into: existing)
        #expect(merged.count == PortStillRunning.maxItems)
        #expect(Array(merged.map(\.id).prefix(3)) == ["old3", "new", "old0"], "new entries first; old3 (same group) and old1 (same root) replaced")
        #expect(!(merged.contains { $0.id == "old1" }))
    }

    @Test func closedMessage() {
        #expect(PortStillRunning.closedMessage(for: []) == nil)
        #expect(PortStillRunning.closedMessage(for: [group("my-app", [listener(1, ports: [5173])])]) == "my-app closed (:5173)")
        #expect(PortStillRunning.closedMessage(for: [group("a", [listener(1, ports: [1])]), group("b", [listener(2, ports: [2])]),
                                                        group("c", [listener(3, ports: [3])])]) == "a and 2 more closed")
    }
}

// MARK: - Engine (real throwaway processes)

extension PortLiveProcessTests {
    @Suite struct PortPipelineEngineTests {
        private let fs = PortResolverTestFS()

        /// Scans with a fake file system: only the sandbox's folders are projects, nothing real is probed.
        private func makeEngine(_ sandbox: PortPipelineSandbox) -> PortScanEngine {
            PortScanEngine(resolver: fs.makeResolver(home: sandbox.container, probeDeadline: 0.2),
                           listenerFilter: sandbox.listenerFilter)
        }

        private func skippingRequest() -> PortScanEngine.ScanRequest {
            PortScanEngine.ScanRequest(includeOtherUsers: false, planGroupIDs: [], skipIfUnchanged: true)
        }

        @Test func unchangedTicksAreSkippedUntilAListenerChanges() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let engine = makeEngine(sandbox)
            let first = await engine.scan(skippingRequest())
            #expect(first != nil, "the first tick always builds")
            #expect(first?.plans.isEmpty == true, "no rows asked for plans")

            // Other processes on this Mac may open or close a port between two ticks; one quiet pair is enough.
            var skipped = false
            for _ in 0..<10 where !skipped {
                skipped = await engine.scan(skippingRequest()) == nil
            }
            #expect(skipped, "nothing changed, so the tick stops after the socket walk")

            let folder = try sandbox.folder("server")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            _ = try sandbox.startServer(in: folder, port: port)
            try sandbox.waitForListener(port: port)
            let changed = await engine.scan(skippingRequest())
            #expect(changed?.snapshot.groups.contains { $0.ports.contains(port) } == true, "a new port is never skipped")

            engine.invalidateManagerCaches()
            let afterAction = await engine.scan(skippingRequest())
            #expect(afterAction != nil, "a control action forces a rebuild")
        }

        @Test func plansAreOnlyComputedForTheRequestedRows() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("planned")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let pid = try sandbox.startServer(in: folder, port: port)
            try sandbox.waitForListener(port: port)
            let engine = makeEngine(sandbox)

            let planned = await engine.scan(PortScanEngine.ScanRequest(includeOtherUsers: false, planGroupIDs: ["project:" + folder]))
            let output = try #require(planned)
            let group = try #require(output.snapshot.groups.first { $0.ports.contains(port) })
            #expect(group.id == "project:" + folder)
            #expect(Set(output.plans.keys) == Set(group.processes.map(\.id)))
            #expect(output.plans.values.first?.root.pid == pid)

            let unplanned = await engine.scan(PortScanEngine.ScanRequest(includeOtherUsers: false, planGroupIDs: []))
            let none = try #require(unplanned)
            #expect(none.plans.isEmpty)

            // A row expanded between ticks gets its plan from the latest scan.
            let previews = await engine.plans(for: [group])
            #expect(previews.values.first?.targets.map(\.pid) == [pid])
        }

        @Test func stopAndPreviewsNeverWaitForARunningScan() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("busy")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let pid = try sandbox.startServer(in: folder, port: port)
            try sandbox.waitForListener(port: port)
            let engine = makeEngine(sandbox)
            let output = await engine.scan(includeOtherUsers: false)
            let group = try #require(output.snapshot.groups.first { $0.ports.contains(port) })

            // A scan stuck on the scan queue (as behind a folder-access prompt). Released after 5 s at the latest, so a
            // regression fails instead of hanging.
            let gate = DispatchSemaphore(value: 0)
            engine.queue.async { gate.wait() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.signal() }
            defer { gate.signal() }

            let started = Date()
            let plans = await engine.freshPlans(for: group.processes, onlyThisProcess: false)
            let previews = await engine.plans(for: [group])
            #expect(Date().timeIntervalSince(started) < 2, "Stop waited for the scan")
            #expect(plans.first?.targets.map(\.pid) == [pid])
            #expect(previews.count == 1)
        }
    }
}

// MARK: - PortsModel loop (real throwaway processes)

extension PortLiveProcessTests {
    @MainActor
    @Suite struct PortPipelineStoreTests {
        private let fs = PortResolverTestFS()

        private func makeStore(_ sandbox: PortPipelineSandbox, probeDeadline: TimeInterval = 0.2) -> PortsModel {
            PortUIFixtures.model(engine: PortScanEngine(resolver: fs.makeResolver(home: sandbox.container,
                                                                                  probeDeadline: probeDeadline),
                                                        listenerFilter: sandbox.listenerFilter))
        }

        /// Full scans until `condition` holds (other tasks of the store may be scanning too).
        private func poll(_ store: PortsModel, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else {
                    Issue.record("condition not met within \(timeout) s")
                    return
                }
                await store.pollOnce(full: true)
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        @Test func closedPanelKeepsTheMenuBarCountLiveWithoutTouchingPanelState() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("live-count")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let pid = try sandbox.startServer(in: folder, port: port)
            try sandbox.waitForListener(port: port)
            let store = makeStore(sandbox)

            await store.pollOnce()
            #expect(store.projectPortCount == 1, "only the sandbox folder is a project for this resolver: \(store.debugGroupsForTesting)")
            #expect(store.snapshot.groups.isEmpty, "nothing is published while nothing shows the list")
            #expect(store.lastUpdated == nil)
            #expect(!store.isScanning)

            // Ticks with the panel closed change nothing the menu bar or the panel observes.
            let flag = PortChangeFlag()
            withObservationTracking {
                _ = store.snapshot
                _ = store.lastUpdated
                _ = store.visibleGroups
                _ = store.projectPortCount
                _ = store.isScanning
                _ = store.banner
            } onChange: {
                flag.set()
            }
            for _ in 0..<3 { await store.pollOnce() }
            #expect(!flag.isSet, "a hidden-page tick wrote observed state")

            // Opening the panel shows the newest scan right away.
            store.acquireVisibility()
            #expect(store.snapshot.groups.contains { $0.ports.contains(port) })
            #expect(store.lastUpdated != nil)
            store.releaseVisibility()

            // The port closes while the panel is closed: the count follows on the next tick.
            sandbox.kill(pid)
            try sandbox.waitUntilGone(pid)
            try await poll(store) { store.projectPortCount == 0 }
        }

        @Test func expandingARowComputesItsStopPreview() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("preview")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let pid = try sandbox.startServer(in: folder, port: port)
            try sandbox.waitForListener(port: port)
            let store = makeStore(sandbox)
            await store.pollOnce(full: true)
            store.acquireVisibility()
            let group = try #require(store.snapshot.groups.first { $0.ports.contains(port) })
            #expect(store.killPlanPreview(for: group).isEmpty, "no plans until a row is expanded")

            store.expandedGroupIDs.insert(group.id)
            let deadline = Date().addingTimeInterval(5)
            while store.killPlanPreview(for: group).isEmpty && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(store.killPlanPreview(for: group).contains { $0.contains("pid \(pid)") }, "\(store.killPlanPreview(for: group))")
            store.releaseVisibility()
        }

        @Test func leftoverOfACrashedServerIsListedAndStopped() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("crashy")
            fs.addFile(folder + "/Makefile", "serve:\n")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let make = try sandbox.startServerWithWorker(in: folder, port: port)
            let server = try sandbox.waitForListener(port: port)
            let store = makeStore(sandbox)
            await store.pollOnce(full: true)
            #expect(store.projectPortCount == 1)

            // The server dies; make and its worker keep running (and holding memory). The panel is closed.
            sandbox.kill(server)
            try sandbox.waitUntilGone(server)
            try await poll(store) { !store.stillRunning.isEmpty }
            let item = try #require(store.stillRunning.first)
            #expect(item.id == "project:" + folder)
            #expect(item.formerPorts == [port])
            #expect(item.root.pid == make, "make launched it, so Stop ends make's whole tree")
            #expect(item.processes.contains { $0.pid == make })
            let worker = try #require(sandbox.pid(commandContaining: "time.sleep"))
            #expect(item.processes.contains { $0.pid == worker }, "\(item.processes.map(\.comm))")
            #expect(!(item.processes.contains { $0.pid == server }))
            #expect(store.banner == nil, "nothing to say about it while the panel is closed")

            store.stopStillRunning(item)
            let deadline = Date().addingTimeInterval(10)
            while store.busyGroupIDs.contains(item.busyID) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(!(item.processes.contains { sandbox.isRunning($0) }), "every leftover process was stopped")
            #expect(store.stillRunning.isEmpty)
            #expect(store.banner?.message.hasPrefix("Stopped crashy") == true, "\(String(describing: store.banner))")
        }

        @Test func leftoverGoesAwayOnItsOwnWhenItsProcessesExit() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("fades")
            fs.addFile(folder + "/Makefile", "serve:\n")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            _ = try sandbox.startServerWithWorker(in: folder, port: port)
            let server = try sandbox.waitForListener(port: port)
            let store = makeStore(sandbox)
            await store.pollOnce(full: true)
            sandbox.kill(server)
            try sandbox.waitUntilGone(server)
            try await poll(store) { !store.stillRunning.isEmpty }

            // The rest exits too (no port changes, so closed-panel ticks skip the rebuild): the entry still goes.
            sandbox.killAll()
            let deadline = Date().addingTimeInterval(10)
            while !store.stillRunning.isEmpty && Date() < deadline {
                await store.pollOnce()
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(store.stillRunning.isEmpty)
        }

        @Test func toolThatClosesOnItsOwnGetsAShortNoteWhileThePanelIsOpen() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("quitter")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let pid = try sandbox.startServer(in: folder, port: port)
            try sandbox.waitForListener(port: port)
            let store = makeStore(sandbox)
            await store.pollOnce(full: true)
            store.acquireVisibility()

            sandbox.kill(pid)
            try sandbox.waitUntilGone(pid)
            try await poll(store) { store.banner != nil }
            #expect(store.banner?.message == "quitter closed (:\(port))")
            #expect(store.stillRunning.isEmpty, "nothing of it runs any more")
            store.releaseVisibility()
        }
    }
}

/// Set from Observation's change callback, read by the test.
final class PortChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Throwaway servers for pipeline tests: a temporary folder (symlinks resolved, as processes report their cwd) and
/// processes started in their own process groups, all killed by `killAll()`.
final class PortPipelineSandbox: @unchecked Sendable {
    let container: String
    private let lock = NSLock()
    private var spawnedGroups: [pid_t] = []
    private var killed = false

    /// Process groups started here (each spawn leads its own group).
    var groups: [pid_t] { lock.withLock { spawnedGroups } }

    /// For `PortScanEngine(listenerFilter:)`: scans see only this sandbox's processes, never the rest of the Mac.
    var listenerFilter: @Sendable (PortProcessBasic) -> Bool {
        { [self] basic in groups.contains(basic.pgid) }
    }

    init() throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cleaner-network-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        guard let resolved = realpath(created.path, nil) else { throw PortTestError("realpath failed") }
        container = String(cString: resolved)
        free(resolved)
    }

    deinit { killAll() }

    static var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func folder(_ subpath: String) throws -> String {
        let path = container + "/" + subpath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Where the processes started here write their output, so a failure can say why a server didn't start.
    var outputLog: String { container + "/spawned-output.log" }

    /// The end of `outputLog`, for failure messages.
    func outputTail() -> String {
        guard let text = try? String(contentsOfFile: outputLog, encoding: .utf8), !text.isEmpty else { return " (no output)" }
        return "; output: " + String(text.suffix(800))
    }

    /// `python3 -m http.server <port>` on 127.0.0.1 with `directory` as its working directory.
    @discardableResult
    func startServer(in directory: String, port: UInt16) throws -> pid_t {
        guard let python = Self.python else { throw PortTestError("python3 is not installed") }
        let script = "cd \(Self.quoted(directory)) && exec \(python) -m http.server \(port) --bind 127.0.0.1"
        return try spawn("/bin/sh", ["sh", "-c", script])
    }

    /// `make serve`: starts the server in the background next to a long-running python worker that outlives it.
    /// Returns make's pid.
    func startServerWithWorker(in directory: String, port: UInt16) throws -> pid_t {
        guard let python = Self.python else { throw PortTestError("python3 is not installed") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/make") else { throw PortTestError("make is not installed") }
        let makefile = "serve:\n\t\(python) -m http.server \(port) --bind 127.0.0.1 >>\(Self.quoted(outputLog)) 2>&1 & "
            + "\(python) -c 'import time; time.sleep(600)'\n"
        try makefile.write(toFile: directory + "/Makefile", atomically: true, encoding: .utf8)
        return try spawn("/usr/bin/make", ["make", "-s", "-C", directory, "serve"])
    }

    /// Waits until some process listens on `port`; returns its pid.
    @discardableResult
    func waitForListener(port: UInt16, timeout: TimeInterval = 15) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for process in PortSysProc.allProcesses() where process.uid == getuid() && groups.contains(process.pgid) {
                if PortSysProc.listeningTCPSockets(pid: process.pid)?.contains(where: { $0.port == port }) == true {
                    return process.pid
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let processes = PortSysProc.allProcesses().filter { groups.contains($0.pgid) }
        throw PortTestError("the throwaway server did not start listening on :\(port)" + outputTail()
                            + "; " + portVisibilityReport(port: port, processes: processes))
    }

    /// A running process started here whose command line contains `text`.
    func pid(commandContaining text: String) -> pid_t? {
        PortSysProc.allProcesses().first { process in
            groups.contains(process.pgid)
                && (PortSysProc.details(for: process)?.arguments.joined(separator: " ").contains(text) ?? false)
        }?.pid
    }

    /// SIGKILL to one of our processes.
    func kill(_ pid: pid_t) {
        guard let process = PortSysProc.basic(pid: pid), groups.contains(process.pgid) else { return }
        Darwin.kill(pid, SIGKILL)
    }

    /// Waits until `pid` exited (reaping it when it is our child; zombies count as gone, as for the engine).
    func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            if !PortSysProc.allProcesses().contains(where: { $0.pid == pid }) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Issue.record("pid \(pid) did not exit")
    }

    /// True while the process (same pid and start time) runs; reaps it first when it is our exited child.
    func isRunning(_ process: PortProcessBasic) -> Bool {
        var status: Int32 = 0
        _ = waitpid(process.pid, &status, WNOHANG)
        return PortSysProc.allProcesses().contains { $0.identity == process.identity }
    }

    /// Kills every process group started here, then anything of this user still listening on one of the sandbox's
    /// ports from inside the sandbox folder (a relaunched server runs in its own session), and removes the folder.
    /// Idempotent.
    func killAll() {
        guard !killed else { return }
        killed = true
        for group in groups where group > 1 {
            Darwin.kill(-group, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(group, &status, 0)
        }
        for process in strays() {
            Darwin.kill(process.pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(process.pid, &status, WNOHANG)
        }
        try? FileManager.default.removeItem(atPath: container)
    }

    /// This user's processes working inside the sandbox folder that aren't in a sandbox process group.
    func strays() -> [PortProcessBasic] {
        let uid = getuid()
        let own = getpid()
        return PortSysProc.allProcesses().filter { process in
            guard process.uid == uid, process.pid > 1, process.pid != own, !groups.contains(process.pgid),
                  let cwd = PortSysProc.currentDirectory(pid: process.pid) else { return false }
            return cwd == container || cwd.hasPrefix(container + "/")
        }
    }

    /// `npm run dev` in a package folder whose dev script runs a tiny node HTTP server on `port`:
    /// npm → sh -c → node, like a real dev server. Returns npm's pid.
    func startNPMDev(in directory: String, name: String, port: UInt16) throws -> pid_t {
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw PortTestError("npm is not installed") }
        let package = #"{"name": "\#(name)", "private": true, "scripts": {"dev": "node server.js"}}"#
        try package.write(toFile: directory + "/package.json", atomically: true, encoding: .utf8)
        let server = "require('http').createServer((q, s) => s.end('ok')).listen(Number(process.env.PORT), '127.0.0.1')\n"
            + "setInterval(() => {}, 1000)\n"
        try server.write(toFile: directory + "/server.js", atomically: true, encoding: .utf8)
        let environment = ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME=" + NSHomeDirectory(),
                           "PORT=\(port)", "npm_config_cache=" + container + "/.npm-cache",
                           "npm_config_userconfig=" + container + "/.npmrc", "npm_config_logs_max=0",
                           "npm_config_update_notifier=false", "npm_config_fund=false", "npm_config_audit=false"]
        return try spawn(npm, [npm, "run", "dev"], directory: directory, environment: environment)
    }

    /// A python listener on `port` that ignores SIGTERM (only SIGKILL ends it).
    func startStubbornListener(in directory: String, port: UInt16) throws -> pid_t {
        guard let python = Self.python else { throw PortTestError("python3 is not installed") }
        let script = """
            import signal, socket, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", \(port)))
            s.listen()
            time.sleep(600)
            """
        return try spawn(python, [python, "-c", script], directory: directory)
    }

    /// A python process with a UDP socket "connected" to `address` (no packet is sent), sleeping.
    func startUDPClient(in directory: String, address: String, port: UInt16) throws -> pid_t {
        guard let python = Self.python else { throw PortTestError("python3 is not installed") }
        let script = "import socket, time\ns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
            + "s.connect((\"\(address)\", \(port)))\ntime.sleep(600)\n"
        return try spawn(python, [python, "-c", script], directory: directory)
    }

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortTestError("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw PortTestError("bind() failed") }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// posix_spawn in a new process group (so `killAll` reaches every child), stdio on /dev/null.
    private func spawn(_ path: String, _ arguments: [String], directory: String? = nil,
                       environment: [String]? = nil) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let directory {
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&actions, directory)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, directory)
            }
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputLog, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?]? = environment.map { $0.map { strdup($0) } + [nil] }
        defer {
            argv.forEach { free($0) }
            envp?.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = envp.map { posix_spawn(&pid, path, &actions, &attributes, argv, $0) }
            ?? posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard status == 0 else { throw PortTestError("posix_spawn failed: \(status)") }
        lock.withLock { spawnedGroups.append(pid) }
        return pid
    }
}
