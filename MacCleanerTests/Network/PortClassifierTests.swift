import Foundation
import Testing
@testable import MacCleaner

/// Process fixtures shared by the classifier and listener-builder tests.
struct PortClassifierFixture {
    var basic: PortProcessBasic
    var details: PortProcessDetails?

    static let uid: UInt32 = 501

    init(pid: Int32, ppid: Int32 = 1, uid: UInt32 = PortClassifierFixture.uid, comm: String? = nil, executable: String?,
         arguments: [String] = [], environment: [String: String] = [:], cwd: String? = "/", readable: Bool = true) {
        let name = comm ?? executable.map { String(($0 as NSString).lastPathComponent.prefix(16)) } ?? "?"
        basic = PortProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: uid, comm: name, startTime: UInt64(pid) * 1_000)
        details = readable
            ? PortProcessDetails(identity: basic.identity, executablePath: executable,
                             arguments: arguments.isEmpty ? [executable ?? name] : arguments,
                             environment: environment, cwd: cwd)
            : nil
    }
}

@Suite struct PortClassifierTests {
    private let uid = PortClassifierFixture.uid
    private let pythonFramework =
        "/opt/homebrew/Cellar/python@3.12/3.12.12/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
    private let project = PortProjectInfo(rootPath: "/Users/test/code/app", name: "app", subpath: nil, markers: [".git"])

    private func category(_ fixture: PortClassifierFixture, project: PortProjectInfo? = nil) -> PortListenerCategory {
        PortClassifier.category(basic: fixture.basic, details: fixture.details, project: project, manager: .none,
                            currentUID: uid)
    }

    private func label(_ executable: String?, _ arguments: [String], comm: String? = nil) -> String {
        let fixture = PortClassifierFixture(pid: 10, comm: comm, executable: executable, arguments: arguments)
        return PortClassifier.displayName(basic: fixture.basic, details: fixture.details)
    }

    private func frameworks(_ executable: String?, _ arguments: [String]) -> [String] {
        let fixture = PortClassifierFixture(pid: 10, executable: executable, arguments: arguments)
        return PortClassifier.frameworks(details: fixture.details, comm: fixture.basic.comm)
    }

    // MARK: Category

    @Test func categories() {
        #expect(category(PortClassifierFixture(pid: 709, executable: "/usr/libexec/rapportd")) == .system)
        #expect(category(PortClassifierFixture(pid: 88, uid: 0, executable: "/usr/sbin/httpd")) == .system)
        #expect(category(PortClassifierFixture(pid: 89, uid: 0, executable: nil, readable: false)) == .system)
        #expect(category(PortClassifierFixture(pid: 90, comm: "rapportd", executable: nil, readable: false)) == .system)
        #expect(category(PortClassifierFixture(pid: 91, comm: "mystery", executable: nil, readable: false)) == .service)
        #expect(category(PortClassifierFixture(pid: 92, executable: "/Applications/Player.app/Contents/MacOS/Player")) == .app)
        #expect(category(PortClassifierFixture(
            pid: 93, executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")) == .app)
        #expect(category(PortClassifierFixture(pid: 94, executable: "/Applications/Postgres.app/Contents/Versions/16/bin/postgres")) == .service, "servers shipped in an app bundle are services")
        #expect(category(PortClassifierFixture(pid: 95, executable: pythonFramework, arguments: ["Python", "-m", "http.server"])) == .service, "a runtime inside Python.framework is not an app")
        #expect(category(PortClassifierFixture(pid: 96, executable: "/opt/homebrew/opt/redis/bin/redis-server")) == .service)
        #expect(category(PortClassifierFixture(pid: 97, executable: "/opt/homebrew/bin/node"), project: project) == .project)
        #expect(category(PortClassifierFixture(pid: 98, executable: "/usr/bin/python3"), project: project) == .project, "dev runtimes in /usr/bin are not system processes")
        #expect(category(PortClassifierFixture(pid: 99, executable: "/usr/sbin/sshd"), project: project) == .system)
    }

    @Test func appBundleUsesOutermostBundle() {
        let bundle = PortClassifier.appBundle(
            forExecutable: "/Applications/Imaginary Studio.app/Contents/Frameworks/Imaginary Helper (Plugin).app/Contents/MacOS/Imaginary Helper (Plugin)")
        #expect(bundle?.bundlePath == "/Applications/Imaginary Studio.app")
        #expect(bundle?.name == "Imaginary Studio")
        #expect(PortClassifier.appBundle(forExecutable: "/opt/homebrew/bin/node") == nil)
    }

