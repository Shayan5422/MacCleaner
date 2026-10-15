import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Performance CPU math")
struct PerformanceCPUMathTests {
    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> PerformanceCPUTicks {
        PerformanceCPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test func computesTotalAndPerCoreUsageFromTickDeltas() throws {
        let previous = [ticks(100, 50, 850), ticks(1_000, 0, 9_000)]
        let current = [ticks(130, 70, 900), ticks(1_000, 0, 9_100)]
        let usage = try #require(PerformanceCPUMath.usage(previous: previous, current: current))
        // Core 0: busy 50 of 100 ticks. Core 1: busy 0 of 100 ticks.
        #expect(usage.perCore == [0.5, 0])
        #expect(abs(usage.total.busy - 0.25) < 1e-9)
        #expect(abs(usage.total.user - 0.15) < 1e-9)
        #expect(abs(usage.total.system - 0.10) < 1e-9)
        #expect(abs(usage.total.idle - 0.75) < 1e-9)
    }

    @Test func countsNiceTimeAsUserTime() throws {
        let usage = try #require(PerformanceCPUMath.usage(previous: [ticks(0, 0, 0, 0)], current: [ticks(10, 0, 70, 20)]))
        #expect(abs(usage.total.user - 0.3) < 1e-9)
        #expect(abs(usage.perCore[0] - 0.3) < 1e-9)
    }

    @Test func handlesThirtyTwoBitTickWraparound() {
        let delta = PerformanceCPUMath.delta(from: ticks(UInt32.max - 9, 5, UInt32.max), to: ticks(10, 5, 99))
        #expect(delta.user == 20)
        #expect(delta.system == 0)
        #expect(delta.idle == 100)
    }

    @Test func rejectsReadingsWithDifferentCoreCounts() {
        #expect(PerformanceCPUMath.usage(previous: [ticks(0, 0, 0)], current: [ticks(1, 1, 1), ticks(1, 1, 1)]) == nil)
        #expect(PerformanceCPUMath.usage(previous: [], current: []) == nil)
    }

    @Test func noElapsedTicksMeansIdle() throws {
        let usage = try #require(PerformanceCPUMath.usage(previous: [ticks(5, 5, 5)], current: [ticks(5, 5, 5)]))
        #expect(usage.total == .idle)
        #expect(usage.perCore == [0])
    }
}

@Suite("Performance counter deltas")
struct PerformanceCounterTests {
    @Test func growthIsTheDifference() {
        #expect(PerformanceCounterMath.delta(previous: 1_000, current: 4_500) == 3_500)
        #expect(PerformanceCounterMath.delta(previous: 7, current: 7) == 0)
    }

    @Test func sixtyFourBitResetCountsAsZero() {
        // An interface that was re-created starts counting from zero again.
        #expect(PerformanceCounterMath.delta(previous: 50_000_000_000, current: 1_024) == 0)
    }

    @Test func thirtyTwoBitWrapNearTheTopIsAccounted() {
        let previous = UInt64(UInt32.max) - 999
        #expect(PerformanceCounterMath.delta(previous: previous, current: 500, wrapsAt32Bits: true) == 1_500)
    }

    @Test func thirtyTwoBitDropFromTheMiddleIsAReset() {
        #expect(PerformanceCounterMath.delta(previous: 2_000_000_000, current: 10_000, wrapsAt32Bits: true) == 0)
        #expect(PerformanceCounterMath.delta(previous: 6_000_000_000, current: 10, wrapsAt32Bits: true) == 0)
    }

    @Test func trackerSumsKnownDevicesAndIgnoresNewOrResetOnes() {
        var tracker = PerformanceCounterTracker<String>()
        #expect(tracker.update(with: ["en0": .init(first: 100, second: 50), "en1": .init(first: 1_000, second: 1_000)]) == nil)
        #expect(tracker.hasBaseline)

        let delta = tracker.update(with: [
            "en0": .init(first: 300, second: 80), // +200 / +30
            "en1": .init(first: 10, second: 5), // reset: contributes nothing
            "en2": .init(first: 9_999, second: 9_999), // new: baseline only
        ])
        #expect(delta == PerformanceCounterPair(first: 200, second: 30))

        let next = tracker.update(with: ["en1": .init(first: 110, second: 25), "en2": .init(first: 10_099, second: 10_000)])
        #expect(next == PerformanceCounterPair(first: 200, second: 21))
    }

    @Test func trackerResetStartsOver() {
        var tracker = PerformanceCounterTracker<Int>()
        _ = tracker.update(with: [1: .init(first: 1, second: 1)])
        tracker.reset()
        #expect(!tracker.hasBaseline)
        #expect(tracker.update(with: [1: .init(first: 5, second: 5)]) == nil)
    }
}

@Suite("Performance network interfaces")
struct PerformanceNetworkFilterTests {
    private let up = Int32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)

