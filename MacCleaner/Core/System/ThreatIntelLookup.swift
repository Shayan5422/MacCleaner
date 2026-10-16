import Foundation

/// An entry of a downloaded threat-intelligence feed that matched something on this
/// Mac (abuse.ch ThreatFox, URLhaus...).
struct ThreatIntelMatch: Sendable, Hashable, Codable {
    /// The indicator that matched: "185.1.2.3:443", "evil.example", a URL or a hash.
    var indicator: String
    /// The feed's threat type, e.g. "botnet_cc", "payload_delivery", "malware_download".
    var threatType: String
    /// Malware family when the feed names one, e.g. "AMOS Stealer".
    var malware: String?
    /// 0–100 when the feed provides it.
    var confidence: Int?
    /// Feed name shown to the person, e.g. "ThreatFox (abuse.ch)".
    var source: String
    var firstSeen: Date?
    /// A page with details about the indicator.
    var reference: URL?
}

/// Read-only lookups in the threat-intelligence feeds the Antivirus page downloads.
/// Implementations keep the feeds in memory and are safe to call from any thread.
protocol ThreatIntelLookup: Sendable {
    /// A known malicious IP address, optionally with the port it was seen on.
    func match(ip: String, port: UInt16?) -> ThreatIntelMatch?
    /// A known malicious host name (exact host or a parent domain listed by the feed).
    func match(host: String) -> ThreatIntelMatch?
    /// A known malware download URL.
    func match(url: String) -> ThreatIntelMatch?
}

/// Process-wide access to the feeds currently loaded. `lookup` is nil until the
/// Antivirus feature has downloaded and loaded them, so callers must treat "no
/// lookup" as "not checked", never as "clean".
final class ThreatIntelRegistry: @unchecked Sendable {
    static let shared = ThreatIntelRegistry()

    /// Posted (on any thread) after `install(_:)`.
    static let didChangeNotification = Notification.Name("ThreatIntelRegistryDidChange")

    private let lock = NSLock()
    private var current: (any ThreatIntelLookup)?

    var lookup: (any ThreatIntelLookup)? { lock.withLock { current } }

    func install(_ lookup: (any ThreatIntelLookup)?) {
        lock.withLock { current = lookup }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
