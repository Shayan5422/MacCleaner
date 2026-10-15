import Darwin
import Foundation

/// Turns successive `ProcessInspector` snapshots into per-process CPU usage
/// (from CPU-time deltas) and recent averages. Not thread-safe; owned by
/// `PerformanceSampler`.
struct PerformanceProcessTracker {
    /// pid plus start time, so a recycled pid is never mistaken for the old process.
    private struct Key: Hashable {
        var pid: pid_t
        var startMicroseconds: Int64
    }

    private struct State {
        var uptime: UInt64
        var cpuTime: UInt64
        var window: PerformanceCPUWindow
        var appBundlePath: String?
        var displayName: String
    }

    private var states: [Key: State] = [:]
    private var userNames: [uid_t: String] = [:]
    private let currentUser = getuid()

    init() {}

    var hasBaseline: Bool { !states.isEmpty }

    mutating func reset() {
        states.removeAll(keepingCapacity: true)
    }

    /// Current user's processes (and any others `ProcessInspector` could read) with
    /// CPU usage since the previous call. CPU is nil for processes seen for the first time.
    mutating func update(snapshots: [ProcessSnapshot], uptime: UInt64) -> [PerformanceProcess] {
        var next: [Key: State] = [:]
        next.reserveCapacity(snapshots.count)
        var result: [PerformanceProcess] = []
        result.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let key = Key(pid: snapshot.pid, startMicroseconds: Self.microseconds(snapshot.startTime))
            let hasUsage = snapshot.memoryFootprint > 0 || snapshot.cpuTimeNanoseconds > 0
            var state = states[key] ?? State(
                uptime: uptime,
                cpuTime: snapshot.cpuTimeNanoseconds,
                window: PerformanceCPUWindow(),
                appBundlePath: snapshot.executablePath.flatMap(Self.outermostAppBundle),
                displayName: Self.displayName(for: snapshot)
            )
            var cpu: Double?
            if states[key] != nil, hasUsage, uptime > state.uptime, snapshot.cpuTimeNanoseconds >= state.cpuTime {
                cpu = Double(snapshot.cpuTimeNanoseconds - state.cpuTime) / Double(uptime - state.uptime)
            }
            var recent: PerformanceCPUWindow.Average?
            if hasUsage {
                recent = state.window.add(.init(uptime: uptime, cpuTime: snapshot.cpuTimeNanoseconds))
            }
            state.uptime = uptime
            state.cpuTime = snapshot.cpuTimeNanoseconds
            next[key] = state

            result.append(PerformanceProcess(
                pid: snapshot.pid,
                parentPID: snapshot.parentPID > 0 ? snapshot.parentPID : nil,
                uid: snapshot.uid,
                userName: userName(for: snapshot.uid),
                name: state.displayName,
                executablePath: snapshot.executablePath,
                appBundlePath: state.appBundlePath,
                startTime: snapshot.startTime,
                memoryFootprint: hasUsage ? snapshot.memoryFootprint : nil,
                cpu: cpu,
                recentCPU: recent?.fraction,
                recentCPUWindow: recent?.covered ?? 0,
                isCurrentUser: snapshot.uid == currentUser,
                hasUsageInfo: hasUsage
            ))
        }
        states = next
        return result
    }

    /// Other users' processes (mostly macOS' own), which `ProcessInspector` can't read:
    /// only pid, owner, name and path are available.
    mutating func limitedProcesses(pids: [pid_t], excluding visible: Set<pid_t>) -> [PerformanceProcess] {
        var result: [PerformanceProcess] = []
        for pid in pids where !visible.contains(pid) {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            // The current user's processes missing from the snapshot just started or exited.
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid != currentUser else { continue }
            let path = ProcessInspector.executablePath(of: pid)
            let shortName = withUnsafeBytes(of: info.pbsi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let name = path.map { ($0 as NSString).lastPathComponent } ?? shortName
            result.append(PerformanceProcess(
                pid: pid,
                parentPID: info.pbsi_ppid > 0 ? pid_t(info.pbsi_ppid) : nil,
                uid: info.pbsi_uid,
                userName: userName(for: info.pbsi_uid),
                name: name.isEmpty ? "Process \(pid)" : name,
                executablePath: path,
                appBundlePath: path.flatMap(Self.outermostAppBundle),
                startTime: nil,
                memoryFootprint: nil,
                cpu: nil,
                recentCPU: nil,
                recentCPUWindow: 0,
                isCurrentUser: info.pbsi_uid == currentUser,
                hasUsageInfo: false
            ))
        }
        return result
    }

    // MARK: - Helpers

    private mutating func userName(for uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        var name = "\(uid)"
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        if getpwuid_r(uid, &record, &buffer, buffer.count, &result) == 0, result != nil, let raw = record.pw_name {
            let decoded = String(validatingCString: raw) ?? ""
            if !decoded.isEmpty { name = decoded }
        }
        userNames[uid] = name
        return name
    }

    private static func microseconds(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// `proc_name` truncates long names to 32 characters; prefer the executable's file name then.
    private static func displayName(for snapshot: ProcessSnapshot) -> String {
        let name = snapshot.name
        guard let path = snapshot.executablePath else { return name.isEmpty ? "Process \(snapshot.pid)" : name }
        let fileName = (path as NSString).lastPathComponent
        if name.isEmpty { return fileName }
        if fileName.count > name.count, fileName.hasPrefix(name) { return fileName }
        return name
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper" → "/Applications/Foo.app".
    static func outermostAppBundle(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
