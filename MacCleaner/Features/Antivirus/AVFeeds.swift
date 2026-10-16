import Foundation

/// The free abuse.ch exports (CC0) Mac Cleaner downloads in-app.
enum AVFeedID: String, Codable, Sendable, CaseIterable, Identifiable {
    case malwareBazaarRecent, malwareBazaarFull, urlhausOnline, urlhausHosts, threatFoxRecent

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .malwareBazaarRecent: return URL(string: "https://bazaar.abuse.ch/export/txt/sha256/recent/")!
        case .malwareBazaarFull: return URL(string: "https://bazaar.abuse.ch/export/txt/sha256/full/")!
        case .urlhausOnline: return URL(string: "https://urlhaus.abuse.ch/downloads/text_online/")!
        case .urlhausHosts: return URL(string: "https://urlhaus.abuse.ch/downloads/hostfile/")!
        case .threatFoxRecent: return URL(string: "https://threatfox.abuse.ch/export/json/recent/")!
        }
    }

    var title: String {
        switch self {
        case .malwareBazaarRecent: return "MalwareBazaar (recent samples)"
        case .malwareBazaarFull: return "MalwareBazaar (full archive)"
        case .urlhausOnline: return "URLhaus (malware URLs)"
        case .urlhausHosts: return "URLhaus (malware hosts)"
        case .threatFoxRecent: return "ThreatFox (indicators)"
        }
    }

    var detail: String {
        switch self {
        case .malwareBazaarRecent: return "SHA-256 hashes of malware samples shared in the last 48 hours, collected locally for a year."
        case .malwareBazaarFull: return "Every MalwareBazaar sample hash (over a million). Large download, refreshed weekly."
        case .urlhausOnline: return "Web addresses currently distributing malware, kept for 30 days."
        case .urlhausHosts: return "Host names currently serving malware, kept for 30 days."
        case .threatFoxRecent: return "Command-and-control servers, malware sites and file hashes from the last 48 hours, kept for 30 days."
        }
    }

    var maxBytes: Int64 {
        switch self {
        case .malwareBazaarRecent: return 20_000_000
        case .malwareBazaarFull: return 150_000_000
        case .urlhausOnline: return 60_000_000
        case .urlhausHosts: return 20_000_000
        case .threatFoxRecent: return 80_000_000
        }
    }

    var typicalDownloadBytes: Int64 {
        switch self {
        case .malwareBazaarRecent: return 70_000
        case .malwareBazaarFull: return 43_000_000
        case .urlhausOnline: return 2_800_000
        case .urlhausHosts: return 15_000
        case .threatFoxRecent: return 5_200_000
        }
    }

    var checkInterval: TimeInterval {
        self == .malwareBazaarFull ? 7 * 24 * 3600 : 4 * 3600
    }

    /// How long an entry is kept after it was last seen in the feed.
    var retention: TimeInterval {
        switch self {
        case .malwareBazaarRecent, .malwareBazaarFull: return 365 * 24 * 3600
        case .urlhausOnline, .urlhausHosts, .threatFoxRecent: return 30 * 24 * 3600
        }
    }

    func isEnabled(in sources: AVSourceSelection) -> Bool {
        switch self {
        case .malwareBazaarRecent: return sources.malwareBazaarRecent
        case .malwareBazaarFull: return sources.malwareBazaarFull
        case .urlhausOnline, .urlhausHosts: return sources.urlhaus
        case .threatFoxRecent: return sources.threatFox
        }
    }
}

/// One ThreatFox indicator of compromise.
struct AVThreatFoxIOC: Sendable, Hashable {
    enum Kind: String, Sendable {
        case ipPort = "ip:port"
        case domain
        case url
        case sha256 = "sha256_hash"
    }

    var id: String
    var kind: Kind
    var value: String
    var threatType: String
    var malware: String?
    var confidence: Int?
    var firstSeen: Date?
    var isCompromised: Bool
}

enum AVFeedParser {
    /// Hex SHA-256 values, one per line (`#` comments), lower-cased and de-duplicated.
    static func sha256Hashes(_ data: Data) -> [String] {
        var seen = Set<String>()
        var hashes: [String] = []
        forEachLine(data) { line in
            guard let hash = normalizedSHA256(line), seen.insert(hash).inserted else { return }
            hashes.append(hash)
        }
        return hashes
    }

    static func normalizedSHA256(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.utf8.count == 64, !trimmed.hasPrefix("#"), AVAllowedHash.isValidSHA256(trimmed) else { return nil }
        return trimmed.lowercased()
    }

    /// Counts valid SHA-256 lines without keeping them (the full MalwareBazaar list has over a million).
    static func countSHA256Lines(in url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return 0 }
        var count = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var length = 0
            var valid = true
            for byte in raw {
                if byte == 0x0A || byte == 0x0D {
                    if length == 64 && valid { count += 1 }
                    length = 0
                    valid = true
                    continue
                }
                length += 1
                let isHex = (48...57).contains(byte) || (97...102).contains(byte) || (65...70).contains(byte)
                if !isHex { valid = false }
            }
            if length == 64 && valid { count += 1 }
        }
        return count
    }

    /// URLhaus "online" export: one URL per line.
    static func urls(_ data: Data) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        forEachLine(data) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let normalized = AVURLNormalizer.normalize(trimmed),
                  seen.insert(normalized).inserted else { return }
            urls.append(normalized)
        }
        return urls
    }

    /// URLhaus hosts file: `127.0.0.1<TAB>host`.
    static func hosts(_ data: Data) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        forEachLine(data) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let host = AVHostNormalizer.normalize(String(fields[1])),
                  host != "localhost", seen.insert(host).inserted else { return }
            hosts.append(host)
        }
        return hosts
    }

    /// ThreatFox JSON export: `{"<id>": [{"ioc_value": …, "ioc_type": …}], …}`.
    static func threatFox(_ data: Data) throws -> [AVThreatFoxIOC] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw AVDefsArchiveError.corrupt("ThreatFox export") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var indicators: [AVThreatFoxIOC] = []
        for (id, value) in root {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let raw = entry["ioc_value"] as? String, let type = entry["ioc_type"] as? String,
                      let kind = AVThreatFoxIOC.Kind(rawValue: type) else { continue }
                let normalized: String?
                switch kind {
                case .ipPort: normalized = AVHostNormalizer.normalizeIPPort(raw)
                case .domain: normalized = AVHostNormalizer.normalize(raw)
                case .url: normalized = AVURLNormalizer.normalize(raw)
                case .sha256: normalized = normalizedSHA256(Substring(raw))
                }
                guard let normalized else { continue }
                indicators.append(AVThreatFoxIOC(
                    id: id,
                    kind: kind,
                    value: normalized,
                    threatType: entry["threat_type"] as? String ?? "unknown",
                    malware: (entry["malware_printable"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    confidence: entry["confidence_level"] as? Int,
                    firstSeen: (entry["first_seen_utc"] as? String).flatMap(formatter.date(from:)),
                    isCompromised: entry["is_compromised"] as? Bool ?? false
                ))
            }
        }
        return indicators
    }

    private static func forEachLine(_ data: Data, _ body: (Substring) -> Void) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) { body(line) }
    }
}
