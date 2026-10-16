import Darwin
import Foundation

/// User-facing error thrown by the Ports control layer (launchctl / pm2 / docker / signals).
struct PortControlError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(message: String) { self.message = message }
    init(_ message: String) { self.message = message }
}

/// One row of `launchctl list`.
struct PortLaunchctlListEntry: Hashable, Sendable {
    /// nil when the job is loaded but not running ("-").
    let pid: Int32?
    /// Last exit status; negative values are signals (e.g. -15 = SIGTERM). nil when "-".
    let lastExitStatus: Int32?
    let label: String
}

/// The launchd-relevant parts of a job plist.
struct PortLaunchdPlistInfo: Hashable, Sendable {
    let label: String
    let path: String
    /// Program + arguments summary, e.g. "/opt/homebrew/bin/node server.js". Empty when the plist has no program.
    let command: String
    let workingDirectory: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    /// The plist's own `Disabled` key (overridden by `launchctl enable/disable`).
    let disabledInPlist: Bool
    /// False when `LimitLoadToSessionType` excludes "Aqua" (e.g. "LoginWindow"-only agents): such a job never
    /// loads in the user's GUI domain.
    var loadsInGUISession: Bool = true
}

/// Reads launchd jobs for the Ports tab and stops or disables the user's own agents.
///
/// State changes go through Mac Cleaner's `LaunchctlClient` (current user's agents only, never Apple's labels);
/// plists are parsed with `LaunchdPlistParser`. Thread-safe: caches are guarded by a lock. Never modifies or
/// deletes a plist file.
final class PortLaunchdService: @unchecked Sendable {
    let uid: UInt32
    private let homeDirectory: String
    private let client = LaunchctlClient()

    /// How long the label → plist index and `launchctl print` fallbacks are reused.
    private let indexMaxAge: TimeInterval = 30

    private let lock = NSLock()
    private var plistIndex: [String: PortLaunchdPlistInfo] = [:]
    private var plistIndexDate: Date?
    private var printCache: [String: (job: PortLaunchdJob?, date: Date)] = [:]

    init(uid: UInt32 = getuid(), homeDirectory: String = NSHomeDirectory()) {
        self.uid = uid
        self.homeDirectory = homeDirectory
    }

    var guiDomain: String { "gui/\(uid)" }

    /// `~/Library/LaunchAgents`: agents the user owns and can manage without admin rights.
    var userAgentsDirectory: String { homeDirectory + "/Library/LaunchAgents" }
    static let sharedAgentsDirectory = LaunchdLocations.systemAgentsFolder
    static let daemonsDirectory = LaunchdLocations.systemDaemonsFolder

    /// Search order for the label index: earlier folders win when two plists declare the same label.
    private var indexedDirectories: [String] {
        [userAgentsDirectory, Self.sharedAgentsDirectory, Self.daemonsDirectory]
    }

    // MARK: - Reading state

    /// `launchctl list` → pid → label for running jobs (skips "-" pids). Includes "application.*" labels (callers
    /// filter).
    func runningJobLabels() async -> [Int32: String] {
        guard let result = try? await ProcessRunner.run(LaunchctlClient.executable, arguments: ["list"], timeout: 5),
              result.succeeded else { return [:] }
        return Self.runningLabels(fromListOutput: result.standardOutput)
    }

