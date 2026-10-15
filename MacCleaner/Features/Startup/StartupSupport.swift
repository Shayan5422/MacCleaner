import Darwin
import Foundation

/// Distinguishes "doesn't exist" from "can't be checked" (a folder this user can't enter),
/// so items behind restrictive permissions are never reported as broken.
enum LaunchdPathProbe {
    enum Status: Sendable, Equatable {
        case exists, missing, inaccessible
    }

    static func status(_ path: String) -> Status {
        var info = stat()
        if stat(path, &info) == 0 { return .exists }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        case ELOOP:
            // A symbolic link loop or a dangling chain: treat as missing.
            return .missing
        default: return .inaccessible
        }
    }

    /// `true` unless the path definitely doesn't exist.
    static func mightExist(_ path: String) -> Bool { status(path) != .missing }
}

/// Runs async work for many inputs with bounded concurrency, keeping input order.
enum StartupParallel {
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int = 6,
        _ transform: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        var results = [Output?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            let initial = min(max(1, limit), inputs.count)
            while next < initial {
                let index = next
                let input = inputs[index]
                group.addTask { (index, await transform(input)) }
                next += 1
            }
            while let (index, output) = await group.next() {
                results[index] = output
                if next < inputs.count {
                    let nextIndex = next
                    let input = inputs[nextIndex]
                    group.addTask { (nextIndex, await transform(input)) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }
}

/// Running processes indexed for matching startup items to what is actually running.
struct StartupProcessIndex: Sendable {
    let processes: [ProcessSnapshot]
    private let byPID: [Int32: ProcessSnapshot]
    private let byExecutable: [String: [ProcessSnapshot]]

    init(processes: [ProcessSnapshot]) {
        self.processes = processes
        var pids: [Int32: ProcessSnapshot] = [:]
        var executables: [String: [ProcessSnapshot]] = [:]
        for process in processes {
            pids[process.pid] = process
            if let path = process.executablePath { executables[path, default: []].append(process) }
        }
        byPID = pids
        byExecutable = executables
    }

    func process(pid: Int32) -> ProcessSnapshot? { byPID[pid] }

    /// Processes started from exactly this executable.
    func processes(executable: String) -> [ProcessSnapshot] {
        var matches = byExecutable[executable] ?? []
        if let resolved = PathUtilities.resolvedPath(executable), resolved != executable {
            matches += byExecutable[resolved] ?? []
        }
        return matches
    }

    /// Processes whose executable lives inside the bundle at `bundlePath` (the app and its helpers).
    func processes(insideBundle bundlePath: String) -> [ProcessSnapshot] {
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return processes.filter { $0.executablePath?.hasPrefix(prefix) == true }
    }

    /// Aggregated resource use; nil when nothing runs.
    static func usage(of processes: [ProcessSnapshot], now: Date = Date()) -> StartupResourceUsage? {
        guard !processes.isEmpty else { return nil }
        var memory: UInt64 = 0
        var cpu: UInt64 = 0
        var average = 0.0
        var measured = false
        var partial = false
        for process in processes {
            if process.memoryFootprint == 0 && process.cpuTimeNanoseconds == 0 {
                partial = true
                continue
            }
            measured = true
            memory += process.memoryFootprint
            cpu += process.cpuTimeNanoseconds
            if let start = process.startTime {
                let elapsed = max(1, now.timeIntervalSince(start))
                average += Double(process.cpuTimeNanoseconds) / 1_000_000_000 / elapsed
            }
        }
        return StartupResourceUsage(
            processCount: processes.count,
            memoryBytes: memory,
            cpuTimeNanoseconds: cpu,
            averageCPU: measured ? average : nil,
            isPartial: partial
        )
    }
}

/// Installed apps indexed for finding the app a startup item belongs to.
struct StartupAppIndex: Sendable {
    let apps: [AppBundleInfo]
    private let byBundleIdentifier: [String: AppBundleInfo]
    private let byPath: [String: AppBundleInfo]
    /// First two components of every installed app's bundle identifier ("com.google").
    let vendorPrefixes: Set<String>

    init(apps: [AppBundleInfo]) {
        self.apps = apps
        var identifiers: [String: AppBundleInfo] = [:]
        var paths: [String: AppBundleInfo] = [:]
        var vendors = Set<String>()
        for app in apps {
            paths[app.path] = app
            if let identifier = app.bundleIdentifier?.lowercased() {
                identifiers[identifier] = identifiers[identifier] ?? app
                if let vendor = StartupHeuristics.vendorPrefix(of: identifier) { vendors.insert(vendor) }
            }
        }
        byBundleIdentifier = identifiers
        byPath = paths
        vendorPrefixes = vendors
    }

    func app(bundleIdentifier: String) -> AppBundleInfo? { byBundleIdentifier[bundleIdentifier.lowercased()] }

    func app(path: String) -> AppBundleInfo? { byPath[path] }

    /// The installed app whose bundle identifier is the label or a prefix of it ("com.vendor.app.helper" → "com.vendor.app").
    func app(matchingLabel label: String) -> AppBundleInfo? {
        let lowered = label.lowercased()
        var best: (length: Int, app: AppBundleInfo)?
        for (identifier, app) in byBundleIdentifier where lowered == identifier || lowered.hasPrefix(identifier + ".") {
            if identifier.split(separator: ".").count < 2 { continue }
            if let current = best, current.length >= identifier.count { continue }
            best = (identifier.count, app)
        }
        return best?.app
    }

    /// `true` for apps that live in an Applications folder (apps people open themselves).
    static func isInApplicationsFolder(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }
}
