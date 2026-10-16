import Darwin
import Foundation

/// Decides *what* gets signalled when the user stops a listener.
///
/// The planner is pure: it only reads the process table and the `details` provider it is given (no syscalls,
/// no subprocesses), so it is cheap enough to run for every listener on every scan and easy to unit test.
///
/// Safety model (defence in depth): besides `PortClassifier.isBoundaryProcess`, the planner itself refuses to
/// climb into or signal anything that looks like the user's interactive session — login/interactive shells,
/// terminal multiplexers, sshd, launchd, coding agents and editors, REPLs, the PM2 daemon and any process
/// that lives inside a `.app` bundle (except dev runtimes such as the Python framework or bundled node).
enum PortKillPlanner {

    /// Builds the set of processes to signal for `listener`. See SPEC "Control/PortKillPlanner.swift".
    ///
    /// - Parameter socketsByPID: optional listening sockets from the same scan (`PortRawScan.socketsByPID`). Only used
    ///   to annotate the summary with ports and to warn "Also stops: …" when the plan takes down other listeners.
    static func plan(for listener: PortListenerProcess, table: PortProcessTable,
                     details: (PortProcessBasic) -> PortProcessDetails?, currentUID: UInt32,
                     ownPID: Int32 = getpid(),
                     socketsByPID: [Int32: [PortListeningSocket]] = [:]) -> PortKillPlan {
        let basic = listener.basic
        guard basic.pid > 1, basic.pid != ownPID else { return protectedPlan(for: listener) }
        if case .docker = listener.manager {
            // The listener is Docker's port forwarder (com.docker.backend, vpnkit, OrbStack…): killing it never stops
            // the container but takes Docker itself down. Plan no signals; the container is stopped through Docker.
            return PortKillPlan(root: basic, targets: [], summary: [], requiresAdmin: false,
                            warnings: managerWarnings(for: listener.manager))
        }
        // pm2 cluster mode: the God Daemon itself holds the port. A Docker backend without a container match (docker
        // CLI missing, daemon unreachable). Either way, signalling it takes down every app it runs.
        if let warning = managerDaemonWarning(basic, details: listener.details) {
            return PortKillPlan(root: basic, targets: [], summary: [], requiresAdmin: false, warnings: [warning])
        }

        // The table must describe *this* process. If the pid exited or was recycled since the scan, never walk
        // the relatives of whatever owns the pid now; the killer will re-verify and skip the stale identity.
        guard let live = table[basic.pid], live.startTime == basic.startTime else {
            return singleProcessPlan(for: listener, currentUID: currentUID, ownPID: ownPID)
        }

        return withoutActuallyEscaping(details) { details in
            let walker = PortTreeWalker(table: table, details: details, currentUID: currentUID, ownPID: ownPID,
                                    projectRoot: listener.project?.rootPath)
            let root = walker.launchRoot(of: live)
            let ordered = walker.planTree(from: root, listener: live)
            return makePlan(for: listener, root: root, ordered: ordered, currentUID: currentUID,
                            socketsByPID: socketsByPID, details: details)
        }
    }

    /// Plan containing only the listener ("Stop Only This Process" in a process row's context menu).
    static func singleProcessPlan(for listener: PortListenerProcess) -> PortKillPlan {
        singleProcessPlan(for: listener, currentUID: getuid(), ownPID: getpid())
    }

    /// Testable variant of `singleProcessPlan(for:)`.
    static func singleProcessPlan(for listener: PortListenerProcess, currentUID: UInt32, ownPID: Int32) -> PortKillPlan {
        let basic = listener.basic
        guard basic.pid > 1, basic.pid != ownPID else { return protectedPlan(for: listener) }
        if let warning = managerDaemonWarning(basic, details: listener.details) {
            return PortKillPlan(root: basic, targets: [], summary: [], requiresAdmin: false, warnings: [warning])
        }
        let requiresAdmin = basic.uid != currentUID
        var warnings = managerWarnings(for: listener.manager)
        if listener.isExposedToNetwork { warnings.append(networkWarning(for: listener)) }
        if requiresAdmin { warnings.append(adminWarning) }
        let line = summaryLine(for: basic, label: label(for: basic, details: listener.details),
                               ports: listener.ports, currentUID: currentUID)
        return PortKillPlan(root: basic, targets: [basic], summary: [line], requiresAdmin: requiresAdmin,
                        warnings: warnings)
    }

