import Foundation

// Pure, side-effect-free calculations used by the sampler. Kept separate from
// the system calls so they can be unit tested with synthetic counters.

// MARK: - CPU

/// Cumulative scheduler ticks of one logical CPU (`PROCESSOR_CPU_LOAD_INFO`).
/// The kernel keeps them as 32-bit counters that wrap around.
struct PerformanceCPUTicks: Sendable, Hashable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Share of CPU time spent in each state over one measurement window (sums to 1).
struct PerformanceCPULoad: Sendable, Hashable {
    var user: Double
    var system: Double
    var idle: Double

    var busy: Double { user + system }
    static let idle = PerformanceCPULoad(user: 0, system: 0, idle: 1)
}

enum PerformanceCPUMath {
    struct TickDelta: Sendable, Hashable {
        var user: UInt64
        var system: UInt64
        var idle: UInt64

        var busy: UInt64 { user + system }
        var total: UInt64 { user + system + idle }
    }

    /// Ticks spent in each state between two readings. Wrapping subtraction keeps
    /// the result correct when a 32-bit counter rolls over. Nice time counts as user time,
    /// like Activity Monitor.
    static func delta(from previous: PerformanceCPUTicks, to current: PerformanceCPUTicks) -> TickDelta {
        TickDelta(
            user: UInt64(current.user &- previous.user) + UInt64(current.nice &- previous.nice),
            system: UInt64(current.system &- previous.system),
            idle: UInt64(current.idle &- previous.idle)
        )
    }

    /// Total load and per-core usage (0...1) between two readings, or nil when the
    /// readings don't describe the same set of CPUs.
    static func usage(previous: [PerformanceCPUTicks], current: [PerformanceCPUTicks]) -> (total: PerformanceCPULoad, perCore: [Double])? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        for index in current.indices {
            let delta = delta(from: previous[index], to: current[index])
            user += delta.user
            system += delta.system
            idle += delta.idle
            perCore.append(delta.total > 0 ? Double(delta.busy) / Double(delta.total) : 0)
        }
        let total = user + system + idle
        guard total > 0 else { return (.idle, perCore) }
        return (PerformanceCPULoad(user: Double(user) / Double(total), system: Double(system) / Double(total), idle: Double(idle) / Double(total)), perCore)
    }
}

// MARK: - Cumulative counters (network, disk)

enum PerformanceCounterMath {
    /// Growth of a cumulative counter between two readings.
    ///
    /// A counter that went down was either reset (interface re-created, disk
    /// re-attached) or, for 32-bit counters, wrapped around. Resets contribute 0 so
    /// they never show up as a spike. A 32-bit wrap is only assumed when the old value
    /// was near the top of the range and the new one near the bottom; anything else is
    /// treated as a reset.
    static func delta(previous: UInt64, current: UInt64, wrapsAt32Bits: Bool = false) -> UInt64 {
        if current >= previous { return current - previous }
        guard wrapsAt32Bits else { return 0 }
        let range = UInt64(UInt32.max) + 1
        guard previous < range, current < range, previous >= range / 4 * 3, current < range / 4 else { return 0 }
        return (range - previous) + current
    }
}

/// A pair of cumulative counters (bytes in/out, bytes read/written).
struct PerformanceCounterPair: Sendable, Hashable {
    var first: UInt64
    var second: UInt64
}

/// Tracks cumulative counters of several devices (network interfaces, disks)
/// and returns how much they grew in total since the previous update. Devices
/// that appear or disappear between updates don't contribute.
struct PerformanceCounterTracker<Key: Hashable & Sendable>: Sendable {
    private(set) var previous: [Key: PerformanceCounterPair] = [:]
    private(set) var hasBaseline = false

    init() {}

