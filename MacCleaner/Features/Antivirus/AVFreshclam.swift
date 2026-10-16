import Foundation

/// ClamAV's official updater, used whenever it's installed (ClamAV supports only freshclam
/// and cvdupdate for downloading its databases). Mac Cleaner runs it one-shot with a private
/// configuration that writes into Mac Cleaner's own database folder; the person's own
/// ClamAV setup is never touched.
struct AVFreshclamTool: Sendable, Hashable {
    var path: String
    /// "ClamAV 1.4.3" from `freshclam --version`.
    var version: String?
}

enum AVFreshclamLocator {
    static let candidatePaths = ["/opt/homebrew/bin/freshclam", "/usr/local/bin/freshclam", "/opt/local/bin/freshclam"]
    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// The first installed freshclam, also asking Homebrew where ClamAV lives.
    static func locate(
        candidates: [String] = candidatePaths,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        brew: String? = homebrewPath()
    ) async -> String? {
        if let found = candidates.first(where: isExecutable) { return found }
        guard let brew, let prefix = await homebrewPrefix(brew: brew, formula: "clamav") else { return nil }
        let path = prefix + "/bin/freshclam"
        return isExecutable(path) ? path : nil
    }

    static func homebrewPath(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        brewPaths.first(where: isExecutable)
    }

    /// `brew --prefix <formula>` (local, no network). nil when the formula isn't installed.
    static func homebrewPrefix(brew: String, formula: String) async -> String? {
        guard let result = try? await ProcessRunner.run(brew, arguments: ["--prefix", "--installed", formula], environment: AVHomebrew.environment(), timeout: 20),
              result.succeeded else { return nil }
        let prefix = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.hasPrefix("/") ? prefix : nil
    }

    /// Reads the version without touching the network.
    static func version(of path: String) async -> String? {
        guard let result = try? await ProcessRunner.run(path, arguments: ["--version"], timeout: 15), result.succeeded else { return nil }
        return AVFreshclamOutput.version(from: result.standardOutput)
    }
}

/// Mac Cleaner's private freshclam configuration.
enum AVFreshclamConfiguration {
    static func render(databaseDirectory: String, logFile: String, mirror: String = "database.clamav.net") -> String {
        """
        # Written by Mac Cleaner for its own copy of the ClamAV databases.
        # It is used only when Mac Cleaner runs freshclam and doesn't affect other ClamAV installations.
        DatabaseDirectory \(databaseDirectory)
        UpdateLogFile \(logFile)
        LogTime yes
        DatabaseMirror \(mirror)
        ScriptedUpdates yes
        Bytecode no
        Foreground yes
        TestDatabases yes

        """
    }

    static func write(paths: AVPaths) throws {
        try paths.prepare()
        let text = render(databaseDirectory: paths.clamav.path, logFile: paths.freshclamLog.path)
        try Data(text.utf8).write(to: paths.freshclamConfig, options: .atomic)
    }

    /// Arguments for a one-shot update (no daemon).
    static func arguments(paths: AVPaths) -> [String] {
        ["--config-file=\(paths.freshclamConfig.path)", "--stdout", "--show-progress"]
    }
}

/// What freshclam printed and what it means.
struct AVFreshclamReport: Sendable, Equatable {
    var updated: [String: Int] = [:]
    var upToDate: [String: Int] = [:]
    var errors: [String] = []
    var warnings: [String] = []
    /// freshclam's own cool-down after 429/403 from the CDN.
    var coolDownUntil: Date?
    var exitCode: Int32 = 0

    /// Exit codes 0 (updated) and 1 (already up to date) are success.
    var succeeded: Bool { (exitCode == 0 || exitCode == 1) && errors.isEmpty }
    var changed: Bool { !updated.isEmpty }

    var summary: String {
        if !updated.isEmpty {
            return "Updated " + updated.keys.sorted().map { "\($0) to version \(updated[$0] ?? 0)" }.joined(separator: ", ") + "."
        }
        if succeeded { return "The ClamAV databases are up to date." }
        if let coolDownUntil { return "ClamAV's servers asked to wait until \(DateFormatting.short(coolDownUntil))." }
        return errors.last ?? AVFreshclamOutput.explanation(exitCode: exitCode)
    }
}

enum AVFreshclamOutput {
    enum Event: Equatable, Sendable {
        case checking(String)
        case downloadingPatch(Int)
        case progress(Double)
        case testing
        case updated(String, Int)
        case upToDate(String, Int)
        case warning(String)
        case error(String)
        case coolDown(Date?)
    }

