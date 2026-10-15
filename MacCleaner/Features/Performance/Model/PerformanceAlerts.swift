import Foundation

/// Value snapshot of the alert settings, so evaluation never reads UI state.
struct PerformanceAlertSettings: Sendable, Hashable {
    var enabled: Bool
    /// Total CPU usage (0...1) that must be exceeded for `PerformanceAlertEvaluator.sustainedCPUDuration`.
    var cpuThreshold: Double
    var memoryPressureAlerts: Bool
    /// Alert when free space on the startup disk drops below this many bytes; nil turns it off.
    var lowDiskThresholdBytes: Int64?
    /// Longer gaps between samples (monitoring paused) restart the "sustained" timer.
    var maximumSampleGap: TimeInterval

    init(enabled: Bool, cpuThreshold: Double, memoryPressureAlerts: Bool, lowDiskThresholdBytes: Int64?, maximumSampleGap: TimeInterval) {
        self.enabled = enabled
        self.cpuThreshold = cpuThreshold
        self.memoryPressureAlerts = memoryPressureAlerts
        self.lowDiskThresholdBytes = lowDiskThresholdBytes
        self.maximumSampleGap = maximumSampleGap
    }

    @MainActor
    init(settings: SettingsManager, refreshInterval: TimeInterval) {
        // The threshold is stored as a fraction (0.9); accept percentages defensively.
        var threshold = settings.cpuAlertThreshold
        if threshold > 1 { threshold /= 100 }
        self.init(
            enabled: settings.performanceAlertsEnabled,
            cpuThreshold: min(1, max(0.05, threshold)),
            memoryPressureAlerts: settings.memoryPressureAlerts,
            lowDiskThresholdBytes: settings.lowDiskAlertGB > 0 ? Int64(settings.lowDiskAlertGB) * 1_000_000_000 : nil,
            maximumSampleGap: max(15, refreshInterval * 3)
        )
    }
}

/// Facts used to make alert messages specific.
struct PerformanceAlertContext: Sendable, Hashable {
    struct BusyProcess: Sendable, Hashable {
        var name: String
        /// 1.0 = one core.
        var cpu: Double
    }

    struct LargeApp: Sendable, Hashable {
        var name: String
        var bytes: UInt64
    }

    var busiestProcess: BusyProcess?
    var largestApp: LargeApp?
    var startupVolumeName: String?
    /// Free space on the startup disk, including purgeable space macOS frees on demand.
    var startupVolumeAvailable: Int64?

    init(busiestProcess: BusyProcess? = nil, largestApp: LargeApp? = nil, startupVolumeName: String? = nil, startupVolumeAvailable: Int64? = nil) {
        self.busiestProcess = busiestProcess
        self.largestApp = largestApp
        self.startupVolumeName = startupVolumeName
        self.startupVolumeAvailable = startupVolumeAvailable
    }
}

struct PerformanceAlert: Sendable, Hashable {
    var kind: PerformanceAlertKind
    var title: String
    var body: String
}

/// Decides when to notify about sustained high CPU, critical memory pressure and a
/// nearly full startup disk, with one notification per kind every 30 minutes at most.
/// Alerts can only be evaluated while monitoring runs (Performance page or menu bar
/// monitor open), because Mac Cleaner doesn't sample in the background.
struct PerformanceAlertEvaluator: Sendable {
    static let sustainedCPUDuration: TimeInterval = 60

    private(set) var throttle: PerformanceAlertThrottle
    private var highCPU = PerformanceSustainedCondition(requiredDuration: PerformanceAlertEvaluator.sustainedCPUDuration)
    private var lastSampleDate: Date?

    init(throttle: PerformanceAlertThrottle = PerformanceAlertThrottle()) {
        self.throttle = throttle
    }

    /// Forgets partial observations (call when monitoring stops).
    mutating func resetObservations() {
        highCPU.reset()
        lastSampleDate = nil
    }

    mutating func evaluate(sample: PerformanceSample, settings: PerformanceAlertSettings, context: PerformanceAlertContext) -> [PerformanceAlert] {
        defer { lastSampleDate = sample.date }
        guard settings.enabled else {
            highCPU.reset()
            return []
        }
        if let lastSampleDate, sample.date.timeIntervalSince(lastSampleDate) > settings.maximumSampleGap || sample.date < lastSampleDate {
            // Monitoring was paused; we can't claim the CPU stayed busy in between.
            highCPU.reset()
        }

        var alerts: [PerformanceAlert] = []
        let now = sample.date

        let cpuSustained = sample.isCPUAvailable && highCPU.update(isMet: sample.cpuUsage >= settings.cpuThreshold, at: now)
        if cpuSustained, throttle.shouldFire(.highCPU, at: now) {
            var body = "CPU usage has stayed above \(NumberFormatting.percent(settings.cpuThreshold)) for more than a minute."
            if let busiest = context.busiestProcess {
                body += " \(busiest.name) is using the most (\(PerformanceFormat.coreShare(busiest.cpu)) of a core)."
            }
            body += " Open Performance to see what's running."
            alerts.append(PerformanceAlert(kind: .highCPU, title: "Your Mac has been busy for a while", body: body))
        }

        if settings.memoryPressureAlerts, sample.memoryPressure == .critical, throttle.shouldFire(.memoryPressure, at: now) {
            var body = "Your Mac is running low on memory, so apps may slow down."
            if let largest = context.largestApp {
                body += " \(largest.name) is using \(PerformanceFormat.memory(largest.bytes))."
            }
            body += " Quitting apps you aren't using will help."
            alerts.append(PerformanceAlert(kind: .memoryPressure, title: "Memory pressure is critical", body: body))
        }

        if let limit = settings.lowDiskThresholdBytes, let available = context.startupVolumeAvailable, available < limit,
           throttle.shouldFire(.lowDisk, at: now) {
            let name = context.startupVolumeName ?? "your startup disk"
            alerts.append(PerformanceAlert(
                kind: .lowDisk,
                title: "Your startup disk is almost full",
                body: "Only \(ByteFormatting.string(max(0, available))) is available on \(name). macOS needs free space to run smoothly."
            ))
        }
        return alerts
    }
}

/// Formatting shared by the Performance views and notifications.
enum PerformanceFormat {
    /// Memory sizes in binary units, like Activity Monitor (64 GiB of RAM reads "64 GB").
    /// Disk sizes and transfer rates keep the app's decimal units, like Finder.
    static func memory(_ bytes: UInt64) -> String {
        ByteFormatting.string(Int64(clamping: bytes), style: .memory)
    }

    /// Swap in use; "None" instead of "Zero KB".
    static func swap(_ bytes: UInt64) -> String {
        bytes == 0 ? "None" : memory(bytes)
    }

    /// Share of one core, Activity Monitor style ("152%").
    static func coreShare(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// "12.5" — percent of one core with one decimal, for tables.
    static func cpuColumn(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return (fraction * 100).formatted(.number.precision(.fractionLength(1)))
    }
}