    /// Job info for a label: plist path (searched by Label in ~/Library/LaunchAgents, /Library/LaunchAgents,
    /// /Library/LaunchDaemons — cached index, refreshed at most every 30 s), KeepAlive/RunAtLoad from the plist, pid.
    /// Falls back to `launchctl print gui/<uid>/<label>` ("path = …" and "properties = keepalive | runatload").
    ///
    /// nil for "application.*" labels (GUI app instances, never auto-start jobs) and for labels launchd doesn't
    /// know when `pid` is nil. Fallback lookups are cached per label for 30 s.
    func job(label: String, pid: Int32?) async -> PortLaunchdJob? {
        guard Self.isValidLabel(label), !Self.isAppInstanceLabel(label) else { return nil }

        if let info = await indexedPlist(for: label) {
            let domain = info.path.hasPrefix(Self.daemonsDirectory + "/") ? "system" : guiDomain
            return PortLaunchdJob(label: label, domain: domain, plistPath: info.path,
                                  keepAlive: info.keepAlive, runAtLoad: info.runAtLoad, pid: pid)
        }

        let cached = lock.withLock { printCache[label] }
        if let cached, Date().timeIntervalSince(cached.date) < indexMaxAge {
            return Self.restamped(cached.job, label: label, domain: guiDomain, pid: pid)
        }

        var resolved: PortLaunchdJob?
        if let service = await client.serviceInfo(label: label, domain: .gui(uid)) {
            let properties = Self.propertyFlags(service.properties.first { $0.key == "properties" }?.value.stringValue)
            var keepAlive = properties.contains("keepalive")
            var runAtLoad = properties.contains("runatload")
            let path = service.path.flatMap { $0.hasPrefix("/") ? $0 : nil }
            if let path, let plist = await BackgroundWork.run(qos: .utility, { Self.readPlist(at: path) }) {
                keepAlive = plist.keepAlive
                runAtLoad = plist.runAtLoad
            }
            resolved = PortLaunchdJob(label: label, domain: guiDomain, plistPath: path,
                                      keepAlive: keepAlive, runAtLoad: runAtLoad, pid: pid)
        }
        lock.withLock { printCache[label] = (resolved, Date()) }
        return Self.restamped(resolved, label: label, domain: guiDomain, pid: pid)
    }

    /// Re-stamps a cached job with the caller's pid; a running label launchd could not describe still counts
    /// as a (non-restarting) launchd job.
    private static func restamped(_ cached: PortLaunchdJob?, label: String, domain: String, pid: Int32?) -> PortLaunchdJob? {
        if let cached {
            return PortLaunchdJob(label: cached.label, domain: cached.domain, plistPath: cached.plistPath,
                                  keepAlive: cached.keepAlive, runAtLoad: cached.runAtLoad, pid: pid)
        }
        guard let pid else { return nil }
        return PortLaunchdJob(label: label, domain: domain, plistPath: nil, keepAlive: false, runAtLoad: false, pid: pid)
    }

    /// "runatload | inferred program | keepalive" → lowercased flags.
    static func propertyFlags(_ line: String?) -> Set<String> {
        guard let line else { return [] }
        var flags = Set<String>()
        for flag in line.split(separator: "|") {
            let name = flag.trimmingCharacters(in: .whitespaces).lowercased()
            if !name.isEmpty { flags.insert(name) }
        }
        return flags
    }

    // MARK: - Actions (current user's agents, through LaunchctlClient)

    /// `launchctl bootout gui/<uid>/<label>`: stops the job until the next login (when it has RunAtLoad).
    /// A job that isn't loaded counts as stopped.
    func stop(label: String) async throws {
        try await client.bootoutUserAgent(label: label)
        invalidateCaches()
    }

    /// `launchctl disable` + bootout: stays off across logins. The plist is kept, so the agent can be turned back
    /// on from Mac Cleaner's Startup Items page.
    func disable(label: String) async throws {
        try await client.disableUserAgent(label: label)
        invalidateCaches()
    }

    // MARK: - Reversible disable

    /// Folders whose agents Mac Cleaner's Startup Items page can switch back on after a disable. (Agents in
    /// /Library/LaunchAgents are shown there read-only, so they are only ever stopped here.)
    var manageableAgentDirectories: [String] { [userAgentsDirectory] }

    /// True when `plistPath` is a `.plist` directly inside a manageable LaunchAgents folder.
    func isManageable(plistPath: String?) -> Bool {
        guard let plistPath, plistPath.hasPrefix("/"), plistPath.hasSuffix(".plist") else { return false }
        let standardized = (plistPath as NSString).standardizingPath
        let directory = (standardized as NSString).deletingLastPathComponent
        return manageableAgentDirectories.contains { ($0 as NSString).standardizingPath == directory }
    }

