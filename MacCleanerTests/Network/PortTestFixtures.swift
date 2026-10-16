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

/// Every suite that starts processes or opens sockets runs inside this one, one test at a time: they all see the
/// same process table, so one test's server closing would otherwise show up in another test's scan.
@Suite(.serialized) enum PortLiveProcessTests {}
