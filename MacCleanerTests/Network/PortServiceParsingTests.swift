import Foundation
import Testing
@testable import MacCleaner

// Pure-parser tests for the Control layer (launchctl, launchd plists, docker, pm2, Shell helpers).
// A few Shell.run tests spawn tiny local processes (/bin/echo, /bin/sh, /bin/sleep) that the test owns.

// MARK: - launchctl

@Suite struct PortLaunchctlParsingTests {
    private let listOutput = """
    PID\tStatus\tLabel
    -\t0\tcom.apple.SafariHistoryServiceAgent
    1170\t0\tcom.apple.progressd
    50706\t-15\tcom.contoso.billing-backend
    -\t78\tus.zoom.updater
    993\t0\tsh.brew.postgresql@16
    57752\t0\tapplication.com.contoso.FieldNotes.15940426.15940432
    this is not a row
    abc\t0\tbroken.pid

    """

    @Test func parseListSkipsHeaderAndMalformedRows() {
        let entries = PortLaunchdService.parseList(listOutput)
        #expect(entries.map(\.label) == [
            "com.apple.SafariHistoryServiceAgent", "com.apple.progressd", "com.contoso.billing-backend",
            "us.zoom.updater", "sh.brew.postgresql@16", "application.com.contoso.FieldNotes.15940426.15940432",
        ])
        #expect(entries[0] == PortLaunchctlListEntry(pid: nil, lastExitStatus: 0, label: "com.apple.SafariHistoryServiceAgent"))
        #expect(entries[2] == PortLaunchctlListEntry(pid: 50706, lastExitStatus: -15, label: "com.contoso.billing-backend"))
        #expect(entries[3].lastExitStatus == 78)
        #expect(entries[3].pid == nil)
    }

    @Test func parseListStatusDash() {
        let entries = PortLaunchdService.parseList("PID\tStatus\tLabel\n-\t-\tcom.example.never-ran\n")
        #expect(entries == [PortLaunchctlListEntry(pid: nil, lastExitStatus: nil, label: "com.example.never-ran")])
    }

    @Test func runningLabelsOnlyIncludesRunningJobsAndKeepsAppInstances() {
        let labels = PortLaunchdService.runningLabels(fromListOutput: listOutput)
        #expect(labels == [
            1170: "com.apple.progressd",
            50706: "com.contoso.billing-backend",
            993: "sh.brew.postgresql@16",
            57752: "application.com.contoso.FieldNotes.15940426.15940432",
        ])
    }

    @Test func runningLabelsEmptyOutput() {
        #expect(PortLaunchdService.runningLabels(fromListOutput: "").isEmpty)
        #expect(PortLaunchdService.runningLabels(fromListOutput: "PID\tStatus\tLabel\n").isEmpty)
    }

    @Test func parsePrintOutputTakesTopLevelPathOnly() {
        let output = """
        gui/501/com.contoso.billing-backend = {
        \tactive count = 1
        \tpath = /Users/me/Library/LaunchAgents/com.contoso.billing-backend.plist
        \ttype = LaunchAgent
        \tstate = running

        \tprogram = /Users/me/backend/.venv/bin/python
        \targuments = {
        \t\t/Users/me/backend/.venv/bin/python
        \t\t-m
        \t\tuvicorn
        \t}

        \tstdout path = /Users/me/backend.log
        \tenvironment = {
        \t\tPATH => /opt/homebrew/bin:/usr/bin:/bin
        \t}

        \tendpoints = {
        \t\t"com.example.endpoint" = {
        \t\t\tpath = /nested/should/not/win
        \t\t}
        \t}

        \tproperties = keepalive | runatload | inferred program
        }
        """
        let info = LaunchctlParser.parseService(output, label: "com.contoso.billing-backend")
        #expect(info.path == "/Users/me/Library/LaunchAgents/com.contoso.billing-backend.plist")
        #expect(PortLaunchdService.propertyFlags(info.properties.first { $0.key == "properties" }?.value.stringValue)
                == ["keepalive", "runatload", "inferred program"])
    }

    @Test func parsePrintOutputIgnoresNestedPathWhenTopLevelMissing() {
        let output = """
        gui/501/com.example.submitted = {
        \tstdout path = /tmp/out.log
        \tsockets = {
        \t\tpath = /tmp/socket
        \t}
        \tproperties = runatload
        }
        """
        let info = LaunchctlParser.parseService(output, label: "com.example.submitted")
        #expect(info.path == nil)
        #expect(PortLaunchdService.propertyFlags(info.properties.first { $0.key == "properties" }?.value.stringValue)
                == ["runatload"])
    }

    @Test func appInstanceLabelsAndLabelValidation() {
        #expect(PortLaunchdService.isAppInstanceLabel("application.com.spotify.client.31973708.31974546"))
        #expect(!(PortLaunchdService.isAppInstanceLabel("homebrew.mxcl.redis")))
        #expect(PortLaunchdService.isValidLabel("sh.brew.postgresql@16"))
        #expect(!(PortLaunchdService.isValidLabel("")))
        #expect(!(PortLaunchdService.isValidLabel("gui/501/x")))
        #expect(!(PortLaunchdService.isValidLabel("a\nb")))
    }

    @Test func guiDomainUsesUID() {
        #expect(PortLaunchdService(uid: 501).guiDomain == "gui/501")
    }
}

