import Darwin
import Foundation

/// Normalizes URLs so the same address always compares equal: lower-case scheme and host,
/// no default port, no fragment or credentials, "/" for an empty path. Path and query keep
/// their case and encoding.
enum AVURLNormalizer {
    static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 8_192, !text.contains("\t"),
              let components = URLComponents(string: text, encodingInvalidCharacters: true),
              let scheme = components.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme),
              let rawHost = components.host, let host = AVHostNormalizer.normalizeHostOrIP(rawHost) else { return nil }
        let defaults = ["http": 80, "https": 443, "ftp": 21]
        var authority = host.contains(":") ? "[\(host)]" : host
        if let port = components.port, port != defaults[scheme] { authority += ":\(port)" }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        var result = "\(scheme)://\(authority)\(path)"
        if let query = components.percentEncodedQuery, !query.isEmpty { result += "?" + query }
        return result
    }

    /// Host and effective port of a URL (for IP-hosted malware servers).
    static func hostAndPort(of normalized: String) -> (host: String, port: Int)? {
        guard let components = URLComponents(string: normalized), let scheme = components.scheme, let host = components.host else { return nil }
        let defaults = ["http": 80, "https": 443, "ftp": 21]
        guard let port = components.port ?? defaults[scheme] else { return nil }
        return (AVHostNormalizer.normalizeHostOrIP(host) ?? host, port)
    }
}

enum AVHostNormalizer {
    /// A DNS host name in lower case without a trailing dot, or nil when it isn't one.
    static func normalize(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253, host.contains("."), canonicalIP(host) == nil else { return nil }
        let allowed = host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
        guard allowed, !host.hasPrefix("."), !host.contains("..") else { return nil }
        return host
    }

    static func normalizeHostOrIP(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return canonicalIP(trimmed) ?? normalize(trimmed)
    }

    /// Canonical text form of an IPv4 or IPv6 address (IPv4-mapped IPv6 becomes IPv4).
    static func canonicalIP(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        var v4 = in_addr()
        if text.contains("."), !text.contains(":"), inet_pton(AF_INET, text, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(nulTerminated: buffer)
        }
        var v6 = in6_addr()
        guard text.contains(":"), inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return bytes[12...].map(String.init).joined(separator: ".")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(nulTerminated: buffer)
    }

    /// "1.2.3.4:443" or "[2001:db8::1]:443" → canonical "ip:port".
    static func normalizeIPPort(_ raw: String) -> String? {
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
        return key(ip: canonical, port: port)
    }

    static func key(ip: String, port: Int) -> String {
        ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }
}

/// Where an indicator came from.
enum AVIntelSource: String, Codable, Sendable, CaseIterable {
    case urlhaus, threatFox

    var title: String {
        switch self {
        case .urlhaus: return "URLhaus (abuse.ch)"
        case .threatFox: return "ThreatFox (abuse.ch)"
        }
    }
}

/// One downloaded indicator, kept until `retention` after it was last seen in its feed.
struct AVIndicator: Sendable, Hashable {
    enum Kind: String, Sendable, CaseIterable {
        case url, host, ipPort, sha256
    }

    var kind: Kind
    var value: String
    var source: AVIntelSource
    var threatType: String
    var malware: String?
    var confidence: Int?
    var firstSeen: Date
    var lastSeen: Date
    var isCompromised = false
    /// ThreatFox IOC id, for its web page.
    var reference: String?

    var key: String { kind.rawValue + "|" + value }

    var referenceURL: URL? {
        switch source {
        case .threatFox:
            return reference.flatMap { URL(string: "https://threatfox.abuse.ch/ioc/\($0)/") }
        case .urlhaus:
            var components = URLComponents(string: "https://urlhaus.abuse.ch/browse.php")
            components?.queryItems = [URLQueryItem(name: "search", value: value)]
            return components?.url
        }
    }

    var match: ThreatIntelMatch {
        ThreatIntelMatch(indicator: value, threatType: threatType, malware: malware, confidence: confidence,
                         source: source.title, firstSeen: firstSeen, reference: referenceURL)
    }
}

