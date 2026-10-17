import Foundation

/// Turns the downloaded lists into rules for Safari's content blocker.
///
/// Malware hosts (the URLhaus host list, ThreatFox domains and servers reached by their IP) are
/// blocked with all their subdomains. A ThreatFox web address on a named host blocks only that
/// address: those hosts are often shared services (Telegram channels and Steam profiles are
/// common malware "dead drops"), and blocking the whole site would break it for everyone.
enum SafariBlocklist {
    /// The most rules Mac Cleaner gives Safari.
    static let ruleLimit = 50_000
    /// ThreatFox indicators below this confidence (0–100) aren't blocked.
    static let minimumConfidence = 50

    struct Candidate: Sendable, Hashable {
        enum Kind: Sendable, Hashable {
            /// A host name or public IP, blocked with its subdomains.
            case host
            /// One web address.
            case address
        }

        var kind: Kind
        var value: String
        /// When the feed listed it; newer entries are kept first when there are too many.
        var date: Date?
    }

    struct Rules: Sendable, Equatable {
        /// The content-blocker JSON.
        var json: Data
        /// Hosts blocked with their subdomains.
        var siteCount: Int
        /// Single addresses blocked.
        var linkCount: Int
        /// Left out because of `ruleLimit`.
        var omittedCount: Int

        var ruleCount: Int { siteCount + linkCount }
    }

    /// What to block from the URLhaus host list (listed at `urlhausDate`) and the ThreatFox indicators.
    static func candidates(urlhausHosts: [String], urlhausDate: Date?, threatFox: [ThreatFoxStore.Entry]) -> [Candidate] {
        var result = urlhausHosts.map { Candidate(kind: .host, value: $0, date: urlhausDate) }
        for entry in threatFox {
            let ioc = entry.ioc
            if let confidence = ioc.confidence, confidence < minimumConfidence { continue }
            let date = ioc.firstSeen ?? entry.lastSeen
            switch ioc.kind {
            case .domain:
                // A hacked site is someone's real website: only its listed addresses are blocked.
                if !ioc.isCompromised { result.append(Candidate(kind: .host, value: ioc.value, date: date)) }
            case .url:
                guard let address = ThreatIntel.address(ioc.value) else { continue }
                if address.isIPAddress && !ioc.isCompromised {
                    // A server reached by its IP address is the malware server itself.
                    result.append(Candidate(kind: .host, value: address.host, date: date))
                } else {
                    result.append(Candidate(kind: .address, value: address.string, date: date))
                }
            case .ipPort:
                // Command-and-control servers: malware talks to them, Safari doesn't open them.
                continue
            }
        }
        return result
    }