    @Test func countsPhysicalInterfaces() {
        #expect(PerformanceNetworkMath.isCounted(name: "en0", flags: up, type: Int32(IFT_ETHER)))
        #expect(PerformanceNetworkMath.isCounted(name: "awdl0", flags: up, type: Int32(IFT_ETHER)))
    }

    @Test func skipsLoopbackTunnelsBridgesVirtualMachinesAndDownInterfaces() {
        #expect(!PerformanceNetworkMath.isCounted(name: "lo0", flags: Int32(IFF_UP | IFF_LOOPBACK), type: Int32(IFT_LOOP)))
        #expect(!PerformanceNetworkMath.isCounted(name: "utun3", flags: Int32(IFF_UP | IFF_POINTOPOINT | IFF_RUNNING), type: 1))
        #expect(!PerformanceNetworkMath.isCounted(name: "bridge100", flags: up, type: Int32(IFT_BRIDGE)))
        #expect(!PerformanceNetworkMath.isCounted(name: "vmenet0", flags: up, type: Int32(IFT_ETHER)))
        #expect(!PerformanceNetworkMath.isCounted(name: "en5", flags: Int32(IFF_BROADCAST), type: Int32(IFT_ETHER)))
    }
}

@Suite("Performance memory composition")
struct PerformanceMemoryTests {
    @Test func computesActivityMonitorCategories() {
        let page: UInt64 = 16_384
        let memory = PerformanceMemoryBreakdown.compute(
            pageSize: page,
            totalBytes: 4_194_304 * page,
            internalPages: 2_238_798,
            purgeablePages: 110_611,
            externalPages: 1_016_935,
            wiredPages: 354_840,
            compressorPages: 227_613
        )
        #expect(memory.app == (2_238_798 - 110_611) * page)
        #expect(memory.wired == 354_840 * page)
        #expect(memory.compressed == 227_613 * page)
        #expect(memory.cachedFiles == (1_016_935 + 110_611) * page)
        #expect(memory.used == memory.app + memory.wired + memory.compressed)
        #expect(memory.free == memory.total - memory.used - memory.cachedFiles)
        #expect(memory.usedFraction > 0.6 && memory.usedFraction < 0.7)
    }

    @Test func purgeableLargerThanInternalNeverUnderflows() {
        let memory = PerformanceMemoryBreakdown.compute(pageSize: 4_096, totalBytes: 1_000 * 4_096, internalPages: 10, purgeablePages: 20, externalPages: 0, wiredPages: 0, compressorPages: 0)
        #expect(memory.app == 0)
        #expect(memory.cachedFiles == 20 * 4_096)
    }

    @Test func usedIsClampedToPhysicalMemory() {
        let memory = PerformanceMemoryBreakdown(total: 100, app: 80, wired: 30, compressed: 10, cachedFiles: 50)
        #expect(memory.used == 100)
        #expect(memory.free == 0)
    }

    @Test func pressureLevelsMapKernelValues() {
        #expect(MemoryPressureLevel(kernelLevel: 1) == .normal)
        #expect(MemoryPressureLevel(kernelLevel: 2) == .warning)
        #expect(MemoryPressureLevel(kernelLevel: 4) == .critical)
        #expect(MemoryPressureLevel(kernelLevel: 0) == .normal)
        #expect(MemoryPressureLevel.warning < .critical)
    }
}

@Suite("Performance ring buffer")
struct PerformanceRingBufferTests {
    @Test func staysWithinCapacityAndKeepsNewestInOrder() {
        var ring = PerformanceRingBuffer<Int>(capacity: 3)
        #expect(ring.isEmpty)
        for value in 1...7 { ring.append(value) }
        #expect(ring.count == 3)
        #expect(ring.elements == [5, 6, 7])
        #expect(ring.first == 5)
        #expect(ring.last == 7)
    }

    @Test func removesOldElementsWhilePredicateHolds() {
        var ring = PerformanceRingBuffer<Int>(capacity: 5)
        for value in 1...7 { ring.append(value) }
        ring.removeFirst { $0 < 5 }
        #expect(ring.elements == [5, 6, 7])
        ring.append(8)
        ring.append(9)
        ring.append(10)
        #expect(ring.elements == [6, 7, 8, 9, 10])
        ring.removeFirst { _ in true }
        #expect(ring.isEmpty)
        #expect(ring.last == nil)
    }

    @Test func capacityIsAtLeastOne() {
        var ring = PerformanceRingBuffer<String>(capacity: 0)
        ring.append("a")
        ring.append("b")
        #expect(ring.elements == ["b"])
        ring.removeAll()
        #expect(ring.count == 0)
    }
}

@Suite("Performance per-process CPU window")
struct PerformanceCPUWindowTests {
    private let second: UInt64 = 1_000_000_000