    // MARK: Labels

    @Test func displayNames() {
        let node = "/opt/homebrew/bin/node"
        #expect(label(node, ["node", "/p/frontend/node_modules/vite/bin/vite.js", "--host", "127.0.0.1"]) == "vite")
        #expect(label(node, ["node", "/p/node_modules/.bin/next", "dev", "-p", "3000"]) == "next dev")
        #expect(label(node, ["node", "/p/node_modules/@nestjs/cli/bin/nest.js", "start", "--watch"]) == "nest start")
        #expect(label(node, ["node", "server.js"]) == "node server.js")
        #expect(label(node, ["node", "--watch", "--env-file", ".env", "/p/src/index.mjs"]) == "node index.mjs")
        #expect(label(node, ["next-server (v15.0.3)", "", ""]) == "next-server")
        #expect(label(pythonFramework, ["Python", "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "8000"]) == "uvicorn app.main:app")
        #expect(label(pythonFramework, ["Python", "app.py"]) == "python app.py")
        #expect(label("/usr/bin/python3", ["python3", "-m", "http.server", "8000"]) == "python -m http.server")
        #expect(label(pythonFramework, ["python", "/p/.venv/bin/gunicorn", "-w", "4", "-b", "0.0.0.0:8000", "app:create_app()"]) == "gunicorn app:create_app()")
        #expect(label(pythonFramework, ["python", "manage.py", "runserver", "0.0.0.0:8000"]) == "manage.py runserver")
        #expect(label(pythonFramework, ["python", "-m", "flask", "run", "--debug"]) == "flask run")
        #expect(label(pythonFramework, ["python", "-c", "from multiprocessing.spawn import spawn_main"]) == "python worker")
        #expect(label("/opt/homebrew/bin/nginx", ["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf", "", ""]) == "nginx")
        #expect(label("/opt/homebrew/bin/nginx", ["nginx: worker process", ""]) == "nginx worker")
        #expect(label("/opt/homebrew/bin/cloudflared", ["cloudflared", "tunnel", "run", "--token-file", "/x"]) == "cloudflared tunnel")
        #expect(label("/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"]) == "postgres")
        #expect(label("/opt/homebrew/opt/redis/bin/redis-server", ["redis-server 127.0.0.1:6379", ""]) == "redis-server")
        #expect(label("/Users/test/.bun/bin/bun", ["bun", "run", "dev"]) == "bun run dev")
        #expect(label("/usr/bin/java", ["java", "-Xmx1g", "-jar", "/p/target/app-0.1.jar"]) == "java -jar app-0.1.jar")
        #expect(label("/opt/homebrew/bin/php", ["php", "-S", "localhost:8080", "-t", "public"]) == "php -S localhost:8080")
        #expect(label(nil, [], comm: "launchd") == "launchd")
        let unreadable = PortClassifierFixture(pid: 5, comm: "secretd", executable: nil, readable: false)
        #expect(PortClassifier.displayName(basic: unreadable.basic, details: nil) == "secretd")
    }

    @Test func frameworks() {
        let node = "/opt/homebrew/bin/node"
        #expect(frameworks(node, ["node", "/p/node_modules/vite/bin/vite.js"]) == ["Vite"])
        #expect(frameworks(node, ["next-server (v14.2.1)"]) == ["Next.js"])
        #expect(frameworks(node, ["node", "/p/node_modules/@angular/cli/bin/ng.js", "serve"]) == ["Angular"])
        #expect(frameworks(node, ["node", "server.js"]) == ["Node.js"])
        #expect(frameworks(node, ["node", "/p/next.js"]) == ["Node.js"], "user scripts are not mistaken for tools")
        #expect(frameworks(pythonFramework, ["Python", "-m", "uvicorn", "main:app"]) == ["uvicorn"])
        #expect(frameworks(pythonFramework, ["python", "manage.py", "runserver"]) == ["Django"])
        #expect(frameworks(pythonFramework, ["python", "/p/.venv/bin/streamlit", "run", "app.py"]) == ["Streamlit"])
        #expect(frameworks(pythonFramework, ["python", "app.py"]) == ["Python"])
        #expect(frameworks("/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres"]) == ["PostgreSQL"])
        #expect(frameworks("/opt/homebrew/bin/nginx", ["nginx: worker process"]) == ["nginx"])
        #expect(frameworks("/Users/test/code/svc/target/debug/svc", ["./target/debug/svc"]) == ["Rust"])
        #expect(frameworks("/Users/test/.bun/bin/bun", ["bun", "run", "dev"]) == ["Bun"])
        #expect(frameworks("/usr/bin/java", ["java", "-jar", "spring-boot-app.jar"]) == ["Spring"])
        #expect(frameworks("/Applications/Player.app/Contents/MacOS/Player", ["Player"]) == [])
    }

