import Foundation
import Observation

/// The app's single source of live performance data, shared by the Performance
/// page, the menu bar extra and the Dashboard.
///
/// Sampling only runs while someone holds the monitor (`acquire()` / `release()`,
/// reference counted), so nothing runs in the background when no monitoring UI is
/// visible. Readings are taken off the main thread by `PerformanceSampler`; state
/// is published on the main actor. Performance alerts are evaluated with every
/// sample, which means they only fire while monitoring is active.
@MainActor
@Observable
final class PerformanceMonitor {
    /// Refresh intervals offered in the UI, in seconds.
    static let supportedIntervals: [TimeInterval] = [1, 2, 5, 10]
    /// How much history is kept.
    static let historyDuration: TimeInterval = 15 * 60

    // MARK: - Published state

    /// Most recent reading, nil until the first measurement completes.
    private(set) var latest: PerformanceSample?
    /// Readings of this session (oldest first), bounded to the last 15 minutes.
    private(set) var history: [PerformanceSample] = []
    /// Processes from the last sample. Empty unless a process-list client (the
    /// Performance page or the menu bar popover) holds the monitor.
    private(set) var processes: [PerformanceProcess] = []
    /// True once per-process CPU has been measured (two process readings).
    private(set) var processesMeasured = false
    /// When the current process list started being collected (per-process averages need ~30 s).
    private(set) var processTrackingStarted: Date?
    /// Processes of other users (mostly macOS) whose resource usage macOS doesn't reveal.
    private(set) var restrictedProcessCount: Int?
    private(set) var battery: PerformanceBatteryStatus = .unknown
    /// Where power comes from (AC, battery or UPS); nil until read.
    private(set) var powerSource: PerformanceBattery.PowerSource?
    private(set) var startupVolume: VolumeInfo?
    private(set) var topology: PerformanceCPUTopology = PerformanceCPUTopology(
        logicalCoreCount: ProcessInfo.processInfo.processorCount, performanceCoreCount: nil, efficiencyCoreCount: nil, coreKinds: nil
    )
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var isMonitoring = false

    /// Also list other users' processes (name, owner and path only). Set by the process table.
    var includesOtherUsersProcesses = false

    /// True while the menu bar extra is in the menu bar: keeps system totals (not the
    /// process list) sampling for its label. Idempotent, so `MenuBarMonitorLabel` and
    /// the app shell can both set it without double counting.
    var isMenuBarExtraActive = false {
        didSet {
            guard isMenuBarExtraActive != oldValue else { return }
            if isMenuBarExtraActive {
                acquire(includingProcesses: false)
            } else {
                release(includingProcesses: false)
            }
        }
    }

    // MARK: - Private state

    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let sampler = PerformanceSampler()
    @ObservationIgnored private var ring = PerformanceRingBuffer<PerformanceSample>(capacity: Int(PerformanceMonitor.historyDuration) + 60)
    @ObservationIgnored private var clients = 0
    @ObservationIgnored private var processClients = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastBatteryRefresh: Date?
    @ObservationIgnored private var lastVolumeRefresh: Date?
    @ObservationIgnored private var alerts = PerformanceAlertEvaluator()
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = ActivityLogger.shared

    init(settings: SettingsManager) {
        self.settings = settings
    }

    /// Seconds between samples (`settings.monitorRefreshInterval`, kept within 1…60 s).
    var refreshInterval: TimeInterval {
        get { Self.clampedInterval(settings.monitorRefreshInterval) }
        set {
            let value = Self.clampedInterval(newValue)
            guard value != settings.monitorRefreshInterval else { return }
            settings.monitorRefreshInterval = value
            logger.info("Monitor refresh interval set to \(Int(value)) s", category: .monitor)
            if isMonitoring { restartLoop(prime: false) }
        }
    }

    // MARK: - Reference-counted sampling

    /// Starts sampling system totals (or keeps it running). Cheap: the process list
    /// isn't collected for these clients. Balance every call with `release()`.
    func acquire() {
        acquire(includingProcesses: false)
    }

    /// Balances `acquire()`; sampling stops when the last client releases.
    func release() {
        release(includingProcesses: false)
    }

    /// `includingProcesses: true` also collects the process list (Performance page,
    /// menu bar popover). Balance with the matching `release(includingProcesses:)`.
    func acquire(includingProcesses: Bool) {
        clients += 1
        if includingProcesses {
            processClients += 1
            if processClients == 1 {
                lastBatteryRefresh = nil
                processTrackingStarted = nil
            }
        }
        if clients == 1 {
            start()
        } else if includingProcesses, processClients == 1 {
            // Collect the process list promptly instead of waiting for the next tick.
            restartLoop(prime: false)
        }
    }

    func release(includingProcesses: Bool) {
        guard clients > 0 else {
            logger.logger(.monitor).error("PerformanceMonitor.release() without matching acquire()")
            return
        }
        clients -= 1
        if includingProcesses, processClients > 0 {
            processClients -= 1
            if processClients == 0 {
                processes = []
                processesMeasured = false
                processTrackingStarted = nil
                restrictedProcessCount = nil
            }
        }
        if clients == 0 { stop() }
    }

