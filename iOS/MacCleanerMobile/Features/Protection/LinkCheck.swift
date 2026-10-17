import Foundation

/// A link or domain the person typed or pasted, ready to look up.
struct CheckedLink: Sendable, Equatable {
    var address: ThreatIntel.Address
    /// The host as typed, in lower case ("www." kept).
    var originalHost: String

    /// The host in lower case without "www.", or the IP address.
    var host: String { ThreatIntel.withoutWWW(address.host) }
    var isIPAddress: Bool { address.isIPAddress }

    /// "https://example.com/path": a scheme added when missing, the host in lower case, no "www.".
    var url: String {
        var normalized = address
        normalized.host = host
        return normalized.string
    }

    /// "example.com/path", or "example.com" for a bare domain.
    var display: String {
        var normalized = address
        normalized.host = host
        let resource = normalized.resource == "/" ? "" : normalized.resource
        return (address.scheme == "ftp" ? "ftp://" : "") + normalized.authority + resource
    }

    /// What exact-address matching compares.
    var key: String { ThreatIntel.addressKey(address) }

    /// localhost, a local name or a private IP: never on the lists.
    var isLocal: Bool {
        isIPAddress ? !ThreatIntel.isPublicIP(address.host) : ThreatIntel.isLocalName(address.host)
    }

    /// The host and every parent domain, plus "www." in front when it wasn't typed.
    var hostsToCheck: [String] {
        guard !isIPAddress else { return [] }
        var hosts = ThreatIntel.hostAndParents(originalHost)
        if !originalHost.hasPrefix("www.") { hosts.append("www." + originalHost) }
        return hosts
    }

    /// Reads a link ("https://…"), a domain ("example.com") or a sentence with a link in it.
    /// Missing schemes become https.
    init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”‘’"))
        guard !text.isEmpty else { return nil }
        if text.contains(where: \.isWhitespace), let found = Self.firstLink(in: text) {
            text = found
        }
        if !text.contains("://") { text = "https://" + text }
        guard let address = ThreatIntel.address(text) else { return nil }
        self.address = address
        originalHost = address.host
    }

    private static func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}

/// The downloaded lists, indexed for the link check.
struct ThreatIndex: Sendable {
    /// What the lists say about one entry.
    struct Listing: Sendable, Equatable {
        var sources: Set<ThreatSource>
        var threatType: String?
        var malware: String?
        var firstSeen: Date?
        var threatFoxID: String?

        mutating func merge(_ other: Listing) {
            sources.formUnion(other.sources)
            // ThreatFox's details are more specific than URLhaus's.
            if other.sources.contains(.threatFox) || threatType == nil {
                threatType = other.threatType ?? threatType
                malware = other.malware ?? malware
                threatFoxID = other.threatFoxID ?? threatFoxID
            }
            if let date = other.firstSeen { firstSeen = min(firstSeen ?? date, date) }
        }
    }

    private(set) var addresses: [String: Listing] = [:]
    private(set) var hosts: [String: Listing] = [:]
    private(set) var ips: [String: Listing] = [:]

    var entryCount: Int { addresses.count + hosts.count + ips.count }
    var isEmpty: Bool { entryCount == 0 }

    init() {}

