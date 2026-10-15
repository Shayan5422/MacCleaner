import Darwin
import Foundation

/// What a sampling pass should collect besides the always-collected system metrics.
struct PerformanceSampleRequest: Sendable, Hashable {
    enum ProcessDetail: Sendable, Hashable {
        /// No process list (the menu bar label only needs system totals).
        case none
        /// Processes macOS lets this app read (the current user's).
        case readable
        /// Readable processes plus other users' processes with limited information.
        case all
    }

    var processes: ProcessDetail = .none
    var battery = false
    var startupVolume = false
}

/// Result of one sampling pass.
struct PerformanceSamplerOutput: Sendable {
    /// nil for the first pass after a reset: rates need two readings.
    var sample: PerformanceSample?
    /// nil when processes weren't requested.
    var processes: [PerformanceProcess]?
    /// Processes owned by other users (mostly macOS itself) whose usage macOS doesn't reveal.
    var restrictedProcessCount: Int?
    /// True when the process list was (re)started in this pass, so per-process CPU isn't known yet.
    var processBaselineStarted: Bool
    var power: PerformancePowerReading?
    var startupVolume: VolumeInfo?
    var topology: PerformanceCPUTopology
}

/// Collects system metrics off the main thread.
///
/// The actor runs on its own serial dispatch queue rather than the shared Swift
/// concurrency pool, because every reading is a blocking system call. Previous
/// counter values (needed for rates) live here, so callers just ask for samples.
actor PerformanceSampler {
    private let queue: DispatchSerialQueue
    private let host: host_t
    private let pageSize: UInt64
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    private var cpu = PerformanceCPUReader()
    private var network = PerformanceNetworkReader()
    private var disk = PerformanceDiskReader()
    private var processes = PerformanceProcessTracker()
    private var lastUptime: UInt64?
    private var lastSwapCounters: (ins: UInt64, outs: UInt64)?
    /// Last successful memory reading, reused if a later `host_statistics64` call fails.
    private var lastMemory: PerformanceMemoryBreakdown?
    private var pressureFallback: PerformancePressureEventMonitor?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(label: String = "MacCleaner.PerformanceSampler") {
        queue = DispatchSerialQueue(label: label, qos: .utility)
        // One send right for the sampler's lifetime (each mach_host_self() call adds a reference).
        host = mach_host_self()
        pageSize = PerformanceMemoryReader.pageSize(host: host)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// Forgets previous readings; the next pass only records a baseline.
    func reset() {
        cpu.reset()
        network.reset()
        disk.reset()
        processes.reset()
        lastUptime = nil
        lastSwapCounters = nil
    }

    func sample(_ request: PerformanceSampleRequest) -> PerformanceSamplerOutput {
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed: TimeInterval? = lastUptime.flatMap { uptime > $0 ? Double(uptime - $0) / 1e9 : nil }
        lastUptime = uptime

        let cpuUsage = cpu.read(host: host)
        let networkDelta = network.read()
        let diskDelta = disk.read()
        let counters = PerformanceMemoryReader.vmCounters(host: host)
        let swap = PerformanceMemoryReader.swapUsage()
        let pressure = currentPressure()

        var swapInRate = 0.0
        var swapOutRate = 0.0
        if let counters {
            if let previous = lastSwapCounters, let elapsed, elapsed > 0 {
                swapInRate = Double(PerformanceCounterMath.delta(previous: previous.ins, current: counters.swapIns) &* pageSize) / elapsed
                swapOutRate = Double(PerformanceCounterMath.delta(previous: previous.outs, current: counters.swapOuts) &* pageSize) / elapsed
            }
            lastSwapCounters = (counters.swapIns, counters.swapOuts)
        }

        if let counters {
            lastMemory = .compute(
                pageSize: pageSize,
                totalBytes: physicalMemory,
                internalPages: counters.internalPages,
                purgeablePages: counters.purgeablePages,
                externalPages: counters.externalPages,
                wiredPages: counters.wiredPages,
                compressorPages: counters.compressorPages
            )
        }

        var sample: PerformanceSample?
        if let elapsed, elapsed > 0 {
            // host_statistics64 doesn't fail in practice; if it ever did before a first
            // success, the composition stays empty rather than guessed.
            let memory = lastMemory ?? PerformanceMemoryBreakdown(total: physicalMemory, app: 0, wired: 0, compressed: 0, cachedFiles: 0)
            let load = cpuUsage?.total ?? .idle
            sample = PerformanceSample(
                date: Date(),
                window: elapsed,
                cpuUsage: cpuUsage == nil ? 0 : min(1, load.busy),
                cpuUserUsage: cpuUsage == nil ? 0 : load.user,
                cpuSystemUsage: cpuUsage == nil ? 0 : load.system,
                perCoreUsage: cpuUsage?.perCore ?? [],
                loadAverage: PerformanceCPUReader.loadAverage(),
                memoryUsed: memory.used,
                memoryTotal: physicalMemory,
                memory: memory,
                memoryPressure: pressure,
                swapUsed: swap?.used ?? 0,
                swapTotal: swap?.total ?? 0,
                swapInPerSecond: swapInRate,
                swapOutPerSecond: swapOutRate,
                networkInPerSecond: networkDelta.map { Double($0.first) / elapsed } ?? 0,
                networkOutPerSecond: networkDelta.map { Double($0.second) / elapsed } ?? 0,
                diskReadPerSecond: diskDelta.map { Double($0.first) / elapsed } ?? 0,
                diskWritePerSecond: diskDelta.map { Double($0.second) / elapsed } ?? 0,
                thermalState: ProcessInfo.processInfo.thermalState
            )
        }

        var processList: [PerformanceProcess]?
        var restrictedCount: Int?
        var baselineStarted = false
        if request.processes == .none {
            processes.reset()
        } else {
            baselineStarted = !processes.hasBaseline
            let snapshots = ProcessInspector.allProcesses()
            var list = processes.update(snapshots: snapshots, uptime: uptime)
            let allPIDs = ProcessInspector.listPIDs().filter { $0 != 0 }
            let visible = Set(snapshots.map(\.pid))
            if request.processes == .all {
                let limited = processes.limitedProcesses(pids: allPIDs, excluding: visible)
                restrictedCount = limited.count
                list.append(contentsOf: limited)
            } else {
                restrictedCount = allPIDs.reduce(0) { $0 + (visible.contains($1) ? 0 : 1) }
            }
            processList = list
        }

        return PerformanceSamplerOutput(
            sample: sample,
            processes: processList,
            restrictedProcessCount: restrictedCount,
            processBaselineStarted: baselineStarted,
            power: request.battery ? PerformanceBatteryReader.read() : nil,
            startupVolume: request.startupVolume ? VolumeService.startupVolume() : nil,
            topology: PerformanceCPUTopologyReader.current
        )
    }

    private func currentPressure() -> MemoryPressureLevel {
        if let level = PerformanceMemoryReader.pressureLevel() { return level }
        if pressureFallback == nil {
            pressureFallback = PerformancePressureEventMonitor(queue: queue)
        }
        return pressureFallback?.current ?? .normal
    }

    // MARK: - One-off readings

    /// A complete reading without continuous monitoring: takes a baseline, waits
    /// `window`, and measures again. Uses its own sampler so it never disturbs the
    /// monitor's baselines.
    static func measure(window: Duration = .milliseconds(500)) async -> PerformanceSample {
        let sampler = PerformanceSampler(label: "MacCleaner.PerformanceSampler.oneShot")
        _ = await sampler.sample(PerformanceSampleRequest())
        try? await Task.sleep(for: window)
        // The second pass always has a baseline and a later uptime, so it yields a
        // sample; the loop only guards against a cancelled sleep leaving no time between passes.
        while true {
            if let sample = await sampler.sample(PerformanceSampleRequest()).sample { return sample }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
