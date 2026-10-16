import Foundation
import Testing
@testable import MacCleaner

/// PortBanner wording and the actions offered after Stop, Stop All, Relaunch and Start (pure, no processes).
@Suite struct PortStopReportTests {
    private func outcome(_ title: String = "web", ports: [UInt16] = [3000], groupID: String = "project:/x/web",
                         _ change: (inout PortStopOutcome) -> Void = { _ in }) -> PortStopOutcome {
        var outcome = PortStopOutcome(groupID: groupID, title: title, ports: ports)
        outcome.stoppedCount = 1
        change(&outcome)
        return outcome
    }

    private func record(_ arguments: [String], executable: String? = "/opt/homebrew/bin/node",
                        manager: PortProcessManager = .none, ports: [UInt16] = [3000]) -> PortStoppedRecord {
        PortStoppedRecord(id: UUID(), date: Date(), title: "web · node", ports: ports, cwd: "/x/web", arguments: arguments,
                      environment: [:], executablePath: executable, manager: manager)
    }

    // MARK: One Stop

    @Test func successOffersUndoForEveryRecordTheStopCreated() {
        let ids = [UUID(), UUID()]
        let banner = PortStopReport.banner(for: outcome(ports: [3000, 5173]) { $0.undoRecordIDs = ids })
        #expect(banner.style == .success)
        #expect(banner.message == "Stopped web (:3000, :5173)")
        #expect(banner.action == .relaunch(recordID: ids[0], moreRecordIDs: [ids[1]]))
        #expect(banner.actionTitle == "Undo")
    }

    @Test func unloadedLaunchdJobOffersDisableAutoStartWithItsLabel() {
        let banner = PortStopReport.banner(for: outcome { $0.autoStartLabels = ["com.acme.api"]; $0.undoRecordIDs = [UUID()] })
        #expect(banner.message == "Stopped web (:3000). It will start again at next login.")
        #expect(banner.action == .disableAutoStart(groupID: "project:/x/web", launchdLabels: ["com.acme.api"]))
        #expect(banner.actionTitle == "Disable Auto-Start")
    }

    @Test func notesForceKillAndErrors() {
        let noted = PortStopReport.banner(for: outcome { $0.escalated = true; $0.notes = ["pm2 api stopped"] })
        #expect(noted.message == "Stopped web (:3000) — had to force-stop · pm2 api stopped")
        #expect(noted.action == nil)

        let failed = PortStopReport.banner(for: outcome { $0.errors = ["a", "b", "c", "d"]; $0.undoRecordIDs = [UUID()] })
        #expect(failed.style == .error)
        #expect(failed.message == "Couldn't fully stop web: a; b; c")
        #expect(failed.action == nil)
    }

    @Test func alreadyExitedIsInformationNotAnError() {
        let banner = PortStopReport.banner(for: outcome { $0.stoppedCount = 0; $0.alreadyExited = true })
        #expect(banner.style == .info)
        #expect(banner.message == "web had already exited")
    }

    @Test func appsAreQuitOrAskedToQuitWithoutUndo() {
        let quit = PortStopReport.banner(for: outcome("Spotify", ports: [57621]) { $0.quitApp = true })
        #expect(quit.message == "Quit Spotify (:57621)")
        #expect(quit.action == nil)

        let asked = PortStopReport.banner(for: outcome("Xcode", ports: []) { $0.stoppedCount = 0; $0.stillQuitting = true })
        #expect(asked.style == .info)
        #expect(asked.message.hasPrefix("Asked Xcode to quit. It's still open"), "\(asked.message)")
    }

    // MARK: Stop All

    @Test func stopAllSummarizesInOneBanner() throws {
        let undo = [UUID(), UUID(), UUID()]
        let outcomes = [outcome("a", ports: [3000]) { $0.undoRecordIDs = [undo[0]] },
                        outcome("b", ports: [5173]) { $0.undoRecordIDs = [undo[1]] },
                        outcome("c", ports: [8000]) { $0.undoRecordIDs = [undo[2]] }]
        let banner = try #require(PortStopReport.summary(for: outcomes))
        #expect(banner.message == "Stopped 3 projects (:3000, :5173, :8000)")
        #expect(banner.action == .relaunch(recordID: undo[0], moreRecordIDs: [undo[1], undo[2]]))
        #expect(PortStopReport.summary(for: []) == nil)
        #expect(PortStopReport.summary(for: [outcomes[0]])?.message == "Stopped a (:3000)", "one project: as Stop")
    }

    @Test func stopAllNamesTheFailures() throws {
        let outcomes = [outcome("a"), outcome("b") { $0.errors = ["pid 4: Permission denied"] },
                        outcome("c") { $0.errors = ["already exited"] }, outcome("d") { $0.errors = ["x"] }]
        let banner = try #require(PortStopReport.summary(for: outcomes))
        #expect(banner.style == .error)
        #expect(banner.message == "Stopped 1 of 4 projects — b: pid 4: Permission denied; c: already exited; 1 more failed")
    }