    /// True when Stop & Disable may write a persistent `launchctl disable` for `job`: a non-Apple agent in the
    /// user's GUI domain whose plist sits in ~/Library/LaunchAgents, still declares this label and loads in the GUI
    /// session — exactly the agents the Startup Items page can turn back on.
    ///
    /// False for SMAppService helpers (no plist path), plists inside app bundles or project folders, shared agents
    /// and daemons: Mac Cleaner could never undo a disable for those, so they are only stopped. Reads the plist; call
    /// it off the main thread.
    func canDisableReversibly(job: PortLaunchdJob) -> Bool {
        guard job.isUserAgent, job.domain == guiDomain, Self.isValidLabel(job.label),
              !LaunchctlClient.isProtectedLabel(job.label), let path = job.plistPath, isManageable(plistPath: path),
              let info = Self.readPlist(at: path) else { return false }
        return info.label == job.label && info.loadsInGUISession
    }

    /// Stop & Disable for one job, never leaving a disable Mac Cleaner can't undo: `disable(label:)` when
    /// `canDisableReversibly(job:)`, otherwise only `stop(label:)` (it may start again at next login).
    /// Returns true when auto-start was disabled, false when the job was only stopped.
    @discardableResult
    func stopAndDisableIfReversible(job: PortLaunchdJob) async throws -> Bool {
        let reversible = await BackgroundWork.run(qos: .userInitiated) { self.canDisableReversibly(job: job) }
        if reversible {
            try await disable(label: job.label)
            return true
        }
        try await stop(label: job.label)
        return false
    }

    /// "application.*" labels are GUI app instances, not auto-start jobs.
    static func isAppInstanceLabel(_ label: String) -> Bool {
        label.hasPrefix("application.")
    }

    /// Labels go inside a service target ("gui/501/<label>"): non-empty single-line strings without "/".
    static func isValidLabel(_ label: String) -> Bool {
        LaunchctlClient.isValidLabel(label)
    }

    // MARK: - Plist index

    /// Drops cached lookups so the next `job(label:pid:)` sees fresh state.
    func invalidateCaches() {
        lock.withLock {
            plistIndexDate = nil
            printCache.removeAll()
        }
    }

    private func indexedPlist(for label: String) async -> PortLaunchdPlistInfo? {
        let fresh = lock.withLock { () -> [String: PortLaunchdPlistInfo]? in
            guard let date = plistIndexDate, Date().timeIntervalSince(date) < indexMaxAge else { return nil }
            return plistIndex
        }
        if let fresh { return fresh[label] }
        let directories = indexedDirectories
        let index = await BackgroundWork.run(qos: .utility) { Self.buildIndex(directories) }
        lock.withLock {
            plistIndex = index
            plistIndexDate = Date()
        }
        return index[label]
    }

    /// label → plist info over `directories` (earlier folders win).
    static func buildIndex(_ directories: [String]) -> [String: PortLaunchdPlistInfo] {
        var index: [String: PortLaunchdPlistInfo] = [:]
        for directory in directories {
            for info in scanDirectory(directory) where index[info.label] == nil {
                index[info.label] = info
            }
        }
        return index
    }

    /// Parses every `*.plist` in `directory` (sorted by file name). Unreadable entries are skipped.
    static func scanDirectory(_ directory: String) -> [PortLaunchdPlistInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
            .sorted()
            .compactMap { readPlist(at: directory + "/" + $0) }
    }

    /// Largest plist we are willing to parse; launchd plists are a few KB.
    static let maxPlistBytes = 1 << 20

    /// Reads a launchd plist (XML or binary). nil when it is not a regular file, too large, unreadable or invalid.
    static func readPlist(at path: String) -> PortLaunchdPlistInfo? {
        var info = stat()
        // stat follows symlinks (e.g. /Library/LaunchAgents/x.plist → inside an app bundle); refusing non-regular
        // files keeps us from blocking on a FIFO.
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(maxPlistBytes) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parsePlist(data: data, path: path)
    }

