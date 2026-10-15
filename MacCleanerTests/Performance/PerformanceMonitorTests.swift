import Foundation
import Testing
@testable import MacCleaner

@MainActor
@Suite("Performance monitor lifecycle", .serialized)
struct PerformanceMonitorLifecycleTests {
    private func makeMonitor(_ name: String) -> (PerformanceMonitor, UserDefaults) {
        let suite = "PerformanceMonitorLifecycleTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PerformanceMonitor(settings: SettingsManager(defaults: defaults)), defaults)
    }

    @Test func referenceCountingStartsAndStopsSampling() {
        let (monitor, defaults) = makeMonitor("refcount")
        defer { defaults.removePersistentDomain(forName: "PerformanceMonitorLifecycleTests.refcount") }
        #expect(!monitor.isMonitoring)
        monitor.acquire(includingProcesses: true) // Performance page
        monitor.acquire() // Dashboard: totals only
        #expect(monitor.isMonitoring)
        monitor.release(includingProcesses: true)
        #expect(monitor.isMonitoring)
        #expect(monitor.processes.isEmpty)
        monitor.release()
        #expect(!monitor.isMonitoring)
        // An unbalanced release is ignored instead of going negative.
        monitor.release()
        monitor.acquire()
        #expect(monitor.isMonitoring)
        monitor.release()
        #expect(!monitor.isMonitoring)
    }

    @Test func menuBarFlagIsIdempotent() {
        let (monitor, defaults) = makeMonitor("menubar")
        defer { defaults.removePersistentDomain(forName: "PerformanceMonitorLifecycleTests.menubar") }
        monitor.isMenuBarExtraActive = true
        monitor.isMenuBarExtraActive = true
        #expect(monitor.isMonitoring)
        monitor.isMenuBarExtraActive = false
        #expect(!monitor.isMonitoring)
        monitor.isMenuBarExtraActive = false
        #expect(!monitor.isMonitoring)
    }

    @Test func refreshIntervalIsStoredAndClamped() {
        let (monitor, defaults) = makeMonitor("interval")
        defer { defaults.removePersistentDomain(forName: "PerformanceMonitorLifecycleTests.interval") }
        monitor.refreshInterval = 5
        #expect(monitor.refreshInterval == 5)
        #expect(defaults.double(forKey: SettingsManager.Key.monitorRefreshInterval) == 5)
        monitor.refreshInterval = 0.01
        #expect(monitor.refreshInterval == 1)
        monitor.refreshInterval = 3_600
        #expect(monitor.refreshInterval == 60)
    }

    @Test func sampleOnceMeasuresWithoutStartingTheMonitor() async {
        let (monitor, defaults) = makeMonitor("once")
        defer { defaults.removePersistentDomain(forName: "PerformanceMonitorLifecycleTests.once") }
        let sample = await monitor.sampleOnce()
        #expect(!monitor.isMonitoring)
        #expect(monitor.latest == nil)
        #expect(sample.window >= 0.4)
        #expect(sample.memoryTotal == ProcessInfo.processInfo.physicalMemory)
        #expect(sample.memoryUsed > 0 && sample.memoryUsed <= sample.memoryTotal)
        #expect((0...1).contains(sample.cpuUsage))
        #expect(sample.perCoreUsage.count == ProcessInfo.processInfo.processorCount)
        #expect(sample.perCoreUsage.allSatisfy { (0...1).contains($0) })
        #expect(sample.networkInPerSecond >= 0 && sample.diskWritePerSecond >= 0)
    }
}

@Suite("Performance sampler readings")
struct PerformanceSamplerReadingTests {
    @Test func readingsFromThisMacArePlausible() async throws {
        let sampler = PerformanceSampler(label: "PerformanceSamplerReadingTests")
        let baseline = await sampler.sample(PerformanceSampleRequest(processes: .readable))
        #expect(baseline.sample == nil) // rates need two readings
        #expect(baseline.processBaselineStarted)
        try await Task.sleep(for: .milliseconds(300))
        let output = await sampler.sample(PerformanceSampleRequest(processes: .readable))
        let sample = try #require(output.sample)
        #expect(sample.memory.app + sample.memory.wired + sample.memory.compressed >= sample.memoryUsed)
        #expect(sample.memory.cachedFiles <= sample.memoryTotal)
        #expect(sample.swapUsed <= sample.swapTotal || sample.swapTotal == 0)
        #expect(abs(sample.cpuUserUsage + sample.cpuSystemUsage - sample.cpuUsage) < 0.0001)

        let processes = try #require(output.processes)
        #expect(!output.processBaselineStarted)
        let me = try #require(processes.first { $0.pid == getpid() })
        #expect(me.isCurrentUser && me.hasUsageInfo)
        #expect((me.memoryFootprint ?? 0) > 0)
        #expect(me.cpu != nil)
    }
}
