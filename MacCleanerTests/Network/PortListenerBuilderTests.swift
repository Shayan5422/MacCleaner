import Foundation
import Testing
@testable import MacCleaner

@Suite struct PortListenerBuilderTests {
    private let uid = PortClassifierFixture.uid
    private let home = PortResolverTestFS.home
    private let node = "/opt/homebrew/bin/node"
    private let python =
        "/opt/homebrew/Cellar/python@3.12/3.12.12/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"

    /// A fake machine: processes, their details, listening sockets and usage.
    private final class World {
        var fixtures: [PortClassifierFixture] = [
            PortClassifierFixture(pid: 1, ppid: 0, uid: 0, executable: "/sbin/launchd", arguments: ["/sbin/launchd"]),
        ]
        var sockets: [Int32: [PortListeningSocket]] = [:]
        var restricted: Set<Int32> = []
        var usage: [Int32: PortResourceUsage] = [:]
        var maps = PortManagerMaps()
        let fs = PortResolverTestFS()

        @discardableResult
        func add(_ fixture: PortClassifierFixture, ports: [UInt16] = [], address: String = "127.0.0.1",
                 memory: UInt64 = 1_000) -> PortClassifierFixture {
            fixtures.append(fixture)
            let pid = fixture.basic.pid
            if !ports.isEmpty {
                sockets[pid] = ports.map { PortListeningSocket(port: $0, address: address, family: .ipv4, pid: pid) }
            }
            usage[pid] = PortResourceUsage(cpuPercent: 1, memoryBytes: memory)
            return fixture
        }

        func build(traits: PortProcessTraitsCache? = nil,
                   sampleUsage: (([PortProcessBasic]) -> [Int32: PortResourceUsage])? = nil) -> [PortListenerGroup] {
            let table = PortProcessTable(processes: fixtures.map(\.basic))
            let details = fixtures.reduce(into: [Int32: PortProcessDetails]()) { $0[$1.basic.pid] = $1.details }
            let raw = PortRawScan(table: table, socketsByPID: sockets, restrictedPIDs: restricted)
            return PortListenerBuilder.build(raw: raw, details: { details[$0.pid] }, usage: usage,
                                         resolver: fs.makeResolver(), maps: maps, currentUID: PortClassifierFixture.uid,
                                         traits: traits, sampleUsage: sampleUsage)
        }
    }

    // MARK: Projects

