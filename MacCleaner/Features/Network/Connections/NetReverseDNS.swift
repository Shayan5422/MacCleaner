import Darwin
import Foundation

/// Reverse-DNS host names for IP addresses ("140.82.112.3" → "lb-140-82-112-3-iad.github.com").
///
/// Only used when the person turns on "Look up host names" in Settings, because every lookup sends a DNS query
/// to the configured DNS server. Answers (including "no name") are cached; lookups for the same address are
/// shared; each lookup gives up after `timeout`, and at most `maxBlockingLookups` resolver calls run at once (a
/// call that timed out keeps its slot until the system resolver returns, so threads stay bounded).
actor NetReverseDNS {
    static let shared = NetReverseDNS()

    private struct Entry {
        let name: String?
        let expires: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let timeout: TimeInterval
    private let gate: NetBlockingGate

    /// Names are kept for an hour; "no name" for five minutes.
    static let positiveLifetime: TimeInterval = 3600
    static let negativeLifetime: TimeInterval = 300
    static let maxBlockingLookups = 6

    init(timeout: TimeInterval = 3, maxBlockingLookups: Int = NetReverseDNS.maxBlockingLookups) {
        self.timeout = timeout
        gate = NetBlockingGate(limit: maxBlockingLookups)
    }

    /// The cached answer: nil when the address wasn't looked up (or the answer expired), `.some(nil)` when it has
    /// no name.
    func cached(_ address: String) -> String?? {
        guard let entry = cache[address], entry.expires > Date() else { return nil }
        return .some(entry.name)
    }

    /// Host name of `address`, or nil when it has none, the lookup timed out, or too many lookups are running.
    func name(for address: String) async -> String? {
        if let entry = cache[address], entry.expires > Date() { return entry.name }
        if let task = inFlight[address] { return await task.value }
        let timeout = self.timeout
        let gate = self.gate
        let task = Task.detached(priority: .utility) { await Self.lookup(address, timeout: timeout, gate: gate) }
        inFlight[address] = task
        let name = await task.value
        inFlight[address] = nil
        if cache.count > 4096 { cache = cache.filter { $0.value.expires > Date() } }
        cache[address] = Entry(name: name, expires: Date().addingTimeInterval(name == nil ? Self.negativeLifetime : Self.positiveLifetime))
        return name
    }

    /// Resolves up to `limit` of `addresses` concurrently and returns the names found.
    func names(for addresses: [String], limit: Int = 48) async -> [String: String] {
        let unique = Array(Set(addresses)).sorted().prefix(limit)
        return await withTaskGroup(of: (String, String?).self) { group in
            for address in unique {
                group.addTask { (address, await self.name(for: address)) }
            }
            var result: [String: String] = [:]
            for await (address, name) in group {
                if let name { result[address] = name }
            }
            return result
        }
    }

    /// One lookup with a deadline. The blocking resolver call runs on a GCD thread; whichever finishes first (the
    /// answer or the deadline) resumes the caller.
    private static func lookup(_ address: String, timeout: TimeInterval, gate: NetBlockingGate) async -> String? {
        guard gate.enter() else { return nil }
        let once = NetOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let name = blockingLookup(address)
                gate.leave()
                if once.claim() { continuation.resume(returning: name) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// `getnameinfo(NI_NAMEREQD)`: the PTR name of an IPv4 or IPv6 address, nil when there is none.
    static func blockingLookup(_ address: String) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var status: Int32 = EAI_FAIL
        var v4 = in_addr()
        var v6 = in6_addr()
        let plain = address.split(separator: "%").first.map(String.init) ?? address
        if inet_pton(AF_INET, plain, &v4) == 1 {
            var socket = sockaddr_in()
            socket.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socket.sin_family = sa_family_t(AF_INET)
            socket.sin_addr = v4
            status = withUnsafePointer(to: &socket) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else if inet_pton(AF_INET6, plain, &v6) == 1 {
            var socket = sockaddr_in6()
            socket.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socket.sin6_family = sa_family_t(AF_INET6)
            socket.sin6_addr = v6
            status = withUnsafePointer(to: &socket) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        }
        guard status == 0 else { return nil }
        let name = String(nulTerminated: host).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // A "name" that is just the address again is no name.
        guard !name.isEmpty, name != plain, NetAddress.bytes(name) == nil else { return nil }
        return name
    }
}

/// Counts blocking calls in progress and refuses new ones above `limit`.
final class NetBlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var running = 0

    init(limit: Int) { self.limit = max(1, limit) }

    func enter() -> Bool {
        lock.withLock {
            guard running < limit else { return false }
            running += 1
            return true
        }
    }

    func leave() {
        lock.withLock { running = max(0, running - 1) }
    }
}

/// True for the first caller only.
final class NetOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