    // MARK: - Boundary detection (shared with PortProcessKiller)

    /// True for processes that must never be signalled as part of a tree plan, nor climbed through when looking
    /// for the launch root: `PortClassifier.isBoundaryProcess` OR any of the planner's own conservative checks.
    static func isProtected(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        if basic.pid <= 1 { return true }
        if PortClassifier.isBoundaryProcess(basic: basic, details: details) { return true }
        return isLocallyProtected(basic, details: details)
    }

    /// The PM2 God Daemon or a Docker / OrbStack / Colima backend: one process that runs many apps. It is never
    /// signalled, not even when it is the listener itself (pm2 cluster mode, a backend without a container match).
    static func isManagerDaemon(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        PortPM2Service.isDaemon(basic, details: details) || PortDockerService.isDockerBackend(basic, details: details)
    }

    /// Why Stop does nothing for a manager daemon listener; nil for every other process.
    static func managerDaemonWarning(_ basic: PortProcessBasic, details: PortProcessDetails?) -> String? {
        if PortPM2Service.isDaemon(basic, details: details) {
            return "This port belongs to the PM2 daemon, which runs all your pm2 apps — stop the app with pm2 instead"
        }
        if PortDockerService.isDockerBackend(basic, details: details) {
            return "This port belongs to Docker itself — stop the container in Docker instead"
        }
        return nil
    }

    /// The planner's own boundary rules, independent of `PortClassifier` (defence in depth).
    static func isLocallyProtected(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        let names = candidateNames(basic, details: details)
        if !names.isDisjoint(with: sessionProcessNames) { return true }
        if !names.isDisjoint(with: agentAndEditorNames) { return true }
        if let arguments = details?.arguments, let argv0 = arguments.first {
            // process.title of the PM2 daemon: "PM2 v5.3.0: God Daemon (/Users/me/.pm2)". Killing it stops every pm2 app.
            if argv0.hasPrefix("PM2 v") || argv0.contains("God Daemon") { return true }
            // Agent CLIs installed as node/bun/python scripts: `node /opt/homebrew/bin/qwen`,
            // `node --max-old-space-size=8192 /opt/homebrew/bin/gemini`, `python ~/.local/bin/aider`.
            if isInterpreter(normalizedName(argv0)) || isInterpreter(normalizedName(details?.executablePath ?? "")),
               let script = scriptOperand(arguments) {
                let base = normalizedName(script)
                let stem = base.split(separator: ".", maxSplits: 1).first.map(String.init) ?? base
                let directory = normalizedName((script as NSString).deletingLastPathComponent)
                let isShim = directory == "bin" || directory == ".bin" || !base.contains(".")
                if isShim, agentAndEditorNames.contains(stem) { return true }
            }
            if arguments.contains(where: { $0.hasSuffix("ipykernel_launcher") || $0.hasSuffix("ipykernel_launcher.py") }) {
                return true
            }
        }
        switch shellMode(basic, details: details) {
        case .interactive: return true
        case .command, .script, .notShell: break
        }
        if isInteractiveInterpreter(basic, details: details) { return true }
        if isInsideAppBundle(basic, details: details) { return true }
        return false
    }

    // MARK: - Shell & interpreter heuristics

    enum ShellMode: Equatable {
        case notShell
        /// Login or interactive shell (`-zsh`, `zsh -l`, `bash -i`, `zsh` with no script) — a user session.
        case interactive
        /// `sh -c "…"`, `bash -lc "…"`: runs one command line and exits.
        case command
        /// `bash ./dev.sh`: runs a script file.
        case script(String)
    }