// MARK: - launchd plists

@Suite struct PortLaunchdPlistTests {
    private let dir = "/Users/me/Library/LaunchAgents"

    @Test func programArgumentsPlist() throws {
        let plist: [String: Any] = [
            "Label": "com.example.uptime-monitor",
            "ProgramArguments": ["/opt/homebrew/bin/node", "/Users/me/uptime check/server.js"],
            "WorkingDirectory": "/Users/me/uptime check",
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let info = try #require(PortLaunchdService.parsePlist(plist, path: dir + "/com.example.uptime-monitor.plist"))
        #expect(info.label == "com.example.uptime-monitor")
        #expect(info.command == "/opt/homebrew/bin/node \"/Users/me/uptime check/server.js\"")
        #expect(info.workingDirectory == "/Users/me/uptime check")
        #expect(info.runAtLoad)
        #expect(info.keepAlive)
        #expect(!info.disabledInPlist)
    }

    @Test func programWithArgumentsUsesProgramAsExecutable() throws {
        let plist: [String: Any] = ["Label": "com.example.y", "Program": "/usr/local/bin/y", "ProgramArguments": ["y", "--serve"]]
        let info = try #require(PortLaunchdService.parsePlist(plist, path: dir + "/y.plist"))
        #expect(info.command == "/usr/local/bin/y --serve")
        #expect(!info.runAtLoad)
        #expect(!info.keepAlive)
    }

    @Test func programOnly() throws {
        let plist: [String: Any] = ["Label": "io.fabrikam.daemon",
                                    "Program": "/Applications/Fabrikam.app/Contents/Resources/fabrikam-daemon",
                                    "KeepAlive": false, "RunAtLoad": true]
        let info = try #require(PortLaunchdService.parsePlist(plist, path: dir + "/io.fabrikam.daemon.plist"))
        #expect(info.command == "/Applications/Fabrikam.app/Contents/Resources/fabrikam-daemon")
        #expect(!info.keepAlive)
        #expect(info.runAtLoad)
    }

    @Test func missingLabelFallsBackToFileName() throws {
        let plist: [String: Any] = ["ProgramArguments": ["/bin/sleep", "1"]]
        let info = try #require(PortLaunchdService.parsePlist(plist, path: dir + "/com.example.nolabel.plist"))
        #expect(info.label == "com.example.nolabel")
    }

    @Test func emptyPlaceholderPlistIsSkipped() {
        // Google ships empty `<dict/>` plists to block Keystone; they are not jobs.
        #expect(PortLaunchdService.parsePlist([:], path: dir + "/com.google.keystone.agent.plist") == nil)
    }

    @Test func sessionTypeLimits() throws {
        #expect(PortLaunchdService.loadsInGUISession([]))
        #expect(PortLaunchdService.loadsInGUISession(["Aqua"]))
        #expect(PortLaunchdService.loadsInGUISession(["Aqua", "Background", "LoginWindow", "StandardIO", "System"]))
        #expect(!(PortLaunchdService.loadsInGUISession(["LoginWindow"])))
        #expect(!(PortLaunchdService.loadsInGUISession(["Background"])))
        let prelogin: [String: Any] = ["Label": "com.example.remote-desktop.prelogin",
                                       "ProgramArguments": ["/x/remote-agent", "service"],
                                       "LimitLoadToSessionType": "LoginWindow", "RunAtLoad": true]
        #expect(!(try #require(PortLaunchdService.parsePlist(prelogin, path: "/Library/LaunchAgents/p.plist")).loadsInGUISession))
    }

    @Test func disabledKey() throws {
        let plist: [String: Any] = ["Label": "com.example.off", "Program": "/bin/true", "Disabled": true]
        #expect(try #require(PortLaunchdService.parsePlist(plist, path: dir + "/off.plist")).disabledInPlist)
    }

    @Test func keepAliveInterpretation() {
        func keepAlive(_ value: Any?) -> Bool {
            var plist: [String: Any] = ["Label": "com.example.k", "Program": "/bin/true"]
            if let value { plist["KeepAlive"] = value }
            return PortLaunchdService.parsePlist(plist, path: dir + "/k.plist")?.keepAlive ?? false
        }
        #expect(keepAlive(true))
        #expect(!(keepAlive(false)))
        #expect(keepAlive(["SuccessfulExit": false]))
        #expect(keepAlive(["NetworkState": true, "Crashed": true]))
        #expect(!(keepAlive([String: Any]())))
        #expect(keepAlive(NSNumber(value: 1)))
        // Mac Cleaner's plist reader is lenient with hand-made plists: a "yes" string counts as on, which is the
        // safe reading for Stop (it warns that the job comes back).
        #expect(keepAlive("yes"))
        #expect(!(keepAlive(nil)))
    }

    @Test func binaryAndXMLPlistData() throws {
        let plist: [String: Any] = [
            "Label": "homebrew.mxcl.redis",
            "ProgramArguments": ["/opt/homebrew/opt/redis/bin/redis-server", "/opt/homebrew/etc/redis.conf"],
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": true,
        ]
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            let info = try #require(PortLaunchdService.parsePlist(data: data, path: dir + "/homebrew.mxcl.redis.plist"))
            #expect(info.label == "homebrew.mxcl.redis")
            #expect(info.keepAlive)
            #expect(info.runAtLoad)
            #expect(info.command == "/opt/homebrew/opt/redis/bin/redis-server /opt/homebrew/etc/redis.conf")
        }
    }