    @Test func stopAllOffersOneDisableAutoStartForEveryUnloadedJob() throws {
        let outcomes = [outcome("a") { $0.autoStartLabels = ["com.acme.a"] },
                        outcome("b") { $0.autoStartLabels = ["com.acme.b", "com.acme.a"] }]
        let banner = try #require(PortStopReport.summary(for: outcomes))
        #expect(banner.message == "Stopped 2 projects (:3000). 2 launchd jobs start again at next login.")
        #expect(banner.action == .disableAutoStart(groupID: "", launchdLabels: ["com.acme.a", "com.acme.b"]))
    }

    @Test func stopAllConfirmTooltipListsTheProjects() {
        let job = PortLaunchdJob(label: "com.acme.monitor", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: 9)
        let groups = ["web", "api", "docs", "monitor"].map { name in
            PortUIFixtures.group(id: "project:/x/\(name)", category: .project, title: name, processes: [
                PortUIFixtures.process(pid: Int32(name.count), manager: name == "monitor" ? .launchd(job) : .none),
            ])
        }
        #expect(PortStopReport.stopAllConfirmHelp(Array(groups.prefix(2))) == "Click again to stop web and api.")
        #expect(PortStopReport.stopAllConfirmHelp(groups) == "Click again to stop web, api, docs and 1 more. monitor starts again at next login.")
    }

    // MARK: Relaunch

    @Test func onlyRealCommandsOrRebuildableTitlesCanBeRelaunched() {
        #expect(PortStopReport.canRelaunch(record(["node", "server.js"])))
        #expect(PortStopReport.canRelaunch(record(["npm run dev", "", ""])), "rebuilt as npm run dev")
        #expect(!(PortStopReport.canRelaunch(record(["nginx: master process /opt/homebrew/bin/nginx", ""],
                                                     executable: "/opt/homebrew/bin/nginx"))))
        #expect(!(PortStopReport.canRelaunch(record([]))))
        let job = PortLaunchdJob(label: "com.acme.api", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: nil)
        #expect(!(PortStopReport.canRelaunch(record(["node", "api.js"], manager: .launchd(job)))))
    }

    @Test func relaunchBannersTellTheTruth() throws {
        let server = record(["node", "server.js"])
        let log = "/tmp/logs/web.log"
        func banner(_ state: PortRelaunchResult.State, _ target: PortStoppedRecord = server) throws -> PortBanner {
            try #require(PortStopReport.relaunchBanner(for: [PortRelaunchResult(record: target, state: state, logPath: log)]))
        }
        #expect(try banner(.listening(pid: 7, port: 3000)).message == "Relaunched web · node — listening on :3000 again")
        #expect(try banner(.listening(pid: 7, port: 3000)).style == .success)
        #expect(try banner(.running(pid: 7)).style == .success)

        let quiet = try banner(.notListening(pid: 7))
        #expect(quiet.style == .warning)
        #expect(quiet.message == "Started web · node (pid 7), but :3000 isn't open yet. Its output is in /tmp/logs/web.log.")

        let exited = try banner(.exited)
        #expect(exited.style == .error)
        #expect(exited.message == "Couldn't relaunch web · node: it exited soon after starting. Its output is in /tmp/logs/web.log")
        #expect(try banner(.failed("the folder ~/x no longer exists")).message == "Couldn't relaunch web · node: the folder ~/x no longer exists")

        let other = record(["node", "api.js"], ports: [4000])
        let many = try #require(PortStopReport.relaunchBanner(for: [
            PortRelaunchResult(record: server, state: .listening(pid: 7, port: 3000), logPath: log),
            PortRelaunchResult(record: other, state: .listening(pid: 8, port: 4000), logPath: log),
        ]))
        #expect(many.message == "Relaunched 2 servers (:3000, :4000)")
        let partly = try #require(PortStopReport.relaunchBanner(for: [
            PortRelaunchResult(record: server, state: .listening(pid: 7, port: 3000), logPath: log),
            PortRelaunchResult(record: other, state: .failed("boom"), logPath: log),
        ]))
        #expect(partly.style == .error)
        #expect(partly.message == "Relaunched 1 of 2 — web · node: boom")
        #expect(PortStopReport.relaunchBanner(for: []) == nil)
    }

    @Test func runningRelaunchesLeaveRecentlyStopped() {
        let server = record(["node", "server.js"])
        #expect(PortRelaunchResult(record: server, state: .notListening(pid: 1), logPath: "").isRunning, "running: relaunching again would start a second copy")
        #expect(!(PortRelaunchResult(record: server, state: .exited, logPath: "").isRunning))
        #expect(!(PortRelaunchResult(record: server, state: .failed("x"), logPath: "").isRunning))
    }

    // MARK: Auto-start and Start

    @Test func autoStartBanner() {
        #expect(PortStopReport.autoStartBanner(disabled: ["com.acme.api"], manual: [], errors: []).message == "com.acme.api won't start at login anymore. Turn it back on under Startup Items.")
        let manual = PortStopReport.autoStartBanner(disabled: ["com.acme.a"], manual: ["com.app.helper"], errors: [])
        #expect(manual.style == .warning)
        #expect(manual.message == "Turned off auto-start for com.acme.a. Mac Cleaner can't turn off auto-start for "
                       + "com.app.helper. Turn it off in System Settings › General › Login Items & Extensions.")
        #expect(PortStopReport.autoStartBanner(disabled: [], manual: [], errors: ["x: denied"]).style == .error)
    }

    // MARK: Helpers and contracts

    @Test func portTextAndLists() {
        #expect(PortStopReport.portText([]) == "")
        #expect(PortStopReport.portText([1, 2, 3], limit: 2) == " (:1, :2 +1)")
        #expect(PortStopReport.joinedList(["a"]) == "a")
        #expect(PortStopReport.joinedList(["a", "b", "c"]) == "a, b and c")
    }

    @Test func bannerActionsKeepTheirOldShape() {
        let id = UUID()
        #expect(PortBanner.Action.disableAutoStart(groupID: "g") == .disableAutoStart(groupID: "g", launchdLabels: []))
        #expect(PortBanner.Action.relaunch(recordID: id) == .relaunch(recordID: id, moreRecordIDs: []))
    }
}

