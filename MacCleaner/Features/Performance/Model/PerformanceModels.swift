import Darwin
import Foundation
import SwiftUI

// MARK: - Memory pressure

/// System-wide memory pressure as reported by the kernel. Memory pressure — not
/// the amount of "free" memory — tells whether a Mac has enough memory.
enum MemoryPressureLevel: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
    case normal = 1
    case warning = 2
    case critical = 4

    /// Maps the value of `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical).
    init(kernelLevel: Int) {
        switch kernelLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    /// One-sentence, plain-language meaning.
    var explanation: String {
        switch self {
        case .normal: return "Your Mac has enough memory for what's running."
        case .warning: return "Memory is getting tight: macOS is compressing memory and may start using swap."
        case .critical: return "Your Mac is short on memory. Apps can pause or slow down until memory is freed."
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Samples

/// Memory composition computed like Activity Monitor.
struct PerformanceMemoryBreakdown: Sendable, Hashable {
    /// Installed physical memory.
    var total: UInt64
    /// Anonymous memory used by apps and processes (internal pages minus purgeable pages).
    var app: UInt64
    /// Memory the kernel keeps resident and can't compress or page out.
    var wired: UInt64
    /// Physical memory occupied by the compressor (compressed pages of apps).
    var compressed: UInt64
    /// File-backed pages and purgeable memory macOS can reclaim instantly.
    var cachedFiles: UInt64

    /// "Memory Used" in Activity Monitor: app + wired + compressed.
    var used: UInt64 { min(total, app &+ wired &+ compressed) }

    /// Memory not used for anything right now.
    var free: UInt64 {
        let occupied = used &+ cachedFiles
        return total > occupied ? total - occupied : 0
    }

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// 1, 5 and 15 minute load averages (runnable threads, not a percentage).
struct PerformanceLoadAverage: Sendable, Hashable {
    var oneMinute: Double
    var fiveMinutes: Double
    var fifteenMinutes: Double
}

/// One reading of system-wide activity. Rates and CPU usage cover the
/// `window` seconds before `date`.
struct PerformanceSample: Sendable, Hashable, Identifiable {
    var date: Date
    /// Length of the measurement window, in seconds.
    var window: TimeInterval

    /// Total CPU usage across all cores, 0...1.
    var cpuUsage: Double
    /// User (including nice) and system shares of all CPU time, 0...1.
    var cpuUserUsage: Double
    var cpuSystemUsage: Double
    /// Usage of each logical core, 0...1, in kernel CPU order. Empty if the CPU couldn't be read.
    var perCoreUsage: [Double]
    var loadAverage: PerformanceLoadAverage?

    /// "Memory Used" (app + wired + compressed), in bytes.
    var memoryUsed: UInt64
    /// Installed physical memory, in bytes.
    var memoryTotal: UInt64
    var memory: PerformanceMemoryBreakdown
    var memoryPressure: MemoryPressureLevel
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// Data read back from swap / written to swap, in bytes per second.
    var swapInPerSecond: Double
    var swapOutPerSecond: Double

    /// Bytes per second over physical network interfaces.
    var networkInPerSecond: Double
    var networkOutPerSecond: Double
    /// Bytes per second over physical disks (disk images are excluded to avoid double counting).
    var diskReadPerSecond: Double
    var diskWritePerSecond: Double

    var thermalState: ProcessInfo.ThermalState

    var id: Date { date }
    var memoryUsedFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    /// False in the (unexpected) case the kernel refused the CPU statistics request.
    var isCPUAvailable: Bool { !perCoreUsage.isEmpty }
}

// MARK: - Processes

/// A process with its recent resource usage.
struct PerformanceProcess: Sendable, Hashable, Identifiable {
    var pid: pid_t
    var parentPID: pid_t?
    var uid: uid_t
    var userName: String
    var name: String
    var executablePath: String?
    /// Outermost `.app` bundle containing the executable (helpers resolve to their app).
    var appBundlePath: String?
    var startTime: Date?
    /// Physical memory footprint ("Memory" in Activity Monitor). nil when macOS doesn't allow reading it.
    var memoryFootprint: UInt64?
    /// CPU used during the last sampling window; 1.0 is one fully busy core. nil until measured.
    var cpu: Double?
    /// Average CPU over the recent past (up to about 30 seconds); 1.0 is one core.
    var recentCPU: Double?
    /// Seconds covered by `recentCPU`.
    var recentCPUWindow: TimeInterval
    var isCurrentUser: Bool
    /// False for other users' processes: macOS only reveals their name, owner and path.
    var hasUsageInfo: Bool

    var id: pid_t { pid }

    /// True when the process has kept at least `threshold` of a core busy for `minimumWindow` seconds.
    func isSustainedCPU(atLeast threshold: Double, minimumWindow: TimeInterval = 20) -> Bool {
        guard let recentCPU, recentCPUWindow >= minimumWindow else { return false }
        return recentCPU >= threshold
    }
}

// MARK: - CPU topology

/// Logical CPU layout. Core kinds are only provided when the kernel's CPU
/// numbering could be matched to the hardware description.
struct PerformanceCPUTopology: Sendable, Hashable {
    enum CoreKind: String, Sendable, Hashable {
        case performance, efficiency

        var shortLabel: String { self == .performance ? "P" : "E" }
    }

    var logicalCoreCount: Int
    var performanceCoreCount: Int?
    var efficiencyCoreCount: Int?
    /// Kind of each logical CPU in `host_processor_info` order; nil when not verifiable.
    var coreKinds: [CoreKind]?

    func kind(ofCore index: Int) -> CoreKind? {
        guard let coreKinds, coreKinds.indices.contains(index) else { return nil }
        return coreKinds[index]
    }

    /// "P3", "E1", or "Core 5" when the kind isn't known.
    func label(forCore index: Int) -> String {
        guard let kinds = coreKinds, kinds.indices.contains(index) else { return "Core \(index + 1)" }
        let kind = kinds[index]
        let ordinal = kinds[...index].filter { $0 == kind }.count
        return "\(kind.shortLabel)\(ordinal)"
    }

    /// "10 performance + 4 efficiency cores" or "8 cores".
    var summary: String {
        if let performanceCoreCount, let efficiencyCoreCount, performanceCoreCount + efficiencyCoreCount > 0 {
            return "\(performanceCoreCount) performance + \(efficiencyCoreCount) efficiency cores"
        }
        return "\(logicalCoreCount) core\(logicalCoreCount == 1 ? "" : "s")"
    }
}

// MARK: - Battery

/// Internal battery details from IOKit power sources and the battery's registry entry.
struct PerformanceBattery: Sendable, Hashable {
    enum PowerSource: String, Sendable, Hashable {
        case powerAdapter, battery, ups, unknown

        var title: String {
            switch self {
            case .powerAdapter: return "Power Adapter"
            case .battery: return "Battery"
            case .ups: return "UPS"
            case .unknown: return "Unknown"
            }
        }
    }

    /// Charge level, 0...1.
    var level: Double?
    var isCharging: Bool
    var isCharged: Bool
    var powerSource: PowerSource
    /// Estimated time until empty or full, in seconds; nil while macOS is still calculating.
    var timeToEmpty: TimeInterval?
    var timeToFull: TimeInterval?
    var cycleCount: Int?
    /// Capacities in mAh.
    var designCapacity: Int?
    var fullChargeCapacity: Int?
    /// macOS' own condition summary ("Good", "Check Battery", "Service Recommended"…), when provided.
    var condition: String?
    /// Battery (not CPU) temperature, in °C.
    var temperatureCelsius: Double?
    var optimizedChargingEngaged: Bool?

    /// Full-charge capacity relative to the design capacity.
    var healthFraction: Double? {
        guard let designCapacity, designCapacity > 0, let fullChargeCapacity, fullChargeCapacity > 0 else { return nil }
        return Double(fullChargeCapacity) / Double(designCapacity)
    }
}

/// Battery details plus where power currently comes from.
struct PerformancePowerReading: Sendable, Hashable {
    var battery: PerformanceBatteryStatus
    /// The source currently powering the Mac (AC, battery or UPS).
    var source: PerformanceBattery.PowerSource
}

enum PerformanceBatteryStatus: Sendable, Hashable {
    /// Not read yet.
    case unknown
    /// Desktop Macs (and Macs whose battery was removed).
    case noBattery
    case present(PerformanceBattery)

    var battery: PerformanceBattery? {
        if case .present(let battery) = self { return battery }
        return nil
    }
}

// MARK: - Thermal state

extension ProcessInfo.ThermalState {
    var performanceTitle: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var performanceExplanation: String {
        switch self {
        case .nominal: return "Temperatures are within normal limits."
        case .fair: return "Slightly elevated. macOS may reduce background work to keep things cool."
        case .serious: return "High. macOS is reducing performance to cool your Mac down."
        case .critical: return "Very high. macOS is reducing performance significantly. Give your Mac a break and keep its vents clear."
        @unknown default: return "macOS reported a thermal state Mac Cleaner doesn't recognize."
        }
    }

    var performanceTint: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    var performanceSymbol: String {
        switch self {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious, .critical: return "thermometer.high"
        @unknown default: return "thermometer.medium"
        }
    }
}