    // MARK: Origin

    @Test func originFromNearestRecognizedAncestor() {
        let claude = PortClassifierFixture(pid: 50, comm: "claude",
                                       executable: "/Users/test/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude")
        let shell = PortClassifierFixture(pid: 51, ppid: 50, executable: "/bin/zsh", arguments: ["/bin/zsh", "-c", "python app.py"])
        let server = PortClassifierFixture(pid: 52, ppid: 51, executable: pythonFramework, arguments: ["Python", "app.py"],
                                       environment: ["TERM_PROGRAM": "Apple_Terminal"])
        let lookup = [claude, shell].reduce(into: [Int32: PortProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        let origin = PortClassifier.origin(details: server.details, ancestors: [shell.basic, claude.basic],
                                       ancestorDetails: { lookup[$0] }, launchdLabel: nil)
        #expect(origin == PortLaunchOrigin(kind: .claudeCode, name: "Claude Code"))
    }

    @Test func originFromTerminalAndIDEAncestors() {
        let terminal = PortClassifierFixture(pid: 60, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let login = PortClassifierFixture(pid: 61, ppid: 60, executable: "/usr/bin/login", arguments: ["login", "-pf", "test"])
        let zsh = PortClassifierFixture(pid: 62, ppid: 61, executable: "/bin/zsh", arguments: ["-zsh"])
        let lookup = [terminal, login, zsh].reduce(into: [Int32: PortProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        #expect(PortClassifier.origin(details: nil, ancestors: [zsh.basic, login.basic, terminal.basic],
                                         ancestorDetails: { lookup[$0] }, launchdLabel: nil) == PortLaunchOrigin(kind: .terminal, name: "Terminal"))

        let helper = PortClassifierFixture(pid: 70, comm: "Code Helper",
                                       executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
        #expect(PortClassifier.origin(details: nil, ancestors: [helper.basic],
                                         ancestorDetails: { $0 == 70 ? helper.details : nil }, launchdLabel: nil) == PortLaunchOrigin(kind: .ide, name: "VS Code"))
    }

    /// Apple's /usr/bin/make execs Xcode's gnumake: a dev server started by `make` in Terminal is not from Xcode.
    @Test func xcodeToolchainAncestorIsNotTheXcodeIDE() {
        let terminal = PortClassifierFixture(pid: 90, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let zsh = PortClassifierFixture(pid: 91, ppid: 90, executable: "/bin/zsh", arguments: ["-zsh"])
        let make = PortClassifierFixture(pid: 92, ppid: 91, comm: "gnumake",
                                     executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/gnumake",
                                     arguments: ["make", "dev"])
        let lookup = [terminal, zsh, make].reduce(into: [Int32: PortProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        #expect(PortClassifier.origin(details: nil, ancestors: [make.basic, zsh.basic, terminal.basic],
                                         ancestorDetails: { lookup[$0] }, launchdLabel: nil) == PortLaunchOrigin(kind: .terminal, name: "Terminal"))
        #expect(PortClassifier.origin(details: nil, ancestors: [make.basic], ancestorDetails: { lookup[$0] },
                                       launchdLabel: nil) == nil)

        let xcode = PortClassifierFixture(pid: 93, executable: "/Applications/Xcode.app/Contents/MacOS/Xcode")
        #expect(PortClassifier.origin(details: nil, ancestors: [xcode.basic],
                                         ancestorDetails: { $0 == 93 ? xcode.details : nil }, launchdLabel: nil) == PortLaunchOrigin(kind: .ide, name: "Xcode"), "the IDE itself is still Xcode")
    }

    @Test func originFromEnvironmentWhenReparented() {
        let launchd = PortProcessBasic(pid: 1, ppid: 0, pgid: 1, uid: 0, comm: "launchd", startTime: 0)
        func origin(_ environment: [String: String]) -> PortLaunchOrigin? {
            let fixture = PortClassifierFixture(pid: 80, executable: "/opt/homebrew/bin/node", environment: environment)
            return PortClassifier.origin(details: fixture.details, ancestors: [launchd], ancestorDetails: { _ in nil },
                                     launchdLabel: nil)
        }
        #expect(origin(["CODEX_SHELL": "1", "TERM": "dumb"]) == PortLaunchOrigin(kind: .codex, name: "Codex"))
        #expect(origin(["CLAUDECODE": "1", "TERM_PROGRAM": "vscode"]) == PortLaunchOrigin(kind: .claudeCode, name: "Claude Code"))
        #expect(origin(["TERM_PROGRAM": "iTerm.app"]) == PortLaunchOrigin(kind: .terminal, name: "iTerm2"))
        #expect(origin(["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"]) == PortLaunchOrigin(kind: .ide, name: "Cursor"))
        #expect(origin(["CODEX_HOME": "/Users/test/.codex"]) == nil, "CODEX_HOME alone is user configuration")
        #expect(origin([:]) == nil)
    }

    @Test func launchdLabelWinsUnlessItIsAnAppInstance() {
        let fixture = PortClassifierFixture(pid: 81, executable: "/opt/homebrew/bin/node", environment: ["CLAUDECODE": "1"])
        #expect(PortClassifier.origin(details: fixture.details, ancestors: [], ancestorDetails: { _ in nil },
                                         launchdLabel: "com.claude.monitor") == PortLaunchOrigin(kind: .launchd, name: "launchd"))
        #expect(PortClassifier.origin(details: fixture.details, ancestors: [], ancestorDetails: { _ in nil },
                                         launchdLabel: "application.com.apple.Terminal.123")?.kind == .claudeCode)
    }

    // MARK: Watchers

    @Test func watcherDetection() {
        let node = "/opt/homebrew/bin/node"
        let nodemon = PortClassifierFixture(pid: 20, executable: node, arguments: ["node", "/p/node_modules/nodemon/bin/nodemon.js", "server.js"])
        let child = PortClassifierFixture(pid: 21, ppid: 20, executable: node, arguments: ["node", "server.js"])
        #expect(PortClassifier.watcherName(for: child.basic, details: child.details, ancestors: [nodemon.basic],
                                              ancestorDetails: { $0 == 20 ? nodemon.details : nil }) == "nodemon")

        let reloader = PortClassifierFixture(pid: 30, executable: pythonFramework,
                                         arguments: ["Python", "-m", "uvicorn", "main:app", "--reload"])
        let worker = PortClassifierFixture(pid: 31, ppid: 30, executable: pythonFramework,
                                       arguments: ["Python", "-c", "from multiprocessing.spawn import spawn_main"])
        #expect(PortClassifier.watcherName(for: worker.basic, details: worker.details, ancestors: [reloader.basic],
                                              ancestorDetails: { $0 == 30 ? reloader.details : nil }) == "uvicorn --reload")
        #expect(PortClassifier.watcherName(for: reloader.basic, details: reloader.details, ancestors: [],
                                              ancestorDetails: { _ in nil }) == "uvicorn --reload")

        let watchMode = PortClassifierFixture(pid: 40, executable: node, arguments: ["node", "--watch", "server.js"])
        #expect(PortClassifier.watcherName(for: watchMode.basic, details: watchMode.details, ancestors: [],
                                              ancestorDetails: { _ in nil }) == "node --watch")

        let tsx = PortClassifierFixture(pid: 41, executable: node, arguments: ["node", "/p/node_modules/tsx/dist/cli.mjs", "watch", "src/index.ts"])
        let tsxChild = PortClassifierFixture(pid: 42, ppid: 41, executable: node, arguments: ["node", "--import", "tsx", "src/index.ts"])
        #expect(PortClassifier.watcherName(for: tsxChild.basic, details: tsxChild.details, ancestors: [tsx.basic],
                                              ancestorDetails: { $0 == 41 ? tsx.details : nil }) == "tsx watch")

        let django = PortClassifierFixture(pid: 43, executable: pythonFramework, arguments: ["python", "manage.py", "runserver"],
                                       environment: ["RUN_MAIN": "true"])
        #expect(PortClassifier.watcherName(for: django.basic, details: django.details, ancestors: [],
                                              ancestorDetails: { _ in nil }) == "Django autoreload")

        // An interactive shell between the server and nodemon means nodemon did not start it.
        let shell = PortClassifierFixture(pid: 44, ppid: 20, executable: "/bin/zsh", arguments: ["-zsh"])
        let server = PortClassifierFixture(pid: 45, ppid: 44, executable: node, arguments: ["node", "server.js"])
        let lookup = [nodemon, shell].reduce(into: [Int32: PortProcessDetails]()) { $0[$1.basic.pid] = $1.details }
        #expect(PortClassifier.watcherName(for: server.basic, details: server.details, ancestors: [shell.basic, nodemon.basic],
                                            ancestorDetails: { lookup[$0] }) == nil)
    }

    // MARK: Runtimes, boundaries, runners

    @Test func devRuntimes() {
        for name in ["node", "nodejs", "python3", "python3.12", "Python", "bun", "deno", "ruby", "php", "java", "go",
                     "dotnet", "beam.smp", "perl"] {
            #expect(PortClassifier.isDevRuntime(name: name), "\(name)")
        }
        for name in ["nginx", "php-fpm", "postgres", "Spotify", "Code Helper", "zsh", ""] {
            #expect(!(PortClassifier.isDevRuntime(name: name)), "\(name)")
        }
    }

    @Test func boundaryProcesses() {
        func isBoundary(_ fixture: PortClassifierFixture) -> Bool {
            PortClassifier.isBoundaryProcess(basic: fixture.basic, details: fixture.details)
        }
        #expect(isBoundary(PortClassifierFixture(pid: 1, ppid: 0, uid: 0, executable: "/sbin/launchd")))
        #expect(isBoundary(PortClassifierFixture(pid: 10, executable: "/bin/zsh", arguments: ["-zsh"])))
        #expect(isBoundary(PortClassifierFixture(pid: 11, executable: "/bin/zsh", arguments: ["/bin/zsh", "-l"])))
        #expect(!(isBoundary(PortClassifierFixture(pid: 12, executable: "/bin/sh", arguments: ["sh", "-c", "vite"]))))
        #expect(!(isBoundary(PortClassifierFixture(pid: 13, executable: "/bin/bash", arguments: ["bash", "start.sh"]))))
        #expect(isBoundary(PortClassifierFixture(pid: 14, comm: "zsh", executable: nil, readable: false)))
        #expect(isBoundary(PortClassifierFixture(pid: 15, comm: "claude", executable: "/Users/test/.local/bin/claude")))
        #expect(isBoundary(PortClassifierFixture(pid: 16, executable: "/opt/homebrew/bin/node",
                                                   arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])))
        #expect(isBoundary(PortClassifierFixture(pid: 17, executable: "/opt/homebrew/bin/tmux", arguments: ["tmux"])))
        #expect(isBoundary(PortClassifierFixture(pid: 18, executable: "/opt/homebrew/bin/node",
                                                   arguments: ["PM2 v5.4.2: God Daemon (/Users/test/.pm2)"])))
        #expect(isBoundary(PortClassifierFixture(pid: 19, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")))
        #expect(isBoundary(PortClassifierFixture(pid: 20, executable: "/Applications/Cursor.app/Contents/MacOS/Cursor")))
        #expect(isBoundary(PortClassifierFixture(pid: 21, executable: "/usr/bin/ssh", arguments: ["ssh", "prod"])))
        #expect(!(isBoundary(PortClassifierFixture(pid: 22, executable: "/usr/bin/ssh", arguments: ["ssh", "-N", "-L", "5432:db:5432", "bastion"]))))
        #expect(!(isBoundary(PortClassifierFixture(pid: 23, executable: "/Applications/Player.app/Contents/MacOS/Player"))))
        #expect(!(isBoundary(PortClassifierFixture(pid: 24, executable: "/opt/homebrew/bin/node",
                                                    arguments: ["node", "/p/node_modules/vite/bin/vite.js"]))))
        #expect(isBoundary(PortClassifierFixture(pid: 25, executable: "/usr/bin/vim", arguments: ["vim", "x"])))
    }

    @Test func runnerProcesses() {
        func isRunner(_ executable: String, _ arguments: [String]) -> Bool {
            let fixture = PortClassifierFixture(pid: 30, executable: executable, arguments: arguments)
            return PortClassifier.isRunnerProcess(basic: fixture.basic, details: fixture.details)
        }
        let node = "/opt/homebrew/bin/node"
        #expect(isRunner(node, ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"]))
        #expect(isRunner(node, ["node", "/p/node_modules/.bin/concurrently", "a", "b"]))
        #expect(isRunner(node, ["node", "/p/node_modules/tsx/dist/cli.mjs", "watch", "src/index.ts"]))
        #expect(isRunner("/opt/homebrew/bin/pnpm", ["pnpm", "dev"]))
        #expect(isRunner("/Users/test/.bun/bin/bun", ["bun", "run", "dev"]))
        #expect(!(isRunner("/Users/test/.bun/bin/bun", ["bun", "--hot", "server.ts"])))
        #expect(isRunner("/opt/homebrew/bin/deno", ["deno", "task", "dev"]))
        #expect(isRunner("/Users/test/.cargo/bin/cargo", ["cargo", "run", "--release"]))
        #expect(isRunner("/opt/homebrew/bin/go", ["go", "run", "."]))
        #expect(isRunner("/Users/test/.local/bin/uv", ["uv", "run", "main.py"]))
        #expect(isRunner(pythonFramework, ["python", "/Users/test/.local/bin/poetry", "run", "uvicorn", "main:app"]))
        #expect(isRunner("/usr/bin/make", ["make", "dev"]))
        #expect(isRunner("/usr/bin/ruby", ["ruby", "/usr/local/bin/bundle", "exec", "rails", "s"]))
        #expect(!(isRunner(node, ["node", "/p/node_modules/vite/bin/vite.js"])))
        #expect(!(isRunner(node, ["node", "server.js"])))
        #expect(!(isRunner(pythonFramework, ["python", "-m", "uvicorn", "main:app"])))
    }

    @Test func scriptShells() {
        let script = PortClassifierFixture(pid: 31, executable: "/bin/sh", arguments: ["sh", "-c", "vite --port 5173"])
        let interactive = PortClassifierFixture(pid: 32, executable: "/bin/zsh", arguments: ["-zsh"])
        #expect(PortClassifier.isScriptShell(basic: script.basic, details: script.details))
        #expect(!(PortClassifier.isScriptShell(basic: interactive.basic, details: interactive.details)))
    }

    // MARK: Coding agents (finding #2, defence in depth)

    private let node = "/opt/homebrew/Cellar/node/25.4.0/bin/node"
    private let uvPython = "/Users/test/.local/share/uv/python/cpython-3.12.8-macos-aarch64-none/bin/python3.12"

    @Test func codingAgentsAndAgentHostsAreBoundaries() {
        let agents: [(comm: String?, executable: String, arguments: [String], origin: String)] = [
            ("kimi", "/Users/test/.kimi-code/bin/kimi", ["kimi"], "Kimi"),
            (nil, node, ["node", "/opt/homebrew/bin/qwen"], "Qwen Code"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/@qwen-code/qwen-code/cli.js", "--yolo"], "Qwen Code"),
            (nil, node, ["/opt/homebrew/opt/node/bin/node", "--max-old-space-size=8192",
                         "/opt/homebrew/Cellar/gemini-cli/0.25.2/bin/gemini"], "Gemini CLI"),
            (nil, node, ["node", "/Users/test/.npm-global/lib/node_modules/@google/gemini-cli/dist/index.js"], "Gemini CLI"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], "Claude Code"),
            (nil, node, ["node", "/Users/test/.claude/local/node_modules/.bin/claude"], "Claude Code"),
            ("2.1.0", "/Users/test/.local/share/claude/versions/2.1.0", ["claude"], "Claude Code"),
            (nil, node, ["claude", "", ""], "Claude Code"),   // node-installed Claude Code renames its process
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"], "Codex"),
            ("codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             ["codex", "app-server", "--listen", "stdio://"], "Codex"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"], "opencode"),
            ("crush", "/opt/homebrew/bin/crush", ["crush"], "Crush"),
            ("goose", "/Users/test/.local/bin/goose", ["goose", "session"], "Goose"),
            (nil, node, ["node", "/opt/homebrew/bin/amp"], "Amp"),
            (nil, node, ["/Users/test/.local/share/cursor-agent/versions/2025.10/node",
                         "/Users/test/.local/share/cursor-agent/versions/2025.10/index.js"], "Cursor Agent"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/@github/copilot/index.js"], "Copilot CLI"),
            ("droid", "/Users/test/.local/bin/droid", ["droid"], "Droid"),
            (nil, node, ["node", "/opt/homebrew/bin/cline"], "Cline"),
            (nil, node, ["node", "/opt/homebrew/bin/cn"], "Continue"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/@kilocode/cli/dist/index.js"], "Kilo Code"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/@augmentcode/auggie/augment.mjs"], "Auggie"),
            (nil, node, ["node", "/opt/homebrew/lib/node_modules/openclaw/openclaw.mjs", "gateway"], "OpenClaw"),
            ("plandex", "/usr/local/bin/plandex", ["plandex", "tell"], "Plandex"),
            (nil, uvPython, ["/Users/test/.local/share/uv/tools/aider-chat/bin/python", "/Users/test/.local/bin/aider"], "Aider"),
            (nil, uvPython, ["python3", "-m", "aider", "--model", "x"], "Aider"),
            (nil, uvPython, ["python3", "/Users/test/.local/bin/interpreter"], "Open Interpreter"),
            (nil, uvPython, ["python3", "/Users/test/.local/bin/openhands"], "OpenHands"),
        ]
        for agent in agents {
            let fixture = PortClassifierFixture(pid: 40, comm: agent.comm, executable: agent.executable,
                                            arguments: agent.arguments, cwd: "/Users/test/code/app")
            #expect(PortClassifier.isBoundaryProcess(basic: fixture.basic, details: fixture.details), "\(agent.arguments)")
            // The same detection names the launch origin of anything the agent starts.
            let server = PortClassifierFixture(pid: 41, ppid: 40, executable: node, arguments: ["node", "server.js"])
            let origin = PortClassifier.origin(details: server.details, ancestors: [fixture.basic],
                                           ancestorDetails: { $0 == 40 ? fixture.details : nil }, launchdLabel: nil)
            #expect(origin?.name == agent.origin, "\(agent.arguments)")
        }
    }

    @Test func plainDevServersAreNeverMistakenForAgents() {
        let servers: [(executable: String, arguments: [String])] = [
            (node, ["node", "/Users/test/code/claude-code-dashboard/server.js"]),
            (node, ["node", "/Users/test/code/opencode-site/index.js"]),
            (node, ["node", "/Users/test/code/goose/server.js"]),
            (node, ["node", "/Users/test/code/gemini-app/node_modules/.bin/vite"]),
            (node, ["node", "/Users/test/code/qwen-ui/node_modules/next/dist/bin/next", "dev"]),
            (node, ["node", "/Users/test/code/app/bin/www"]),
            (node, ["node", "/Users/test/code/app/amp.js"]),
            (node, ["node", "--watch", "server.js"]),
            (node, ["next-server (v15.0.3)", "", ""]),
            (uvPython, ["python3", "/Users/test/code/aider-ui/app.py"]),
            (uvPython, ["python3", "-m", "uvicorn", "kimi.main:app"]),
            ("/Users/test/code/amp/target/debug/amp-server", ["./target/debug/amp-server"]),
            ("/opt/homebrew/bin/cloudflared", ["cloudflared", "tunnel", "run"]),
        ]
        for server in servers {
            let fixture = PortClassifierFixture(pid: 50, executable: server.executable, arguments: server.arguments,
                                            cwd: "/Users/test/code/app")
            #expect(!(PortClassifier.isBoundaryProcess(basic: fixture.basic, details: fixture.details)), "\(server.arguments)")
        }
    }

    // MARK: Watchers and package managers as plan anchors (findings #2, #5)

    @Test func watcherProcessPredicate() {
        func isWatcher(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) -> Bool {
            let fixture = PortClassifierFixture(pid: 60, executable: executable, arguments: arguments, environment: environment)
            return PortClassifier.isWatcherProcess(basic: fixture.basic, details: fixture.details)
        }
        #expect(isWatcher(node, ["node", "--watch", "server.js"]))
        #expect(isWatcher(node, ["node", "/p/node_modules/nodemon/bin/nodemon.js", "server.js"]))
        #expect(isWatcher(pythonFramework, ["Python", "-m", "uvicorn", "main:app", "--reload"]))
        #expect(isWatcher(pythonFramework, ["python", "/opt/homebrew/bin/uvicorn", "main:app", "--reload"]))
        #expect(isWatcher(pythonFramework, ["python", "-m", "flask", "run", "--debug"]))
        #expect(isWatcher(pythonFramework, ["python", "manage.py", "runserver"]))
        #expect(isWatcher("/Users/test/.bun/bin/bun", ["bun", "--hot", "server.ts"]))
        #expect(isWatcher("/Users/test/.cargo/bin/cargo", ["cargo", "watch", "-x", "run"]))
        #expect(!(isWatcher(node, ["node", "server.js"])))
        #expect(!(isWatcher(pythonFramework, ["python", "-m", "uvicorn", "main:app"])))
        #expect(!(isWatcher(pythonFramework, ["python", "manage.py", "runserver", "--noreload"])))
        // supervisord runs many programs: stopping one of them must never take the supervisor down.
        #expect(!(isWatcher(pythonFramework, ["python", "/opt/homebrew/bin/supervisord", "-c", "/etc/supervisord.conf"])))
        #expect(!(isWatcher("/opt/homebrew/bin/supervisord", ["supervisord", "-n"])))
        let supervisor = PortClassifierFixture(pid: 62, executable: "/opt/homebrew/bin/supervisord", arguments: ["supervisord", "-n"])
        #expect(PortClassifier.watcherName(for: supervisor.basic, details: supervisor.details, ancestors: [],
                                              ancestorDetails: { _ in nil }) == "supervisord", "still shown as the program's supervisor, just never a plan root")
        // The reloaded Flask child carries WERKZEUG_RUN_MAIN; it is the server, not the watcher.
        #expect(!(isWatcher(pythonFramework, ["python", "app.py"], environment: ["WERKZEUG_RUN_MAIN": "true"])))
        let unreadable = PortClassifierFixture(pid: 61, comm: "node", executable: nil, readable: false)
        #expect(!(PortClassifier.isWatcherProcess(basic: unreadable.basic, details: nil)))
    }

    @Test func packageManagersAreRunnersInEveryForm() {
        func isRunner(_ arguments: [String], executable: String? = nil) -> Bool {
            let fixture = PortClassifierFixture(pid: 70, comm: "node", executable: executable ?? node, arguments: arguments)
            return PortClassifier.isRunnerProcess(basic: fixture.basic, details: fixture.details)
        }
        #expect(isRunner(["npm run dev", "", "", ""]), "npm's process title")
        #expect(isRunner(["npm exec next start", "", ""]))
        #expect(isRunner(["node", "/opt/homebrew/bin/npm", "run", "dev"]))
        #expect(isRunner(["node", "/opt/homebrew/bin/pnpm", "dev"]))
        #expect(isRunner(["node", "/opt/homebrew/bin/yarn", "dev"]))
        #expect(isRunner(["node", "/Users/test/code/app/.yarn/releases/yarn-4.5.0.cjs", "dev"]))
        #expect(!(isRunner(["next-server (v15.0.3)", "", ""])))
        #expect(!(isRunner(["nginx: master process /opt/homebrew/bin/nginx", ""], executable: "/opt/homebrew/bin/nginx")))
        #expect(!(isRunner(["node", "/Users/test/code/app/npm.js"])), "a project's own npm.js is not npm")
        #expect(PortClassifier.isPackageManagerScript("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js"))
        #expect(!(PortClassifier.isPackageManagerScript("server.js")))
        // Corepack loads the real package manager inside its own entry script.
        #expect(isRunner(["node", "/opt/homebrew/lib/node_modules/corepack/dist/pnpm.js", "dev"]))
        #expect(isRunner(["node", "/Users/test/.volta/tools/image/corepack/0.31.0/dist/yarn.js", "dev"]))
        #expect(!(PortClassifier.isPackageManagerScript("/Users/test/code/app/scripts/pnpm.js")))
    }

    @Test func otherRunnersInTheirRealForms() {
        func isRunner(_ executable: String, _ arguments: [String]) -> Bool {
            let fixture = PortClassifierFixture(pid: 71, executable: executable, arguments: arguments)
            return PortClassifier.isRunnerProcess(basic: fixture.basic, details: fixture.details)
        }
        // Apple's /usr/bin/make execs Xcode's (or the Command Line Tools') gnumake, keeping argv[0].
        #expect(isRunner("/Applications/Xcode.app/Contents/Developer/usr/bin/gnumake",
                               ["/Applications/Xcode.app/Contents/Developer/usr/bin/make", "-s", "dev"]))
        #expect(isRunner("/Library/Developer/CommandLineTools/usr/bin/gnumake", ["make", "dev"]))
        // `bun dev` runs a package.json script; `bun server.ts` and `bun install` don't.
        let bun = "/Users/test/.bun/bin/bun"
        #expect(isRunner(bun, ["bun", "dev"]))
        #expect(isRunner(bun, ["bun", "run", "dev"]))
        #expect(isRunner(bun, ["bun", "--bun", "dev"]))
        #expect(!(isRunner(bun, ["bun", "server.ts"])))
        #expect(!(isRunner(bun, ["bun", "--hot", "./src/index.ts"])))
        #expect(!(isRunner(bun, ["bun", "install"])))
        #expect(!(isRunner(bun, ["bun", "test"])))
        #expect(!(isRunner("/opt/homebrew/bin/node", ["node", "server.js"])))
    }
}
