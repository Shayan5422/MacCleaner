import Darwin
import Foundation

/// A line printed by a running tool.
struct AVCommandLine: Sendable, Hashable {
    var text: String
    var isError: Bool
}

/// Runs a command-line tool (argument array, never a shell string) and reports its output
/// line by line while it runs, for live progress (freshclam, `brew install`). Carriage
/// returns end a line too, so progress bars arrive as separate updates.
enum AVStreamingCommand {
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        maxCapturedBytes: Int = 2 * 1024 * 1024,
        onLine: @escaping @Sendable (AVCommandLine) -> Void
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
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let output = AVLineCollector(isError: false, limit: maxCapturedBytes, onLine: onLine)
        let errors = AVLineCollector(isError: true, limit: maxCapturedBytes / 4, onLine: onLine)
        stdout.fileHandleForReading.readabilityHandler = { output.consume($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errors.consume($0.availableData) }

        let state = AVProcessState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    DispatchQueue.global().async {
                        let deadline = Date().addingTimeInterval(2)
                        while !(output.reachedEnd && errors.reachedEnd) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        output.flush()
                        errors.flush()
                        let result = CommandResult(exitCode: status, standardOutput: output.text, standardError: errors.text, timedOut: state.timedOut)
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
                    guard state.isRunning else { return }
                    state.timedOut = true
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        } onCancel: {
            state.terminate()
        }
    }
}

/// Splits a pipe's bytes into lines and keeps a bounded copy of everything.
private final class AVLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let isError: Bool
    private let limit: Int
    private let onLine: @Sendable (AVCommandLine) -> Void
    private var pending = Data()
    private var captured = Data()
    private var ended = false

    init(isError: Bool, limit: Int, onLine: @escaping @Sendable (AVCommandLine) -> Void) {
        self.isError = isError
        self.limit = limit
        self.onLine = onLine
    }

    func consume(_ chunk: Data) {
        var lines: [String] = []
        lock.withLock {
            if chunk.isEmpty {
                ended = true
                return
            }
            let room = limit - captured.count
            if room > 0 { captured.append(chunk.prefix(room)) }
            pending.append(chunk)
            while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = pending[pending.startIndex..<index]
                pending = Data(pending[pending.index(after: index)...])
                lines.append(String(decoding: line, as: UTF8.self))
            }
            if pending.count > 64 * 1024 { // a runaway line without a newline
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
        deliver(lines)
    }

    func flush() {
        let rest = lock.withLock { () -> String? in
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
        if let rest { deliver([rest]) }
    }

    private func deliver(_ lines: [String]) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { onLine(AVCommandLine(text: trimmed, isError: isError)) }
        }
    }

    var reachedEnd: Bool { lock.withLock { ended } }
    var text: String { lock.withLock { String(decoding: captured, as: UTF8.self) } }
}

private final class AVProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var process: Process?
    private var didTimeOut = false

    var timedOut: Bool {
        get { lock.withLock { didTimeOut } }
        set { lock.withLock { didTimeOut = newValue } }
    }

    var isRunning: Bool { lock.withLock { !finished && process?.isRunning == true } }

    func setProcess(_ process: Process) { lock.withLock { self.process = process } }

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