    @Test func invalidPlistDataIsRejected() {
        #expect(PortLaunchdService.parsePlist(data: Data("not a plist".utf8), path: dir + "/bad.plist") == nil)
        let arrayPlist = try? PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)
        #expect(PortLaunchdService.parsePlist(data: arrayPlist ?? Data(), path: dir + "/array.plist") == nil)
    }

    @Test func readPlistRejectsMissingFile() {
        #expect(PortLaunchdService.readPlist(at: "/nonexistent/com.maccleaner.network.test.plist") == nil)
    }

    @Test func commandSummaryQuoting() {
        #expect(PortLaunchdService.commandSummary(program: nil, arguments: ["/bin/zsh", "-lc", "cd '/a b' && npm start"]) == "/bin/zsh -lc \"cd '/a b' && npm start\"")
        #expect(PortLaunchdService.commandSummary(program: nil, arguments: []) == "")
        #expect(PortLaunchdService.commandSummary(program: "/bin/x", arguments: []) == "/bin/x")
    }

}

// MARK: - Docker

@Suite struct PortDockerParsingTests {
    @Test func hostPortsVariants() {
        #expect(PortDockerService.parseHostPorts("0.0.0.0:5432->5432/tcp, :::5432->5432/tcp") == [5432])
        #expect(PortDockerService.parseHostPorts("[::]:8080->80/tcp") == [8080])
        #expect(PortDockerService.parseHostPorts("127.0.0.1:8000-8002->8000-8002/tcp") == [8000, 8001, 8002])
        #expect(PortDockerService.parseHostPorts("6379/tcp") == [])
        #expect(PortDockerService.parseHostPorts("0.0.0.0:53->53/udp, 0.0.0.0:8443->443/tcp") == [8443])
        #expect(PortDockerService.parseHostPorts("0.0.0.0:3000->3000/tcp, 0.0.0.0:3001->3001/tcp, 9229/tcp") == [3000, 3001])
        #expect(PortDockerService.parseHostPorts("") == [])
        #expect(PortDockerService.parseHostPorts("0.0.0.0:1-65535->1-65535/tcp") == [], "huge ranges are ignored")
        #expect(PortDockerService.parseHostPorts("0.0.0.0:99999->80/tcp") == [], "out-of-range port")
    }

