import Foundation
import Testing
@testable import MacCleaner

/// Synthetic listeners and groups for the Ports tests (ported from PortPilot's UIFixtures). Pure values: nothing
/// here inspects or signals real processes.
enum PortUIFixtures {
    static func process(pid: Int32, name: String = "node server.js", ports: [UInt16] = [3000],
                        category: PortListenerCategory = .project, uid: UInt32 = 501, restricted: Bool = false,
                        cpu: Double = 0.4, memory: UInt64 = 48_000_000, project: PortProjectInfo? = nil,
                        manager: PortProcessManager = .none, address: String = "127.0.0.1") -> PortListenerProcess {
        let basic = PortProcessBasic(pid: pid, ppid: 1, pgid: pid, uid: uid, comm: String(name.prefix(16)),
                                     startTime: 1_760_000_000_000_000 + UInt64(pid))
        let details = restricted ? nil : PortProcessDetails(identity: basic.identity, executablePath: "/opt/homebrew/bin/node",
                                                            arguments: name.split(separator: " ").map(String.init),
                                                            environment: [:], cwd: project?.rootPath ?? "/")
        let sockets = ports.map { PortListeningSocket(port: $0, address: address, family: .ipv4, pid: pid) }
        let usage = PortResourceUsage(cpuPercent: cpu, memoryBytes: memory)
        return PortListenerProcess(basic: basic, details: details, sockets: sockets, usage: usage, treeUsage: usage,
                                   category: category, project: project, displayName: name, frameworks: [],
                                   origin: nil, manager: manager, appName: nil, isRestricted: restricted)
    }

    static func group(id: String, category: PortListenerCategory, title: String, subtitle: String? = nil,
                      path: String? = nil, processes: [PortListenerProcess]) -> PortListenerGroup {
        PortListenerGroup(id: id, category: category, title: title, subtitle: subtitle, path: path, processes: processes)
    }

    static func output(_ groups: [PortListenerGroup], plans: [PortProcessIdentity: PortKillPlan] = [:]) -> PortScanOutput {
        PortScanOutput(snapshot: PortScanSnapshot(date: Date(), groups: groups, table: .empty, duration: 0, restrictedCount: 0),
                       plans: plans)
    }

    /// Settings in a throwaway defaults suite, so tests never read or write the person's own.
    @MainActor
    static func preferences(_ configure: (NetworkPreferences) -> Void = { _ in }) -> NetworkPreferences {
        let suite = "com.maccleaner.network.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = NetworkPreferences(defaults: defaults)
        configure(preferences)
        return preferences
    }

    /// A Ports model that never scans, posts or notifies outside the test.
    @MainActor
    static func model(_ groups: [PortListenerGroup] = [], preferences: NetworkPreferences? = nil,
                      eventLog: ProtectionEventLog = ProtectionEventLog(directory: nil),
                      engine: PortScanEngine? = nil) -> PortsModel {
        let model = PortsModel(preferences: preferences ?? self.preferences(), eventLog: eventLog,
                               engine: engine ?? PortScanEngine(resolver: PortProjectResolver(fileExists: { _ in false },
                                                                                              readFile: { _ in nil })),
                               pm2: PortPM2Commands(stop: { _ in }, delete: { _, _ in .notSaved }),
                               initial: groups.isEmpty ? nil : output(groups))
        model.allowsAutomaticPolling = false
        return model
    }
}

/// A settable clock for code that takes `now: @Sendable () -> Date`.
final class PortTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A test can't run its scenario (a missing tool, a failed spawn). Thrown so the test fails with the reason.
struct PortTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Cancels the running test when the server it started is up but this session can't watch it: something
/// accepts connections on `port`, the kernel's listener list says one of `processes` owns it, yet that
/// process's descriptors don't show the socket. GitHub's macOS runners hide them for the Python the tests
/// start (a node server is visible there, and on a Mac in a user session both are), so the tests that
/// watch servers can't observe anything there. A server that really failed to start still fails the test.
func cancelIfServerCantBeWatched(port: UInt16, processes: [PortProcessBasic]) throws {
    guard portAcceptsConnections(port), let listeners = PortSysProc.systemTCPListeners() else { return }
    let owners = Set(listeners.filter { $0.port == port }.map(\.pid))
    let hidden = processes.contains { process in
        owners.contains(process.pid)
            && PortSysProc.listeningTCPSockets(pid: process.pid)?.contains(where: { $0.port == port }) != true
    }
    guard hidden else { return }
    try Test.cancel("The server listens on :\(port), but this session can't read its process's descriptors, so the test can't watch it")
}

/// Whether something accepts TCP connections on 127.0.0.1:`port` within `timeout`.
func portAcceptsConnections(_ port: UInt16, timeout: TimeInterval = 2) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let started = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if started == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&descriptor, 1, Int32(timeout * 1000)) == 1 else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
}

/// For a server that never showed up: whether anything accepts connections on `port`, what the kernel's
/// listener list says about it, and which of `processes` (the test's own) are still running.
func portVisibilityReport(port: UInt16, processes: [PortProcessBasic]) -> String {
    var parts: [String] = []
    parts.append(portAcceptsConnections(port) ? "127.0.0.1:\(port) accepts connections" : "nothing accepts connections on 127.0.0.1:\(port)")
    if let listeners = PortSysProc.systemTCPListeners() {
        let owners = listeners.filter { $0.port == port }.map { String($0.pid) }
        parts.append(owners.isEmpty ? "the kernel's listener list (\(listeners.count) sockets) has nothing on it"
                                    : "the kernel's listener list shows it owned by pid \(owners.joined(separator: ", "))")
    } else {
        parts.append("the kernel's listener list can't be read")
    }
    let running = processes.map { "\($0.pid) \($0.comm)" }
    parts.append(running.isEmpty ? "none of the test's processes is running" : "running: " + running.joined(separator: ", "))
    return parts.joined(separator: "; ")
}

/// Every suite that starts processes or opens sockets runs inside this one, one test at a time: they all see the
/// same process table, so one test's server closing would otherwise show up in another test's scan.
@Suite(.serialized) enum PortLiveProcessTests {}
