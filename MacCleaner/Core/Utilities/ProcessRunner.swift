import Foundation

/// Output of a command-line tool.
struct CommandResult: Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
    var timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Trimmed output for display.
    var combinedOutput: String {
        [standardOutput, standardError].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum CommandError: LocalizedError {
    case toolNotFound(String)
    case launchFailed(String, String)
    case failed(command: String, result: CommandResult)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) isn't installed or couldn't be found."
        case .launchFailed(let tool, let reason):
            return "Couldn't run \(tool): \(reason)"
        case .failed(let command, let result):
            if result.timedOut { return "\(command) took too long and was stopped." }
            let detail = result.combinedOutput.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(command) failed (exit code \(result.exitCode))\(detail.isEmpty ? "." : ": \(detail)")"
        }
    }
}

/// Runs command-line tools with an argument array (never through a shell
/// string), a timeout, cancellation and bounded output capture.
enum ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = 60,
        maxOutputBytes: Int = 8 * 1024 * 1024
    ) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError.toolNotFound((executable as NSString).lastPathComponent)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = environment ?? ToolLocator.shared.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        process.environment = env
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outputBuffer = OutputBuffer(limit: maxOutputBytes)
        let errorBuffer = OutputBuffer(limit: maxOutputBytes / 4)
        stdout.fileHandleForReading.readabilityHandler = { handle in outputBuffer.consume(handle.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { handle in errorBuffer.consume(handle.availableData) }

        let state = RunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    // Drain what's left without blocking: a background grandchild that
                    // inherited the pipes could otherwise keep them open indefinitely.
                    let status = finished.terminationStatus
                    DispatchQueue.global().async {
                        let deadline = Date().addingTimeInterval(2)
                        while !(outputBuffer.reachedEnd && errorBuffer.reachedEnd) && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        let result = CommandResult(
                            exitCode: status,
                            standardOutput: outputBuffer.string,
                            standardError: errorBuffer.string,
                            timedOut: state.timedOut
                        )
                        if state.markFinished() { continuation.resume(returning: result) }
                    }
                }
                do {
                    try process.run()
                    state.setProcess(process)
                } catch {
                    if state.markFinished() {
                        continuation.resume(throwing: CommandError.launchFailed((executable as NSString).lastPathComponent, error.localizedDescription))
                    }
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if state.isRunning {
                        state.timedOut = true
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        } onCancel: {
            state.terminate()
        }
    }

    /// Runs a tool and throws if it exits with a non-zero status.
    @discardableResult
    static func runChecked(
        _ executable: String,
        arguments: [String] = [],
        timeout: TimeInterval = 60
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments: arguments, timeout: timeout)
        guard result.succeeded else {
            let command = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
            throw CommandError.failed(command: command, result: result)
        }
        return result
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Called by the readability handler; empty data means end of file.
    func consume(_ chunk: Data) {
        lock.withLock {
            if chunk.isEmpty {
                ended = true
                return
            }
            let room = limit - data.count
            if room > 0 { data.append(chunk.prefix(room)) }
        }
    }

    var reachedEnd: Bool { lock.withLock { ended } }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var process: Process?
    private var _timedOut = false

    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }

    var isRunning: Bool { lock.withLock { !finished && process?.isRunning == true } }

    func setProcess(_ process: Process) {
        lock.withLock { self.process = process }
    }

    /// Returns true only for the first caller, so the continuation resumes once.
    func markFinished() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }

    func terminate() {
        let running = lock.withLock { finished ? nil : process }
        running?.terminate()
    }
}

/// Finds developer command-line tools. GUI apps start with a minimal `PATH`,
/// so common install locations are searched explicitly.
final class ToolLocator: Sendable {
    static let shared = ToolLocator()

    let searchPaths: [String]
    let environment: [String: String]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
            "\(home)/Library/pnpm", "\(home)/.local/share/pnpm", "\(home)/.deno/bin", "\(home)/go/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "\(home)/.docker/bin", "\(home)/.orbstack/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        // Node version managers install per-version binaries.
        let nvmVersions = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            paths.insert(contentsOf: newest.prefix(1).map { "\(nvmVersions)/\($0)/bin" }, at: 0)
        }
        let fnmDefault = "\(home)/Library/Application Support/fnm/aliases/default/bin"
        if FileManager.default.fileExists(atPath: fnmDefault) { paths.insert(fnmDefault, at: 0) }

        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for path in inherited where !paths.contains(path) { paths.append(path) }
        searchPaths = paths

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.joined(separator: ":")
        env["HOME"] = home
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment = env
    }

    /// Absolute path of an executable named `tool`, or nil if it isn't installed.
    func locate(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for directory in searchPaths {
            let candidate = directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