    static func shellMode(_ basic: PortProcessBasic, details: PortProcessDetails?) -> ShellMode {
        guard !candidateNames(basic, details: details).isDisjoint(with: shellNames) else { return .notShell }
        // Unknown arguments: assume the worst.
        guard let arguments = details?.arguments, let argv0 = arguments.first else { return .interactive }
        // login(1) and terminal emulators prefix argv[0] with "-" for login shells.
        if argv0.hasPrefix("-") { return .interactive }

        var index = 1
        var commandMode = false
        var interactiveFlag = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" || argument == "-" { index += 1; break }
            if argument == "--interactive" { interactiveFlag = true }
            if argument.hasPrefix("--") { index += 1; continue }               // --login, --norc, --noprofile
            guard argument.count > 1, argument.hasPrefix("-") || argument.hasPrefix("+") else { break }
            if argument.hasPrefix("-") {
                let flags = argument.dropFirst()
                if flags.contains("c") { commandMode = true }
                if flags.contains("i") { interactiveFlag = true }
            }
            // Options that consume the next argument (bash/zsh `-o name`, bash `-O shopt`).
            if ["-o", "+o", "-O", "+O"].contains(argument) { index += 2; continue }
            index += 1
        }
        // `zsh -i -l -c 'env'` (IDE environment probes) runs one command and exits.
        if commandMode { return .command }
        if interactiveFlag { return .interactive }
        if index < arguments.count { return .script(arguments[index]) }
        return .interactive
    }

    static func isScriptShell(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        switch shellMode(basic, details: details) {
        case .command, .script: return true
        case .interactive, .notShell: return false
        }
    }

    /// A bare `python3` / `node` / `irb` REPL (no script, module or inline code) is an interactive session.
    static func isInteractiveInterpreter(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        guard let arguments = details?.arguments, let argv0 = arguments.first else { return false }
        let name = normalizedName(argv0)
        if replOnlyNames.contains(name) { return true }
        guard name == "node" || name == "nodejs" || name.hasPrefix("python") || name == "ruby" else { return false }
        let options = arguments.dropFirst()
        if options.contains("-i") || options.contains("--interactive") { return true }
        // `python -m IPython`, `python -m code`, `python -m asyncio`, `python -m pdb app.py`: a REPL or debugger session.
        if name.hasPrefix("python"), let flag = options.firstIndex(of: "-m"), flag + 1 < arguments.count,
           replModules.contains(arguments[flag + 1].lowercased()) {
            return true
        }
        let codeFlags: Set<String> = ["-c", "-m", "-e", "--eval", "-p", "--print", "-r", "--require", "--import",
                                      "--test", "--run"]
        if options.contains(where: { codeFlags.contains($0) || $0.hasPrefix("--eval=") }) { return false }
        // Any operand (script path) means it runs a program.
        return !options.contains { !$0.hasPrefix("-") }
    }

    /// Executables inside `*.app/Contents/` (IDE helpers, terminal emulators, Electron apps…), except dev runtimes
    /// (e.g. Python.framework's `Python.app`, an editor's bundled `node`), app bundles inside `node_modules`
    /// (Electron apps under development) and Xcode's command-line toolchain (`Xcode.app/Contents/Developer/usr/bin/
    /// make`, `git`, `swift`…, which `/usr/bin` shims exec into).
    static func isInsideAppBundle(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        let path = details?.executablePath ?? details?.arguments.first ?? ""
        guard path.hasPrefix("/"),
              let innermost = path.range(of: ".app/Contents/", options: [.caseInsensitive, .backwards]) else { return false }
        if path.contains("/node_modules/") { return false }
        // Judge by the innermost bundle: `Xcode.app/Contents/Developer/Applications/Simulator.app/…` is still an app.
        if path[innermost.upperBound...].hasPrefix("Developer/") { return false }
        return !isDevRuntime(normalizedName(path))
    }

    static func isDevRuntime(_ name: String) -> Bool {
        if devRuntimeNames.contains(name) { return true }
        return devRuntimePrefixes.contains { name.hasPrefix($0) }
    }

    private static func isInterpreter(_ name: String) -> Bool {
        name == "node" || name == "nodejs" || name == "bun" || name == "deno" || name.hasPrefix("python")
    }

    /// node or bun running a package manager — the usual top of a dev server's tree. Matches the script form
    /// (`node /opt/homebrew/bin/npm run dev`, `node …/pnpm.cjs dev`) and npm's process title, which replaces argv
    /// once npm has started ("npm run dev", "npm exec vite").
    static func isPackageManagerProcess(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        guard let arguments = details?.arguments, let argv0 = arguments.first, !argv0.isEmpty else { return false }
        let runtimeNames = [normalizedName(basic.comm), normalizedName(details?.executablePath ?? "")]
        guard runtimeNames.contains(where: { $0 == "node" || $0 == "nodejs" || $0 == "bun" }) else { return false }
        if argv0.contains(" "), !argv0.hasPrefix("/") {
            let first = argv0.split(separator: " ").first.map(String.init) ?? ""
            return PortClassifier.packageManagerNames.contains(first)
        }
        guard let script = scriptOperand(arguments) else { return false }
        return PortClassifier.isPackageManagerScript(script)
    }

    /// The program file an interpreter runs: the first operand after its options, skipping option values
    /// (`node -r dotenv/config server.js` → "server.js"). Subcommand-driven runtimes (bun, deno, java, dotnet, go)
    /// take the first operand that looks like a file instead (`bun run src/index.ts` → "src/index.ts").
    /// nil for inline code or modules (`-e`, `-c`, `-m`, `-p`), a bare REPL, or when argv0 is not a runtime.
    static func scriptOperand(_ arguments: [String]) -> String? {
        guard let argv0 = arguments.first, let runtime = PortClassifier.runtimeKey(for: normalizedName(argv0)) else {
            return nil
        }
        let rules = operandRules[runtime] ?? defaultOperandRules
        var index = 1
        var operandsSeen = 0
        while index < arguments.count, operandsSeen < 4 {
            let argument = arguments[index]
            index += 1
            if argument.isEmpty || argument == "--" { continue }
            if argument.hasPrefix("-") {
                if rules.inline.contains(argument) || argument.hasPrefix("--eval=") || argument.hasPrefix("--print=") {
                    return nil
                }
                if rules.valued.contains(argument) { index += 1 }
                continue
            }
            operandsSeen += 1
            guard subcommandDrivenRuntimes.contains(runtime) else { return argument }
            let base = (argument as NSString).lastPathComponent
            if argument.contains("/") || (base.contains(".") && !argument.contains(":") && !argument.contains("=")) {
                return argument
            }
        }
        return nil
    }

    /// Runtimes whose first operand is a subcommand (`bun run`, `deno task`, `go run`), not the script.
    private static let subcommandDrivenRuntimes: Set<String> = ["bun", "deno", "java", "dotnet", "go"]

    /// Per runtime: flags whose argument is inline code or a module (no script file follows), and options that
    /// consume the next argument.
    private static let operandRules: [String: (inline: Set<String>, valued: Set<String>)] = [
        "node": (["-e", "--eval", "-p", "--print"],
                 ["-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file", "--title",
                  "--inspect-port", "--conditions", "-C", "--watch-path", "--input-type"]),
        "bun": (["-e", "--eval", "-p", "--print"], ["-r", "--preload", "--cwd", "-c", "--config", "--env-file"]),
        "deno": ([], ["-c", "--config", "--import-map", "--env-file", "-L", "--log-level"]),
        "python": (["-c", "-m"], ["-W", "-X", "--check-hash-based-pycs"]),
        "ruby": (["-e"], ["-I", "-r", "-C", "-E", "-F"]),
        "perl": (["-e", "-E"], []),
        "php": (["-r"], ["-S", "-t", "-c", "-d", "-z"]),
        "java": ([], ["-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-opens", "--add-exports",
                      "--add-modules"]),
    ]
    private static let defaultOperandRules: (inline: Set<String>, valued: Set<String>) = (["-e", "-c"], [])

    // MARK: - Labels

    /// Short human label for a process, e.g. "npm run dev", "node vite", "python3 -m http.server 8000".
    static func label(for basic: PortProcessBasic, details: PortProcessDetails?) -> String {
        guard let arguments = details?.arguments, let argv0 = arguments.first, !argv0.isEmpty else { return basic.comm }
        var rest = Array(arguments.dropFirst())
        if let runtime = PortClassifier.runtimeKey(for: normalizedName(argv0)) {
            rest = labelArguments(rest, runtime: runtime)
        }
        var tokens: [String]
        if isInterpreter(normalizedName(argv0)), let script = rest.first, let tool = packageManagerName(script) {
            tokens = [tool]               // node /opt/homebrew/bin/npm run dev → npm run dev
            rest.removeFirst()
        } else {
            tokens = [displayToken(argv0, stripLoginDash: true)]
        }
        for argument in rest where !argument.isEmpty {
            if tokens.count >= 7 { tokens.append("…"); break }
            tokens.append(displayToken(argument, stripLoginDash: false))
        }
        let text = tokens.joined(separator: " ")
        return text.count > 64 ? String(text.prefix(63)) + "…" : text
    }

    /// An interpreter's arguments without its tuning options before the program: `node --max-old-space-size=4096
    /// --enable-source-maps server.js` → `server.js` (node's --watch child carries some 25 of them). Options that say
    /// how it runs (`--watch`, `--hot`, `--inspect`, `-jar`) stay, and so does everything from inline code or a module
    /// (`-m http.server 8000`, `-e …`) or the program onwards.
    private static func labelArguments(_ arguments: [String], runtime: String) -> [String] {
        let rules = operandRules[runtime] ?? defaultOperandRules
        var kept: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return kept + arguments[(index + 1)...] }
            if !argument.hasPrefix("-") || argument == "-" || rules.inline.contains(argument) {
                return kept + arguments[index...]
            }
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if labelRuntimeOptions.contains(name) { kept.append(argument) }
            if rules.valued.contains(argument) { index += 1 }
            index += 1
        }
        return kept
    }

    /// Interpreter options worth showing in a label.
    private static let labelRuntimeOptions: Set<String> = [
        "--watch", "--watch-path", "--hot", "--inspect", "--inspect-brk", "--inspect-wait", "-i", "--interactive",
        "--test", "-jar",
    ]

    private static func displayToken(_ argument: String, stripLoginDash: Bool) -> String {
        var token = argument
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("~/") {
            let last = (token as NSString).lastPathComponent
            token = last.isEmpty ? token : last
        }
        if stripLoginDash, token.hasPrefix("-"), token.count > 1 { token.removeFirst() }
        return token
    }

    private static func packageManagerName(_ scriptPath: String) -> String? {
        let base = ((scriptPath as NSString).lastPathComponent as NSString).deletingPathExtension
        switch base {
        case "npm", "npm-cli": return "npm"
        case "npx", "npx-cli": return "npx"
        case "pnpm", "pnpx", "yarn", "yarnpkg", "corepack": return base
        default: return nil
        }
    }

    // MARK: - Plan assembly

    private static func makePlan(for listener: PortListenerProcess, root: PortProcessBasic, ordered: [PortPlannedProcess],
                                 currentUID: UInt32, socketsByPID: [Int32: [PortListeningSocket]],
                                 details: (PortProcessBasic) -> PortProcessDetails?) -> PortKillPlan {
        let listenerPID = listener.basic.pid
        func ports(of process: PortProcessBasic) -> [UInt16] {
            if process.pid == listenerPID { return listener.ports }
            return Array(Set((socketsByPID[process.pid] ?? []).map(\.port))).sorted()
        }
        func labelFor(_ process: PortProcessBasic) -> String {
            process.pid == listenerPID && listener.details != nil
                ? label(for: process, details: listener.details)
                : label(for: process, details: details(process))
        }

        // Children first: deepest level first, BFS order reversed within a level.
        let targets = ordered.enumerated()
            .sorted { lhs, rhs in
                lhs.element.depth != rhs.element.depth ? lhs.element.depth > rhs.element.depth : lhs.offset > rhs.offset
            }
            .map(\.element.basic)
        let summary = ordered.map { summaryLine(for: $0.basic, label: labelFor($0.basic), ports: ports(of: $0.basic),
                                                currentUID: currentUID) }
        let requiresAdmin = targets.contains { $0.uid != currentUID }

        var warnings = managerWarnings(for: listener.manager)
        if listener.isExposedToNetwork { warnings.append(networkWarning(for: listener)) }
        let otherListeners = ordered.map(\.basic).filter { $0.pid != listenerPID && !ports(of: $0).isEmpty }
        if !otherListeners.isEmpty {
            let names = otherListeners.prefix(4).map { process in
                "\(labelFor(process)) (\(ports(of: process).map { ":\($0)" }.joined(separator: ", ")))"
            }
            let more = otherListeners.count > 4 ? " +\(otherListeners.count - 4) more" : ""
            warnings.append("Also stops: " + names.joined(separator: ", ") + more)
        }
        if requiresAdmin { warnings.append(adminWarning) }

        return PortKillPlan(root: root, targets: targets, summary: summary, requiresAdmin: requiresAdmin, warnings: warnings)
    }

    /// Plan for the listener when it is pid ≤ 1 or Mac Cleaner itself: nothing is ever signalled.
    private static func protectedPlan(for listener: PortListenerProcess) -> PortKillPlan {
        PortKillPlan(root: listener.basic, targets: [], summary: [], requiresAdmin: false,
                 warnings: ["This process is protected and can't be stopped by Mac Cleaner"])
    }

    private static func summaryLine(for basic: PortProcessBasic, label: String, ports: [UInt16], currentUID: UInt32) -> String {
        var line = "\(label) (pid \(basic.pid))"
        if !ports.isEmpty { line += " · " + ports.map { ":\($0)" }.joined(separator: ", ") }
        if basic.uid != currentUID { line += " · other user" }
        return line
    }

    static func managerWarnings(for manager: PortProcessManager) -> [String] {
        let action = "use Stop & Disable Auto-Start"
        switch manager {
        case .none, .watcher:
            return []
        case .launchd(let job):
            if job.keepAlive { return ["Will restart automatically (launchd: \(job.label)) — \(action)"] }
            if job.runAtLoad { return ["Starts again at next login (launchd: \(job.label)) — \(action)"] }
            return []
        case .pm2(_, let name):
            return ["Will restart automatically (pm2: \(name)) — \(action)"]
        case .docker(let container):
            return ["Published by Docker container \(container.name) — stop the container, not the Docker process (\(action))"]
        }
    }

    private static func networkWarning(for listener: PortListenerProcess) -> String {
        let exposed = listener.sockets.filter(\.isExposed).map(\.port)
        let ports = Array(Set(exposed)).sorted().map { ":\($0)" }.joined(separator: ", ")
        return "Exposed to the network: \(ports) accepts connections from other devices"
    }

    private static let adminWarning = "Owned by another user — macOS will ask for an administrator password"

    // MARK: - Names

    /// Lower-cased names a process is known by: p_comm, executable file name and argv[0] (login "-" stripped).
    private static func candidateNames(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Set<String> {
        var names: Set<String> = [normalizedName(basic.comm)]
        if let path = details?.executablePath, !path.isEmpty { names.insert(normalizedName(path)) }
        if let argv0 = details?.arguments.first, !argv0.isEmpty { names.insert(normalizedName(argv0)) }
        names.remove("")
        return names
    }

    /// "/bin/-zsh" → "zsh", "Python" → "python".
    static func normalizedName(_ pathOrName: String) -> String {
        var name = (pathOrName as NSString).lastPathComponent.lowercased()
        while name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "mksh", "oksh", "yash", "fish", "tcsh", "csh", "nu", "xonsh", "elvish",
        "pwsh",
    ]

    /// Session plumbing that owns a user's terminal/login session.
    private static let sessionProcessNames: Set<String> = [
        "launchd", "kernel_task", "loginwindow", "windowserver", "login", "su", "sudo", "doas",
        "sshd", "sshd-session", "sshd-auth", "mosh-server", "tmux", "screen", "zellij", "abduco", "dtach", "byobu",
        "script", "supervisord", "pm2",
    ]

    /// Interactive tools a server is commonly launched *from*; they must survive stopping that server.
    /// Coding agents always run with their cwd in the project, so they must never be mistaken for part of a launch.
    private static let agentAndEditorNames: Set<String> = [
        "claude", "codex", "gemini", "qwen", "kimi", "aider", "opencode", "cursor-agent", "goose", "amp", "copilot",
        "crush", "droid", "cline", "openhands", "plandex", "pdx", "auggie", "kilo", "kilocode", "codebuff", "grok",
        "openclaw", "cn", "interpreter",
        "vim", "nvim", "vi", "emacs", "nano", "hx", "helix", "kak",
    ]

    /// Names that are always an interactive REPL.
    private static let replOnlyNames: Set<String> = ["irb", "ipython", "ipython3", "bpython", "ptpython", "iex"]

    /// `python -m <module>` REPLs and debuggers.
    private static let replModules: Set<String> = ["ipython", "code", "asyncio", "pdb", "idlelib", "bpython", "ptpython"]

    private static let devRuntimeNames: Set<String> = [
        "node", "nodejs", "bun", "deno", "ruby", "php", "php-fpm", "java", "go", "dotnet", "beam.smp", "erl",
        "elixir", "perl", "pypy", "pypy3", "lua", "luajit", "swift",
    ]
    private static let devRuntimePrefixes = ["python", "pypy", "ruby", "php", "perl", "java"]
}

