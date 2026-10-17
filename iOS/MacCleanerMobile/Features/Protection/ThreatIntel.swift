import Darwin
import Foundation

/// Host names, IP addresses and web addresses, normalized the same way for the feeds, Safari's
/// rules and the link check (the rules of the Mac app's threat intel).
enum ThreatIntel {
    // MARK: Host names

    /// A DNS host name in lower case without a trailing dot, or nil when it isn't one.
    static func hostName(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253, host.contains("."), canonicalIP(host) == nil else { return nil }
        var labelLength = 0
        var labelHasLetter = false
        for byte in host.utf8 {
            switch byte {
            case UInt8(ascii: "."):
                guard labelLength > 0 else { return nil }
                labelLength = 0
                labelHasLetter = false
                continue
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                labelHasLetter = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                break
            default:
                return nil
            }
            labelLength += 1
            if labelLength > 63 { return nil }
        }
        // The top-level domain has a letter: "1.2.3" isn't a name.
        guard labelLength > 0, labelHasLetter else { return nil }
        return host
    }

    /// localhost and other names that never reach the internet (reserved or private top-level domains).
    static func isLocalName(_ host: String) -> Bool {
        localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let localSuffixes = ["localhost", "local", "localdomain", "home.arpa", "internal", "lan", "home", "corp",
                                        "invalid", "test", "example"]

    /// The host and each parent domain, longest first, never a bare top-level domain:
    /// "a.b.example.com" → ["a.b.example.com", "b.example.com", "example.com"].
    static func hostAndParents(_ host: String) -> [String] {
        var result = [host]
        var current = Substring(host)
        while let dot = current.firstIndex(of: ".") {
            let parent = current[current.index(after: dot)...]
            guard parent.contains(".") else { break }
            result.append(String(parent))
            current = parent
        }
        return result
    }

    /// "www.example.com" → "example.com"; other names stay as they are.
    static func withoutWWW(_ host: String) -> String {
        guard host.hasPrefix("www."), hostName(String(host.dropFirst(4))) != nil else { return host }
        return String(host.dropFirst(4))
    }

    // MARK: IP addresses

    /// Canonical text form of an IPv4 or IPv6 address (IPv4-mapped IPv6 becomes IPv4), or nil.
    static func canonicalIP(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        var v4 = in_addr()
        if text.contains("."), !text.contains(":"), inet_pton(AF_INET, text, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return string(from: buffer)
        }
        var v6 = in6_addr()
        guard text.contains(":"), inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return bytes[12...].map(String.init).joined(separator: ".")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return string(from: buffer)
    }

    /// Whether an address is on the public internet: not private, loopback, link-local, shared
    /// (carrier-grade NAT), multicast, documentation or reserved.
    static func isPublicIP(_ raw: String) -> Bool {
        guard let ip = canonicalIP(raw) else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let b = withUnsafeBytes(of: v4) { Array($0) }
            switch (b[0], b[1], b[2]) {
            case (0, _, _), (10, _, _), (127, _, _): return false
            case (100, 64...127, _): return false
            case (169, 254, _): return false
            case (172, 16...31, _): return false
            case (192, 0, 0), (192, 0, 2), (192, 168, _): return false
            case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
            case (224..., _, _): return false
            default: return true
            }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        // Global unicast is 2000::/3; 2001:db8::/32 is for documentation.
        guard b[0] & 0xE0 == 0x20 else { return false }
        return !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8)
    }

    /// "1.2.3.4:443" or "[2001:db8::1]:443" → canonical "ip:port".
    static func ipPort(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let ip: String
        let portText: Substring
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            ip = String(text[text.index(after: text.startIndex)..<close])
            guard text[text.index(after: close)...].hasPrefix(":") else { return nil }
            portText = text[text.index(close, offsetBy: 2)...]
        } else {
            guard let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 else { return nil }
            ip = String(text[..<colon])
            portText = text[text.index(after: colon)...]
        }
        guard let port = Int(portText), (1...65535).contains(port), let canonical = canonicalIP(ip) else { return nil }
        return canonical.contains(":") ? "[\(canonical)]:\(port)" : "\(canonical):\(port)"
    }

    /// The IP of an "ip:port" value.
    static func ip(ofIPPort value: String) -> String? {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            return String(value[value.index(after: value.startIndex)..<close])
        }
        return value.lastIndex(of: ":").map { String(value[..<$0]) }
    }

    // MARK: Web addresses

    /// A web address split into the parts the feeds and Safari compare.
    struct Address: Sendable, Hashable {
        /// "http", "https" or "ftp".
        var scheme: String
        /// A lower-case DNS name or a canonical IP (IPv6 without brackets).
        var host: String
        /// nil for the scheme's default port.
        var port: Int?
        /// Percent-encoded, "/" when empty.
        var path: String
        var query: String?

        var isIPAddress: Bool { ThreatIntel.canonicalIP(host) != nil }

        var authority: String {
            (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
        }

        /// The path with its query.
        var resource: String { path + (query.map { "?" + $0 } ?? "") }

        /// "http://example.com/path?x=1".
        var string: String { "\(scheme)://\(authority)\(resource)" }
    }

    /// Parses an http(s) or ftp address: lower-case scheme and host, no default port, fragment or
    /// credentials. Path and query keep their case and encoding.
    static func address(_ raw: String) -> Address? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count < 8_192, !text.contains("\t"),
              let components = URLComponents(string: text, encodingInvalidCharacters: true),
              let scheme = components.scheme?.lowercased(), let defaultPort = defaultPorts[scheme],
              let rawHost = components.encodedHost ?? components.host else { return nil }
        let unbracketed = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let host = canonicalIP(unbracketed) ?? hostName(unbracketed) else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
        return Address(scheme: scheme, host: host, port: port, path: path, query: query)
    }

    /// The normalized text of a web address, e.g. "http://example.com/path?x=1".
    static func normalizedURL(_ raw: String) -> String? {
        address(raw)?.string
    }

    /// What exact-address matching compares: host (without "www."), port, path and query, the
    /// same for http and https.
    static func addressKey(_ address: Address) -> String {
        var key = address
        key.host = withoutWWW(address.host)
        return (address.scheme == "ftp" ? "ftp://" : "") + key.authority + key.resource
    }

    private static let defaultPorts = ["http": 80, "https": 443, "ftp": 21]

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