    private let psOutput = """
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-10-01 10:00:00 +0200 CEST","ID":"3f2a1b4c5d6e","Image":"postgres:16","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"db","Networks":"bridge","Ports":"0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}
    {"ID":"9a8b7c6d5e4f","Image":"redis:7","Names":"cache,app/redis","Ports":"6379/tcp","State":"running"}
    {"ID":"0011aabbccdd","Image":"nginx:latest","Names":"web","Ports":"127.0.0.1:8080->80/tcp, 127.0.0.1:5433->5432/tcp"}
    Cannot connect to the Docker daemon? (noise line)
    {"Names":"no-id"}

    """

    @Test func parsePSOutput() {
        let entries = PortDockerService.parsePSOutput(psOutput)
        #expect(entries == [
            PortDockerPSEntry(id: "3f2a1b4c5d6e", name: "db", image: "postgres:16", hostPorts: [5433]),
            PortDockerPSEntry(id: "9a8b7c6d5e4f", name: "cache", image: "redis:7", hostPorts: []),
            PortDockerPSEntry(id: "0011aabbccdd", name: "web", image: "nginx:latest", hostPorts: [8080, 5433]),
        ])
    }

    @Test func inspectRestartPolicies() {
        let output = """
        3f2a1b4c5d6e00000000000000000000000000000000000000000000000000aa unless-stopped
        9a8b7c6d5e4f00000000000000000000000000000000000000000000000000bb \("")
        0011aabbccdd00000000000000000000000000000000000000000000000000cc always
        Error: No such object: gone
        """
        let policies = PortDockerService.parseInspectRestartPolicies(output)
        #expect(policies.count == 3)
        #expect(policies["3f2a1b4c5d6e00000000000000000000000000000000000000000000000000aa"] == "unless-stopped")
        #expect(policies["9a8b7c6d5e4f00000000000000000000000000000000000000000000000000bb"] == "no")
        #expect(policies["0011aabbccdd00000000000000000000000000000000000000000000000000cc"] == "always")
    }

    @Test func portMapJoinsPoliciesByIDPrefixAndFirstContainerWins() {
        let entries = PortDockerService.parsePSOutput(psOutput)
        let policies = [
            "3f2a1b4c5d6e00000000000000000000000000000000000000000000000000aa": "unless-stopped",
            "0011aabbccdd00000000000000000000000000000000000000000000000000cc": "always",
        ]
        let map = PortDockerService.portMap(entries: entries, restartPolicies: policies)
        #expect(Set(map.keys) == [5433, 8080])
        #expect(map[5433] == PortDockerContainer(id: "3f2a1b4c5d6e", name: "db", image: "postgres:16", restartPolicy: "unless-stopped"))
        #expect(map[8080] == PortDockerContainer(id: "0011aabbccdd", name: "web", image: "nginx:latest", restartPolicy: "always"))
        #expect(PortDockerService.portMap(entries: entries, restartPolicies: [:])[5433]?.restartPolicy == nil)
    }

    @Test func dockerBackendDetection() {
        func basic(_ comm: String) -> PortProcessBasic {
            PortProcessBasic(pid: 100, ppid: 1, pgid: 100, uid: 501, comm: comm, startTime: 0)
        }
        func details(_ path: String?, _ args: [String]) -> PortProcessDetails {
            PortProcessDetails(identity: PortProcessIdentity(pid: 100, startTime: 0), executablePath: path,
                           arguments: args, environment: [:], cwd: nil)
        }
        #expect(PortDockerService.isDockerBackend(basic("com.docker.backe"), details: nil), "truncated p_comm")
        #expect(PortDockerService.isDockerBackend(basic("com.docker.backend"), details: nil))
        #expect(PortDockerService.isDockerBackend(basic("vpnkit-bridge"), details: nil))
        #expect(PortDockerService.isDockerBackend(basic("OrbStack Helper"), details: nil))
        #expect(PortDockerService.isDockerBackend(basic("gvproxy"), details: nil))
        #expect(PortDockerService.isDockerBackend(
            basic("backend"),
            details: details("/Applications/Docker.app/Contents/MacOS/com.docker.backend", ["com.docker.backend"])))
        #expect(PortDockerService.isDockerBackend(
            basic("ssh"), details: details("/usr/bin/ssh", ["ssh: /Users/me/.colima/_lima/colima/ssh.sock [mux]"])))
        #expect(PortDockerService.isDockerBackend(
            basic("limactl"), details: details("/opt/homebrew/bin/limactl", ["limactl", "hostagent", "--pidfile", "x", "default"])))
        #expect(!(PortDockerService.isDockerBackend(basic("ssh"), details: details("/usr/bin/ssh", ["/usr/bin/ssh", "-N", "build-box"]))))
        #expect(!(PortDockerService.isDockerBackend(basic("limactl"), details: details("/opt/homebrew/bin/limactl", ["limactl", "list"]))))
        #expect(!(PortDockerService.isDockerBackend(basic("node"), details: nil)))
        #expect(!(PortDockerService.isDockerBackend(basic("com.docker"), details: nil)), "short prefix must not match")
    }

    @Test func containerReferenceValidation() {
        #expect(PortDockerService.isValidContainerReference("3f2a1b4c5d6e"))
        #expect(PortDockerService.isValidContainerReference("my_db.1-x"))
        #expect(!(PortDockerService.isValidContainerReference("--rm")))
        #expect(!(PortDockerService.isValidContainerReference("")))
        #expect(!(PortDockerService.isValidContainerReference("a b")))
        #expect(!(PortDockerService.isValidContainerReference("é")))
    }
}