// MARK: - Tree walking

/// One process in a plan with its depth below the plan root (root = 0).
private struct PortPlannedProcess {
    let basic: PortProcessBasic
    let depth: Int
}

/// Walks the process table for one plan. Holds the (non-escaping) details provider for the duration of a call.
private struct PortTreeWalker {
    let table: PortProcessTable
    let details: (PortProcessBasic) -> PortProcessDetails?
    let currentUID: UInt32
    let ownPID: Int32
    let projectRoot: String?
    /// Mac Cleaner and its own ancestors: never part of a plan, never climbed through.
    let ownLineage: Set<Int32>

    init(table: PortProcessTable, details: @escaping (PortProcessBasic) -> PortProcessDetails?, currentUID: UInt32, ownPID: Int32,
         projectRoot: String?) {
        self.table = table
        self.details = details
        self.currentUID = currentUID
        self.ownPID = ownPID
        // A root path of "/" or one too short to be a project would make every process "same project".
        if let root = projectRoot, root.count > 1, root != NSHomeDirectory() {
            self.projectRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        } else {
            self.projectRoot = nil
        }
        var lineage: Set<Int32> = [ownPID]
        for ancestor in table.ancestors(of: ownPID) { lineage.insert(ancestor.pid) }
        self.ownLineage = lineage
    }

