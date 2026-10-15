import Darwin
import Foundation

/// Something Mac Cleaner can do about a recommendation.
enum PerformanceAction: String, Sendable, Hashable, Identifiable {
    case quit, forceQuit, stopProcess, openStartupItems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quit: return "Quit"
        case .forceQuit: return "Force Quit…"
        case .stopProcess: return "Stop Process…"
        case .openStartupItems: return "Review Startup Items"
        }
    }

    var symbol: String {
        switch self {
        case .quit: return "xmark.circle"
        case .forceQuit: return "exclamationmark.octagon"
        case .stopProcess: return "stop.circle"
        case .openStartupItems: return "power.circle"
        }
    }
}

/// The app or process an action applies to, captured when the recommendation was
/// made. Re-validated before anything is done, so a reused pid is never affected.
struct PerformanceActionTarget: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable { case app, process }

    var kind: Kind
    var pid: pid_t
    var name: String
    var uid: uid_t
    var startTime: Date?
    var bundleIdentifier: String?
    var bundlePath: String?
    var executablePath: String?

    var id: String { "\(kind.rawValue)|\(pid)|\(startTime?.timeIntervalSince1970 ?? 0)" }

    static func app(_ app: PerformanceRunningApp, uid: uid_t = getuid()) -> PerformanceActionTarget {
        PerformanceActionTarget(kind: .app, pid: app.pid, name: app.name, uid: uid, startTime: nil, bundleIdentifier: app.bundleIdentifier, bundlePath: app.bundlePath, executablePath: nil)
    }

    static func process(_ process: PerformanceProcess) -> PerformanceActionTarget {
        PerformanceActionTarget(kind: .process, pid: process.pid, name: process.name, uid: process.uid, startTime: process.startTime, bundleIdentifier: nil, bundlePath: nil, executablePath: process.executablePath)
    }
}

/// A finding on the Optimize tab, with the reason behind it.
struct PerformanceRecommendation: Identifiable, Sendable, Hashable {
    enum Category: Int, Sendable, Hashable, Comparable {
        case thermal, cpu, background, restart, startup

        static func < (lhs: Category, rhs: Category) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var category: Category
    var severity: FindingSeverity
    var title: String
    /// Why this is shown and what to expect.
    var detail: String
    /// Short facts ("95% of a core", "3.2 GB").
    var metrics: [String]
    var symbol: String
    /// App bundle or executable whose icon to show.
    var iconPath: String?
    var target: PerformanceActionTarget?
    var actions: [PerformanceAction]
}

/// An app and its helper processes, with their combined memory footprint.
struct PerformanceMemoryHeavyApp: Identifiable, Sendable, Hashable {
    var app: PerformanceRunningApp
    var bytes: UInt64
    var processCount: Int
    /// Share of physical memory, 0...1.
    var fractionOfMemory: Double

    var id: pid_t { app.pid }
    var target: PerformanceActionTarget { .app(app) }
}

/// Counts of launch agents and daemons, which start background processes automatically.
struct PerformanceStartupSummary: Sendable, Hashable {
    /// ~/Library/LaunchAgents — started at your login.
    var userLaunchAgents: Int
    /// /Library/LaunchAgents — installed by apps for every user.
    var sharedLaunchAgents: Int?
    /// /Library/LaunchDaemons — installed by apps, run as root at startup.
    var launchDaemons: Int?

    static func read() -> PerformanceStartupSummary {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PerformanceStartupSummary(
            userLaunchAgents: countPropertyLists(in: home + "/Library/LaunchAgents") ?? 0,
            sharedLaunchAgents: countPropertyLists(in: "/Library/LaunchAgents"),
            launchDaemons: countPropertyLists(in: "/Library/LaunchDaemons")
        )
    }

    private static func countPropertyLists(in directory: String) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }.count
    }
}

/// Everything the advisor looks at, captured as values.
struct PerformanceAdvisorInput: Sendable {
    var sample: PerformanceSample?
    var processes: [PerformanceProcess]
    var apps: PerformanceAppDirectory
    var logicalCoreCount: Int
    var startup: PerformanceStartupSummary?
    var bootDate: Date?
    var now: Date = Date()
}