// MARK: - PM2

@Suite struct PM2ParsingTests {
    @Test func jListWithLeadingWarnings() {
        let output = """
        >>>> In-memory PM2 is out-of-date, do:
        >>>> $ pm2 update
        In memory PM2 version: 5.3.0
        Local PM2 version: 5.4.3
        [PM2][WARN] Current process list is not synchronized with saved list. Type 'pm2 save' to synchronize.
        [{"pid":4242,"name":"api","pm2_env":{"pm_id":0,"status":"online","NOTE":"has ] and [ in a string"},"pm_id":0,"monit":{"memory":1024,"cpu":1}},{"pid":0,"name":"worker","pm2_env":{"pm_id":1,"status":"stopped"},"pm_id":1},{"pid":4343,"name":"web","pm2_env":{"pm_id":2,"status":"online"}}]
        [PM2][WARN] trailing noise ]
        """
        let processes = PortPM2Service.parseJList(output)
        #expect(processes == [
            PortPM2Process(id: 0, name: "api", pid: 4242, status: "online"),
            PortPM2Process(id: 1, name: "worker", pid: 0, status: "stopped"),
            PortPM2Process(id: 2, name: "web", pid: 4343, status: "online"),
        ])
    }

    @Test func jListEmptyAndGarbage() {
        #expect(PortPM2Service.parseJList("[]") == [])
        #expect(PortPM2Service.parseJList("[]\n") == [])
        #expect(PortPM2Service.parseJList("") == [])
        #expect(PortPM2Service.parseJList("[PM2] Spawning PM2 daemon") == [])
        #expect(PortPM2Service.parseJList("[{\"name\":\"no id\"}]") == [])
    }

    @Test func matchingBracket() {
        let bytes = Array(#"[1,"]",{"a":[2]}] tail]"#.utf8)
        #expect(PortPM2Service.matchingBracket(in: bytes, from: 0) == 16)
        #expect(PortPM2Service.matchingBracket(in: Array("[1,2".utf8), from: 0) == nil)
    }

    @Test func daemonDetection() {
        let node = PortProcessBasic(pid: 79220, ppid: 1, pgid: 79220, uid: 501, comm: "node", startTime: 0)
        func details(_ args: [String]) -> PortProcessDetails {
            PortProcessDetails(identity: node.identity, executablePath: "/opt/homebrew/Cellar/node/24.0.0/bin/node",
                           arguments: args, environment: [:], cwd: nil)
        }
        #expect(PortPM2Service.isDaemon(node, details: details(["PM2 v5.4.3: God Daemon (/Users/me/.pm2)"])))
        #expect(!(PortPM2Service.isDaemon(node, details: details(["node", "/opt/homebrew/bin/pm2", "jlist"]))))
        #expect(!(PortPM2Service.isDaemon(node, details: details(["node", "/Users/me/app/server.js"]))))
        #expect(!(PortPM2Service.isDaemon(node, details: nil)))
        let titled = PortProcessBasic(pid: 1, ppid: 1, pgid: 1, uid: 501, comm: "PM2 v6.0.0: God Daemon (/x/.pm2)", startTime: 0)
        #expect(PortPM2Service.isDaemon(titled, details: nil))
    }

    @Test func noDaemonMeansNoProcessesAndNoSubprocess() async {
        let service = PortPM2Service(pm2Home: "/nonexistent/com.maccleaner.network.tests/.pm2")
        #expect(!service.isDaemonRunning())
        #expect(await service.processesByPID().isEmpty)
        #expect(await service.processList().isEmpty)
        await #expect(throws: (any Error).self) { try await service.stop(id: 0) }
        await #expect(throws: (any Error).self) { try await service.delete(id: 0, name: "api") }
    }

    // MARK: Cluster mode (finding #9)

    private let clusterJList = """
    [{"pid":5001,"name":"api","pm_id":0,"pm2_env":{"pm_id":0,"status":"online","exec_mode":"cluster_mode","PORT":"3001"}},
     {"pid":5002,"name":"api","pm_id":1,"pm2_env":{"pm_id":1,"status":"online","exec_mode":"cluster_mode","env":{"PORT":3001}}},
     {"pid":5003,"name":"web","pm_id":2,"pm2_env":{"pm_id":2,"status":"online","exec_mode":"fork_mode","env":{"PORT":"8080"}}},
     {"pid":5004,"name":"web","pm_id":3,"pm2_env":{"pm_id":3,"status":"online","exec_mode":"fork_mode"}},
     {"pid":0,"name":"cron","pm_id":4,"pm2_env":{"pm_id":4,"status":"stopped","exec_mode":"fork_mode","PORT":"not a port"}}]
    """

    @Test func jListExecModeAndPort() {
        let processes = PortPM2Service.parseJList(clusterJList)
        #expect(processes.map(\.id) == [0, 1, 2, 3, 4])
        #expect(processes[0] == PortPM2Process(id: 0, name: "api", pid: 5001, status: "online",
                                                execMode: "cluster_mode", port: 3001))
        #expect(processes[1].port == 3001, "PORT from pm2_env.env")
        #expect(processes[0].isClusterMode && processes[1].isClusterMode)
        #expect(!processes[2].isClusterMode)
        #expect(processes[2].port == 8080)
        #expect(processes[3].port == nil)
        #expect(processes[4].port == nil)
    }

    @Test func commandsAddressEveryClusterInstance() {
        let list = PortPM2Service.parseJList(clusterJList)
        let cluster: (PortPM2Process) -> Bool = { $0.isClusterMode }
        // Stop: a cluster app as a whole (its instances share the daemon's port), a fork instance on its own.
        #expect(PortPM2Service.instanceIDs(for: 1, name: nil, in: list, wholeApp: cluster) == [0, 1])
        #expect(PortPM2Service.instanceIDs(for: 3, name: nil, in: list, wholeApp: cluster) == [3])
        // Delete: every instance of the app.
        #expect(PortPM2Service.instanceIDs(for: 2, name: nil, in: list, wholeApp: { _ in true }) == [2, 3])
        // Already gone: nothing (or what is left of the named app), never a stale id that pm2 would reject.
        #expect(PortPM2Service.instanceIDs(for: 9, name: nil, in: list, wholeApp: { _ in true }) == [])
        #expect(PortPM2Service.instanceIDs(for: 9, name: "web", in: list, wholeApp: { _ in true }) == [2, 3])
        // jlist unavailable: fall back to the id we were given.
        #expect(PortPM2Service.instanceIDs(for: 7, name: "x", in: nil, wholeApp: { _ in true }) == [7])
    }

    @Test func daemonPortsAreAttributedToTheirClusterApp() {
        func app(_ id: Int, _ name: String, mode: String = "cluster_mode", status: String = "online",
                 port: UInt16? = nil) -> PortPM2Process {
            PortPM2Process(id: id, name: name, pid: Int32(100 + id), status: status, execMode: mode, port: port)
        }
        // One running cluster app owns every port the daemon holds, whatever its PORT says.
        let single = [app(0, "api", port: 3000), app(1, "api", port: 3000), app(2, "worker", mode: "fork_mode")]
        #expect(PortPM2Service.clusterApp(forDaemonPort: 3000, in: single)?.id == 0)
        #expect(PortPM2Service.clusterApp(forDaemonPort: 3001, in: single)?.name == "api")
        // Several cluster apps: matched by PORT; ambiguous or unknown stays unattributed.
        let several = single + [app(3, "web", port: 8080), app(4, "web", port: 8080), app(5, "admin")]
        #expect(PortPM2Service.clusterApp(forDaemonPort: 8080, in: several)?.id == 3)
        #expect(PortPM2Service.clusterApp(forDaemonPort: 3000, in: several)?.name == "api")
        #expect(PortPM2Service.clusterApp(forDaemonPort: 9999, in: several) == nil)
        // Stopped cluster apps hold no socket; fork apps never listen through the daemon.
        let stopped = [app(0, "api", status: "stopped", port: 3000), app(1, "web", port: 8080)]
        #expect(PortPM2Service.clusterApp(forDaemonPort: 3000, in: stopped)?.name == "web")
        #expect(PortPM2Service.clusterApp(forDaemonPort: 3000, in: [app(0, "solo", mode: "fork_mode", port: 3000)]) == nil)
        #expect(PortPM2Service.clusterApp(forDaemonPort: 47135, in: PortPM2Service.parseJList(clusterJList))?.name == "api")
    }

    // MARK: Saved list (finding #10)

    private func makeDump(_ entries: [[String: Any]]) throws -> (directory: URL, dump: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerNetworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dump = directory.appendingPathComponent("dump.pm2")
        try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]).write(to: dump)
        return (directory, dump)
    }

    @Test func deleteRemovesOnlyThatAppFromTheSavedList() throws {
        let saved: [[String: Any]] = [
            ["name": "api", "pm_id": 0, "exec_mode": "cluster_mode", "pm_exec_path": "/srv/api/index.js"],
            ["name": "api", "pm_id": 1, "exec_mode": "cluster_mode", "pm_exec_path": "/srv/api/index.js"],
            ["name": "web", "pm_id": 2, "env": ["PORT": "8080", "URL": "https://x.test/a/b"], "autorestart": true],
            ["name": "worker", "pm_id": 3, "max_memory_restart": 1.5],
        ]
        let (directory, dump) = try makeDump(saved)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dump.path)
        let original = try Data(contentsOf: dump)

        #expect(PortPM2Service.removeApp(named: "api", fromDumpAt: dump) == .removed(2))

        let remaining = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [[String: Any]])
        #expect(remaining.compactMap { $0["name"] as? String } == ["web", "worker"])
        #expect(NSDictionary(dictionary: remaining[0]) == NSDictionary(dictionary: saved[2]), "other apps untouched")
        #expect(NSDictionary(dictionary: remaining[1]) == NSDictionary(dictionary: saved[3]))
        #expect(!(String(decoding: try Data(contentsOf: dump), as: UTF8.self).contains("\\/")), "slashes stay readable")
        #expect(try Data(contentsOf: directory.appendingPathComponent("dump.pm2.bak")) == original, "backup kept")
        let permissions = try FileManager.default.attributesOfItem(atPath: dump.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600, "permissions kept")

        // Nothing left to remove: the file is not rewritten.
        let before = try Data(contentsOf: dump)
        #expect(PortPM2Service.removeApp(named: "api", fromDumpAt: dump) == .notSaved)
        #expect(try Data(contentsOf: dump) == before)
    }

    @Test func savedListEdgeCases() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerNetworkTests-\(UUID().uuidString)/dump.pm2")
        #expect(PortPM2Service.removeApp(named: "api", fromDumpAt: missing) == .notSaved)
        #expect(PortPM2SavedListUpdate.notSaved.note == nil)
        #expect(PortPM2SavedListUpdate.removed(1).note == nil)

        let (directory, dump) = try makeDump([])
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: dump)
        let result = PortPM2Service.removeApp(named: "api", fromDumpAt: dump)
        guard case .unavailable = result else {
            Issue.record("\(result)")
            return
        }
        #expect(result.note != nil, "the user is told to run pm2 save")
        #expect(try Data(contentsOf: dump) == Data("{ not json".utf8), "an unreadable list is left alone")
        #expect(!(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dump.pm2.bak").path)))
    }
}

