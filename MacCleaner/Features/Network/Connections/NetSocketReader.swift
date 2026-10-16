import Darwin
import Foundation

/// Reads every TCP and UDP socket on the Mac, extending the Ports tab's `PortSysProc`:
///
/// - per process through libproc (`PROC_PIDLISTFDS` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`): exact owners, for
///   the processes this user may inspect;
/// - system-wide through the kernel PCB lists `net.inet.tcp.pcblist_n` and `net.inet.udp.pcblist_n`: every user's
///   sockets, attributed by the kernel to the process that last used each one (`so_last_pid`).
///
/// Pure queries: no signals, no writes, nothing leaves the Mac. Every buffer is bounds-checked; a malformed or
/// unknown record layout makes the kernel-list reader return nil rather than guess.
enum NetSocketReader {
    // MARK: - Per process (libproc)

    /// Every TCP (any state) and UDP socket of `processes`, deduplicated per process (dup'ed descriptors).
    /// Processes that can't be inspected (other users, exiting) are skipped.
    static func descriptorSockets(of processes: [PortProcessBasic]) -> [NetSocketRecord] {
        var fdBuffer: [proc_fdinfo] = []
        var info = socket_fdinfo()
        var result: [NetSocketRecord] = []
        for process in processes where process.pid > 0 {
            guard let count = PortSysProc.listFileDescriptors(pid: process.pid, into: &fdBuffer), count > 0 else { continue }
            var seen = Set<String>()
            for index in 0..<count where fdBuffer[index].proc_fdtype == PortSysProc.socketFDType {
                guard let record = socketRecord(pid: process.pid, fd: fdBuffer[index].proc_fd, scratch: &info),
                      seen.insert(record.endpointKey).inserted else { continue }
                result.append(record)
            }
        }
        return result
    }

    /// The TCP or UDP socket behind `fd`, nil for any other kind of descriptor or socket.
    static func socketRecord(pid: Int32, fd: Int32, scratch info: inout socket_fdinfo) -> NetSocketRecord? {
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let family = info.psi.soi_family
        guard family == AF_INET || family == AF_INET6 else { return nil }

        let inet: in_sockinfo
        let transport: NetTransport
        var state: NetTCPState?
        switch info.psi.soi_kind {
        case PortSysProc.socketInfoTCP:
            inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
            transport = .tcp
            state = NetTCPState(rawValue: info.psi.soi_proto.pri_tcp.tcpsi_state)
        case PortSysProc.socketInfoIn where info.psi.soi_protocol == IPPROTO_UDP:
            inet = info.psi.soi_proto.pri_in
            transport = .udp
        default:
            return nil
        }
        return record(inet: inet, socketFamily: family, transport: transport, state: state, pid: pid,
                      effectivePID: nil, source: .descriptor)
    }