    /// Summed growth since the previous call, or nil on the first call (baseline only).
    mutating func update(with readings: [Key: PerformanceCounterPair], wrapsAt32Bits: Bool = false) -> PerformanceCounterPair? {
        defer {
            previous = readings
            hasBaseline = true
        }
        guard hasBaseline else { return nil }
        var total = PerformanceCounterPair(first: 0, second: 0)
        for (key, reading) in readings {
            guard let old = previous[key] else { continue }
            total.first &+= PerformanceCounterMath.delta(previous: old.first, current: reading.first, wrapsAt32Bits: wrapsAt32Bits)
            total.second &+= PerformanceCounterMath.delta(previous: old.second, current: reading.second, wrapsAt32Bits: wrapsAt32Bits)
        }
        return total
    }

    mutating func reset() {
        previous = [:]
        hasBaseline = false
    }
}

// MARK: - Memory

extension PerformanceMemoryBreakdown {
    /// Activity Monitor's composition from `vm_statistics64` page counts:
    /// app = internal − purgeable, wired = wire_count, compressed = compressor pages,
    /// cached files = external + purgeable.
    static func compute(
        pageSize: UInt64,
        totalBytes: UInt64,
        internalPages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64
    ) -> PerformanceMemoryBreakdown {
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return PerformanceMemoryBreakdown(
            total: totalBytes,
            app: appPages &* pageSize,
            wired: wiredPages &* pageSize,
            compressed: compressorPages &* pageSize,
            cachedFiles: (externalPages &+ purgeablePages) &* pageSize
        )
    }
}

// MARK: - Ring buffer

