import Foundation

/// The abuse.ch exports Safari protection and the link check use. They're free (CC0) and need no key.
enum ThreatFeed: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Host names currently serving malware, in hosts-file format.
    case urlhausHosts
    /// Web addresses currently serving malware, one per line (for the link check).
    case urlhausOnline
    /// ThreatFox indicators reported in the last 48 hours.
    case threatFox

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .urlhausHosts: return URL(string: "https://urlhaus.abuse.ch/downloads/hostfile/")!
        case .urlhausOnline: return URL(string: "https://urlhaus.abuse.ch/downloads/text_online/")!
        case .threatFox: return URL(string: "https://threatfox.abuse.ch/export/json/recent/")!
        }
    }

    var title: String {
        switch self {
        case .urlhausHosts: return "URLhaus host list"
        case .urlhausOnline: return "URLhaus link list"
        case .threatFox: return "ThreatFox list"
        }
    }

    /// The parsed list, in the Protection folder of the App Group container.
    var fileName: String {
        switch self {
        case .urlhausHosts: return "urlhaus-hosts.txt"
        case .urlhausOnline: return "urlhaus-online.txt"
        case .threatFox: return "threatfox.tsv"
        }
    }

    /// Larger answers are refused: the exports are a few megabytes.
    var maxBytes: Int {
        switch self {
        case .urlhausHosts: return 20_000_000
        case .urlhausOnline: return 60_000_000
        case .threatFox: return 80_000_000
        }
    }

    /// The feeds Safari's rules are built from.
    static let safariFeeds: [ThreatFeed] = [.urlhausHosts, .threatFox]
}

/// Who listed an address.
enum ThreatSource: String, Codable, Sendable, CaseIterable, Comparable {
    case urlhaus, threatFox

    var title: String {
        switch self {
        case .urlhaus: return "URLhaus"
        case .threatFox: return "ThreatFox"
        }
    }

    static func < (lhs: ThreatSource, rhs: ThreatSource) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One ThreatFox indicator of compromise that a browser could reach: a domain, a URL or an IP and port.
struct ThreatFoxIOC: Sendable, Hashable {
    enum Kind: String, Sendable, CaseIterable {
        case domain
        case url
        case ipPort = "ip:port"
    }

    /// ThreatFox's id, for its web page.
    var id: String?
    var kind: Kind
    /// A normalized host name, web address or "ip:port".
    var value: String
    /// "botnet_cc", "payload_delivery", …
    var threatType: String
    /// The malware family, e.g. "Vidar".
    var malware: String?
    /// 0–100.
    var confidence: Int?
    var firstSeen: Date?
    /// A legitimate site that was hacked: only its listed addresses are bad, not the whole site.
    var isCompromised = false

    var key: String { kind.rawValue + "|" + value }
}

/// A downloaded list couldn't be read.
struct ThreatFeedError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// Reads the abuse.ch exports.
enum ThreatFeedParser {
    /// URLhaus hosts file (`127.0.0.1<TAB>host`, `#` comments): lower-case host names without
    /// duplicates. Lines with only host names are read too; IP addresses, localhost and local
    /// names are skipped.
    static func hosts(_ data: Data) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        forEachLine(data) { line in
            let content = line.prefix { $0 != "#" }
            let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else { return }
            let names = ThreatIntel.canonicalIP(String(first)) != nil ? fields.dropFirst() : fields[...]
            for name in names {
                guard let host = ThreatIntel.hostName(String(name)), !ThreatIntel.isLocalName(host),
                      seen.insert(host).inserted else { continue }
                hosts.append(host)
            }
        }
        return hosts
    }