    @Test func siblingPackagesFormOneProjectGroup() {
        let world = World()
        let root = home + "/Downloads/Harbor Notes"
        world.fs.addDirectory(root + "/.git")
        world.fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"harbor-api\"\n")
        world.fs.addFile(root + "/frontend/package.json", #"{"name": "harbor-web"}"#)
        world.add(PortClassifierFixture(pid: 200, executable: python,
                                    arguments: ["Python", "-m", "uvicorn", "app.main:app", "--port", "8014"],
                                    environment: ["CODEX_SHELL": "1"], cwd: root + "/backend"), ports: [8014])
        world.add(PortClassifierFixture(pid: 201, executable: node,
                                    arguments: ["node", root + "/frontend/node_modules/vite/bin/vite.js", "--port", "5330"],
                                    environment: ["CODEX_SHELL": "1"], cwd: root + "/frontend"), ports: [5330])

        let groups = world.build()
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.id == "project:" + root)
        #expect(group.category == .project)
        #expect(group.title == "Harbor Notes")
        #expect(group.subtitle == "frontend, backend")
        #expect(group.path == root)
        #expect(group.ports == [5330, 8014])
        #expect(group.processes.map(\.basic.pid) == [201, 200], "processes are sorted by first port")
        #expect(group.processes.map(\.displayName) == ["vite", "uvicorn app.main:app"])
        #expect(group.frameworks == ["Vite", "uvicorn"])
        #expect(group.origin == PortLaunchOrigin(kind: .codex, name: "Codex"))
        #expect(group.manager == .none)
    }

    @Test func launchdManagedProjectKeepsProjectGrouping() {
        let world = World()
        let folder = home + "/Downloads/uptime check"
        world.fs.addDirectory(folder + "/.git")
        world.fs.addFile(folder + "/uptime-monitor/package.json", #"{"name": "uptime-monitor"}"#)
        world.add(PortClassifierFixture(pid: 964, executable: node,
                                    arguments: ["node", folder + "/uptime-monitor/server.js"],
                                    cwd: folder + "/uptime-monitor"), ports: [4180], address: "*")
        let job = PortLaunchdJob(label: "com.example.uptime-monitor", domain: "gui/501", plistPath: nil, keepAlive: true,
                             runAtLoad: true, pid: 964)
        world.maps.launchdLabelsByPID = [964: "com.example.uptime-monitor"]
        world.maps.launchdJobs = ["com.example.uptime-monitor": job]

        let group = world.build()[0]
        #expect(group.title == "uptime-monitor")
        #expect(group.subtitle == "node server.js", "a subpath equal to the title is not repeated")
        #expect(group.manager == .launchd(job))
        #expect(group.manager.isAutoRestarting)
        #expect(group.origin == PortLaunchOrigin(kind: .launchd, name: "launchd"))
        #expect(group.isExposedToNetwork)
    }

    // MARK: Services

    @Test func launchdServiceGroupWithWorkersDoesNotDoubleCountUsage() {
        let world = World()
        let nginx = "/opt/homebrew/Cellar/nginx/1.27.0/bin/nginx"
        world.add(PortClassifierFixture(pid: 300, comm: "nginx", executable: nginx,
                                    arguments: ["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf", "", ""],
                                    cwd: home + "/.codex/deploy"), ports: [4173], memory: 100)
        world.add(PortClassifierFixture(pid: 301, ppid: 300, comm: "nginx", executable: nginx,
                                    arguments: ["nginx: worker process", ""], cwd: home + "/.codex/deploy"),
                  ports: [4173], memory: 10)
        world.add(PortClassifierFixture(pid: 302, ppid: 300, comm: "nginx", executable: nginx,
                                    arguments: ["nginx: worker process", ""], cwd: home + "/.codex/deploy"),
                  ports: [4173], memory: 10)
        world.maps.launchdLabelsByPID = [300: "com.acme.docs-frontend"]

        let groups = world.build()
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.id == "launchd:com.acme.docs-frontend")
        #expect(group.category == .service)
        #expect(group.title == "docs-frontend")
        #expect(group.subtitle == "nginx, nginx worker")
        #expect(group.path == home + "/.codex/deploy")
        #expect(group.usage.memoryBytes == 120, "workers are listeners themselves and must not be counted twice")
        guard case .launchd(let job) = group.manager else {
            Issue.record("expected launchd manager")
            return
        }
        #expect(job.runAtLoad, "unknown jobs are assumed to start at login")
    }

    @Test func homebrewServiceTitle() {
        let world = World()
        world.add(PortClassifierFixture(pid: 993, executable: "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres",
                                    arguments: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"],
                                    cwd: "/opt/homebrew/var/postgresql@16"), ports: [5432])
        world.maps.launchdLabelsByPID = [993: "sh.brew.postgresql@16"]
        let group = world.build()[0]
        #expect(group.title == "postgresql@16")
        #expect(group.subtitle == "postgres")
        #expect(group.frameworks == ["PostgreSQL"])
        #expect(group.manager.badge == "brew services")
    }

    @Test func appInstanceAndAppleLabelsAreNotManagers() {
        let world = World()
        world.add(PortClassifierFixture(pid: 400, executable: home + "/.local/bin/tool-server", cwd: "/"), ports: [9000])
        world.add(PortClassifierFixture(pid: 401, executable: "/usr/libexec/rapportd"), ports: [49152], address: "*")
        world.maps.launchdLabelsByPID = [400: "application.com.example.Tool.123.456", 401: "com.apple.rapportd"]

        let groups = world.build()
        #expect(groups.map(\.manager) == [.none, .none])
        #expect(groups.first { $0.processes[0].basic.pid == 401 }?.category == .system)
        #expect(groups.allSatisfy { $0.id.hasPrefix("pid:") })
    }

    @Test func launchdJobAboveAnInteractiveShellIsNotTheManager() {
        let world = World()
        world.add(PortClassifierFixture(pid: 500, executable: home + "/.local/bin/web-terminal"))
        world.add(PortClassifierFixture(pid: 501, ppid: 500, executable: "/bin/zsh", arguments: ["-zsh"]))
        world.add(PortClassifierFixture(pid: 502, ppid: 501, executable: node, arguments: ["node", "server.js"], cwd: "/"),
                  ports: [3000])
        world.maps.launchdLabelsByPID = [500: "com.example.web-terminal"]
        let group = world.build()[0]
        #expect(group.manager == .none)
    }

    // MARK: Other managers

    @Test func pM2AppsGroupByName() {
        let world = World()
        world.add(PortClassifierFixture(pid: 600, executable: node, arguments: ["PM2 v5.4.2: God Daemon (/Users/test/.pm2)"]))
        world.add(PortClassifierFixture(pid: 601, ppid: 600, executable: node, arguments: ["node", "/srv-less/api.js"], cwd: "/"),
                  ports: [7001])
        world.add(PortClassifierFixture(pid: 602, ppid: 600, executable: node, arguments: ["node", "/srv-less/api.js"], cwd: "/"),
                  ports: [7002])
        world.maps.pm2ByPID = [601: (id: 0, name: "api"), 602: (id: 1, name: "api")]

        let groups = world.build()
        #expect(groups.count == 1)
        #expect(groups[0].id == "pm2:api")
        #expect(groups[0].title == "api")
        #expect(groups[0].manager == .pm2(id: 0, name: "api"))
        #expect(groups[0].origin == PortLaunchOrigin(kind: .pm2, name: "PM2"))
    }

    @Test func dockerPortsAreSplitPerContainer() {
        let world = World()
        world.add(PortClassifierFixture(pid: 700, executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
                  ports: [5432, 6379, 9999], address: "*")
        let postgres = PortDockerContainer(id: "c1", name: "db", image: "postgres:16-alpine", restartPolicy: "always")
        let redis = PortDockerContainer(id: "c2", name: "cache", image: "docker.io/library/redis:7", restartPolicy: "no")
        world.maps.dockerByPort = [5432: postgres, 6379: redis]

        let groups = world.build()
        #expect(groups.map(\.id) == ["docker:c1", "docker:c2", "app:/Applications/Docker.app"])
        #expect(groups[0].title == "db")
        #expect(groups[0].subtitle == "postgres:16-alpine")
        #expect(groups[0].category == .service)
        #expect(groups[0].manager == .docker(postgres))
        #expect(groups[0].frameworks == ["PostgreSQL"])
        #expect(groups[1].frameworks == ["Redis"])
        #expect(groups[2].category == .app)
        #expect(groups[2].ports == [9999])
        #expect(groups[0].usage == .zero, "container usage lives in the VM, not the backend process")
    }

    @Test func watcherBecomesManager() {
        let world = World()
        world.fs.addFile(home + "/code/api/package.json", #"{"name": "api"}"#)
        world.add(PortClassifierFixture(pid: 800, executable: node, arguments: ["node", home + "/code/api/node_modules/nodemon/bin/nodemon.js"],
                                    cwd: home + "/code/api"))
        world.add(PortClassifierFixture(pid: 801, ppid: 800, executable: node, arguments: ["node", "index.js"],
                                    cwd: home + "/code/api"), ports: [4000])
        #expect(world.build()[0].manager == .watcher(name: "nodemon"))
    }

    // MARK: Fallback grouping

    @Test func projectlessListenersUnderOneRunnerShareAGroup() {
        let world = World()
        world.add(PortClassifierFixture(pid: 900, executable: "/bin/zsh", arguments: ["-zsh"]))
        let npm = world.add(PortClassifierFixture(pid: 901, ppid: 900, executable: node,
                                              arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "start"]))
        world.add(PortClassifierFixture(pid: 902, ppid: 901, executable: "/bin/sh", arguments: ["sh", "-c", "concurrently a b"]))
        world.add(PortClassifierFixture(pid: 903, ppid: 902, executable: node, arguments: ["node", "a.js"], cwd: "/"), ports: [8081])
        world.add(PortClassifierFixture(pid: 904, ppid: 902, executable: node, arguments: ["node", "b.js"], cwd: "/"), ports: [8082])

        let groups = world.build()
        #expect(groups.count == 1)
        #expect(groups[0].id == "pid:" + npm.basic.identity.description)
        #expect(groups[0].title == "node a.js")
        #expect(groups[0].category == .service)
    }

    @Test func loneProcessGroupUsesItsOwnIdentityAndCwd() {
        let world = World()
        world.add(PortClassifierFixture(pid: 950, comm: "claude", executable: home + "/.local/bin/claude"))
        let mcp = world.add(PortClassifierFixture(pid: 951, ppid: 950, executable: home + "/.local/bin/codebase-memory-mcp",
                                              environment: ["CLAUDECODE": "1"], cwd: home + "/Downloads/Pixelpost"),
                            ports: [9749])
        let group = world.build()[0]
        #expect(group.id == "pid:" + mcp.basic.identity.description)
        #expect(group.category == .service)
        #expect(group.title == "codebase-memory-mcp")
        #expect(group.subtitle == PortFormat.abbreviatePath(home + "/Downloads/Pixelpost"))
        #expect(group.path == home + "/Downloads/Pixelpost")
        #expect(group.origin == PortLaunchOrigin(kind: .claudeCode, name: "Claude Code"))
    }

    @Test func boundaryListenerIsNeverPartOfAProject() {
        let world = World()
        world.fs.addDirectory(home + "/code/app/.git")
        world.add(PortClassifierFixture(pid: 960, comm: "claude", executable: home + "/.local/bin/claude",
                                    cwd: home + "/code/app"), ports: [61000])
        let group = world.build()[0]
        #expect(group.processes[0].project == nil)
        #expect(group.category != .project)
    }

    @Test func restrictedOtherUserListenerIsSystem() {
        let world = World()
        world.add(PortClassifierFixture(pid: 77, uid: 0, comm: "httpd", executable: nil, readable: false), ports: [80], address: "*")
        world.restricted = [77]
        let group = world.build()[0]
        #expect(group.category == .system)
        #expect(group.processes[0].isRestricted)
        #expect(group.title == "httpd")
        #expect(group.processes[0].project == nil)
        #expect(group.manager == .none)
    }

    @Test func appGroupsUseBundle() {
        let world = World()
        world.add(PortClassifierFixture(pid: 1000, executable: "/Applications/Player.app/Contents/MacOS/Player"),
                  ports: [7768, 57621])
        let group = world.build()[0]
        #expect(group.id == "app:/Applications/Player.app")
        #expect(group.title == "Player")
        #expect(group.processes[0].appName == "Player")
        #expect(group.origin == nil)
        #expect(group.subtitle == nil)
    }

    @Test func treeUsageIncludesHelperDescendants() {
        let world = World()
        world.fs.addFile(home + "/code/web/package.json", #"{"name": "web"}"#)
        world.add(PortClassifierFixture(pid: 1100, executable: node, arguments: ["node", home + "/code/web/node_modules/vite/bin/vite.js"],
                                    cwd: home + "/code/web"), ports: [5173], memory: 500)
        world.add(PortClassifierFixture(pid: 1101, ppid: 1100, executable: home + "/code/web/node_modules/@esbuild/darwin-arm64/bin/esbuild",
                                    arguments: ["esbuild", "--service=0.21.5"], cwd: home + "/code/web"), memory: 50)
        let process = world.build()[0].processes[0]
        #expect(process.usage.memoryBytes == 500)
        #expect(process.treeUsage.memoryBytes == 550)
        #expect(abs(process.treeUsage.cpuPercent - 2) <= 0.001)
    }

    @Test func vanishedProcessesAndEmptySocketListsAreSkipped() {
        let world = World()
        world.sockets[4242] = [PortListeningSocket(port: 1234, address: "*", family: .ipv4, pid: 4242)]
        world.add(PortClassifierFixture(pid: 4243, executable: node))
        world.sockets[4243] = []
        #expect(world.build().isEmpty)
    }

    // MARK: Helpers

    @Test func launchdTitles() {
        #expect(PortListenerBuilder.launchdTitle(for: "homebrew.mxcl.redis") == "redis")
        #expect(PortListenerBuilder.launchdTitle(for: "sh.brew.postgresql@16") == "postgresql@16")
        #expect(PortListenerBuilder.launchdTitle(for: "com.northwind.cloudflared") == "cloudflared")
        #expect(PortListenerBuilder.launchdTitle(for: "com.contoso.billing-backend") == "billing-backend")
        #expect(PortListenerBuilder.launchdTitle(for: "local.myserver") == "myserver")
        #expect(PortListenerBuilder.launchdTitle(for: "pm2.alex") == "pm2.alex")
        #expect(PortListenerBuilder.launchdTitle(for: "worker") == "worker")
        // The vendor is usually the project's name: keep it when the rest is generic or several segments.
        #expect(PortListenerBuilder.launchdTitle(for: "com.example.status.tunnel") == "example status tunnel")
        #expect(PortListenerBuilder.launchdTitle(for: "com.example.monitor") == "example monitor")
        #expect(PortListenerBuilder.launchdTitle(for: "com.northwind.app") == "northwind app")
        #expect(PortListenerBuilder.launchdTitle(for: "io.fabrikam.daemon") == "fabrikam daemon")
        #expect(PortListenerBuilder.launchdTitle(for: "ai.tinybot.gateway") == "tinybot gateway")
        #expect(PortListenerBuilder.launchdTitle(for: "ai.relaybot.gateway") == "relaybot gateway")
        #expect(PortListenerBuilder.launchdTitle(for: "com.northwind.cloudflared", keepingVendor: true) == "northwind cloudflared")
        #expect(PortListenerBuilder.launchdTitle(for: "homebrew.mxcl.redis", keepingVendor: true) == "redis")
        #expect(PortListenerBuilder.launchdTitle(for: "com.") == "com.")
    }

    @Test func launchdJobsWithTheSameShortTitleKeepTheirVendor() {
        let world = World()
        let cloudflared = "/opt/homebrew/Cellar/cloudflared/2025.8.1/bin/cloudflared"
        world.add(PortClassifierFixture(pid: 1200, executable: cloudflared, arguments: ["cloudflared", "tunnel", "run"]),
                  ports: [20241])
        world.add(PortClassifierFixture(pid: 1201, executable: cloudflared, arguments: ["cloudflared", "tunnel", "run"]),
                  ports: [20242])
        world.maps.launchdLabelsByPID = [1200: "com.northwind.cloudflared", 1201: "com.acme.cloudflared"]
        #expect(world.build().map(\.title) == ["northwind cloudflared", "acme cloudflared"])
    }

    // MARK: Service folders

    @Test func launchdServiceInRootFolderNeverUsesThePlistAsPath() {
        let world = World()
        let cloudflared = "/opt/homebrew/Cellar/cloudflared/2025.8.1/bin/cloudflared"
        world.add(PortClassifierFixture(pid: 1300, executable: cloudflared, arguments: ["cloudflared", "tunnel", "run"],
                                    cwd: "/"), ports: [20241])
        let plist = home + "/Library/LaunchAgents/com.northwind.cloudflared.plist"
        world.maps.launchdLabelsByPID = [1300: "com.northwind.cloudflared"]
        world.maps.launchdJobs = ["com.northwind.cloudflared": PortLaunchdJob(
            label: "com.northwind.cloudflared", domain: "gui/501", plistPath: plist, keepAlive: true, runAtLoad: true,
            pid: 1300)]
        let group = world.build()[0]
        #expect(group.path == "/opt/homebrew/Cellar/cloudflared/2025.8.1/bin", "the program's folder, not \(plist)")
        #expect(group.path != plist)
    }

    @Test func serviceFolderRules() {
        func folder(_ executable: String?, _ arguments: [String], cwd: String? = "/") -> String? {
            PortListenerBuilder.serviceFolder(for: PortClassifierFixture(pid: 10, executable: executable, arguments: arguments,
                                                                 cwd: cwd).details)
        }
        #expect(folder(node, ["node", "server.js"], cwd: home + "/srv/api") == home + "/srv/api", "cwd wins")
        #expect(folder("/bin/bash", ["/bin/bash", home + "/tools/backup/run.sh"]) == home + "/tools/backup", "a script's folder, not /bin")
        #expect(folder(python, ["Python", "-u", home + "/bots/relay/main.py"]) == home + "/bots/relay")
        #expect(folder("/usr/bin/python3", ["python3", "-m", "http.server"]) == nil, "no script, interpreter folder is useless")
        #expect(folder("/bin/sh", ["sh", "-c", "exec ./run"]) == nil)
        #expect(folder("/usr/libexec/sharingd", ["/usr/libexec/sharingd"]) == nil, "system folders are not offered")
        #expect(folder("/Applications/Ollama.app/Contents/Resources/ollama", ["ollama", "serve"]) == nil)
        #expect(folder(home + "/go/bin/gosvc", ["gosvc"]) == home + "/go/bin")
        #expect(PortListenerBuilder.serviceFolder(for: nil) == nil)
    }

    // MARK: Group usage covers what Stop ends

    @Test func groupUsageIncludesRunnerParentAndSiblingWorkers() {
        let world = World()
        let app = home + "/Downloads/fullstack"
        world.fs.addFile(app + "/package.json", #"{"name": "fullstack-app"}"#)
        world.add(PortClassifierFixture(pid: 1400, executable: "/bin/zsh", arguments: ["-zsh"]), memory: 5)
        world.add(PortClassifierFixture(pid: 1401, ppid: 1400, executable: node,
                                    arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"],
                                    cwd: app), memory: 26)
        world.add(PortClassifierFixture(pid: 1402, ppid: 1401, executable: "/bin/sh",
                                    arguments: ["sh", "-c", "node server.js & node worker.js & wait"], cwd: app), memory: 1)
        world.add(PortClassifierFixture(pid: 1403, ppid: 1402, executable: node, arguments: ["node", "server.js"], cwd: app),
                  ports: [53030], memory: 17)
        world.add(PortClassifierFixture(pid: 1404, ppid: 1402, executable: node, arguments: ["node", "worker.js"], cwd: app),
                  memory: 133)
        world.add(PortClassifierFixture(pid: 1405, ppid: 1403, executable: node, arguments: ["node", "child.js"], cwd: app),
                  memory: 3)
        // An agent the runner happened to start must not be counted (Stop never ends it).
        world.add(PortClassifierFixture(pid: 1406, ppid: 1401, comm: "claude", executable: home + "/.local/bin/claude"),
                  memory: 400)

        let group = world.build()[0]
        #expect(group.processes.map(\.basic.pid) == [1403])
        #expect(group.processes[0].treeUsage.memoryBytes == 20, "the listener row keeps its own tree")
        #expect(group.extraUsage.memoryBytes == 26 + 1 + 133, "npm, sh -c and the worker Stop also ends")
        #expect(group.usage.memoryBytes == 180)
        #expect(abs(group.usage.cpuPercent - 5) <= 0.001)
    }

    @Test func groupUsageSamplesLaunchTreeProcessesOnDemand() {
        let world = World()
        world.add(PortClassifierFixture(pid: 1500, executable: "/bin/zsh", arguments: ["-zsh"]))
        world.add(PortClassifierFixture(pid: 1501, ppid: 1500, executable: node,
                                    arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "start"]))
        world.add(PortClassifierFixture(pid: 1502, ppid: 1501, executable: node, arguments: ["node", "a.js"], cwd: "/"),
                  ports: [8081], memory: 10)
        world.add(PortClassifierFixture(pid: 1503, ppid: 1501, executable: node, arguments: ["node", "b.js"], cwd: "/"),
                  ports: [8082], memory: 20)
        world.usage[1501] = nil   // the scan only sampled listeners and their descendants

        var requested: [[Int32]] = []
        let groups = world.build(sampleUsage: { basics in
            requested.append(basics.map(\.pid))
            return Dictionary(uniqueKeysWithValues: basics.map { ($0.pid, PortResourceUsage(cpuPercent: 2, memoryBytes: 64)) })
        })
        #expect(requested == [[1501]], "only the missing runner is sampled, once")
        #expect(groups.count == 1, "both servers belong to the npm launch")
        #expect(groups[0].usage.memoryBytes == 10 + 20 + 64, "the runner is counted once for the group")
    }

    @Test func launchTreeSharedByTwoGroupsIsCountedOnce() {
        let world = World()
        world.fs.addDirectory(home + "/code/web/.git")
        world.fs.addDirectory(home + "/code/api/.git")
        world.add(PortClassifierFixture(pid: 1600, executable: "/bin/zsh", arguments: ["-zsh"]))
        world.add(PortClassifierFixture(pid: 1601, ppid: 1600, executable: node,
                                    arguments: ["node", home + "/code/node_modules/concurrently/dist/bin/concurrently.js"],
                                    cwd: home + "/code"), memory: 50)
        world.add(PortClassifierFixture(pid: 1602, ppid: 1601, executable: node, arguments: ["node", "server.js"],
                                    cwd: home + "/code/web"), ports: [3000], memory: 1)
        world.add(PortClassifierFixture(pid: 1603, ppid: 1601, executable: node, arguments: ["node", "server.js"],
                                    cwd: home + "/code/api"), ports: [4000], memory: 1)
        let groups = world.build()
        #expect(groups.map(\.id) == ["project:" + home + "/code/web", "project:" + home + "/code/api"])
        #expect(groups.map(\.extraUsage.memoryBytes) == [50, 0], "the shared runner goes to the first group only")
    }

    @Test func noExtraUsageAboveProtectedParentsOrForManagedListeners() {
        let world = World()
        // claude → zsh -c → python: Stop ends only the listener, so nothing above it is counted.
        world.add(PortClassifierFixture(pid: 1700, comm: "claude", executable: home + "/.local/bin/claude"), memory: 300)
        world.add(PortClassifierFixture(pid: 1701, ppid: 1700, executable: "/bin/zsh",
                                    arguments: ["/bin/zsh", "-c", "python3 -m http.server 8765"]), memory: 2)
        world.add(PortClassifierFixture(pid: 1702, ppid: 1701, executable: python,
                                    arguments: ["Python", "-m", "http.server", "8765"], cwd: home + "/Downloads/x"),
                  ports: [8765], memory: 9)
        // Docker rows carry no host usage at all.
        world.add(PortClassifierFixture(pid: 1710, executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
                  ports: [5432], address: "*", memory: 900)
        world.maps.dockerByPort = [5432: PortDockerContainer(id: "c1", name: "db", image: "postgres:16", restartPolicy: nil)]

        let groups = world.build()
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.extraUsage == .zero }, "\(groups.map { ($0.id, $0.extraUsage) })")
        #expect(groups.first { $0.ports == [8765] }?.usage.memoryBytes == 9)
    }

    // MARK: PM2 cluster mode

    private func clusterWorker(pid: Int32, daemon: Int32, name: String, id: Int, port: String?, cwd: String) -> PortClassifierFixture {
        var env: [String: Any] = ["name": name, "pm_id": id, "exec_mode": "cluster_mode", "pm_cwd": cwd]
        if let port { env["PORT"] = port }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: env)) ?? Data(), as: UTF8.self)
        return PortClassifierFixture(pid: pid, ppid: daemon, executable: node,
                                 arguments: ["node", "/opt/homebrew/lib/node_modules/pm2/lib/ProcessContainer.js"],
                                 environment: ["NODE_UNIQUE_ID": String(id), "pm2_env": json, "PORT": "9"], cwd: cwd)
    }

    @Test func pM2ClusterAppOwnsTheDaemonSocket() {
        let world = World()
        let app = home + "/code/northwind-api"
        world.fs.addDirectory(app + "/.git")
        world.fs.addFile(app + "/package.json", #"{"name": "northwind-api"}"#)
        world.add(PortClassifierFixture(pid: 1800, executable: node, arguments: ["PM2 v5.4.3: God Daemon (/Users/test/.pm2)"]),
                  ports: [3000], memory: 40)
        world.add(clusterWorker(pid: 1801, daemon: 1800, name: "northwind-api", id: 4, port: nil, cwd: app), memory: 100)
        world.add(clusterWorker(pid: 1802, daemon: 1800, name: "northwind-api", id: 3, port: nil, cwd: app), memory: 110)
        // A fork-mode app of the same daemon that does not listen: not part of the cluster app.
        world.add(PortClassifierFixture(pid: 1803, ppid: 1800, executable: node, arguments: ["node", "cron.js"],
                                    environment: ["exec_mode": "fork_mode"], cwd: home + "/code/cron"), memory: 7)
        world.maps.pm2ByPID = [1801: (id: 4, name: "northwind-api"), 1802: (id: 3, name: "northwind-api"),
                               1803: (id: 9, name: "cron")]

        let groups = world.build()
        #expect(groups.map(\.id) == ["pm2:northwind-api"])
        let group = groups[0]
        #expect(group.title == "northwind-api")
        #expect(group.manager == .pm2(id: 3, name: "northwind-api"), "lowest pm_id of the app")
        #expect(group.category == .project)
        #expect(group.path == app)
        #expect(group.origin == PortLaunchOrigin(kind: .pm2, name: "PM2"))
        #expect(group.processes.map(\.basic.pid) == [1800], "the daemon holds the socket")
        #expect(group.processes[0].displayName == "pm2 cluster · 2 workers")
        #expect(group.usage.memoryBytes == 210, "the workers pm2 stop ends; not the daemon or other apps")
    }

    @Test func pM2ClusterAppsAreMatchedByPortAndUnknownSocketsStayWithTheDaemon() {
        let world = World()
        world.add(PortClassifierFixture(pid: 1900, executable: node, arguments: ["PM2 v5.4.3: God Daemon (/Users/test/.pm2)"]),
                  ports: [3001, 3002, 3003], memory: 40)
        world.add(clusterWorker(pid: 1901, daemon: 1900, name: "api", id: 0, port: "3001", cwd: "/"), memory: 10)
        world.add(clusterWorker(pid: 1902, daemon: 1900, name: "public", id: 1, port: "3002", cwd: "/"), memory: 20)
        world.add(clusterWorker(pid: 1903, daemon: 1900, name: "admin", id: 2, port: nil, cwd: "/"), memory: 30)
        world.add(clusterWorker(pid: 1904, daemon: 1900, name: "docs", id: 5, port: nil, cwd: "/"), memory: 40)
        world.maps.pm2ByPID = [1901: (0, "api"), 1902: (1, "public"), 1903: (2, "admin"), 1904: (5, "docs")]

        let groups = world.build()
        #expect(groups.map(\.id).sorted() == ["pm2:api", "pm2:public", groups.first { $0.id.hasPrefix("pid:") }?.id ?? "?"].sorted())
        #expect(groups.first { $0.id == "pm2:api" }?.ports == [3001])
        #expect(groups.first { $0.id == "pm2:public" }?.ports == [3002])
        let daemon = groups.first { $0.id.hasPrefix("pid:") }
        #expect(daemon?.ports == [3003], "two apps without PORT: no guessing")
        #expect(daemon?.manager == PortProcessManager.none)
        #expect(daemon?.title == "PM2 daemon")
        #expect(daemon?.usage.memoryBytes == 40 + 30 + 40, "workers of attributed apps are not counted twice")
    }

    @Test func pM2DaemonWithoutJListStaysUnattributed() {
        let world = World()
        world.add(PortClassifierFixture(pid: 2000, executable: node, arguments: ["PM2 v5.4.3: God Daemon (/tmp/x)"]),
                  ports: [3000])
        world.add(clusterWorker(pid: 2001, daemon: 2000, name: "api", id: 0, port: "3000", cwd: "/"))
        let group = world.build()[0]
        #expect(group.manager == PortProcessManager.none, "only pm2 jlist may name an app pm2 commands can stop")
        #expect(group.id.hasPrefix("pid:"))
    }

    @Test func clusterWorkerEnvironmentParsing() {
        #expect(PortPM2ClusterWorker(environment: ["PATH": "/usr/bin"]) == nil)
        #expect(PortPM2ClusterWorker(environment: ["pm2_env": #"{"exec_mode":"fork_mode","name":"x"}"#]) == nil)
        #expect(PortPM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1"]) == PortPM2ClusterWorker(name: nil, id: nil, port: nil))
        #expect(PortPM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1",
                                                      "pm2_env": #"{"exec_mode":"cluster_mode","name":"api","pm_id":7,"env":{"PORT":3005}}"#]) == PortPM2ClusterWorker(name: "api", id: 7, port: 3005))
        #expect(PortPM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1", "pm2_env": "not json"]) == PortPM2ClusterWorker(name: nil, id: nil, port: nil))
        #expect(PortPM2ClusterWorker(environment: ["NODE_UNIQUE_ID": "1", "pm2_env": #"{"PORT":"99999"}"#])?.port == nil)
    }

    // MARK: Memoization

    @Test func sharedTraitsCacheGivesTheSameGroups() {
        let world = World()
        world.fs.addFile(home + "/code/api/package.json", #"{"name": "api"}"#)
        world.add(PortClassifierFixture(pid: 2100, executable: node, arguments: ["node", home + "/code/api/node_modules/nodemon/bin/nodemon.js"],
                                    cwd: home + "/code/api"))
        world.add(PortClassifierFixture(pid: 2101, ppid: 2100, executable: node, arguments: ["node", "index.js"],
                                    environment: ["TERM_PROGRAM": "Apple_Terminal"], cwd: home + "/code/api"), ports: [4000])
        let cache = PortProcessTraitsCache()
        let fresh = world.build()
        let first = world.build(traits: cache)
        let second = world.build(traits: cache)
        for groups in [first, second] {
            #expect(groups.map(\.id) == fresh.map(\.id))
            #expect(groups.map(\.manager) == fresh.map(\.manager))
            #expect(groups.map(\.origin) == fresh.map(\.origin))
            #expect(groups.map(\.title) == fresh.map(\.title))
            #expect(groups.map(\.frameworks) == fresh.map(\.frameworks))
        }
        #expect(second[0].manager == .watcher(name: "nodemon"))
        #expect(cache.count > 0)
    }

    @Test func traitsCacheRecomputesAfterExecAndPrunesDeadProcesses() {
        let cache = PortProcessTraitsCache()
        let shell = PortClassifierFixture(pid: 2200, comm: "sh", executable: "/bin/sh", arguments: ["sh", "-c", "exec vite"])
        let before = cache.traits(for: shell.basic, details: shell.details)
        // Same pid and start time after exec: p_comm changes, so the entry must not be reused.
        let execd = PortClassifierFixture(pid: 2200, comm: "node", executable: node,
                                      arguments: ["node", home + "/w/node_modules/vite/bin/vite.js"])
        let traits = cache.traits(for: execd.basic, details: execd.details)
        #expect(traits.displayName == "vite")
        #expect(before.displayName != traits.displayName)
        // Details that were unreadable at first are picked up once readable.
        let unreadable = PortClassifierFixture(pid: 2201, comm: "node", executable: node, readable: false)
        #expect(cache.traits(for: unreadable.basic, details: nil).displayName == "node")
        let readable = PortClassifierFixture(pid: 2201, comm: "node", executable: node, arguments: ["node", "server.js"])
        #expect(cache.traits(for: readable.basic, details: readable.details).displayName == "node server.js")

        #expect(cache.count == 2)
        cache.prune(keepingAliveIn: PortProcessTable(processes: [execd.basic]))
        #expect(cache.count == 1)
    }

    @Test func lineageAnswersAreReusedOnlyForTheSameAncestry() {
        let cache = PortProcessTraitsCache()
        let a = PortProcessBasic(pid: 10, ppid: 5, pgid: 10, uid: uid, comm: "node", startTime: 10)
        let parent = PortProcessBasic(pid: 5, ppid: 1, pgid: 5, uid: uid, comm: "nodemon", startTime: 5)
        let other = PortProcessBasic(pid: 6, ppid: 1, pgid: 6, uid: uid, comm: "zsh", startTime: 6)
        func lineage(_ chain: [PortProcessBasic]) -> PortProcessTraitsCache.Lineage {
            PortProcessTraitsCache.Lineage(members: chain.map(\.identity),
                                       signatures: chain.map { PortProcessTraitsCache.Signature($0, nil) })
        }
        var computed = 0
        let compute: () -> String? = { computed += 1; return "nodemon" }
        #expect(cache.watcherName(for: a.identity, lineage: lineage([a, parent]), compute: compute) == "nodemon")
        #expect(cache.watcherName(for: a.identity, lineage: lineage([a, parent]), compute: compute) == "nodemon")
        #expect(computed == 1)
        _ = cache.watcherName(for: a.identity, lineage: lineage([a, other]), compute: compute)
        #expect(computed == 2, "re-parented: recomputed")

        var origins = 0
        let origin: () -> PortLaunchOrigin? = { origins += 1; return PortLaunchOrigin(kind: .terminal, name: "Terminal") }
        _ = cache.origin(for: a.identity, lineage: lineage([a, parent]), launchdLabel: nil, compute: origin)
        _ = cache.origin(for: a.identity, lineage: lineage([a, parent]), launchdLabel: nil, compute: origin)
        _ = cache.origin(for: a.identity, lineage: lineage([a, parent]), launchdLabel: "com.x.y", compute: origin)
        #expect(origins == 2, "a different launchd label is a different answer")

        var roots = 0
        let root: () -> PortProcessBasic = { roots += 1; return parent }
        #expect(cache.launchRoot(for: a.identity, lineage: lineage([a, parent]), projectRoot: "/p", compute: root) == parent)
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, parent]), projectRoot: "/p", compute: root)
        #expect(roots == 1)
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, parent]), projectRoot: nil, compute: root)
        #expect(roots == 2, "a different project is a different answer")
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, other]), projectRoot: nil, compute: root)
        #expect(roots == 3, "re-parented: recomputed")
        cache.prune(keepingAliveIn: PortProcessTable(processes: [parent]))
        _ = cache.launchRoot(for: a.identity, lineage: lineage([a, other]), projectRoot: nil, compute: root)
        #expect(roots == 4, "pruned with the process")
    }

    /// Grouping and group usage use the very root PortKillPlanner signals from, whatever its rules are.
    @Test func processGroupIsKeyedByTheKillPlanRoot() {
        let world = World()
        world.add(PortClassifierFixture(pid: 2400, executable: "/bin/zsh", arguments: ["-zsh"]))
        // /usr/bin/make is a shim that execs Xcode's make, so that is the executable a running make has.
        world.add(PortClassifierFixture(pid: 2401, ppid: 2400, executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/make",
                                    arguments: ["make", "serve"], cwd: "/"), memory: 4)
        world.add(PortClassifierFixture(pid: 2402, ppid: 2401, executable: "/bin/sh",
                                    arguments: ["/bin/sh", "-c", "python3 -m http.server 8111"], cwd: "/"), memory: 2)
        world.add(PortClassifierFixture(pid: 2403, ppid: 2402, executable: python, arguments: ["Python", "-m", "http.server", "8111"],
                                    cwd: "/"), ports: [8111], memory: 9)
        let cache = PortProcessTraitsCache()
        let groups = world.build(traits: cache)
        let listener = groups[0].processes[0]
        let table = PortProcessTable(processes: world.fixtures.map(\.basic))
        let details = world.fixtures.reduce(into: [Int32: PortProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        let plan = PortKillPlanner.plan(for: listener, table: table, details: { details[$0.pid] }, currentUID: uid)
        #expect(plan.root.pid == 2401)
        #expect(groups.map(\.id) == ["pid:" + plan.root.identity.description])
        #expect(groups[0].extraUsage.memoryBytes == 4 + 2, "make and sh -c, which Stop also ends")
        #expect(world.build(traits: cache).map(\.id) == groups.map(\.id), "same answer from the memo")
    }

    // MARK: Models

    @Test func groupPortsStayInSyncWithProcesses() {
        let world = World()
        world.add(PortClassifierFixture(pid: 2300, executable: node, arguments: ["node", "a.js"]), ports: [9002, 9001])
        var group = world.build()[0]
        #expect(group.ports == [9001, 9002])
        let extra = PortListenerProcess(basic: PortProcessBasic(pid: 2301, ppid: 1, pgid: 2301, uid: uid, comm: "x", startTime: 1),
                                    details: nil,
                                    sockets: [PortListeningSocket(port: 80, address: "*", family: .ipv4, pid: 2301),
                                              PortListeningSocket(port: 80, address: "::", family: .ipv6, pid: 2301)],
                                    usage: .zero, treeUsage: .zero, category: .service, project: nil, displayName: "x",
                                    frameworks: [], origin: nil, manager: .none, appName: nil, isRestricted: true)
        #expect(extra.ports == [80])
        group.processes.append(extra)
        #expect(group.ports == [80, 9001, 9002])
        group.processes.removeAll()
        #expect(group.ports == [])
    }

    @Test func commandLineDropsTrailingEmptyArguments() {
        func line(_ arguments: [String]) -> String {
            PortProcessDetails(identity: PortProcessIdentity(pid: 1, startTime: 1), executablePath: nil, arguments: arguments,
                           environment: [:], cwd: nil).commandLine
        }
        #expect(line(["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf", "", ""]) == #""nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf""#)
        #expect(line(["/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379", ""]) == #""/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379""#)
        #expect(line(["node", "", "server.js"]) == #"node "" server.js"#, "empty arguments in the middle matter")
        #expect(line(["node", "server.js"]) == "node server.js")
        #expect(line([]) == "")
        let record = PortStoppedRecord(id: UUID(), date: Date(), title: "t", ports: [], cwd: nil,
                                   arguments: ["redis-server *:6379", ""], environment: [:], executablePath: nil,
                                   manager: .none)
        #expect(record.commandLine == #""redis-server *:6379""#)
    }

    @Test func imageFrameworks() {
        #expect(PortListenerBuilder.frameworks(forImage: "ghcr.io/acme/mongo:7@sha256:abc") == ["MongoDB"])
        #expect(PortListenerBuilder.frameworks(forImage: "acme/api:latest") == [])
    }
}