    /// A one-off reading for screens that don't need continuous monitoring (such as
    /// the Dashboard). Returns the latest sample if monitoring is running; otherwise
    /// measures over half a second without starting the monitor.
    func sampleOnce() async -> PerformanceSample {
        if isMonitoring, let latest, Date().timeIntervalSince(latest.date) <= refreshInterval * 2 + 1 {
            return latest
        }
        return await PerformanceSampler.measure()
    }

    // MARK: - Loop

    private func start() {
        isMonitoring = true
        alerts.resetObservations()
        observeThermalState()
        restartLoop(prime: true)
        logger.logger(.monitor).debug("Performance monitoring started")
    }

    private func stop() {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        isMonitoring = false
        alerts.resetObservations()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        logger.logger(.monitor).debug("Performance monitoring stopped")
    }

    private func restartLoop(prime: Bool) {
        generation &+= 1
        let generation = generation
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation, prime: prime)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == self.generation
    }

    private func runLoop(generation: Int, prime: Bool) async {
        if prime {
            // Rates need two readings: record a baseline, then measure over a short
            // window so the first numbers appear quickly.
            await sampler.reset()
            let baseline = await sampler.sample(nextRequest())
            guard isCurrent(generation) else { return }
            apply(baseline)
            try? await Task.sleep(for: .milliseconds(500))
        } else if let last = latest?.date {
            // Keep at least half a second between readings so they aren't noise.
            let since = Date().timeIntervalSince(last)
            if since >= 0, since < 0.5 { try? await Task.sleep(for: .seconds(0.5 - since)) }
        }

        while isCurrent(generation) {
            let started = ContinuousClock.now
            let output = await sampler.sample(nextRequest())
            guard isCurrent(generation) else { return }
            apply(output)
            let interval = refreshInterval
            // Right after the process list (re)starts, measure again soon so per-process CPU shows up.
            let delay = output.processBaselineStarted ? min(interval, 1) : interval
            try? await Task.sleep(until: started.advanced(by: .seconds(delay)), tolerance: .seconds(delay * 0.1), clock: .continuous)
        }
    }

    private func nextRequest() -> PerformanceSampleRequest {
        let now = Date()
        var request = PerformanceSampleRequest()
        if processClients > 0 {
            request.processes = includesOtherUsersProcesses ? .all : .readable
            if lastBatteryRefresh.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
                request.battery = true
                lastBatteryRefresh = now
            }
        }
        if lastVolumeRefresh.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            request.startupVolume = true
            lastVolumeRefresh = now
        }
        return request
    }

    private func apply(_ output: PerformanceSamplerOutput) {
        if topology != output.topology { topology = output.topology }
        if let power = output.power {
            if power.battery != battery { battery = power.battery }
            if power.source != powerSource { powerSource = power.source }
        }
        if let volume = output.startupVolume, volume != startupVolume { startupVolume = volume }
        if let list = output.processes, processClients > 0 {
            processes = list
            processesMeasured = !output.processBaselineStarted
            if output.processBaselineStarted || processTrackingStarted == nil { processTrackingStarted = Date() }
            if restrictedProcessCount != output.restrictedProcessCount { restrictedProcessCount = output.restrictedProcessCount }
        }
        guard let sample = output.sample else { return }
        if thermalState != sample.thermalState { thermalState = sample.thermalState }
        latest = sample
        ring.append(sample)
        ring.removeFirst { sample.date.timeIntervalSince($0.date) > Self.historyDuration }
        history = ring.elements
        evaluateAlerts(for: sample)
    }

    // MARK: - Alerts

    private func evaluateAlerts(for sample: PerformanceSample) {
        let configuration = PerformanceAlertSettings(settings: settings, refreshInterval: refreshInterval)
        guard configuration.enabled else {
            alerts.resetObservations()
            return
        }
        var context = PerformanceAlertContext(startupVolumeName: startupVolume?.name, startupVolumeAvailable: startupVolume?.effectiveAvailable)
        // Details for the message are only looked up when an alert could fire.
        if sample.cpuUsage >= configuration.cpuThreshold,
           let busiest = processes.max(by: { ($0.cpu ?? 0) < ($1.cpu ?? 0) }), let cpu = busiest.cpu, cpu > 0 {
            context.busiestProcess = .init(name: busiest.name, cpu: cpu)
        }
        if sample.memoryPressure == .critical {
            if let app = PerformanceAdvisor.memoryHeavyApps(processes: processes, apps: .current(), totalMemory: sample.memoryTotal, minimumBytes: 0, limit: 1).first {
                context.largestApp = .init(name: app.app.name, bytes: app.bytes)
            } else if let largest = processes.max(by: { ($0.memoryFootprint ?? 0) < ($1.memoryFootprint ?? 0) }), let bytes = largest.memoryFootprint {
                context.largestApp = .init(name: largest.name, bytes: bytes)
            }
        }
        for alert in alerts.evaluate(sample: sample, settings: configuration, context: context) {
            logger.info("Performance alert: \(alert.title)", category: .monitor)
            let identifier = "performance.\(alert.kind.rawValue)"
            Task {
                await NotificationService.shared.post(title: alert.title, body: alert.body, identifier: identifier, section: .performance)
            }
        }
    }

    // MARK: - Thermal state

    private func observeThermalState() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }

    // MARK: - Helpers

    static func clampedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 2 }
        return min(60, max(1, value))
    }
}