    @Test func averagesOverTheRecentWindow() throws {
        var window = PerformanceCPUWindow(windowSeconds: 30, spacingSeconds: 2)
        #expect(window.add(.init(uptime: 0, cpuTime: 0)) == nil)
        var last: PerformanceCPUWindow.Average?
        // A process keeping 90% of a core busy, sampled every second for 40 seconds.
        for tick in 1...40 {
            last = window.add(.init(uptime: UInt64(tick) * second, cpuTime: UInt64(tick) * second * 9 / 10))
        }
        let average = try #require(last)
        #expect(abs(average.fraction - 0.9) < 1e-9)
        #expect(average.covered >= 30 && average.covered <= 32)
        #expect(window.readings.count <= 17)
    }

    @Test func restartsWhenTheCounterGoesBackwards() {
        var window = PerformanceCPUWindow()
        _ = window.add(.init(uptime: 0, cpuTime: 5 * second))
        _ = window.add(.init(uptime: 3 * second, cpuTime: 6 * second))
        #expect(window.add(.init(uptime: 6 * second, cpuTime: 1 * second)) == nil)
        #expect(window.readings.count == 1)
    }

    @Test func sustainedCheckNeedsEnoughCoverage() {
        var process = PerformanceProcess(pid: 1, parentPID: nil, uid: 501, userName: "me", name: "busy", executablePath: nil, appBundlePath: nil, startTime: nil, memoryFootprint: 1, cpu: 1, recentCPU: 0.95, recentCPUWindow: 10, isCurrentUser: true, hasUsageInfo: true)
        #expect(!process.isSustainedCPU(atLeast: 0.8))
        process.recentCPUWindow = 30
        #expect(process.isSustainedCPU(atLeast: 0.8))
        process.recentCPU = 0.5
        #expect(!process.isSustainedCPU(atLeast: 0.8))
    }
}

@Suite("Performance chart series")
struct PerformanceChartMathTests {
    @Test func splitsSegmentsAtGapsAndDropsOldPoints() {
        let start = Date(timeIntervalSince1970: 1_000)
        let offsets: [TimeInterval] = [0, 1, 2, 30, 31, 32]
        let points = PerformanceChartMath.series(
            dates: offsets.map { start.addingTimeInterval($0) },
            values: [1, 2, 3, 4, 5, .nan],
            end: start.addingTimeInterval(32),
            window: 31.5,
            gapThreshold: 5,
            maxPoints: 100
        )
        #expect(points.map(\.value) == [2, 3, 4, 5, 0])
        #expect(points.map(\.segment) == [0, 0, 1, 1, 1])
    }

    @Test func domainGrowsWithHistoryUpToTheRange() {
        let end = Date(timeIntervalSince1970: 10_000)
        func history(seconds: Int) -> [PerformanceSample] {
            (0...seconds).map { offset in
                let memory = PerformanceMemoryBreakdown(total: 1, app: 0, wired: 0, compressed: 0, cachedFiles: 0)
                return PerformanceSample(
                    date: end.addingTimeInterval(Double(offset - seconds)), window: 1, cpuUsage: 0, cpuUserUsage: 0, cpuSystemUsage: 0,
                    perCoreUsage: [0], loadAverage: nil, memoryUsed: 0, memoryTotal: 1, memory: memory, memoryPressure: .normal,
                    swapUsed: 0, swapTotal: 0, swapInPerSecond: 0, swapOutPerSecond: 0, networkInPerSecond: 0, networkOutPerSecond: 0,
                    diskReadPerSecond: 0, diskWritePerSecond: 0, thermalState: .nominal
                )
            }
        }
        // 20 s of data: at least a one-minute window.
        #expect(PerformanceChartMath.domain(history: history(seconds: 20), range: 300) == end.addingTimeInterval(-60)...end)
        // 3 minutes of data in a 5-minute range: the window covers the data.
        #expect(PerformanceChartMath.domain(history: history(seconds: 180), range: 300) == end.addingTimeInterval(-180)...end)
        // More data than the range: capped at the range.
        #expect(PerformanceChartMath.domain(history: history(seconds: 600), range: 300) == end.addingTimeInterval(-300)...end)
        // A one-minute range never shows more than a minute.
        #expect(PerformanceChartMath.domain(history: history(seconds: 600), range: 60) == end.addingTimeInterval(-60)...end)
    }

    @Test func downsamplesWithoutMixingSegments() {
        let start = Date(timeIntervalSince1970: 0)
        let points = (0..<100).map { PerformanceChartPoint(date: start.addingTimeInterval(Double($0)), value: Double($0), segment: $0 < 50 ? 0 : 1) }
        let reduced = PerformanceChartMath.downsample(points, maxPoints: 10)
        #expect(reduced.count <= 12)
        #expect(reduced.first?.value == 4.5)
        #expect(reduced.last?.date == points.last?.date)
        #expect(Set(reduced.map(\.segment)) == [0, 1])
    }
}