    static func event(for line: String, timeZone: TimeZone = .current) -> Event? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let date = coolDownDate(in: text, timeZone: timeZone) { return .coolDown(date) }
        if text.hasPrefix("ERROR:") { return .error(String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
        if text.hasPrefix("WARNING:") { return .warning(String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
        if let (name, version) = database(in: text, marker: " updated (version: ") { return .updated(name, version) }
        if let (name, version) = database(in: text, marker: " database is up-to-date (version: ") { return .upToDate(name, version) }
        if text.hasPrefix("Downloading database patch #"), let number = Int(text.dropFirst("Downloading database patch #".count).trimmingCharacters(in: CharacterSet(charactersIn: " ."))) {
            return .downloadingPatch(number)
        }
        if text.hasPrefix("Testing database") { return .testing }
        if text.contains(" database available for ") { return .checking(String(text.prefix { $0 != " " })) }
        if text.hasPrefix("Time:"), let fraction = progressFraction(text) { return .progress(fraction) }
        return nil
    }

    static func report(lines: [String], exitCode: Int32, timeZone: TimeZone = .current) -> AVFreshclamReport {
        var report = AVFreshclamReport(exitCode: exitCode)
        for line in lines {
            switch event(for: line, timeZone: timeZone) {
            case .updated(let name, let version)?: report.updated[name] = version
            case .upToDate(let name, let version)?: report.upToDate[name] = version
            case .error(let message)?: report.errors.append(message)
            case .warning(let message)?: report.warnings.append(message)
            case .coolDown(let date)?: report.coolDownUntil = date ?? report.coolDownUntil
            default: break
            }
        }
        return report
    }

    /// "daily.cld updated (version: 28155, …" → ("daily", 28155).
    private static func database(in text: String, marker: String) -> (String, Int)? {
        guard let range = text.range(of: marker) else { return nil }
        let file = text[..<range.lowerBound]
        guard let dot = file.lastIndex(of: "."), ["cvd", "cld"].contains(file[file.index(after: dot)...]) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        guard let version = Int(digits) else { return nil }
        return (String(file[..<dot]), version)
    }

    /// "Time: 1.2s, ETA: 0.3s [=====>   ] 12.5MiB/40.1MiB" → 0.31.
    private static func progressFraction(_ text: String) -> Double? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        let before = text[..<slash].split(separator: " ").last.map(String.init) ?? ""
        let after = String(text[text.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard let done = bytes(before), let total = bytes(after), total > 0 else { return nil }
        return min(1, done / total)
    }

    private static func bytes(_ text: String) -> Double? {
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        switch text.dropFirst(number.count).lowercased() {
        case "b", "": return value
        case "kib", "kb": return value * 1024
        case "mib", "mb": return value * 1024 * 1024
        case "gib", "gb": return value * 1024 * 1024 * 1024
        default: return nil
        }
    }

    /// "… cool-down until after: 2026-10-17 05:44:34".
    private static func coolDownDate(in text: String, timeZone: TimeZone) -> Date? {
        guard let range = text.range(of: "cool-down until after:") else { return nil }
        let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(value.prefix(19)))
    }

    static func version(from output: String) -> String? {
        let line = output.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.hasPrefix("ClamAV ") else { return nil }
        return String(line.prefix { $0 != "/" })
    }

    static func explanation(exitCode: Int32) -> String {
        switch exitCode {
        case 52: return "freshclam couldn't connect to ClamAV's servers."
        case 54: return "freshclam rejected a download that failed its signature check."
        case 56: return "freshclam couldn't read Mac Cleaner's configuration."
        case 57, 53, 50: return "freshclam couldn't write to Mac Cleaner's database folder."
        case 58: return "freshclam couldn't download the databases."
        case 59: return "ClamAV's mirrors aren't fully synchronized yet. Try again later."
        default: return "freshclam stopped with error \(exitCode)."
        }
    }
}

/// Runs freshclam one-shot and reports progress.
struct AVFreshclamRunner: Sendable {
    var paths: AVPaths
    var timeout: TimeInterval = 30 * 60

    func run(tool: AVFreshclamTool, progress: @escaping @Sendable (AVUpdateProgress) -> Void) async throws -> AVFreshclamReport {
        try AVFreshclamConfiguration.write(paths: paths)
        let collected = AVLinesBox()
        progress(AVUpdateProgress(phase: .runningFreshclam, message: "freshclam is checking ClamAV's servers…"))
        let result = try await AVStreamingCommand.run(tool.path, arguments: AVFreshclamConfiguration.arguments(paths: paths), timeout: timeout) { line in
            collected.append(line.text)
            switch AVFreshclamOutput.event(for: line.text) {
            case .checking(let name)?: progress(AVUpdateProgress(phase: .runningFreshclam, message: "freshclam is updating the \(name) database…"))
            case .downloadingPatch(let number)?: progress(AVUpdateProgress(phase: .runningFreshclam, message: "freshclam is applying update \(number)…"))
            case .progress(let fraction)?: progress(AVUpdateProgress(phase: .runningFreshclam, message: "freshclam is downloading…", fraction: fraction))
            case .testing?: progress(AVUpdateProgress(phase: .runningFreshclam, message: "freshclam is testing the new database…"))
            default: break
            }
        }
        var report = AVFreshclamOutput.report(lines: collected.lines, exitCode: result.exitCode)
        if result.timedOut { report.errors.append("freshclam took too long and was stopped.") }
        return report
    }
}

/// Homebrew helpers for "Install ClamAV with Homebrew".
enum AVHomebrew {
    static func environment() -> [String: String] {
        var environment = ToolLocator.shared.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        return environment
    }

    /// The command shown to the person and run after they confirm.
    static func installCommand(brew: String) -> (executable: String, arguments: [String], display: String) {
        (brew, ["install", "clamav"], "brew install clamav")
    }
}

/// Thread-safe line accumulator.
final class AVLinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let limit: Int

    init(limit: Int = 5_000) { self.limit = limit }

    func append(_ line: String) {
        lock.withLock {
            storage.append(line)
            if storage.count > limit { storage.removeFirst(storage.count - limit) }
        }
    }

    var lines: [String] { lock.withLock { storage } }
}
