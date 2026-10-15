import Darwin
import Foundation

/// A running process as seen through `libproc`.
struct ProcessSnapshot: Sendable, Hashable, Identifiable {
    var pid: pid_t
    var parentPID: pid_t
    var uid: uid_t
    var name: String
    var executablePath: String?
    /// Physical memory footprint (the "Memory" column in Activity Monitor), in bytes.
    var memoryFootprint: UInt64
    /// Total CPU time used since launch, in nanoseconds.
    var cpuTimeNanoseconds: UInt64
    var diskBytesRead: UInt64
    var diskBytesWritten: UInt64
    var startTime: Date?
    /// Energy impact proxy: total wakeups from idle, when available.
    var idleWakeups: UInt64
    /// `false` for processes of other users (or root): macOS doesn't let an
    /// unprivileged app read their memory, CPU time or disk activity.
    var usageAvailable: Bool = true

    var id: pid_t { pid }
    var isOwnedByCurrentUser: Bool { uid == getuid() }

    /// The `.app` bundle containing the executable, if any.
    var bundlePath: String? {
        guard let executablePath, let range = executablePath.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }
}

/// Reads process information and open files with public `libproc` calls.
/// Processes of other users can only be listed partially (no resource usage),
/// which is reported honestly rather than estimated.
enum ProcessInspector {
    /// Lists all processes visible to this user.
    static func allProcesses() -> [ProcessSnapshot] {
        listPIDs().compactMap(snapshot(pid:))
    }

    static func listPIDs() -> [pid_t] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    static func snapshot(pid: pid_t) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return limitedSnapshot(pid: pid)
        }

        var snapshot = ProcessSnapshot(
            pid: pid,
            parentPID: pid_t(info.pbi_ppid),
            uid: info.pbi_uid,
            name: name(of: pid, fallback: info),
            executablePath: executablePath(of: pid),
            memoryFootprint: 0,
            cpuTimeNanoseconds: 0,
            diskBytesRead: 0,
            diskBytesWritten: 0,
            startTime: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000),
            idleWakeups: 0
        )

        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if result == 0 {
            snapshot.memoryFootprint = usage.ri_phys_footprint
            snapshot.cpuTimeNanoseconds = machTimeToNanoseconds(usage.ri_user_time + usage.ri_system_time)
            snapshot.diskBytesRead = usage.ri_diskio_bytesread
            snapshot.diskBytesWritten = usage.ri_diskio_byteswritten
            snapshot.idleWakeups = usage.ri_pkg_idle_wkups
        } else {
            snapshot.usageAvailable = false
        }
        return snapshot
    }

    /// Name, owner and parent of a process whose full information isn't readable
    /// (another user's or root's). Resource usage is reported as unavailable.
    private static func limitedSnapshot(pid: pid_t) -> ProcessSnapshot? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        var name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(nulTerminated: buffer) : ""
        if name.isEmpty {
            name = withUnsafeBytes(of: info.pbsi_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return ProcessSnapshot(
            pid: pid, parentPID: pid_t(info.pbsi_ppid), uid: info.pbsi_uid, name: name,
            executablePath: executablePath(of: pid), memoryFootprint: 0, cpuTimeNanoseconds: 0,
            diskBytesRead: 0, diskBytesWritten: 0, startTime: nil, idleWakeups: 0, usageAvailable: false
        )
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(nulTerminated: buffer)
    }

    private static func name(of pid: pid_t, fallback info: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(nulTerminated: buffer)
            if !name.isEmpty { return name }
        }
        return withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// CPU times from `proc_pid_rusage` are in Mach absolute time units on Apple silicon.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func machTimeToNanoseconds(_ value: UInt64) -> UInt64 {
        let timebase = Self.timebase
        guard timebase.denom != 0 else { return value }
        return value / UInt64(timebase.denom) * UInt64(timebase.numer)
            + value % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    // MARK: - Open files

    /// Paths of files and folders currently open by this user's processes.
    static func openFiles() -> OpenFileIndex {
        var index = OpenFileIndex()
        let me = getuid()
        for pid in listPIDs() where pid != getpid() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
            let processName = name(of: pid, fallback: info)

            let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bufferSize > 0 else { continue }
            let capacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride + 16
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let used = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard used > 0 else { continue }
            let count = Int(used) / MemoryLayout<proc_fdinfo>.stride

            for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vnodeInfo = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, infoSize) == infoSize else { continue }
                let path = withUnsafeBytes(of: vnodeInfo.pvip.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if !path.isEmpty { index.add(path: path, process: processName, pid: pid) }
            }

            // The current working directory also keeps a folder "in use".
            var pathInfo = proc_vnodepathinfo()
            let pathInfoSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, pathInfoSize) == pathInfoSize {
                let cwd = withUnsafeBytes(of: pathInfo.pvi_cdir.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if !cwd.isEmpty, cwd != "/" { index.add(path: cwd, process: processName, pid: pid) }
            }
        }
        index.finalize()
        return index
    }
}

/// Sorted index of open file paths for fast "is anything inside this folder open?" queries.
struct OpenFileIndex: Sendable {
    struct Holder: Sendable, Hashable {
        var process: String
        var pid: pid_t
    }

    private var entries: [(path: String, holder: Holder)] = []

    mutating func add(path: String, process: String, pid: pid_t) {
        entries.append((PathUtilities.firmlinkCanonical(path), Holder(process: process, pid: pid)))
    }

    mutating func finalize() {
        entries.sort { $0.path < $1.path }
    }

    var count: Int { entries.count }

    /// Processes holding `path` or anything inside it open.
    func holders(of path: String) -> [Holder] {
        guard !entries.isEmpty else { return [] }
        // Binary search for the first entry >= path, then scan while the prefix matches.
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].path < path { low = mid + 1 } else { high = mid }
        }
        var result: [Holder] = []
        var index = low
        while index < entries.count, entries[index].path.hasPrefix(path) {
            if PathUtilities.isSameOrDescendant(entries[index].path, of: path), !result.contains(entries[index].holder) {
                result.append(entries[index].holder)
            }
            index += 1
        }
        return result
    }
}