/// The accumulated indicators of all feeds (in `intel/indicators.tsv`).
struct AVIntelDatabase: Sendable {
    private(set) var entries: [String: AVIndicator] = [:]

    init() {}

    var count: Int { entries.count }
    func count(source: AVIntelSource) -> Int { entries.values.filter { $0.source == source }.count }
    var sha256Hashes: [String] { entries.values.filter { $0.kind == .sha256 }.map(\.value).sorted() }

    /// Adds fresh indicators, keeping the earliest first-seen date.
    mutating func merge(_ indicators: [AVIndicator]) {
        for indicator in indicators {
            if var existing = entries[indicator.key] {
                existing.lastSeen = max(existing.lastSeen, indicator.lastSeen)
                existing.firstSeen = min(existing.firstSeen, indicator.firstSeen)
                existing.threatType = indicator.threatType
                existing.malware = indicator.malware ?? existing.malware
                existing.confidence = indicator.confidence ?? existing.confidence
                existing.isCompromised = indicator.isCompromised
                existing.reference = indicator.reference ?? existing.reference
                existing.source = indicator.source
                entries[indicator.key] = existing
            } else {
                entries[indicator.key] = indicator
            }
        }
    }

    /// Drops indicators not seen since `cutoff`.
    mutating func expire(before cutoff: Date) {
        entries = entries.filter { $0.value.lastSeen >= cutoff }
    }

    mutating func remove(source: AVIntelSource) {
        entries = entries.filter { $0.value.source != source }
    }

    // MARK: Storage (tab-separated, one indicator per line)

    func write(to url: URL) throws {
        var text = "# kind\tvalue\tsource\tthreat_type\tmalware\tconfidence\tfirst_seen\tlast_seen\tcompromised\treference\n"
        for indicator in entries.values.sorted(by: { $0.key < $1.key }) {
            let fields = [
                indicator.kind.rawValue, indicator.value, indicator.source.rawValue, indicator.threatType,
                indicator.malware ?? "", indicator.confidence.map(String.init) ?? "",
                String(Int(indicator.firstSeen.timeIntervalSince1970)), String(Int(indicator.lastSeen.timeIntervalSince1970)),
                indicator.isCompromised ? "1" : "0", indicator.reference ?? "",
            ].map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            text += fields.joined(separator: "\t") + "\n"
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> AVIntelDatabase {
        var database = AVIntelDatabase()
        guard let data = try? Data(contentsOf: url) else { return database }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 10, let kind = AVIndicator.Kind(rawValue: fields[0]), let source = AVIntelSource(rawValue: fields[2]),
                  let first = TimeInterval(fields[6]), let last = TimeInterval(fields[7]), !fields[1].isEmpty else { continue }
            let indicator = AVIndicator(kind: kind, value: fields[1], source: source, threatType: fields[3],
                                        malware: fields[4].isEmpty ? nil : fields[4], confidence: Int(fields[5]),
                                        firstSeen: Date(timeIntervalSince1970: first), lastSeen: Date(timeIntervalSince1970: last),
                                        isCompromised: fields[8] == "1", reference: fields[9].isEmpty ? nil : fields[9])
            database.entries[indicator.key] = indicator
        }
        return database
    }

    func index(sources: Set<AVIntelSource> = Set(AVIntelSource.allCases)) -> AVThreatIntelIndex {
        AVThreatIntelIndex(indicators: entries.values.filter { sources.contains($0.source) })
    }
}

/// Fast, immutable lookups in the loaded feeds; safe from any thread.
/// Installed into `ThreatIntelRegistry.shared` for the Network page and the Download Shield.
final class AVThreatIntelIndex: ThreatIntelLookup, Sendable {
    let urls: [String: ThreatIntelMatch]
    /// Domains from the URLhaus hosts file and ThreatFox. Hosts that only appear inside URLs
    /// (often shared services such as github.com) are never added here.
    let hosts: [String: ThreatIntelMatch]
    let ipPorts: [String: ThreatIntelMatch]
    let ips: [String: ThreatIntelMatch]
    let indicatorCount: Int

