import Darwin
import Foundation

/// Cumulative byte counters of one network interface.
struct PerformanceNetworkInterfaceReading: Sendable, Hashable {
    var index: Int32
    var name: String
    var flags: Int32
    var type: Int32
    var bytesIn: UInt64
    var bytesOut: UInt64
}

/// Identifies an interface across readings; a different interface reusing the same
/// index is treated as new.
struct PerformanceNetworkInterfaceKey: Sendable, Hashable {
    var index: Int32
    var name: String
}

enum PerformanceNetworkMath {
    /// Whether an interface's traffic counts toward the Mac's network activity.
    ///
    /// Loopback stays inside the Mac. VPN and other point-to-point tunnels, bridges
    /// and virtual-machine adapters carry traffic that is also counted on the physical
    /// interface it travels through, so including them would count the same data twice.
    static func isCounted(name: String, flags: Int32, type: Int32) -> Bool {
        guard flags & IFF_UP != 0 else { return false }
        if flags & IFF_LOOPBACK != 0 || flags & IFF_POINTOPOINT != 0 { return false }
        if type == IFT_BRIDGE || type == IFT_LOOP || type == IFT_GIF || type == IFT_STF { return false }
        if name.hasPrefix("vmenet") { return false }
        return true
    }
}

/// Network throughput from cumulative interface counters.
///
/// Counters come from the interface MIB (`net.link.generic.ifdata.<index>.general`),
/// which reports exact 64-bit totals. The routing-socket list (`NET_RT_IFLIST2`) is
/// used as a fallback; on recent macOS versions it only exposes 32-bit counters rounded
/// to 1 KB, so its readings are treated as wrapping 32-bit values.
struct PerformanceNetworkReader {
    private enum Source { case interfaceMIB, routingList }

    private var tracker = PerformanceCounterTracker<PerformanceNetworkInterfaceKey>()
    private var source: Source?

    init() {}

    /// Bytes received (`first`) and sent (`second`) since the previous call, or nil on the first call.
    mutating func read() -> PerformanceCounterPair? {
        let readingSource: Source
        var interfaces = Self.interfaceMIBReadings()
        if interfaces != nil {
            readingSource = .interfaceMIB
        } else {
            interfaces = Self.routingListReadings()
            readingSource = .routingList
        }
        guard let interfaces else {
            tracker.reset()
            return nil
        }
        if source != readingSource {
            // Never mix exact and truncated counters in one delta.
            tracker.reset()
            source = readingSource
        }
        var counters: [PerformanceNetworkInterfaceKey: PerformanceCounterPair] = [:]
        for interface in interfaces where PerformanceNetworkMath.isCounted(name: interface.name, flags: interface.flags, type: interface.type) {
            counters[PerformanceNetworkInterfaceKey(index: interface.index, name: interface.name)] = PerformanceCounterPair(first: interface.bytesIn, second: interface.bytesOut)
        }
        return tracker.update(with: counters, wrapsAt32Bits: readingSource == .routingList)
    }

    mutating func reset() {
        tracker.reset()
        source = nil
    }

    // MARK: - Interface MIB

    static func interfaceMIBReadings() -> [PerformanceNetworkInterfaceReading]? {
        var count: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        var countMIB: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&countMIB, u_int(countMIB.count), &count, &size, nil, 0) == 0, count > 0 else { return nil }

        var readings: [PerformanceNetworkInterfaceReading] = []
        readings.reserveCapacity(Int(count))
        var data = ifmibdata()
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, 0, IFDATA_GENERAL]
        for index in 1...Int32(clamping: count) {
            mib[4] = index
            var dataSize = MemoryLayout<ifmibdata>.size
            // Indexes of removed interfaces return ENOENT; skip them.
            guard sysctl(&mib, u_int(mib.count), &data, &dataSize, nil, 0) == 0, dataSize == MemoryLayout<ifmibdata>.size else { continue }
            let name = withUnsafeBytes(of: data.ifmd_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            readings.append(PerformanceNetworkInterfaceReading(
                index: index,
                name: name,
                // Interface flags are 16 bits wide; the MIB sign-extends them.
                flags: Int32(data.ifmd_flags & 0xFFFF),
                type: Int32(data.ifmd_data.ifi_type),
                bytesIn: data.ifmd_data.ifi_ibytes,
                bytesOut: data.ifmd_data.ifi_obytes
            ))
        }
        return readings.isEmpty ? nil : readings
    }

    // MARK: - Routing list (fallback)

    static func routingListReadings() -> [PerformanceNetworkInterfaceReading]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Interfaces can appear between the two calls; leave some room.
        length += 2048
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var readings: [PerformanceNetworkInterfaceReading] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    let name = if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil ? String(nulTerminated: nameBuffer) : "if\(message.ifm_index)"
                    readings.append(PerformanceNetworkInterfaceReading(
                        index: Int32(message.ifm_index),
                        name: name,
                        flags: message.ifm_flags & 0xFFFF,
                        type: Int32(message.ifm_data.ifi_type),
                        bytesIn: message.ifm_data.ifi_ibytes,
                        bytesOut: message.ifm_data.ifi_obytes
                    ))
                }
                offset += messageLength
            }
        }
        return readings.isEmpty ? nil : readings
    }
}
