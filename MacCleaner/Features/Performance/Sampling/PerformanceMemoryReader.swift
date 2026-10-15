import Darwin
import Foundation

/// Memory statistics from `host_statistics64`, `vm.swapusage` and
/// `kern.memorystatus_vm_pressure_level`.
enum PerformanceMemoryReader {
    struct VMCounters: Sendable, Hashable {
        var internalPages: UInt64
        var purgeablePages: UInt64
        var externalPages: UInt64
        var wiredPages: UInt64
        var compressorPages: UInt64
        /// Cumulative pages read back from / written to swap since boot.
        var swapIns: UInt64
        var swapOuts: UInt64
    }

    static func vmCounters(host: host_t) -> VMCounters? {
        var stats = vm_statistics64_data_t()
        // HOST_VM_INFO64_COUNT is a C macro Swift can't import.
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMCounters(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            externalPages: UInt64(stats.external_page_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            swapIns: stats.swapins,
            swapOuts: stats.swapouts
        )
    }

    /// Size of the pages `host_statistics64` counts in.
    static func pageSize(host: host_t) -> UInt64 {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 { return UInt64(size) }
        return UInt64(max(4096, getpagesize()))
    }

    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// The kernel's current memory pressure level, or nil if the sysctl isn't available.
    static func pressureLevel() -> MemoryPressureLevel? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressureLevel(kernelLevel: Int(level))
    }
}

/// Fallback for `kern.memorystatus_vm_pressure_level`: remembers the last memory
/// pressure transition delivered by a dispatch source. Only created if the sysctl
/// can't be read.
final class PerformancePressureEventMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var level: MemoryPressureLevel = .normal
    private let source: DispatchSourceMemoryPressure

    init(queue: DispatchQueue) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    /// Last level reported by the system (normal until the first transition).
    var current: MemoryPressureLevel {
        lock.withLock { level }
    }

    private func handleEvent() {
        let event = source.data
        let newLevel: MemoryPressureLevel
        if event.contains(.critical) {
            newLevel = .critical
        } else if event.contains(.warning) {
            newLevel = .warning
        } else {
            newLevel = .normal
        }
        lock.withLock { level = newLevel }
    }
}
