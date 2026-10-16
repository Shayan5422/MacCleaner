import Darwin
import Foundation
import Testing
@testable import MacCleaner

// The whole Stop flow on throwaway servers the tests start themselves in a temporary folder: the stop plan, Stop,
// Recently Stopped, Relaunch, escalation and the activity feed. Scans see only the sandbox's own processes.

extension PortLiveProcessTests {
    @MainActor
    @Suite struct PortStopFlowTests {
        private let fs = PortResolverTestFS()

        private func makeModel(_ sandbox: PortPipelineSandbox, log: ProtectionEventLog,
                               preferences: NetworkPreferences = PortUIFixtures.preferences()) -> PortsModel {
            let engine = PortScanEngine(resolver: fs.makeResolver(home: sandbox.container, probeDeadline: 1),
                                        listenerFilter: sandbox.listenerFilter)
            let model = PortUIFixtures.model(preferences: preferences, eventLog: log, engine: engine)
            model.relaunchLogDirectory = URL(fileURLWithPath: sandbox.container + "/logs", isDirectory: true)
            model.relaunchPortTimeout = 15
            return model
        }

        private func waitFor(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { throw PortTestError("timed out") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        private func listens(_ port: UInt16) -> Bool {
            var buffer: [proc_fdinfo] = []
            return PortSysProc.allProcesses().contains { process in
                process.uid == getuid()
                    && PortSysProc.listeningTCPSockets(pid: process.pid, fdBuffer: &buffer)?.contains { $0.port == port } == true
            }
        }

        @Test func npmDevServerStopsWholeAndRelaunches() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("stop-demo")
            fs.addDirectory(folder + "/.git")
            fs.addFile(folder + "/package.json", #"{"name": "stop-demo", "scripts": {"dev": "node server.js"}}"#)
            let port = try PortPipelineSandbox.freePort()
            let npm = try sandbox.startNPMDev(in: folder, name: "stop-demo", port: port)
            let node = try sandbox.waitForListener(port: port, timeout: 30)

            let log = ProtectionEventLog(directory: nil)
            let model = makeModel(sandbox, log: log)
            await model.pollOnce(full: true)
            model.acquireVisibility()
            defer { model.releaseVisibility() }
            let group = try #require(model.snapshot.groups.first { $0.ports.contains(port) })
            #expect(group.category == .project)
            #expect(group.title == "stop-demo")
            #expect(model.projectPortCount == 1)

            // Expanding the row shows exactly what Stop will end, runner first.
            model.expandedGroupIDs.insert(group.id)
            try await waitFor(5) { !model.killPlanPreview(for: group).isEmpty }
            let preview = model.killPlanPreview(for: group)
            #expect(preview.first == "npm run dev (pid \(npm))", "\(preview)")
            #expect(preview.contains { $0.hasPrefix("node server.js (pid \(node))") && $0.hasSuffix(":\(port)") }, "\(preview)")

            // Stop ends npm, its sh -c and the server: nothing else.
            await model.stop(group)?.value
            #expect(!listens(port))
            #expect(PortSysProc.basic(pid: npm) == nil && PortSysProc.basic(pid: node) == nil)
            #expect(model.banner?.message == "Stopped stop-demo (:\(port))", "\(String(describing: model.banner))")
            #expect(model.banner?.actionTitle == "Undo")
            let record = try #require(model.recentlyStopped.first)
            #expect(record.ports == [port])
            #expect(record.cwd == folder)
            // npm's intact child with npm's environment: `sh -c "node server.js"`, or `node server.js` itself when the
            // shell exec'd it.
            #expect(record.commandLine == "sh -c \"node server.js\"" || record.commandLine.hasSuffix("node server.js"),
                    "\(record.commandLine)")
            #expect(record.environment["PORT"] == String(port))
            #expect(log.events(of: [.portClosed]).first?.title == "Stopped “stop-demo” (port \(port))")

            // Relaunch runs it again with the original command, environment and folder.
            await model.relaunch(record)?.value
            #expect(model.banner?.message == "Relaunched \(record.title) — listening on :\(port) again",
                    "\(String(describing: model.banner))")
            #expect(model.recentlyStopped.isEmpty)
            #expect(listens(port))
            #expect(!sandbox.strays().isEmpty, "the relaunched server runs in its own session (killAll ends it)")
        }