    // MARK: Step 1 — launch root

    /// Highest ancestor that still belongs to the server's launch (e.g. `npm run dev`), or `listener` itself.
    ///
    /// Climbs while ancestors are eligible and are either launch anchors (runner / same-project program) or
    /// non-interactive script shells. Script shells only become part of the plan when an anchor sits above them
    /// (`npm → sh -c vite → node`): the root is the highest *anchor*, so a chain like
    /// `claude → zsh -c → python` stops at the listener and never takes the agent's shell.
    func launchRoot(of listener: PortProcessBasic) -> PortProcessBasic {
        var root = listener
        var below = listener
        for candidate in table.ancestors(of: listener.pid) {      // nearest first
            let candidateDetails = details(candidate)
            guard isEligibleAncestor(candidate, details: candidateDetails, below: below) else { break }
            if isLaunchAnchor(candidate, details: candidateDetails) {
                root = candidate
            } else if !PortKillPlanner.isScriptShell(candidate, details: candidateDetails) {
                break
            }
            below = candidate
        }
        return root
    }

    /// Same user, not pid ≤ 1, not Mac Cleaner's own lineage, not protected, and plausibly the parent of `child`
    /// (a parent can't be younger than its child — protects against stale tables / recycled ppids).
    private func isEligibleAncestor(_ candidate: PortProcessBasic, details candidateDetails: PortProcessDetails?,
                                    below child: PortProcessBasic) -> Bool {
        guard candidate.pid > 1, !ownLineage.contains(candidate.pid), candidate.uid == currentUID,
              candidate.startTime <= child.startTime else { return false }
        return !PortKillPlanner.isProtected(candidate, details: candidateDetails)
    }