    /// One rule per host (lower-case, without duplicates or subdomains of a listed parent) and per
    /// address not already covered by a host, newest first, at most `limit`.
    static func rules(from candidates: [Candidate], limit: Int = ruleLimit) -> Rules {
        var hostDates: [String: Date] = [:]
        var addressDates: [String: (address: ThreatIntel.Address, date: Date)] = [:]
        for candidate in candidates {
            let date = candidate.date ?? .distantPast
            switch candidate.kind {
            case .host:
                guard let host = blockableHost(candidate.value) else { continue }
                hostDates[host] = max(hostDates[host] ?? .distantPast, date)
            case .address:
                guard let address = ThreatIntel.address(candidate.value), blockableHost(address.host) != nil else { continue }
                let key = address.string
                if let existing = addressDates[key], existing.date >= date { continue }
                addressDates[key] = (address, date)
            }
        }

        // A listed parent domain already blocks its subdomains: keep the parent, with the newer date.
        var coveredBy: [String: String] = [:]
        for host in hostDates.keys where ThreatIntel.canonicalIP(host) == nil {
            if let parent = ThreatIntel.hostAndParents(host).dropFirst().last(where: { hostDates[$0] != nil }) {
                coveredBy[host] = parent
            }
        }
        for (host, parent) in coveredBy {
            hostDates[parent] = max(hostDates[parent] ?? .distantPast, hostDates[host] ?? .distantPast)
            hostDates[host] = nil
        }

        struct Entry {
            var filter: String
            var date: Date
            var isHost: Bool
            var value: String
        }
        var entries: [Entry] = []
        entries.reserveCapacity(hostDates.count + addressDates.count)
        for (host, date) in hostDates {
            if let filter = hostFilter(host) { entries.append(Entry(filter: filter, date: date, isHost: true, value: host)) }
        }
        for (key, item) in addressDates {
            let host = item.address.host
            let isBlocked = item.address.isIPAddress
                ? hostDates[host] != nil
                : ThreatIntel.hostAndParents(host).contains { hostDates[$0] != nil }
            guard !isBlocked, let filter = addressFilter(item.address) else { continue }
            entries.append(Entry(filter: filter, date: item.date, isHost: false, value: key))
        }
        entries.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.isHost != $1.isHost { return $0.isHost }
            return $0.value < $1.value
        }
        let kept = entries.prefix(max(0, limit))
        var rules = kept.map { Rule(filter: $0.filter) }
        // Safari needs at least one rule; this one never matches a real site.
        if rules.isEmpty { rules = [Rule(filter: placeholderFilter)] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(rules)) ?? Data("[]".utf8)
        let siteCount = kept.filter(\.isHost).count
        return Rules(json: json, siteCount: siteCount, linkCount: kept.count - siteCount, omittedCount: entries.count - kept.count)
    }

    /// `^[a-z]+://([^/]+\.)?evil\.com[:/]`: the host and every subdomain, on any scheme and port.
    /// IP addresses match exactly. nil for local names, private IPs and invalid names.
    static func hostFilter(_ host: String) -> String? {
        guard let host = blockableHost(host) else { return nil }
        if ThreatIntel.canonicalIP(host) != nil {
            return "^[a-z]+://" + hostPattern(host) + "[:/]"
        }
        return "^[a-z]+://([^/]+\\.)?" + escapeForRegex(host) + "[:/]"
    }

    /// `^[a-z]+://evil\.com/payload\.exe`: one address on any scheme (and everything below it).
    static func addressFilter(_ address: ThreatIntel.Address) -> String? {
        guard blockableHost(address.host) != nil else { return nil }
        let filter = "^[a-z]+://" + hostPattern(address.host) + (address.port.map { ":\($0)" } ?? "")
            + escapeForRegex(address.resource)
        // Safari's rules are ASCII only; very long addresses aren't worth a rule.
        guard filter.utf8.count <= 1_000, filter.allSatisfy(\.isASCII) else { return nil }
        return filter
    }

    /// A backslash before each regular-expression character.
    static func escapeForRegex(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count + 8)
        for character in text {
            if regexCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    static let placeholderFilter = "^https?://blocked\\.invalid/"

    private static let regexCharacters: Set<Character> = ["\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"]

    /// The normalized host when Safari should block it: a public IP or a valid internet name.
    private static func blockableHost(_ raw: String) -> String? {
        if let ip = ThreatIntel.canonicalIP(raw) { return ThreatIntel.isPublicIP(ip) ? ip : nil }
        guard let host = ThreatIntel.hostName(raw), !ThreatIntel.isLocalName(host) else { return nil }
        return host
    }

    private static func hostPattern(_ host: String) -> String {
        host.contains(":") ? "\\[" + escapeForRegex(host) + "\\]" : escapeForRegex(host)
    }

    private struct Rule: Encodable {
        struct Trigger: Encodable {
            var urlFilter: String

            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter"
            }
        }

        struct Action: Encodable {
            var type = "block"
        }

        var trigger: Trigger
        var action = Action()

        init(filter: String) {
            trigger = Trigger(urlFilter: filter)
        }
    }
}