    /// Parses plist bytes. Pure; used by tests.
    static func parsePlist(data: Data, path: String) -> PortLaunchdPlistInfo? {
        guard let definition = try? LaunchdPlistParser.parse(data: data) else { return nil }
        return info(from: definition, path: path)
    }

    /// Interprets a launchd plist dictionary. Missing Label → file name without ".plist". Returns nil for
    /// placeholder plists that have neither a Label nor a program (launchd refuses those anyway).
    static func parsePlist(_ plist: [String: Any], path: String) -> PortLaunchdPlistInfo? {
        info(from: LaunchdPlistParser.parse(dictionary: plist), path: path)
    }

    private static func info(from job: LaunchdJobDefinition, path: String) -> PortLaunchdPlistInfo? {
        let program = job.program.flatMap { $0.isEmpty ? nil : $0 }
        let arguments = job.programArguments
        let explicitLabel = job.label.flatMap { isValidLabel($0) ? $0 : nil }
        guard explicitLabel != nil || program != nil || !arguments.isEmpty else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let fallbackLabel = fileName.hasSuffix(".plist") ? String(fileName.dropLast(6)) : fileName
        guard let label = explicitLabel ?? (isValidLabel(fallbackLabel) ? fallbackLabel : nil) else { return nil }
        return PortLaunchdPlistInfo(label: label, path: path,
                                    command: commandSummary(program: program, arguments: arguments),
                                    workingDirectory: job.workingDirectory.flatMap { $0.isEmpty ? nil : $0 },
                                    runAtLoad: job.runAtLoad,
                                    keepAlive: job.keepAlive.isEnabled,
                                    disabledInPlist: job.disabled,
                                    loadsInGUISession: loadsInGUISession(job.limitLoadToSessionTypes))
    }

    /// `LimitLoadToSessionType` is a string or an array of strings; absent means "Aqua" for agents.
    static func loadsInGUISession(_ types: [String]) -> Bool {
        types.isEmpty || types.contains { $0.caseInsensitiveCompare("Aqua") == .orderedSame }
    }

    /// launchd semantics: `Program` is the executable, `ProgramArguments` is argv (argv[0] included). When both
    /// are present the summary is Program + argv[1...]. Arguments with spaces are quoted like
    /// `PortProcessDetails.commandLine`.
    static func commandSummary(program: String?, arguments: [String]) -> String {
        var parts: [String]
        if let program {
            parts = [program] + arguments.dropFirst()
        } else {
            parts = arguments
        }
        parts = parts.map { $0.isEmpty || $0.contains(" ") ? "\"\($0)\"" : $0 }
        return parts.joined(separator: " ")
    }

    // MARK: - Output parsers (pure, tested)

    /// Parses `launchctl list` ("PID\tStatus\tLabel" header + one tab-separated row per job).
    static func parseList(_ output: String) -> [PortLaunchctlListEntry] {
        var entries: [PortLaunchctlListEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count != 3 {
                // Defensive: tolerate space-separated columns.
                fields = rawLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            guard fields.count == 3, fields[0] != "PID", !fields[2].isEmpty else { continue }
            guard fields[0] == "-" || Int32(fields[0]) != nil else { continue }
            let pid = Int32(fields[0]).flatMap { $0 > 0 ? $0 : nil }
            entries.append(PortLaunchctlListEntry(pid: pid, lastExitStatus: Int32(fields[1]), label: fields[2]))
        }
        return entries
    }

    /// pid → label for running jobs. When two rows share a pid the first wins.
    static func runningLabels(fromListOutput output: String) -> [Int32: String] {
        var labels: [Int32: String] = [:]
        for entry in parseList(output) {
            guard let pid = entry.pid, labels[pid] == nil else { continue }
            labels[pid] = entry.label
        }
        return labels
    }
}
