import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
    /// A transparent, rule-based status for one area of the system (no invented "health score").
    struct HealthItem: Identifiable {
        enum Level: Int, Comparable {
            case good, attention, problem, unknown

            static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        var id: String
        var title: String
        var symbol: String
        var level: Level
        var detail: String
        var destination: AppSection
    }

    let services: AppServices
    let monitor: PerformanceMonitor
    var navigate: ((AppSection) -> Void)?
    var startSmartScan: (() -> Void)?

    private(set) var volume: VolumeInfo?
    private(set) var posture: SecurityPosture?
    private(set) var recentEntries: [CleanupHistoryEntry] = []
    private(set) var totalCleaned: Int64 = 0
    private(set) var isLoadingPosture = false

    let systemDescription: String

    init(services: AppServices, monitor: PerformanceMonitor) {
        self.services = services
        self.monitor = monitor
        systemDescription = Self.describeSystem()
    }

    func appear() {
        monitor.acquire()
        Task { await refresh() }
    }

    func disappear() {
        monitor.release()
    }

    func refresh() async {
        volume = VolumeService.startupVolume()
        services.permissions.refresh()
        let entries = await services.history.allEntries()
        recentEntries = Array(entries.prefix(5))
        totalCleaned = entries.filter { !$0.dryRun }.reduce(0) { $0 + $1.bytes }
        if posture == nil {
            isLoadingPosture = true
            posture = await SecurityPostureChecker.check()
            isLoadingPosture = false
        }
    }

    // MARK: - Health

    var healthItems: [HealthItem] {
        [storageHealth, memoryHealth, securityHealth, junkHealth]
    }

    var attentionCount: Int {
        healthItems.filter { $0.level == .attention || $0.level == .problem }.count
    }

    private var storageHealth: HealthItem {
        guard let volume else {
            return HealthItem(id: "storage", title: "Storage", symbol: "internaldrive", level: .unknown, detail: "Couldn't read the startup disk.", destination: .storage)
        }
        let free = volume.effectiveAvailable
        let fraction = Double(free) / Double(max(volume.totalCapacity, 1))
        let level: HealthItem.Level = fraction < 0.05 || free < 5_000_000_000 ? .problem : (fraction < 0.12 || free < 15_000_000_000 ? .attention : .good)
        let detail = "\(ByteFormatting.string(free)) available of \(ByteFormatting.string(volume.totalCapacity))"
        return HealthItem(id: "storage", title: "Storage", symbol: "internaldrive", level: level, detail: detail, destination: .storage)
    }

    private var memoryHealth: HealthItem {
        guard let sample = monitor.latest else {
            return HealthItem(id: "memory", title: "Memory", symbol: "memorychip", level: .unknown, detail: "Measuring…", destination: .performance)
        }
        let level: HealthItem.Level
        switch sample.memoryPressure {
        case .normal: level = .good
        case .warning: level = .attention
        case .critical: level = .problem
        }
        return HealthItem(id: "memory", title: "Memory", symbol: "memorychip", level: level,
                          detail: "Memory pressure is \(sample.memoryPressure.title.lowercased())", destination: .performance)
    }

    private var securityHealth: HealthItem {
        guard let posture else {
            return HealthItem(id: "security", title: "Security", symbol: "lock.shield", level: .unknown,
                              detail: isLoadingPosture ? "Checking protections…" : "Not checked", destination: .security)
        }
        let checks = [posture.gatekeeperEnabled, posture.sipEnabled, posture.fileVaultEnabled, posture.firewallEnabled]
        let known = checks.compactMap { $0 }
        let off = known.filter { !$0 }.count
        let level: HealthItem.Level = known.isEmpty ? .unknown : (off == 0 ? .good : (posture.gatekeeperEnabled == false || posture.sipEnabled == false ? .problem : .attention))
        let detail = known.isEmpty ? "Couldn't read protection status" : (off == 0 ? "All \(known.count) protections are on" : "\(off) of \(known.count) protections \(off == 1 ? "is" : "are") off")
        return HealthItem(id: "security", title: "Security", symbol: "lock.shield", level: level, detail: detail, destination: .security)
    }

    private var junkHealth: HealthItem {
        guard let date = services.settings.lastSmartScanDate else {
            return HealthItem(id: "junk", title: "Cleanup", symbol: "sparkles", level: .unknown, detail: "Run Smart Scan to see what can be cleaned", destination: .smartScan)
        }
        let bytes = services.settings.lastSmartScanReclaimable
        let level: HealthItem.Level = bytes > 10_000_000_000 ? .attention : .good
        return HealthItem(id: "junk", title: "Cleanup", symbol: "sparkles", level: level,
                          detail: "\(ByteFormatting.string(bytes)) found \(DateFormatting.relative(date))", destination: .smartScan)
    }

    // MARK: - System description

    private static func describeSystem() -> String {
        var parts: [String] = []
        let version = ProcessInfo.processInfo.operatingSystemVersion
        parts.append("macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""))
        if let chip = sysctlString("machdep.cpu.brand_string") { parts.append(chip) }
        parts.append(ByteFormatting.memory(ProcessInfo.processInfo.physicalMemory) + " memory")
        parts.append("up \(DateFormatting.duration(ProcessInfo.processInfo.systemUptime))")
        return parts.joined(separator: " · ")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(nulTerminated: buffer)
    }
}