    init(indicators: [AVIndicator]) {
        var urls: [String: ThreatIntelMatch] = [:]
        var hosts: [String: ThreatIntelMatch] = [:]
        var ipPorts: [String: ThreatIntelMatch] = [:]
        var ips: [String: ThreatIntelMatch] = [:]
        for indicator in indicators {
            let match = indicator.match
            switch indicator.kind {
            case .url:
                urls[indicator.value] = match
                if let (host, port) = AVURLNormalizer.hostAndPort(of: indicator.value), AVHostNormalizer.canonicalIP(host) != nil {
                    ipPorts[AVHostNormalizer.key(ip: host, port: port)] = ipPorts[AVHostNormalizer.key(ip: host, port: port)] ?? match
                    ips[host] = ips[host] ?? match
                }
            case .host:
                // Compromised legitimate sites are matched by exact URL only.
                if !indicator.isCompromised { hosts[indicator.value] = match }
            case .ipPort:
                ipPorts[indicator.value] = match
                if let ip = Self.ip(fromKey: indicator.value) { ips[ip] = ips[ip] ?? match }
            case .sha256:
                break
            }
        }
        self.urls = urls
        self.hosts = hosts
        self.ipPorts = ipPorts
        self.ips = ips
        indicatorCount = indicators.count
    }

    /// With a port, only that exact address and port; without one, any listed port of the IP.
    func match(ip: String, port: UInt16?) -> ThreatIntelMatch? {
        guard let canonical = AVHostNormalizer.canonicalIP(ip) else { return nil }
        if let port { return ipPorts[AVHostNormalizer.key(ip: canonical, port: Int(port))] }
        return ips[canonical]
    }

    /// The host itself or any parent domain listed by a feed (never a bare top-level domain).
    func match(host raw: String) -> ThreatIntelMatch? {
        if let ip = AVHostNormalizer.canonicalIP(raw) { return match(ip: ip, port: nil) }
        guard var host = AVHostNormalizer.normalize(raw) else { return nil }
        while true {
            if let match = hosts[host] { return match }
            guard let dot = host.firstIndex(of: ".") else { return nil }
            let parent = String(host[host.index(after: dot)...])
            guard parent.contains(".") else { return nil }
            host = parent
        }
    }

    /// The exact (normalized) URL.
    func match(url: String) -> ThreatIntelMatch? {
        AVURLNormalizer.normalize(url).flatMap { urls[$0] }
    }

    private static func ip(fromKey key: String) -> String? {
        if key.hasPrefix("["), let close = key.firstIndex(of: "]") { return String(key[key.index(after: key.startIndex)..<close]) }
        return key.lastIndex(of: ":").map { String(key[..<$0]) }
    }
}

/// Keeps the loaded feeds and installs them process-wide.
final class AVIntelHolder: @unchecked Sendable {
    static let shared = AVIntelHolder()

    private let lock = NSLock()
    private var current: AVThreatIntelIndex?

    init() {}

    var index: AVThreatIntelIndex? { lock.withLock { current } }

    func install(_ index: AVThreatIntelIndex?) {
        lock.withLock { current = index }
        ThreatIntelRegistry.shared.install(index)
    }

    /// Loads the saved indicators for the enabled feeds (blocking). Nothing is installed when no
    /// feed is enabled or nothing was downloaded yet, so callers see "not checked".
    @discardableResult
    func loadSaved(paths: AVPaths, sources: AVSourceSelection) -> AVThreatIntelIndex? {
        var enabled = Set<AVIntelSource>()
        if sources.urlhaus { enabled.insert(.urlhaus) }
        if sources.threatFox { enabled.insert(.threatFox) }
        let database = AVIntelDatabase.read(from: paths.intel.appendingPathComponent("indicators.tsv"))
        let index = enabled.isEmpty || database.count == 0 ? nil : database.index(sources: enabled)
        install(index)
        return index
    }
}
