import Darwin
import Foundation

/// One read of the Mac's sockets for the Connections tab.
struct NetConnectionScan: Sendable {
    let date: Date
    let connections: [NetConnection]
    /// macOS provided its system-wide socket lists (other users' and macOS's sockets are included).
    let kernelListAvailable: Bool
    let duration: TimeInterval

    static let empty = NetConnectionScan(date: .distantPast, connections: [], kernelListAvailable: false, duration: 0)
}

/// Reads every socket and attributes it to its process. Keeps the "first seen" date of each socket across scans
/// and a small per-process cache. Thread-safe; `scan()` blocks (syscalls), so call it off the main thread.
final class NetConnectionScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let currentUID: UInt32
    private let ownPID = getpid()
    /// endpoint|pid → when it was first seen. Pruned to the sockets of the latest scan.
    private var firstSeen: [String: Date] = [:]
    private var processCache: [PortProcessIdentity: NetProcessInfo] = [:]

    init(currentUID: UInt32 = PortSysProc.currentUID) {
        self.currentUID = currentUID
    }

    /// - Parameter includeOtherUsers: also list sockets of other users' and macOS's processes (from the kernel
    ///   lists). The current user's processes are always included.
    func scan(includeOtherUsers: Bool = true, now: Date = Date()) -> NetConnectionScan {
        let started = Date()
        let processes = PortSysProc.allProcesses()
        let table = PortProcessTable(processes: processes)
        let mine = currentUID == 0 ? processes : processes.filter { $0.uid == currentUID }
        let descriptor = NetSocketReader.descriptorSockets(of: mine)
        let kernel = NetSocketReader.kernelSockets()
        var records = NetSocketReader.merge(descriptor: descriptor, kernel: kernel)
        if !includeOtherUsers {
            records = records.filter { record in
                guard record.source == .kernelList else { return true }
                return table[record.pid].map { $0.uid == currentUID } ?? false
            }
        }

        var connections: [NetConnection] = []
        connections.reserveCapacity(records.count)
        var seenKeys = Set<String>()
        lock.lock()
        for record in records {
            let process = processInfo(pid: record.pid, table: table)
            let key = record.endpointKey + "|\(record.pid)"
            seenKeys.insert(key)
            let first = firstSeen[key] ?? now
            firstSeen[key] = first
            connections.append(NetConnection(record: record, process: process, firstSeen: first))
        }
        firstSeen = firstSeen.filter { seenKeys.contains($0.key) }
        processCache = processCache.filter { table.isAlive($0.key) }
        lock.unlock()

        return NetConnectionScan(date: now, connections: connections, kernelListAvailable: kernel != nil,
                                 duration: Date().timeIntervalSince(started))
    }

    /// Process facts for `pid`, cached per identity. Caller holds `lock`.
    private func processInfo(pid: Int32, table: PortProcessTable) -> NetProcessInfo {
        guard let basic = table[pid] else {
            return NetProcessInfo(pid: pid, startTime: 0, uid: UInt32.max, name: "Exited process", executablePath: nil,
                                  appBundlePath: nil, appName: nil, isCurrentUser: false, hasExited: true)
        }
        if let cached = processCache[basic.identity] { return cached }
        let path = PortSysProc.executablePath(pid: pid)
        let bundle = path.flatMap { PortClassifier.isApplicationExecutable($0) ? PortClassifier.appBundle(forExecutable: $0) : nil }
        let name: String
        if pid == ownPID {
            name = "Mac Cleaner"
        } else if let path, !path.isEmpty {
            name = (path as NSString).lastPathComponent
        } else {
            name = basic.comm
        }
        let info = NetProcessInfo(pid: pid, startTime: basic.startTime, uid: basic.uid, name: name, executablePath: path,
                                  appBundlePath: bundle?.bundlePath, appName: bundle?.name,
                                  isCurrentUser: basic.uid == currentUID, hasExited: false)
        processCache[basic.identity] = info
        return info
    }

    /// Remote endpoints of every active connection, for the Network Shield: the cheapest read available (the kernel
    /// lists; this user's descriptor tables when they are unavailable).
    func remoteEndpoints() -> (records: [NetSocketRecord], kernelListAvailable: Bool) {
        if let kernel = NetSocketReader.kernelSockets() {
            return (kernel.filter { $0.remoteAddress != nil }, true)
        }
        let processes = PortSysProc.allProcesses()
        let mine = currentUID == 0 ? processes : processes.filter { $0.uid == currentUID }
        return (NetSocketReader.descriptorSockets(of: mine).filter { $0.remoteAddress != nil }, false)
    }

    /// Process facts for one pid (the Shield's notifications).
    func processInfo(pid: Int32) -> NetProcessInfo {
        let table = PortProcessTable(processes: PortSysProc.basic(pid: pid).map { [$0] } ?? [])
        return lock.withLock { processInfo(pid: pid, table: table) }
    }
}