// MARK: - launchd: reversible disable (finding #12)

@Suite struct PortLaunchdReversibleDisableTests {
    @Test func onlyAgentsInLaunchAgentsFoldersCanBeDisabledReversibly() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerNetworkTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let elsewhere = home.appendingPathComponent("code/app", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let service = PortLaunchdService(uid: 501, homeDirectory: home.path)

        func writePlist(_ label: String, in directory: URL, extra: [String: Any] = [:]) throws -> String {
            var plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "60"], "RunAtLoad": true]
            plist.merge(extra) { $1 }
            let url = directory.appendingPathComponent("\(label).plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            return url.path
        }
        func job(_ label: String, _ path: String?, domain: String = "gui/501") -> PortLaunchdJob {
            PortLaunchdJob(label: label, domain: domain, plistPath: path, keepAlive: true, runAtLoad: true, pid: 123)
        }

        let managed = try writePlist("com.maccleaner.network.selftest.managed", in: agents)
        #expect(service.isManageable(plistPath: managed))
        #expect(service.canDisableReversibly(job: job("com.maccleaner.network.selftest.managed", managed)))
        // Shared agents are read-only on Mac Cleaner's Startup Items page, so a disable couldn't be undone there.
        #expect(!(service.isManageable(plistPath: "/Library/LaunchAgents/com.example.agent.plist")))