/// The UI wiring of these flows (pure parts).
@MainActor
@Suite struct PortStopFlowUITests {
    @Test func stopAllCountsWhatItStops() {
        let visible = PortUIFixtures.group(id: "project:/x/web", category: .project, title: "web",
                                           processes: [PortUIFixtures.process(pid: 11, ports: [3000])])
        let hidden = PortUIFixtures.group(id: "project:/x/old", category: .project, title: "old",
                                          processes: [PortUIFixtures.process(pid: 12, ports: [4000])])
        let mutedPorts = PortUIFixtures.group(id: "project:/x/muted", category: .project, title: "muted",
                                              processes: [PortUIFixtures.process(pid: 13, ports: [5000])])
        let service = PortUIFixtures.group(id: "launchd:redis", category: .service, title: "redis",
                                           processes: [PortUIFixtures.process(pid: 14, ports: [6379], category: .service)])
        let preferences = PortUIFixtures.preferences {
            $0.hiddenGroupIDs = [hidden.id]
            $0.hiddenPorts = [5000]
        }
        let store = PortUIFixtures.model([visible, hidden, mutedPorts, service], preferences: preferences)
        #expect(store.stoppableProjects.map(\.id) == [visible.id])
    }

    @Test func autoRestartNoticeSaysWhatStopAndDisableDo() {
        let launchd = PortLaunchdService(homeDirectory: NSHomeDirectory())
        let agents = NSHomeDirectory() + "/Library/LaunchAgents"
        let managed = PortLaunchdJob(label: "com.acme.api", domain: "gui/501", plistPath: agents + "/com.acme.api.plist",
                                     keepAlive: true, runAtLoad: true, pid: 9)
        #expect(PortGroupRow.autoRestartNotice(for: .launchd(managed), launchd: launchd)
                == "launchd starts this again at next login. Stop & Disable keeps it off (turn it back on under Startup Items).")
        let helper = PortLaunchdJob(label: "com.app.helper", domain: "gui/501", plistPath: nil, keepAlive: true,
                                    runAtLoad: false, pid: 9)
        #expect(PortGroupRow.autoRestartNotice(for: .launchd(helper), launchd: launchd)
                == "launchd starts this again at next login. Turn that off in System Settings › General › Login Items & Extensions.")
        let shared = PortLaunchdJob(label: "com.vendor.agent", domain: "gui/501",
                                    plistPath: "/Library/LaunchAgents/com.vendor.agent.plist", keepAlive: true, runAtLoad: true, pid: 9)
        #expect(PortGroupRow.autoRestartNotice(for: .launchd(shared), launchd: launchd).contains("Login Items"),
                "Mac Cleaner can't switch a shared agent back on, so it never offers to disable one")
        #expect(PortGroupRow.autoRestartNotice(for: .pm2(id: 1, name: "api"), launchd: launchd) == "pm2 restarts “api” automatically.")
    }

    @Test func terminalOpensTheFolderOfAFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pp-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("com.acme.api.plist")
        try Data().write(to: plist)
        #expect(PortsModel.terminalFolder(for: directory.path) == directory.path)
        #expect(PortsModel.terminalFolder(for: plist.path) == directory.path)
        #expect(PortsModel.terminalFolder(for: directory.path + "/missing") == nil)
    }

}
