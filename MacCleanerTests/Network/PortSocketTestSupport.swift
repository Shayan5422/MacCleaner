import Darwin
import Foundation
@testable import MacCleaner

/// A TCP socket listening on an ephemeral loopback port, opened with plain Darwin APIs.
final class PortTestListener {
    struct SocketError: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
    }

    let port: UInt16
    private var fd: Int32

    /// - Parameter v6Only: sets IPV6_V6ONLY on an AF_INET6 socket before binding (nil keeps the system default).
    init(family: Int32, address: String, v6Only: Bool? = nil) throws {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        do {
            if family == AF_INET6, let v6Only {
                var flag: Int32 = v6Only ? 1 : 0
                guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &flag, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw SocketError(call: "setsockopt", code: errno)
                }
            }
            port = try Self.bindAndListen(fd: fd, family: family, address: address)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
    }

    deinit { close() }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private static func bindAndListen(fd: Int32, family: Int32, address: String) throws -> UInt16 {
        if family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = 0
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { throw SocketError(call: "inet_pton", code: EINVAL) }
            try withSockaddr(&addr) { try bindListen(fd: fd, $0, $1) }
            var bound = sockaddr_in6()
            try withSockaddr(&bound) { try getName(fd: fd, $0, $1) }
            return UInt16(bigEndian: bound.sin6_port)
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { throw SocketError(call: "inet_pton", code: EINVAL) }
            try withSockaddr(&addr) { try bindListen(fd: fd, $0, $1) }
            var bound = sockaddr_in()
            try withSockaddr(&bound) { try getName(fd: fd, $0, $1) }
            return UInt16(bigEndian: bound.sin_port)
        }
    }

    private static func withSockaddr<T>(_ value: inout T,
                                        _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) throws -> Void) throws {
        try withUnsafeMutablePointer(to: &value) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<T>.size))
            }
        }
    }

    private static func bindListen(fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t) throws {
        guard bind(fd, address, length) == 0 else { throw SocketError(call: "bind", code: errno) }
        guard listen(fd, 8) == 0 else { throw SocketError(call: "listen", code: errno) }
    }

    private static func getName(fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t) throws {
        var length = length
        guard getsockname(fd, address, &length) == 0 else { throw SocketError(call: "getsockname", code: errno) }
    }
}

/// Builds a synthetic `net.inet.tcp.pcblist_n` / `net.inet.udp.pcblist_n` buffer with the xnu record layout.
struct PortPCBListBuilder {
    private var bytes: [UInt8] = []

    init() {
        bytes = Self.generationHeader(count: 0)
    }

    /// - Parameter vflag: inp_vflag (INP_IPV4 0x1, INP_IPV6 0x2); defaults to the family's usual value.
    /// - Parameters:
    ///   - remoteIPv4 / remoteIPv6 / remotePort: the foreign end (zero = none).
    ///   - state: the TCP state; nil writes a UDP PCB (no tcpcb record).
    ///   - effectivePID: so_e_pid (0 = none).
    mutating func append(port: UInt16, family: Int32, ipv4: [UInt8] = [], ipv6: [UInt8] = [], vflag: UInt8? = nil,
                         pid: Int32, state: Int32?, remotePort: UInt16 = 0, remoteIPv4: [UInt8] = [],
                         remoteIPv6: [UInt8] = [], effectivePID: Int32 = 0) {
        var inpcb = Self.record(kind: 0x10, length: 104)
        Self.write(remotePort.bigEndian, at: 16, in: &inpcb)
        Self.write(port.bigEndian, at: 18, in: &inpcb)
        inpcb[44] = vflag ?? (family == AF_INET6 ? 0x2 : 0x1)
        if family == AF_INET6 {
            inpcb.replaceSubrange(64..<80, with: ipv6)
            if !remoteIPv6.isEmpty { inpcb.replaceSubrange(48..<64, with: remoteIPv6) }
        } else {
            inpcb.replaceSubrange(76..<80, with: ipv4)
            if !remoteIPv4.isEmpty { inpcb.replaceSubrange(60..<64, with: remoteIPv4) }
        }
        var socket = Self.record(kind: 0x1, length: 104)
        Self.write(family, at: 40, in: &socket)
        Self.write(UInt32(501), at: 64, in: &socket)
        Self.write(pid, at: 68, in: &socket)
        Self.write(effectivePID, at: 72, in: &socket)
        let receiveBuffer = Self.record(kind: 0x2, length: 32)
        let sendBuffer = Self.record(kind: 0x4, length: 32)
        let stats = Self.record(kind: 0x8, length: 44)          // not a multiple of 8: exercises rounding
        var records = [inpcb, socket, receiveBuffer, sendBuffer, stats]
        if let state {
            var tcpcb = Self.record(kind: 0x20, length: 40)
            Self.write(state, at: 36, in: &tcpcb)
            records.append(tcpcb)
        }

        for record in records {
            bytes.append(contentsOf: record)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: (8 - record.count % 8) % 8))
        }
    }

    func finish() -> [UInt8] {
        bytes + Self.generationHeader(count: 0)
    }

    private static func generationHeader(count: UInt32) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 24)
        write(UInt32(24), at: 0, in: &header)
        write(count, at: 4, in: &header)
        return header
    }

    private static func record(kind: UInt32, length: Int) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: length)
        write(UInt32(length), at: 0, in: &record)
        write(kind, at: 4, in: &record)
        return record
    }

    private static func write<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
        withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
    }
}