/// Fixed-capacity FIFO: appending to a full buffer drops the oldest element.
struct PerformanceRingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: nil, count: self.capacity)
    }

    var isEmpty: Bool { count == 0 }

    var first: Element? { count > 0 ? storage[head] : nil }

    var last: Element? { count > 0 ? storage[(head + count - 1) % capacity] : nil }

    /// Elements from oldest to newest.
    var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            if let element = storage[(head + offset) % capacity] { result.append(element) }
        }
        return result
    }

    mutating func append(_ element: Element) {
        if count < capacity {
            storage[(head + count) % capacity] = element
            count += 1
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Drops elements from the oldest end while `predicate` holds.
    mutating func removeFirst(while predicate: (Element) -> Bool) {
        while count > 0, let oldest = storage[head], predicate(oldest) {
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}

extension PerformanceRingBuffer: Sendable where Element: Sendable {}

// MARK: - Per-process CPU averaging

/// Keeps a few cumulative CPU-time readings of one process (spaced at least
/// `spacing` apart, covering about `window`) so its average CPU use over the recent
/// past can be computed cheaply.
struct PerformanceCPUWindow: Sendable {
    struct Reading: Sendable, Hashable {
        /// Uptime when the reading was taken, in nanoseconds.
        var uptime: UInt64
        /// Cumulative CPU time of the process, in nanoseconds.
        var cpuTime: UInt64
    }

    struct Average: Sendable, Hashable {
        /// 1.0 = one core fully busy.
        var fraction: Double
        /// Seconds covered by the average.
        var covered: TimeInterval
    }

    private(set) var readings: [Reading] = []
    let window: UInt64
    let spacing: UInt64

    init(windowSeconds: Double = 30, spacingSeconds: Double = 2) {
        window = UInt64(max(1, windowSeconds) * 1e9)
        spacing = UInt64(max(0, spacingSeconds) * 1e9)
    }

    /// Records `reading` and returns the average from the oldest kept reading up to it.
    mutating func add(_ reading: Reading) -> Average? {
        if let last = readings.last, reading.uptime < last.uptime || reading.cpuTime < last.cpuTime {
            // Clock or counter went backwards: the process isn't the one we knew.
            readings.removeAll()
        }
        var result: Average?
        if let oldest = readings.first, reading.uptime > oldest.uptime {
            let elapsed = reading.uptime - oldest.uptime
            result = Average(fraction: Double(reading.cpuTime - oldest.cpuTime) / Double(elapsed), covered: Double(elapsed) / 1e9)
        }
        if let last = readings.last {
            if reading.uptime - last.uptime >= spacing { readings.append(reading) }
        } else {
            readings.append(reading)
        }
        // Keep exactly one reading at least `window` old as the anchor.
        while readings.count >= 2, reading.uptime - readings[1].uptime >= window {
            readings.removeFirst()
        }
        return result
    }
}

// MARK: - Alerts

/// Detects a condition that has held continuously for a minimum duration
/// (for example "CPU above 90% for at least 60 seconds").
struct PerformanceSustainedCondition: Sendable {
    let requiredDuration: TimeInterval
    private(set) var since: Date?

    init(requiredDuration: TimeInterval) {
        self.requiredDuration = requiredDuration
    }

    /// Returns true while the condition has held for at least `requiredDuration`.
    mutating func update(isMet: Bool, at date: Date) -> Bool {
        guard isMet else {
            since = nil
            return false
        }
        let start = since ?? date
        since = start
        return date.timeIntervalSince(start) >= requiredDuration
    }

    mutating func reset() {
        since = nil
    }
}

/// Limits notifications to one per kind within `minimumInterval`.
struct PerformanceAlertThrottle: Sendable {
    let minimumInterval: TimeInterval
    private(set) var lastFired: [PerformanceAlertKind: Date] = [:]

    init(minimumInterval: TimeInterval = 30 * 60) {
        self.minimumInterval = minimumInterval
    }

    func canFire(_ kind: PerformanceAlertKind, at date: Date) -> Bool {
        guard let last = lastFired[kind] else { return true }
        // A clock change that moved time backwards shouldn't block alerts forever.
        if date < last { return true }
        return date.timeIntervalSince(last) >= minimumInterval
    }

    /// Returns true (and records the time) when an alert of `kind` may be posted now.
    mutating func shouldFire(_ kind: PerformanceAlertKind, at date: Date) -> Bool {
        guard canFire(kind, at: date) else { return false }
        lastFired[kind] = date
        return true
    }
}

enum PerformanceAlertKind: String, Sendable, Hashable, CaseIterable {
    case highCPU, memoryPressure, lowDisk
}

// MARK: - Charts

/// One plotted value; `segment` changes where monitoring paused so lines aren't drawn across gaps.
struct PerformanceChartPoint: Sendable, Hashable, Identifiable {
    var date: Date
    var value: Double
    var segment: Int

    var id: Date { date }
}

enum PerformanceChartMath {
    /// Points of `values` within `window` seconds before `end`, split into segments at
    /// gaps longer than `gapThreshold`, and averaged down to at most `maxPoints`.
    static func series(
        dates: [Date],
        values: [Double],
        end: Date,
        window: TimeInterval,
        gapThreshold: TimeInterval,
        maxPoints: Int
    ) -> [PerformanceChartPoint] {
        precondition(dates.count == values.count)
        let start = end.addingTimeInterval(-window)
        var points: [PerformanceChartPoint] = []
        var segment = 0
        var previousDate: Date?
        for index in dates.indices where dates[index] >= start && dates[index] <= end {
            if let previousDate, dates[index].timeIntervalSince(previousDate) > gapThreshold { segment += 1 }
            previousDate = dates[index]
            let value = values[index].isFinite ? values[index] : 0
            points.append(PerformanceChartPoint(date: dates[index], value: value, segment: segment))
        }
        return downsample(points, maxPoints: maxPoints)
    }

    /// Averages runs of consecutive points (never across segments) so at most about `maxPoints` remain.
    static func downsample(_ points: [PerformanceChartPoint], maxPoints: Int) -> [PerformanceChartPoint] {
        guard maxPoints > 0, points.count > maxPoints else { return points }
        let groupSize = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        var result: [PerformanceChartPoint] = []
        result.reserveCapacity(maxPoints + 8)
        var bucket: [PerformanceChartPoint] = []
        func flush() {
            guard let last = bucket.last else { return }
            let average = bucket.reduce(0) { $0 + $1.value } / Double(bucket.count)
            result.append(PerformanceChartPoint(date: last.date, value: average, segment: last.segment))
            bucket.removeAll(keepingCapacity: true)
        }
        for point in points {
            if let first = bucket.first, first.segment != point.segment || bucket.count >= groupSize { flush() }
            bucket.append(point)
        }
        flush()
        return result
    }
}