/// Turns measurements into explained recommendations. It never recommends
/// "freeing" memory: macOS manages caches itself, and only memory pressure matters.
enum PerformanceAdvisor {
    /// Sustained CPU use (fraction of one core) considered unusual for an app.
    static let unusualCPUThreshold = 0.8
    /// Background processes above this sustained CPU are mentioned.
    static let busyBackgroundThreshold = 0.25
    /// Background processes above this footprint (1 GB, binary like Activity Monitor) are mentioned.
    static let largeBackgroundMemory: UInt64 = 1 << 30
    /// Apps above this footprint (500 MB) are listed as memory-intensive.
    static let largeAppMemory: UInt64 = 500 << 20
    static let maximumMemoryApps = 5

    static func recommendations(for input: PerformanceAdvisorInput) -> [PerformanceRecommendation] {
        var result: [PerformanceRecommendation] = []
        var handledPIDs = Set<pid_t>()
        let pressure = input.sample?.memoryPressure ?? .normal
        let roles = Dictionary(input.processes.map { ($0.pid, PerformanceProcessPolicy.role(of: $0, apps: input.apps)) }, uniquingKeysWith: { first, _ in first })

        if let sample = input.sample {
            result += thermalRecommendations(sample: sample, processes: input.processes)
        }

        // Unusual CPU: anything keeping most of a core busy for the recent window.
        let busy = input.processes
            .filter { $0.hasUsageInfo && $0.isSustainedCPU(atLeast: unusualCPUThreshold) }
            .sorted { ($0.recentCPU ?? 0) > ($1.recentCPU ?? 0) }
        for process in busy {
            handledPIDs.insert(process.pid)
            result.append(cpuRecommendation(for: process, role: roles[process.pid] ?? .unknown, cores: input.logicalCoreCount))
        }

        // Background processes of the current user with high usage.
        for process in input.processes where process.isCurrentUser && process.hasUsageInfo && !handledPIDs.contains(process.pid) {
            let role = roles[process.pid] ?? .unknown
            guard role.canStopProcess || role == .macOSComponent else { continue }
            let busyCPU = process.isSustainedCPU(atLeast: busyBackgroundThreshold)
            let largeMemory = (process.memoryFootprint ?? 0) >= largeBackgroundMemory
            guard busyCPU || largeMemory else { continue }
            handledPIDs.insert(process.pid)
            result.append(backgroundRecommendation(for: process, role: role, busyCPU: busyCPU, largeMemory: largeMemory, pressure: pressure))
        }

        if let restart = restartRecommendation(input: input) { result.append(restart) }
        if let startup = input.startup, let recommendation = startupRecommendation(startup) { result.append(recommendation) }

        return result.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.category < rhs.category
        }
    }

    // MARK: - CPU

    private static func cpuRecommendation(for process: PerformanceProcess, role: PerformanceProcessRole, cores: Int) -> PerformanceRecommendation {
        let share = process.recentCPU ?? 0
        let seconds = Int(process.recentCPUWindow.rounded())
        let usage = "about \(PerformanceFormat.coreShare(share)) of a CPU core for the last \(seconds) seconds"
        var detail: String
        var actions: [PerformanceAction] = []
        var target: PerformanceActionTarget?
        var title = "\(process.name) is using a lot of CPU"
        switch role {
        case .app(let app):
            detail = "\(app.name) has kept \(usage). That's expected while it exports, renders, compiles or plays games. If it should be idle, it may be stuck — quitting it stops the load."
            target = .app(app)
            actions = [.quit, .forceQuit]
        case .appHelper(let app):
            title = "\(app.name) is using a lot of CPU"
            detail = "\(process.name), part of \(app.name), has kept \(usage). If \(app.name) isn't doing heavy work, a tab, document or extension in it may be misbehaving: close it, or quit \(app.name)."
            target = .app(app)
            actions = [.quit, .forceQuit]
        case .background:
            detail = "This background process has kept \(usage). If you don't know why it's working this hard, it may be stuck. Stopping it asks it to quit; the app that installed it may start it again."
            target = .process(process)
            actions = [.stopProcess]
        case .webContent:
            detail = "A web page in Safari or in an app that shows web content has kept \(usage). Closing the busy tab or window stops it."
        case .macOSComponent, .protectedSystem:
            detail = (PerformanceKnownProcesses.explanation(for: process.name) ?? "This is part of macOS and usually settles down on its own.") + " Mac Cleaner doesn't stop macOS components."
        case .thisApp:
            detail = "Mac Cleaner itself has kept \(usage), most likely because a scan is running."
        case .otherUser, .unknown:
            detail = "This process has kept \(usage)."
        }
        let totalShare = share / Double(max(1, cores))
        return PerformanceRecommendation(
            id: "cpu|\(process.pid)",
            category: .cpu,
            severity: role.actionableApp != nil || role.canStopProcess ? .recommendation : .info,
            title: title,
            detail: detail,
            metrics: ["\(PerformanceFormat.coreShare(share)) of a core", "\(NumberFormatting.percent(totalShare)) of total CPU"],
            symbol: "cpu",
            iconPath: role.actionableApp?.bundlePath ?? process.appBundlePath ?? process.executablePath,
            target: target,
            actions: actions
        )
    }

    // MARK: - Background

    private static func backgroundRecommendation(
        for process: PerformanceProcess,
        role: PerformanceProcessRole,
        busyCPU: Bool,
        largeMemory: Bool,
        pressure: MemoryPressureLevel
    ) -> PerformanceRecommendation {
        var metrics: [String] = []
        var reasons: [String] = []
        if busyCPU, let share = process.recentCPU {
            metrics.append("\(PerformanceFormat.coreShare(share)) of a core")
            reasons.append("has averaged \(PerformanceFormat.coreShare(share)) of a CPU core over the last \(Int(process.recentCPUWindow.rounded())) seconds")
        }
        if largeMemory, let bytes = process.memoryFootprint {
            metrics.append(PerformanceFormat.memory(bytes))
            reasons.append("is using \(PerformanceFormat.memory(bytes)) of memory")
        }
        let summary = "It runs without a window and " + reasons.joined(separator: " and ") + "."
        var detail: String
        var actions: [PerformanceAction] = []
        var target: PerformanceActionTarget?
        if role.canStopProcess {
            detail = summary + " Stop it only if you recognize it and don't need it right now; the app that installed it may start it again."
            target = .process(process)
            actions = [.stopProcess]
        } else {
            detail = summary + " " + (PerformanceKnownProcesses.explanation(for: process.name) ?? "It's part of macOS and is managed by the system.")
        }
        let severity: FindingSeverity = busyCPU || pressure >= .warning ? .recommendation : .info
        return PerformanceRecommendation(
            id: "background|\(process.pid)",
            category: .background,
            severity: role.canStopProcess ? severity : .info,
            title: busyCPU ? "\(process.name) is busy in the background" : "\(process.name) is using a lot of memory in the background",
            detail: detail,
            metrics: metrics,
            symbol: "gearshape.2",
            iconPath: process.executablePath,
            target: target,
            actions: actions
        )
    }

    // MARK: - Memory

    /// Apps (with their helper processes) using the most memory, largest first.
    static func memoryHeavyApps(
        processes: [PerformanceProcess],
        apps: PerformanceAppDirectory,
        totalMemory: UInt64,
        minimumBytes: UInt64 = largeAppMemory,
        limit: Int = maximumMemoryApps
    ) -> [PerformanceMemoryHeavyApp] {
        var groups: [pid_t: PerformanceMemoryHeavyApp] = [:]
        for process in processes {
            guard let bytes = process.memoryFootprint,
                  let app = PerformanceProcessPolicy.role(of: process, apps: apps).actionableApp else { continue }
            var group = groups[app.pid] ?? PerformanceMemoryHeavyApp(app: app, bytes: 0, processCount: 0, fractionOfMemory: 0)
            group.bytes += bytes
            group.processCount += 1
            groups[app.pid] = group
        }
        return groups.values
            .filter { $0.bytes >= minimumBytes && $0.bytes > 0 }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.app.name < $1.app.name }
            .prefix(limit)
            .map { group in
                var group = group
                group.fractionOfMemory = totalMemory > 0 ? Double(group.bytes) / Double(totalMemory) : 0
                return group
            }
    }

    // MARK: - Thermal

    private static func thermalRecommendations(sample: PerformanceSample, processes: [PerformanceProcess]) -> [PerformanceRecommendation] {
        guard sample.thermalState == .serious || sample.thermalState == .critical else { return [] }
        let top = processes
            .filter { ($0.recentCPU ?? 0) >= 0.5 }
            .sorted { ($0.recentCPU ?? 0) > ($1.recentCPU ?? 0) }
            .prefix(3)
            .map(\.name)
        var detail = "macOS reports a \(sample.thermalState.performanceTitle.lowercased()) thermal state and is slowing the processor down to cool it."
        if !top.isEmpty {
            detail += " The busiest processes right now: \(top.joined(separator: ", "))."
        }
        detail += " Keep the vents clear and give heavy tasks a break."
        return [PerformanceRecommendation(
            id: "thermal",
            category: .thermal,
            severity: .recommendation,
            title: "Your Mac is running hot",
            detail: detail,
            metrics: [sample.thermalState.performanceTitle],
            symbol: "thermometer.high",
            iconPath: nil,
            target: nil,
            actions: []
        )]
    }

    // MARK: - Restart

    private static func restartRecommendation(input: PerformanceAdvisorInput) -> PerformanceRecommendation? {
        guard let sample = input.sample, let bootDate = input.bootDate else { return nil }
        let uptime = input.now.timeIntervalSince(bootDate)
        guard uptime >= 14 * 86_400, sample.swapUsed >= 2 << 30 || sample.memoryPressure >= .warning else { return nil }
        return PerformanceRecommendation(
            id: "restart",
            category: .restart,
            severity: .recommendation,
            title: "Consider restarting your Mac",
            detail: "Your Mac has been running for \(DateFormatting.duration(uptime)) and is using \(PerformanceFormat.memory(sample.swapUsed)) of swap. A restart starts memory and swap from a clean slate; save your work first.",
            metrics: [DateFormatting.duration(uptime), "\(PerformanceFormat.memory(sample.swapUsed)) swap"],
            symbol: "arrow.clockwise",
            iconPath: nil,
            target: nil,
            actions: []
        )
    }

    // MARK: - Startup

    /// Number of your own launch agents from which startup activity is called out.
    static let manyLaunchAgents = 10

    /// Only shown when there are many agents; the Startup Activity card always shows the counts.
    private static func startupRecommendation(_ startup: PerformanceStartupSummary) -> PerformanceRecommendation? {
        let count = startup.userLaunchAgents
        guard count >= manyLaunchAgents else { return nil }
        var metrics = ["\(count) in your Library"]
        if let shared = startup.sharedLaunchAgents, let daemons = startup.launchDaemons {
            metrics.append("\(shared + daemons) for all users")
        }
        return PerformanceRecommendation(
            id: "startup",
            category: .startup,
            severity: .recommendation,
            title: "\(count) launch agents start when you log in",
            detail: "Launch agents start helper processes automatically. That's a lot of them: each adds work at login and can keep running in the background. Review them in Startup Items and turn off the ones you don't need.",
            metrics: metrics,
            symbol: "power.circle",
            iconPath: nil,
            target: nil,
            actions: [.openStartupItems]
        )
    }
}

