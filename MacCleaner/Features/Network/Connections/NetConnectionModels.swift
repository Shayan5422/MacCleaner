import Foundation

/// Transport of a socket.
enum NetTransport: String, Sendable, Hashable, Codable {
    case tcp, udp

    var title: String { rawValue.uppercased() }
}

/// TCP connection states (the `TSI_S_*` / `TCPS_*` numbering of <netinet/tcp_fsm.h>).
enum NetTCPState: Int32, Sendable, Hashable, CaseIterable {
    case closed = 0, listen, synSent, synReceived, established, closeWait, finWait1, closing, lastAck, finWait2, timeWait

    var title: String {
        switch self {
        case .closed: return "Closed"
        case .listen: return "Listening"
        case .synSent: return "Connecting"
        case .synReceived: return "Accepting"
        case .established: return "Established"
        case .closeWait: return "Remote closed"
        case .finWait1, .finWait2, .closing, .lastAck: return "Closing"
        case .timeWait: return "Closed, waiting"
        }
    }

    /// The name tools like netstat use ("CLOSE_WAIT"), for tooltips.
    var systemName: String {
        switch self {
        case .closed: return "CLOSED"
        case .listen: return "LISTEN"
        case .synSent: return "SYN_SENT"
        case .synReceived: return "SYN_RCVD"
        case .established: return "ESTABLISHED"
        case .closeWait: return "CLOSE_WAIT"
        case .finWait1: return "FIN_WAIT_1"
        case .closing: return "CLOSING"
        case .lastAck: return "LAST_ACK"
        case .finWait2: return "FIN_WAIT_2"
        case .timeWait: return "TIME_WAIT"
        }
    }

    /// Exchanging (or about to exchange) data with the remote end.
    var isActive: Bool {
        switch self {
        case .synSent, .synReceived, .established, .closeWait: return true
        default: return false
        }
    }
}

/// One socket as read from the kernel: libproc (the current user's processes, per file descriptor) or the
/// system-wide PCB lists (`net.inet.tcp.pcblist_n` / `net.inet.udp.pcblist_n`, every user, attributed by the
/// kernel to the process that last used the socket).
struct NetSocketRecord: Sendable, Hashable {
    enum Source: String, Sendable, Hashable {
        /// The process's own descriptor table (exact owner).
        case descriptor
        /// The system-wide list (owner = the process that last used the socket).
        case kernelList
    }

    let transport: NetTransport
    let family: PortIPFamily
    /// "*" for an unspecified address.
    let localAddress: String
    let localPort: UInt16
    /// nil for a socket without a peer (listening TCP, unconnected UDP).
    let remoteAddress: String?
    let remotePort: UInt16?
    /// nil for UDP.
    let state: NetTCPState?
    let pid: Int32
    /// The app a daemon works for (`so_e_pid`), when the kernel list says it differs from `pid`.
    let effectivePID: Int32?
    let source: Source

    /// Identifies the socket across scans (owner excluded: a kernel-list entry may be re-attributed).
    var endpointKey: String {
        "\(transport.rawValue)|\(localAddress)|\(localPort)|\(remoteAddress ?? "-")|\(remotePort.map(String.init) ?? "-")"
    }

    var isListening: Bool { state == .listen }
}

/// What the Connections tab shows about the process that owns a socket.
struct NetProcessInfo: Sendable, Hashable {
    let pid: Int32
    let startTime: UInt64
    let uid: UInt32
    /// Executable name, or the kernel's short name when the path can't be read.
    let name: String
    let executablePath: String?
    /// Outermost .app bundle, for its icon and name.
    let appBundlePath: String?
    let appName: String?
    let isCurrentUser: Bool
    /// The process exited (a kernel-list socket in TIME_WAIT keeps its last user's pid).
    let hasExited: Bool

    var displayName: String { appName ?? name }
    var identity: PortProcessIdentity { PortProcessIdentity(pid: pid, startTime: startTime) }
}