    /// Builds a record from libproc's `in_sockinfo`. The PCB's version flags decide how its addresses are stored
    /// (an IPv4-only PCB on an AF_INET6 socket keeps them in the in4in6 form), as in `PortSysProc`.
    private static func record(inet: in_sockinfo, socketFamily: Int32, transport: NetTransport, state: NetTCPState?,
                               pid: Int32, effectivePID: Int32?, source: NetSocketRecord.Source) -> NetSocketRecord {
        let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
        let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport))
        let local: (String, PortIPFamily)
        let remote: (String, PortIPFamily)
        if PortSysProc.isIPv4Only(vflag: inet.insi_vflag) || socketFamily == AF_INET {
            local = (PortSysProc.render(ipv4: inet.insi_laddr.ina_46.i46a_addr4), .ipv4)
            remote = (PortSysProc.render(ipv4: inet.insi_faddr.ina_46.i46a_addr4), .ipv4)
        } else {
            local = render6(inet.insi_laddr.ina_6)
            remote = render6(inet.insi_faddr.ina_6)
        }
        let hasPeer = remotePort != 0 && remote.0 != "*"
        return NetSocketRecord(transport: transport, family: local.1, localAddress: local.0, localPort: localPort,
                               remoteAddress: hasPeer ? remote.0 : nil, remotePort: hasPeer ? remotePort : nil,
                               state: state, pid: pid, effectivePID: effectivePID, source: source)
    }

    /// An IPv6 address, or the IPv4 address inside a v4-mapped one.
    private static func render6(_ address: in6_addr) -> (String, PortIPFamily) {
        if let mapped = PortSysProc.ipv4Mapped(address) {
            return (PortSysProc.render(ipv4: mapped), .ipv4)
        }
        var copy = address
        return (PortSysProc.render(ipv6: &copy), .ipv6)
    }

    // MARK: - System-wide (kernel PCB lists)

    /// Every TCP and UDP socket on the system, or nil when macOS doesn't provide the lists to this process (a
    /// command-line binary outside an app bundle gets empty lists) or their layout is unknown.
    static func kernelSockets() -> [NetSocketRecord]? {
        guard let tcp = PortSysProc.readSysctl(named: "net.inet.tcp.pcblist_n"),
              let tcpRecords = tcp.withUnsafeBytes({ parsePCBList($0, transport: .tcp) }) else { return nil }
        let udpRecords = PortSysProc.readSysctl(named: "net.inet.udp.pcblist_n")
            .flatMap { data in data.withUnsafeBytes { parsePCBList($0, transport: .udp) } } ?? []
        return tcpRecords + udpRecords
    }

    private typealias Layout = PortSysProc.PCBLayout

    /// Parses a `net.inet.tcp.pcblist_n` or `net.inet.udp.pcblist_n` buffer (see `PortSysProc.parsePCBList` for the
    /// record layout). TCP PCBs end with a tcpcb record; UDP PCBs have none, so a UDP socket is complete once its
    /// inpcb and socket records were read. nil when the buffer is malformed, uses an unknown layout, or contains no
    /// PCBs at all (a filtered view).
    static func parsePCBList(_ buffer: UnsafeRawBufferPointer, transport: NetTransport) -> [NetSocketRecord]? {
        let end = buffer.count
        func u32(_ offset: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        func roundUp8(_ value: Int) -> Int { (value + 7) & ~7 }

        guard end >= Layout.generationHeaderSize, Int(u32(0)) == Layout.generationHeaderSize else { return nil }

        var records: [NetSocketRecord] = []
        var pcbCount = 0
        var inpcb: Int?, socket: Int?, tcpcb: Int?
        var offset = Layout.generationHeaderSize

        while offset + 8 <= end {
            let length = Int(u32(offset))
            // The list is terminated by a trailing xinpgen (length 24).
            if length <= Layout.generationHeaderSize { break }
            guard offset + length <= end else { return nil }

            switch u32(offset + 4) {
            case Layout.kindInpcb:
                guard length == Layout.inpcbSize else { return nil }
                if inpcb != nil { socket = nil; tcpcb = nil }
                inpcb = offset
                pcbCount += 1
            case Layout.kindSocket:
                guard length == Layout.socketSize else { return nil }
                if socket != nil { inpcb = nil; tcpcb = nil }
                socket = offset
            case Layout.kindTcpcb:
                guard transport == .tcp else { break }
                guard length >= Layout.tcpcbMinimumSize else { return nil }
                if tcpcb != nil { inpcb = nil; socket = nil }
                tcpcb = offset
            default:
                break   // socket buffers and stats are not needed
            }

            if let inp = inpcb, let so = socket, transport == .udp || tcpcb != nil {
                if let record = pcbRecord(buffer, inpcb: inp, socket: so, tcpcb: tcpcb, transport: transport) {
                    records.append(record)
                }
                inpcb = nil; socket = nil; tcpcb = nil
            }
            offset += roundUp8(length)
        }
        return pcbCount > 0 ? records : nil
    }

    private static func pcbRecord(_ buffer: UnsafeRawBufferPointer, inpcb: Int, socket: Int, tcpcb: Int?,
                                  transport: NetTransport) -> NetSocketRecord? {
        let pid = buffer.loadUnaligned(fromByteOffset: socket + Layout.socketLastPID, as: Int32.self)
        let effective = buffer.loadUnaligned(fromByteOffset: socket + Layout.socketEffectivePID, as: Int32.self)
        let family = buffer.loadUnaligned(fromByteOffset: socket + Layout.socketFamily, as: Int32.self)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var state: NetTCPState?
        if let tcpcb {
            state = NetTCPState(rawValue: buffer.loadUnaligned(fromByteOffset: tcpcb + Layout.tcpcbState, as: Int32.self))
        }
        let localPort = UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: inpcb + Layout.inpcbLocalPort, as: UInt16.self))
        let remotePort = UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: inpcb + Layout.inpcbForeignPort, as: UInt16.self))
        let versionFlag = buffer[inpcb + Layout.inpcbVersionFlag]

        let local: (String, PortIPFamily)
        let remote: (String, PortIPFamily)
        if family == AF_INET6, !PortSysProc.isIPv4Only(vflag: versionFlag) {
            local = render6(load6(buffer, at: inpcb + Layout.inpcbLocalAddress))
            remote = render6(load6(buffer, at: inpcb + Layout.inpcbForeignAddress))
        } else {
            let localV4 = buffer.loadUnaligned(fromByteOffset: inpcb + Layout.inpcbLocalIPv4, as: UInt32.self)
            let remoteV4 = buffer.loadUnaligned(fromByteOffset: inpcb + Layout.inpcbForeignIPv4, as: UInt32.self)
            local = (PortSysProc.render(ipv4: in_addr(s_addr: localV4)), .ipv4)
            remote = (PortSysProc.render(ipv4: in_addr(s_addr: remoteV4)), .ipv4)
        }
        let hasPeer = remotePort != 0 && remote.0 != "*"
        return NetSocketRecord(transport: transport, family: local.1, localAddress: local.0, localPort: localPort,
                               remoteAddress: hasPeer ? remote.0 : nil, remotePort: hasPeer ? remotePort : nil,
                               state: state, pid: pid,
                               effectivePID: effective > 0 && effective != pid ? effective : nil,
                               source: .kernelList)
    }

    private static func load6(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> in6_addr {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { out in
            out.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + 16)]))
        }
        return address
    }

    // MARK: - Merging

    /// Descriptor records first (exact owners), then kernel-list records for sockets no inspected process holds
    /// (other users' and macOS's sockets, TIME_WAIT leftovers).
    static func merge(descriptor: [NetSocketRecord], kernel: [NetSocketRecord]?) -> [NetSocketRecord] {
        var seen = Set(descriptor.map(\.endpointKey))
        var result = descriptor
        for record in kernel ?? [] where seen.insert(record.endpointKey).inserted {
            result.append(record)
        }
        return result
    }
}
