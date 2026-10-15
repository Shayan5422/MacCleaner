import Foundation
import Testing
@testable import MacCleaner

@Suite("Performance alert throttling")
struct PerformanceAlertThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Records `shouldFire` results (the macros can't call mutating methods directly).
    private func fire(_ throttle: inout PerformanceAlertThrottle, _ kind: PerformanceAlertKind, after seconds: TimeInterval) -> Bool {
        throttle.shouldFire(kind, at: start.addingTimeInterval(seconds))
    }

    @Test func allowsOneAlertPerKindEveryThirtyMinutes() {
        var throttle = PerformanceAlertThrottle()
        let results = [0, 60, 29 * 60, 30 * 60].map { fire(&throttle, .highCPU, after: TimeInterval($0)) }
        #expect(results == [true, false, false, true])
    }

    @Test func kindsAreThrottledIndependently() {
        var throttle = PerformanceAlertThrottle()
        let results = [PerformanceAlertKind.highCPU, .memoryPressure, .lowDisk].map { fire(&throttle, $0, after: 0) }
        #expect(results == [true, true, true])
        #expect(!throttle.canFire(.memoryPressure, at: start.addingTimeInterval(10)))
    }

    @Test func clockMovingBackwardsDoesNotBlockForever() {
        var throttle = PerformanceAlertThrottle()
        let first = fire(&throttle, .lowDisk, after: 0)
        let afterClockChange = fire(&throttle, .lowDisk, after: -3_600)
        #expect(first)
        #expect(afterClockChange)
    }

    @Test func sustainedConditionNeedsContinuousTime() {
        var condition = PerformanceSustainedCondition(requiredDuration: 60)
        let readings: [(Bool, TimeInterval)] = [(true, 0), (true, 59), (true, 60), (false, 61), (true, 62), (true, 122)]
        let results = readings.map { condition.update(isMet: $0.0, at: start.addingTimeInterval($0.1)) }
        #expect(results == [false, false, true, false, false, true])
    }
}

@Suite("Performance alert evaluation")
struct PerformanceAlertEvaluatorTests {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func sample(at offset: TimeInterval, cpu: Double, pressure: MemoryPressureLevel = .normal) -> PerformanceSample {
        let memory = PerformanceMemoryBreakdown(total: 16_000_000_000, app: 4_000_000_000, wired: 2_000_000_000, compressed: 0, cachedFiles: 4_000_000_000)
        return PerformanceSample(
            date: start.addingTimeInterval(offset), window: 2, cpuUsage: cpu, cpuUserUsage: cpu, cpuSystemUsage: 0,
            perCoreUsage: [cpu, cpu], loadAverage: nil, memoryUsed: memory.used, memoryTotal: memory.total, memory: memory,
            memoryPressure: pressure, swapUsed: 0, swapTotal: 0, swapInPerSecond: 0, swapOutPerSecond: 0,
            networkInPerSecond: 0, networkOutPerSecond: 0, diskReadPerSecond: 0, diskWritePerSecond: 0, thermalState: .nominal
        )
    }

    private func settings(enabled: Bool = true, lowDisk: Int64? = nil) -> PerformanceAlertSettings {
        PerformanceAlertSettings(enabled: enabled, cpuThreshold: 0.9, memoryPressureAlerts: true, lowDiskThresholdBytes: lowDisk, maximumSampleGap: 15)
    }

    @Test func highCPUAlertsAfterAMinuteThenThrottles() {
        var evaluator = PerformanceAlertEvaluator()
        let context = PerformanceAlertContext(busiestProcess: .init(name: "Compressor", cpu: 3.5))
        var fired: [PerformanceAlert] = []
        for offset in stride(from: 0.0, through: 120, by: 2) {
            fired += evaluator.evaluate(sample: sample(at: offset, cpu: 0.95), settings: settings(), context: context)
        }
        #expect(fired.count == 1)
        #expect(fired.first?.kind == .highCPU)
        #expect(fired.first?.body.contains("Compressor") == true)
    }

    @Test func briefSpikesDoNotAlert() {
        var evaluator = PerformanceAlertEvaluator()
        var fired: [PerformanceAlert] = []
        for offset in stride(from: 0.0, through: 300, by: 2) {
            // Busy for 40 s, quiet for 4 s, repeatedly.
            let busy = offset.truncatingRemainder(dividingBy: 44) < 40
            fired += evaluator.evaluate(sample: sample(at: offset, cpu: busy ? 0.99 : 0.2), settings: settings(), context: .init())
        }
        #expect(fired.isEmpty)
    }

    @Test func pausedMonitoringRestartsTheTimer() {
        var evaluator = PerformanceAlertEvaluator()
        var fired = evaluator.evaluate(sample: sample(at: 0, cpu: 0.95), settings: settings(), context: .init())
        // Monitoring resumes 10 minutes later; one busy reading isn't a sustained minute.
        fired += evaluator.evaluate(sample: sample(at: 600, cpu: 0.95), settings: settings(), context: .init())
        fired += evaluator.evaluate(sample: sample(at: 602, cpu: 0.95), settings: settings(), context: .init())
        #expect(fired.isEmpty)
    }

    @Test func criticalMemoryPressureAlertsOncePerThirtyMinutes() {
        var evaluator = PerformanceAlertEvaluator()
        let context = PerformanceAlertContext(largestApp: .init(name: "Xcode", bytes: 6_000_000_000))
        let first = evaluator.evaluate(sample: sample(at: 0, cpu: 0.1, pressure: .critical), settings: settings(), context: context)
        let second = evaluator.evaluate(sample: sample(at: 10, cpu: 0.1, pressure: .critical), settings: settings(), context: context)
        let later = evaluator.evaluate(sample: sample(at: 31 * 60, cpu: 0.1, pressure: .critical), settings: settings(), context: context)
        #expect(first.map(\.kind) == [.memoryPressure])
        #expect(first.first?.body.contains("Xcode") == true)
        #expect(second.isEmpty)
        #expect(later.map(\.kind) == [.memoryPressure])
    }

    @Test func lowDiskAlertsBelowTheThreshold() {
        var evaluator = PerformanceAlertEvaluator()
        let plenty = PerformanceAlertContext(startupVolumeName: "Macintosh HD", startupVolumeAvailable: 50_000_000_000)
        let low = PerformanceAlertContext(startupVolumeName: "Macintosh HD", startupVolumeAvailable: 4_000_000_000)
        #expect(evaluator.evaluate(sample: sample(at: 0, cpu: 0.1), settings: settings(lowDisk: 10_000_000_000), context: plenty).isEmpty)
        let alerts = evaluator.evaluate(sample: sample(at: 2, cpu: 0.1), settings: settings(lowDisk: 10_000_000_000), context: low)
        #expect(alerts.map(\.kind) == [.lowDisk])
        #expect(evaluator.evaluate(sample: sample(at: 4, cpu: 0.1), settings: settings(lowDisk: nil), context: low).isEmpty)
    }

    @Test func disabledAlertsNeverFire() {
        var evaluator = PerformanceAlertEvaluator()
        var fired: [PerformanceAlert] = []
        for offset in stride(from: 0.0, through: 180, by: 2) {
            fired += evaluator.evaluate(sample: sample(at: offset, cpu: 1, pressure: .critical), settings: settings(enabled: false, lowDisk: 1_000_000_000_000), context: .init(startupVolumeAvailable: 1))
        }
        #expect(fired.isEmpty)
    }
}