/// One row of the Connections tab.
struct NetConnection: Sendable, Hashable, Identifiable {
    let record: NetSocketRecord
    let process: NetProcessInfo
    /// When Mac Cleaner first saw this socket (it can't know when the socket was really opened).
    let firstSeen: Date

    var id: String { "\(record.endpointKey)|\(process.pid)" }
    var transport: NetTransport { record.transport }
    var state: NetTCPState? { record.state }

    /// A remote address worth looking up and checking: not loopback, link-local, multicast or unspecified.
    var checkableRemoteAddress: String? {
        guard let remote = record.remoteAddress, NetAddress.isRoutable(remote) else { return nil }
        return remote
    }

    var isEstablished: Bool { record.state == .established }
    var isListening: Bool { record.state == .listen }
}

/// Filters of the Connections tab.
enum NetConnectionFilter: String, CaseIterable, Identifiable, Sendable {
    case established, listening, udp, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .established: return "Established"
        case .listening: return "Listening"
        case .udp: return "UDP"
        case .all: return "All"
        }
    }

    func includes(_ connection: NetConnection) -> Bool {
        switch self {
        case .established: return connection.transport == .tcp && connection.state?.isActive == true
        case .listening: return connection.isListening
        case .udp: return connection.transport == .udp
        case .all: return true
        }
    }
}

/// A connection to a server listed by a downloaded threat feed.
struct NetThreatHit: Sendable, Hashable, Identifiable {
    let process: NetProcessInfo
    let remoteAddress: String
    let remotePort: UInt16?
    /// The host name the address resolved to, when it was the name that matched.
    let host: String?
    let match: ThreatIntelMatch
    let firstSeen: Date

    /// Stable per process and indicator (the same malware connecting again is the same hit).
    var id: String { "\(process.pid)@\(process.startTime)|\(match.indicator)" }

    var remoteText: String {
        NetAddress.endpoint(remoteAddress, port: remotePort)
    }
}

/// Small helpers for IP address text.
enum NetAddress {
    /// "1.2.3.4:443", "[2001:db8::1]:443", "1.2.3.4".
    static func endpoint(_ address: String, port: UInt16?) -> String {
        guard let port else { return address }
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    /// Parses an IPv4 or IPv6 address (scoped "fe80::1%en0" accepted).
    static func bytes(_ text: String) -> [UInt8]? {
        let plain = text.split(separator: "%").first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, plain, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    /// The IPv4 address inside an IPv4-mapped IPv6 address (::ffff:a.b.c.d).
    static func unmapped(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return Array(bytes[12..<16])
        }
        return bytes
    }

    enum Scope: Sendable, Equatable {
        case loopback, linkLocal, privateNetwork, sharedCGNAT, multicast, unspecified, publicInternet
    }

    static func scope(_ text: String) -> Scope? {
        guard let raw = bytes(text) else { return nil }
        let b = unmapped(raw)
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _): return .unspecified
            case (127, _): return .loopback
            case (10, _): return .privateNetwork
            case (172, 16...31): return .privateNetwork
            case (192, 168): return .privateNetwork
            case (169, 254): return .linkLocal
            case (100, 64...127): return .sharedCGNAT
            case (224...239, _): return .multicast
            case (255, 255) where b[2] == 255 && b[3] == 255: return .multicast
            default: return .publicInternet
            }
        }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return .linkLocal }
        if (b[0] & 0xfe) == 0xfc { return .privateNetwork }   // fc00::/7 unique local
        if b[0] == 0xff { return .multicast }
        return .publicInternet
    }

    /// Worth checking against threat feeds and resolving: anything but loopback, link-local, multicast and
    /// unspecified addresses. Private addresses count (malware can use a compromised device on the network).
    static func isRoutable(_ text: String) -> Bool {
        switch scope(text) {
        case .publicInternet?, .privateNetwork?, .sharedCGNAT?: return true
        default: return false
        }
    }

    static func isPublic(_ text: String) -> Bool {
        scope(text) == .publicInternet
    }
}
