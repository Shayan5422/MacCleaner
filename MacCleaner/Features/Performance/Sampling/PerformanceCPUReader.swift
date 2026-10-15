import Darwin
import Foundation
import IOKit

/// Reads per-core scheduler ticks with `host_processor_info` and turns two
/// consecutive readings into usage. Not thread-safe; owned by `PerformanceSampler`.
struct PerformanceCPUReader {
    private var previous: [PerformanceCPUTicks] = []
    private var current: [PerformanceCPUTicks] = []

    init() {}

    /// Usage since the previous call, or nil on the first call (baseline) or on failure.
    mutating func read(host: host_t) -> (total: PerformanceCPULoad, perCore: [Double])? {
        guard Self.readTicks(host: host, into: &current) else { return nil }
        defer { swap(&previous, &current) }
        guard !previous.isEmpty else { return nil }
        return PerformanceCPUMath.usage(previous: previous, current: current)
    }

    mutating func reset() {
        previous.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
    }

    /// Fills `ticks` (reusing its storage) with the cumulative ticks of every logical CPU.
    static func readTicks(host: host_t, into ticks: inout [PerformanceCPUTicks]) -> Bool {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return false }
        // The kernel allocates the array in our address space; it must be released every time.
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stride = Int(CPU_STATE_MAX)
        guard cpuCount > 0, Int(infoCount) >= Int(cpuCount) * stride else { return false }
        ticks.removeAll(keepingCapacity: true)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            ticks.append(PerformanceCPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return true
    }

    static func loadAverage() -> PerformanceLoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return PerformanceLoadAverage(oneMinute: values[0], fiveMinutes: values[1], fifteenMinutes: values[2])
    }
}

/// Determines how many performance and efficiency cores the Mac has and, when it
/// can be verified, which logical CPU is which.
///
/// Counts come from `hw.perflevel0/1.logicalcpu`. Per-core kinds come from the
/// device tree (`IODeviceTree:/cpus/*`: `logical-cpu-id` and `cluster-type`), the
/// same numbering the kernel uses for `host_processor_info`. Kinds are only
/// reported when the device tree lists exactly one entry per logical CPU and its
/// totals match the sysctl counts; otherwise cores are shown as "Core N".
enum PerformanceCPUTopologyReader {
    static let current: PerformanceCPUTopology = read()

    static func read() -> PerformanceCPUTopology {
        let logical = max(1, sysctlInt("hw.logicalcpu_max") ?? sysctlInt("hw.ncpu") ?? ProcessInfo.processInfo.processorCount)
        var performance: Int?
        var efficiency: Int?
        if let levels = sysctlInt("hw.nperflevels"), levels >= 2 {
            for level in 0..<levels {
                guard let count = sysctlInt("hw.perflevel\(level).logicalcpu") else { continue }
                switch sysctlString("hw.perflevel\(level).name")?.lowercased() {
                case "performance": performance = count
                case "efficiency": efficiency = count
                default: break
                }
            }
        }
        let kinds = verifiedCoreKinds(logicalCount: logical, performance: performance, efficiency: efficiency)
        return PerformanceCPUTopology(logicalCoreCount: logical, performanceCoreCount: performance, efficiencyCoreCount: efficiency, coreKinds: kinds)
    }

    private static func verifiedCoreKinds(logicalCount: Int, performance: Int?, efficiency: Int?) -> [PerformanceCPUTopology.CoreKind]? {
        guard let performance, let efficiency, performance + efficiency == logicalCount else { return nil }
        let entries = deviceTreeCPUs()
        guard entries.count == logicalCount else { return nil }
        var kinds = [PerformanceCPUTopology.CoreKind?](repeating: nil, count: logicalCount)
        for entry in entries {
            guard kinds.indices.contains(entry.logicalID), kinds[entry.logicalID] == nil else { return nil }
            kinds[entry.logicalID] = entry.kind
        }
        let resolved = kinds.compactMap { $0 }
        guard resolved.count == logicalCount,
              resolved.filter({ $0 == .performance }).count == performance,
              resolved.filter({ $0 == .efficiency }).count == efficiency else { return nil }
        return resolved
    }

    private static func deviceTreeCPUs() -> [(logicalID: Int, kind: PerformanceCPUTopology.CoreKind)] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(Int, PerformanceCPUTopology.CoreKind)] = []
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard let logicalID = registryInteger(entry, key: "logical-cpu-id"),
                  let type = registryString(entry, key: "cluster-type") else { return [] }
            switch type {
            case "P": result.append((logicalID, .performance))
            case "E": result.append((logicalID, .efficiency))
            default: return []
            }
        }
        return result
    }

    private static func registryInteger(_ entry: io_registry_entry_t, key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data, data.count >= 4 {
            return Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        return nil
    }

    private static func registryString(_ entry: io_registry_entry_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        if let string = value as? String { return string }
        if let data = value as? Data { return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
        return nil
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            return Int(withUnsafeBytes(of: value) { $0.loadUnaligned(as: Int32.self) })
        case MemoryLayout<Int64>.size:
            return Int(value)
        default:
            return nil
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(nulTerminated: buffer)
    }
}