/// Plain-language reading of memory pressure, compression and swap.
enum PerformanceMemoryInterpretation {
    struct Message: Sendable, Hashable {
        var title: String
        var detail: String
        var level: MemoryPressureLevel
    }

    static func message(for sample: PerformanceSample) -> Message {
        let swap = PerformanceFormat.memory(sample.swapUsed)
        let compressed = PerformanceFormat.memory(sample.memory.compressed)
        let activelySwapping = sample.swapOutPerSecond >= 1_000_000
        switch sample.memoryPressure {
        case .critical:
            return Message(
                title: "Your Mac is short on memory",
                detail: "macOS has compressed \(compressed) of memory and is relying on swap (\(swap) in use). Apps can pause or become slow. Quit apps you aren't using, starting with the largest ones below.",
                level: .critical
            )
        case .warning:
            return Message(
                title: "Memory is getting tight",
                detail: "macOS is compressing memory (\(compressed)) and may write some of it to disk as swap. Quitting an app you don't need would relieve the pressure.",
                level: .warning
            )
        case .normal:
            if activelySwapping {
                return Message(
                    title: "Memory is fine, with some swapping",
                    detail: "Pressure is normal, but macOS is writing memory to swap right now (\(ByteFormatting.rate(sample.swapOutPerSecond))). If this continues, quitting a large app will help.",
                    level: .normal
                )
            }
            if sample.swapUsed > 0 {
                return Message(
                    title: "Memory is fine",
                    detail: "The \(swap) of swap in use is left over from a busier moment. macOS clears it gradually; it isn't slowing your Mac down now.",
                    level: .normal
                )
            }
            return Message(
                title: "Memory is fine",
                detail: "Your Mac has enough memory for what's running. Memory shown as used includes caches macOS keeps on purpose to make apps faster.",
                level: .normal
            )
        }
    }
}