    /// URLhaus "online" export: one web address per line, normalized, without duplicates.
    static func addresses(_ data: Data) -> [String] {
        var seen = Set<String>()
        var addresses: [String] = []
        forEachLine(data) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let normalized = ThreatIntel.normalizedURL(trimmed),
                  seen.insert(normalized).inserted else { return }
            addresses.append(normalized)
        }
        return addresses
    }

    /// ThreatFox JSON export: `{"<id>": [{"ioc_value": …, "ioc_type": …, …}], …}`. Keeps domains,
    /// URLs and IP:port indicators; file hashes are left out.
    static func threatFox(_ data: Data) throws -> [ThreatFoxIOC] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThreatFeedError(message: "The ThreatFox list couldn't be read.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // The API's shape ({"query_status": …, "data": […]}) is read too.
        let groups: [(id: String?, value: Any)]
        if let list = root["data"] as? [[String: Any]] {
            groups = list.map { (id: nil, value: $0) }
        } else {
            groups = root.map { (id: $0.key, value: $0.value) }
        }
        var indicators: [ThreatFoxIOC] = []
        for (groupID, value) in groups {
            let entries = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
            for entry in entries {
                guard let raw = entry["ioc_value"] as? String ?? entry["ioc"] as? String,
                      let type = entry["ioc_type"] as? String, let kind = ThreatFoxIOC.Kind(rawValue: type) else { continue }
                let normalized: String?
                switch kind {
                case .domain: normalized = ThreatIntel.hostName(raw)
                case .url: normalized = ThreatIntel.normalizedURL(raw.contains("://") ? raw : "http://" + raw)
                case .ipPort: normalized = ThreatIntel.ipPort(raw)
                }
                guard let normalized else { continue }
                let id = groupID ?? (entry["id"]).map { "\($0)" }
                indicators.append(ThreatFoxIOC(
                    id: id,
                    kind: kind,
                    value: normalized,
                    threatType: entry["threat_type"] as? String ?? "",
                    malware: (entry["malware_printable"] as? String).flatMap { $0.isEmpty || $0 == "Unknown malware" ? nil : $0 },
                    confidence: integer(entry["confidence_level"]),
                    firstSeen: (entry["first_seen_utc"] as? String ?? entry["first_seen"] as? String).flatMap(formatter.date(from:)),
                    isCompromised: boolean(entry["is_compromised"])
                ))
            }
        }
        return indicators
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "1" || text.lowercased() == "true" }
        return false
    }

    private static func forEachLine(_ data: Data, _ body: (Substring) -> Void) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) { body(line) }
    }
}

/// ThreatFox indicators collected over time. Its export only covers the last 48 hours, so each
/// indicator is kept for 30 days after it was last listed, like the Mac app does.
struct ThreatFoxStore: Sendable, Equatable {
    struct Entry: Sendable, Hashable {
        var ioc: ThreatFoxIOC
        /// When a download last listed it.
        var lastSeen: Date
    }

    static let retention: TimeInterval = 30 * 24 * 3600

    private(set) var entries: [String: Entry] = [:]

    var count: Int { entries.count }

    /// Adds a fresh download, keeping the earliest first-seen date of each indicator.
    mutating func merge(_ indicators: [ThreatFoxIOC], seenAt date: Date) {
        for indicator in indicators {
            if var existing = entries[indicator.key] {
                let firstSeen = [existing.ioc.firstSeen, indicator.firstSeen].compactMap { $0 }.min()
                existing.ioc = indicator
                existing.ioc.firstSeen = firstSeen
                existing.lastSeen = max(existing.lastSeen, date)
                entries[indicator.key] = existing
            } else {
                entries[indicator.key] = Entry(ioc: indicator, lastSeen: date)
            }
        }
    }

    /// Drops indicators no download has listed since `cutoff`.
    mutating func expire(before cutoff: Date) {
        entries = entries.filter { $0.value.lastSeen >= cutoff }
    }

    /// The indicators still kept at `date`.
    func current(at date: Date) -> [Entry] {
        let cutoff = date.addingTimeInterval(-Self.retention)
        return entries.values.filter { $0.lastSeen >= cutoff }
    }

    // MARK: Storage (tab-separated, one indicator per line)

    func encoded() -> Data {
        var text = "# kind\tvalue\tid\tthreat_type\tmalware\tconfidence\tfirst_seen\tlast_seen\tcompromised\n"
        for entry in entries.values.sorted(by: { $0.ioc.key < $1.ioc.key }) {
            let ioc = entry.ioc
            let fields = [
                ioc.kind.rawValue, ioc.value, ioc.id ?? "", ioc.threatType, ioc.malware ?? "",
                ioc.confidence.map(String.init) ?? "", ioc.firstSeen.map { String(Int($0.timeIntervalSince1970)) } ?? "",
                String(Int(entry.lastSeen.timeIntervalSince1970)), ioc.isCompromised ? "1" : "0",
            ].map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            text += fields.joined(separator: "\t") + "\n"
        }
        return Data(text.utf8)
    }

    static func decode(_ data: Data) -> ThreatFoxStore {
        var store = ThreatFoxStore()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9, let kind = ThreatFoxIOC.Kind(rawValue: fields[0]), !fields[1].isEmpty,
                  let lastSeen = TimeInterval(fields[7]) else { continue }
            let ioc = ThreatFoxIOC(id: fields[2].isEmpty ? nil : fields[2], kind: kind, value: fields[1], threatType: fields[3],
                                   malware: fields[4].isEmpty ? nil : fields[4], confidence: Int(fields[5]),
                                   firstSeen: TimeInterval(fields[6]).map(Date.init(timeIntervalSince1970:)),
                                   isCompromised: fields[8] == "1")
            store.entries[ioc.key] = Entry(ioc: ioc, lastSeen: Date(timeIntervalSince1970: lastSeen))
        }
        return store
    }
}