    /// Runner (npm, make, turbo…), package manager (`node …/npm`, npm's "npm run dev" title), file watcher
    /// (`node --watch`, `uvicorn --reload`, with or without a project), a program that runs code from the project
    /// (`node scripts/dev.js`, `./target/debug/launcher`), or a script-file shell whose script lives in the project
    /// (`bash ./scripts/dev.sh`).
    ///
    /// Shells are never anchors through `PortClassifier.isRunnerProcess`: a `zsh -c "npm run dev"` spawned by a coding
    /// agent or IDE belongs to that tool, so a shell is only ever included *below* a real anchor.
    private func isLaunchAnchor(_ candidate: PortProcessBasic, details candidateDetails: PortProcessDetails?) -> Bool {
        let mode = PortKillPlanner.shellMode(candidate, details: candidateDetails)
        if mode == .notShell {
            if PortClassifier.isRunnerProcess(basic: candidate, details: candidateDetails) { return true }
            if PortKillPlanner.isPackageManagerProcess(candidate, details: candidateDetails) { return true }
            // A watcher left alive restarts the server on the next file change.
            if PortClassifier.isWatcherProcess(basic: candidate, details: candidateDetails) { return true }
        }
        guard let root = projectRoot, let candidateDetails else { return false }
        switch mode {
        case .notShell:
            return belongsToProject(candidateDetails, root: root)
        case .script(let script):
            let path = script.hasPrefix("/") ? script
                : ((candidateDetails.cwd ?? "") as NSString).appendingPathComponent(script)
            return isPath((path as NSString).standardizingPath, inside: root)
        case .command, .interactive:
            return false
        }
    }