        // A plist bootstrapped from a project folder, an SMAppService helper (no path), an app bundle plist.
        let project = try writePlist("com.maccleaner.network.selftest.project", in: elsewhere)
        #expect(!(service.isManageable(plistPath: project)))
        #expect(!(service.canDisableReversibly(job: job("com.maccleaner.network.selftest.project", project))))
        #expect(!(service.canDisableReversibly(job: job("com.openai.chat-helper", nil))))
        #expect(!(service.isManageable(plistPath: "/Applications/Avast.app/Contents/Resources/com.avast.av.gui.plist")))
        #expect(!(service.isManageable(plistPath: agents.path + "/nested/x.plist")))
        #expect(!(service.isManageable(plistPath: agents.path + "/../LaunchAgents-other/x.plist")))
        #expect(!(service.isManageable(plistPath: "relative/x.plist")))

        // In the folder but not what Startup Items would show: other label, LoginWindow-only, Apple, daemon domain.
        #expect(!(service.canDisableReversibly(job: job("com.maccleaner.network.selftest.other", managed))))
        let loginWindow = try writePlist("com.maccleaner.network.selftest.prelogin", in: agents,
                                         extra: ["LimitLoadToSessionType": "LoginWindow"])
        #expect(!(service.canDisableReversibly(job: job("com.maccleaner.network.selftest.prelogin", loginWindow))))
        let apple = try writePlist("com.apple.selftest", in: agents)
        #expect(!(service.canDisableReversibly(job: job("com.apple.selftest", apple))))
        #expect(!(service.canDisableReversibly(job: job("com.maccleaner.network.selftest.managed", managed,
                                                             domain: "system"))))
    }
}

// MARK: - Administrator prompt

@Suite struct PortAdminScriptTests {
    @Test func appleScriptStringLiteralEscaping() {
        #expect(PortProcessKiller.appleScriptStringLiteral(#"kill -TERM 123"#) == #""kill -TERM 123""#)
        #expect(PortProcessKiller.appleScriptStringLiteral(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(PortProcessKiller.appleScriptStringLiteral("") == #""""#)
        #expect(PortProcessKiller.doShellScript(#"echo "hi""#, administrator: true)
                == #"do shell script "echo \"hi\"" with administrator privileges"#)
        #expect(PortProcessKiller.doShellScript("true", administrator: false) == #"do shell script "true""#)
    }
}