    /// Indexes the URLhaus host and link lists and the ThreatFox indicators. Hosts of hacked sites
    /// are matched by their listed addresses only.
    init(urlhausHosts: [String], urlhausAddresses: [String], threatFox: [ThreatFoxStore.Entry]) {
        let urlhaus = Listing(sources: [.urlhaus], threatType: "malware_download")
        for host in urlhausHosts {
            if let host = ThreatIntel.hostName(host) { Self.add(urlhaus, for: host, to: &hosts) }
        }
        for raw in urlhausAddresses {
            guard let address = ThreatIntel.address(raw) else { continue }
            Self.add(urlhaus, for: ThreatIntel.addressKey(address), to: &addresses)
            if address.isIPAddress { Self.add(urlhaus, for: address.host, to: &ips) }
        }
        for entry in threatFox {
            let ioc = entry.ioc
            if let confidence = ioc.confidence, confidence < SafariBlocklist.minimumConfidence { continue }
            let listing = Listing(sources: [.threatFox], threatType: ioc.threatType.isEmpty ? nil : ioc.threatType,
                                  malware: ioc.malware, firstSeen: ioc.firstSeen, threatFoxID: ioc.id)
            switch ioc.kind {
            case .domain:
                if !ioc.isCompromised { Self.add(listing, for: ioc.value, to: &hosts) }
            case .url:
                guard let address = ThreatIntel.address(ioc.value) else { continue }
                Self.add(listing, for: ThreatIntel.addressKey(address), to: &addresses)
                if address.isIPAddress && !ioc.isCompromised { Self.add(listing, for: address.host, to: &ips) }
            case .ipPort:
                if let ip = ThreatIntel.ip(ofIPPort: ioc.value) { Self.add(listing, for: ip, to: &ips) }
            }
        }
    }

    /// The exact address first, then the host and its parent domains (or the IP address).
    func verdict(for link: CheckedLink) -> LinkVerdict {
        if link.isLocal { return .localAddress }
        if let listing = addresses[link.key] { return .listed(LinkMatch(scope: .address, listing: listing)) }
        if link.isIPAddress {
            if let listing = ips[link.address.host] { return .listed(LinkMatch(scope: .ipAddress(link.address.host), listing: listing)) }
        } else {
            for host in link.hostsToCheck {
                if let listing = hosts[host] { return .listed(LinkMatch(scope: .host(host), listing: listing)) }
            }
        }
        return .notListed
    }

    private static func add(_ listing: Listing, for key: String, to index: inout [String: Listing]) {
        if var existing = index[key] {
            existing.merge(listing)
            index[key] = existing
        } else {
            index[key] = listing
        }
    }
}

/// What the link check found.
enum LinkVerdict: Sendable, Equatable {
    case listed(LinkMatch)
    case notListed
    /// localhost or a private network address.
    case localAddress

    var headline: String {
        switch self {
        case .listed(let match): return match.headline
        case .notListed: return "Not in the lists — that doesn't prove it's safe"
        case .localAddress: return "This address is on a private network"
        }
    }
}

/// A listed entry the link matched.
struct LinkMatch: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        /// This exact address.
        case address
        /// The host or a parent domain.
        case host(String)
        case ipAddress(String)
    }

    var scope: Scope
    var listing: ThreatIndex.Listing

    /// "Listed as malicious by URLhaus and ThreatFox".
    var headline: String {
        "Listed as malicious by " + listing.sources.sorted().map(\.title).joined(separator: " and ")
    }

    /// "ThreatFox lists it as a malware control server (Vidar)."
    var reason: String {
        let feeds = listing.sources.sorted().map(\.title).joined(separator: " and ")
        let verb = listing.sources.count > 1 ? "list" : "lists"
        let family = listing.malware.map { " (\($0))" } ?? ""
        return "\(feeds) \(verb) it \(Self.phrase(for: listing.threatType))\(family)."
    }

    static func phrase(for threatType: String?) -> String {
        let type = threatType?.lowercased() ?? ""
        switch type {
        case "malware_download": return "for spreading malware"
        case "payload_delivery": return "for delivering malware"
        case "botnet_cc", "c2", "command_and_control": return "as a malware control server"
        case "phishing": return "for phishing"
        case "cc_skimming": return "for stealing payment card details"
        case "": return "as malicious"
        default: return "as malicious (\(type.replacingOccurrences(of: "_", with: " ")))"
        }
    }

    /// The listing's page on abuse.ch, when there is one.
    var referenceURL: URL? {
        listing.threatFoxID.flatMap { URL(string: "https://threatfox.abuse.ch/ioc/\($0)/") }
    }
}