    /// True when the process runs code that lives in the project: its executable is inside the root, or it is an
    /// interpreter whose script resolves (relative paths against its cwd) inside the root.
    ///
    /// The working directory alone proves nothing: coding agents, editors and terminals all sit in the project
    /// folder, and an agent such as `kimi` or `node /opt/homebrew/bin/qwen` must never become the plan root.
    /// Arbitrary absolute arguments do not count either (`agent --add-dir /path/to/project`).
    private func belongsToProject(_ details: PortProcessDetails, root: String) -> Bool {
        if let executable = details.executablePath, isPath(executable, inside: root) { return true }
        guard let script = PortKillPlanner.scriptOperand(details.arguments) else { return false }
        let path: String
        if script.hasPrefix("/") {
            path = script
        } else {
            guard let cwd = details.cwd, cwd.hasPrefix("/") else { return false }
            path = (cwd as NSString).appendingPathComponent(script)
        }
        return isPath((path as NSString).standardizingPath, inside: root)
    }

    private func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // MARK: Step 2 — targets

    /// Root plus descendants in BFS order with depths. Subtrees are pruned at Mac Cleaner itself, pid ≤ 1, protected
    /// processes and processes of other users — except the listener, which is always kept (it is what the user
    /// asked to stop; another user's listener makes the plan require admin rights).
    func planTree(from root: PortProcessBasic, listener: PortProcessBasic) -> [PortPlannedProcess] {
        var result = [PortPlannedProcess(basic: root, depth: 0)]
        var seen: Set<Int32> = [root.pid]
        var index = 0
        while index < result.count {
            let parent = result[index]
            index += 1
            for childPID in table.childrenByPID[parent.basic.pid] ?? [] {
                guard seen.insert(childPID).inserted, let child = table[childPID] else { continue }
                guard child.pid > 1, !ownLineage.contains(child.pid),
                      child.startTime >= parent.basic.startTime else { continue }
                if child.identity != listener.identity {
                    guard child.uid == currentUID, !PortKillPlanner.isProtected(child, details: details(child)) else { continue }
                }
                result.append(PortPlannedProcess(basic: child, depth: parent.depth + 1))
            }
        }
        return result
    }
}