        @Test func gracefulStopEscalatesForAServerThatIgnoresSIGTERM() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("stubborn")
            fs.addDirectory(folder + "/.git")
            let port = try PortPipelineSandbox.freePort()
            let pid = try sandbox.startStubbornListener(in: folder, port: port)
            _ = try sandbox.waitForListener(port: port)

            let preferences = PortUIFixtures.preferences { $0.gracefulTimeout = 1 }
            let model = makeModel(sandbox, log: ProtectionEventLog(directory: nil), preferences: preferences)
            await model.pollOnce(full: true)
            model.acquireVisibility()
            defer { model.releaseVisibility() }
            let group = try #require(model.snapshot.groups.first { $0.ports.contains(port) })
            await model.stop(group)?.value
            #expect(PortSysProc.basic(pid: pid) == nil)
            #expect(model.banner?.message.hasSuffix("— had to force-stop") == true, "\(String(describing: model.banner))")
        }

        @Test func stopOnlyThisProcessLeavesTheRunner() async throws {
            // make → sh -c "while true; do python3 -m http.server …; done": a runner that outlives its server.
            let tree = try PortThrowawayServerTree()
            defer { tree.kill() }
            let server = try tree.waitForServer()
            fs.addFile(tree.directory + "/Makefile", "serve:\n")
            let group = tree.makePID
            let engine = PortScanEngine(resolver: fs.makeResolver(home: PortProjectResolver.parent(of: tree.directory)),
                                        listenerFilter: { $0.pgid == group })
            let model = PortUIFixtures.model(eventLog: ProtectionEventLog(directory: nil), engine: engine)
            await model.pollOnce(full: true)
            model.acquireVisibility()
            defer { model.releaseVisibility() }
            let listener = try #require(model.debugLatestListener(port: tree.port))
            #expect(listener.basic.pid == server)

            await model.stop(listener, onlyThisProcess: true)?.value
            #expect(PortSysProc.basic(pid: server) == nil, "the listener stopped")
            #expect(PortSysProc.basic(pid: tree.makePID) != nil, "the runner was left running")
            _ = try tree.waitForServer(other: server)   // …and it started the server again
        }

        @Test func connectionsTabStopsAProcessThroughTheSafePlan() async throws {
            let sandbox = try PortPipelineSandbox()
            defer { sandbox.killAll() }
            let folder = try sandbox.folder("udp-client")
            let pid = try sandbox.startUDPClient(in: folder, address: "192.0.2.77", port: 5555)
            let preferences = PortUIFixtures.preferences()
            let lookup = NetFakeThreatLookup(ips: ["192.0.2.77": NetFakeThreatLookup.entry("192.0.2.77:5555")])
            let log = ProtectionEventLog(directory: nil)
            let shield = NetShield(eventLog: log, lookupProvider: { lookup })
            let ports = makeModel(sandbox, log: log, preferences: preferences)
            let connections = ConnectionsModel(preferences: preferences, shield: shield, ports: ports, lookupProvider: { lookup })

            var hit: NetThreatHit?
            for _ in 0..<60 where hit == nil {
                await connections.refresh()
                hit = connections.threatHits.first { $0.process.pid == pid }
                if hit == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
            let found = try #require(hit, "the flagged connection was not seen")
            #expect(found.remoteText == "192.0.2.77:5555")
            #expect(log.events(of: [.maliciousConnection]).count == 1)

            connections.requestStop(found.process)
            try await waitFor(5) { connections.pendingStop != nil }
            let confirmation = try #require(connections.pendingStop)
            #expect(confirmation.plan.targets.contains { $0.pid == pid })
            #expect(confirmation.plan.summary.first?.contains("pid \(pid)") == true, "\(confirmation.plan.summary)")
            connections.confirmStop(confirmation)
            try await waitFor(10) { PortSysProc.basic(pid: pid) == nil }
            try await waitFor(5) { connections.banner != nil }
            #expect(connections.banner?.style == .success, "\(String(describing: connections.banner))")
        }
    }
}

extension PortsModel {
    /// The listener on `port` in the latest scan, for tests.
    func debugLatestListener(port: UInt16) -> PortListenerProcess? {
        snapshot.groups.flatMap(\.processes).first { $0.ports.contains(port) }
    }
}
