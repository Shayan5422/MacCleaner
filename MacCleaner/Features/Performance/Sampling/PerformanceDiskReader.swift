import Foundation
import IOKit

/// Disk throughput from the cumulative statistics of IOKit block storage drivers
/// (`IOBlockStorageDriver` → "Statistics" → "Bytes (Read)" / "Bytes (Write)").
///
/// Disk images are skipped: their reads and writes also reach the physical disk that
/// stores the image, so counting both would double the numbers.
struct PerformanceDiskReader {
    private var tracker = PerformanceCounterTracker<UInt64>()
    /// Registry entry ID → whether the driver belongs to a virtual (disk image) device.
    private var virtualDrivers: [UInt64: Bool] = [:]

    init() {}

    /// Bytes read (`first`) and written (`second`) since the previous call, or nil on the first call.
    mutating func read() -> PerformanceCounterPair? {
        var readings: [UInt64: PerformanceCounterPair] = [:]
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            tracker.reset()
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var seen = Set<UInt64>()
        while case let driver = IOIteratorNext(iterator), driver != IO_OBJECT_NULL {
            defer { IOObjectRelease(driver) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &entryID) == KERN_SUCCESS else { continue }
            seen.insert(entryID)
            let isVirtual: Bool
            if let cached = virtualDrivers[entryID] {
                isVirtual = cached
            } else {
                isVirtual = Self.isVirtualDevice(driver)
                virtualDrivers[entryID] = isVirtual
            }
            guard !isVirtual, let statistics = Self.statistics(of: driver) else { continue }
            readings[entryID] = statistics
        }
        // Forget drivers of disks that were ejected.
        if virtualDrivers.count > seen.count {
            virtualDrivers = virtualDrivers.filter { seen.contains($0.key) }
        }
        return tracker.update(with: readings)
    }

    mutating func reset() {
        tracker.reset()
    }

    private static func statistics(of driver: io_registry_entry_t) -> PerformanceCounterPair? {
        guard let value = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let statistics = value as? [String: Any] else { return nil }
        let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        return PerformanceCounterPair(first: read, second: written)
    }

    /// True for drivers whose device reports a "Virtual Interface" interconnect (disk images).
    private static func isVirtualDevice(_ driver: io_registry_entry_t) -> Bool {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(driver, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault, options),
              let characteristics = value as? [String: Any] else { return false }
        return (characteristics["Physical Interconnect"] as? String) == "Virtual Interface"
    }
}
