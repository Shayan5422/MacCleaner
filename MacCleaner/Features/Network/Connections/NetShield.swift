import Foundation
import Observation

/// A socket whose remote end is listed by a threat feed.
struct NetThreatMatchResult: Sendable, Hashable {
    let record: NetSocketRecord
    /// The host name that matched (when the address itself didn't).
    let host: String?
    let match: ThreatIntelMatch
}

/// Checks remote endpoints against the downloaded threat feeds (abuse.ch ThreatFox and URLhaus, loaded by the
/// Antivirus page into `ThreatIntelRegistry`). Pure apart from the lookups it is given.
enum NetThreatMatcher {
    /// Every record with a routable remote address that the feeds list, by IP and port, else by the host name it
    /// resolved to (`hosts`: address → name, only when reverse DNS is on). Each address is looked up once.
    static func matches(in records: [NetSocketRecord], hosts: [String: String] = [:],
                        lookup: any ThreatIntelLookup) -> [NetThreatMatchResult] {
        var byEndpoint: [String: ThreatIntelMatch?] = [:]
        var byHost: [String: ThreatIntelMatch?] = [:]
        var results: [NetThreatMatchResult] = []
        for record in records {
            guard let remote = record.remoteAddress, NetAddress.isRoutable(remote) else { continue }
            let endpoint = NetAddress.endpoint(remote, port: record.remotePort)
            let ipMatch: ThreatIntelMatch?
            if let cached = byEndpoint[endpoint] {
                ipMatch = cached
            } else {
                ipMatch = lookup.match(ip: remote, port: record.remotePort)
                byEndpoint[endpoint] = .some(ipMatch)
            }
            if let ipMatch {
                results.append(NetThreatMatchResult(record: record, host: nil, match: ipMatch))
                continue
            }
            guard let host = hosts[remote] else { continue }
            let hostMatch: ThreatIntelMatch?
            if let cached = byHost[host] {
                hostMatch = cached
            } else {
                hostMatch = lookup.match(host: host)
                byHost[host] = .some(hostMatch)
            }
            if let hostMatch {
                results.append(NetThreatMatchResult(record: record, host: host, match: hostMatch))
            }
        }
        return results
    }

    /// "ThreatFox: botnet C&C (AMOS Stealer) · 90% confidence".
    static func summary(of match: ThreatIntelMatch) -> String {
        var text = feedName(match.source) + ": " + threatTypeTitle(match.threatType)
        if let malware = match.malware, !malware.isEmpty { text += " (\(malware))" }
        if let confidence = match.confidence { text += " · \(confidence)% confidence" }
        return text
    }

    /// "ThreatFox (abuse.ch)" → "ThreatFox".
    static func feedName(_ source: String) -> String {
        source.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? source
    }

    /// Plain names for the feeds' threat types.
    static func threatTypeTitle(_ type: String) -> String {
        switch type.lowercased() {
        case "botnet_cc", "botnet_c2", "c2": return "botnet C&C"
        case "payload_delivery": return "malware delivery"
        case "malware_download": return "malware download"
        case "payload": return "malware payload"
        case "cc_skimming": return "card skimming"
        default: return type.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Network Shield: while Mac Cleaner runs, checks every connection against the downloaded threat feeds about every
/// 20 seconds, and notifies the person the first time a process talks to a known malicious server.
///
/// Cheap by design: nothing happens until feeds are loaded; a check is one read of the kernel's socket lists (or of
/// this user's descriptor tables when those are unavailable) plus in-memory lookups, with no network access.
/// Mac Cleaner can't block connections (that needs a network extension), so the Shield reports; the person
/// decides whether to stop the process.
@MainActor
@Observable
final class NetShield {
    /// Hits found since launch, newest first, kept in memory only.
    private(set) var hits: [NetThreatHit] = []
    private(set) var isRunning = false
    private(set) var lastCheck: Date?
    /// Threat feeds are loaded, so checks mean something ("no hits" never means "safe" without them).
    private(set) var feedsLoaded = false

    @ObservationIgnored let interval: TimeInterval
    @ObservationIgnored private let scanner: NetConnectionScanner
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let eventLog: ProtectionEventLog
    @ObservationIgnored private let lookupProvider: @Sendable () -> (any ThreatIntelLookup)?
    /// Whether the background loop may notify (the Network Shield setting).
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var reportedIDs: Set<String> = []
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var feedObserver: NSObjectProtocol?

    init(interval: TimeInterval = 20, scanner: NetConnectionScanner = NetConnectionScanner(),
         notifications: NotificationService = .shared, eventLog: ProtectionEventLog = .shared,
         lookupProvider: @escaping @Sendable () -> (any ThreatIntelLookup)? = { ThreatIntelRegistry.shared.lookup }) {
        self.interval = interval
        self.scanner = scanner
        self.notifications = notifications
        self.eventLog = eventLog
        self.lookupProvider = lookupProvider
        feedsLoaded = lookupProvider() != nil
        feedObserver = NotificationCenter.default.addObserver(forName: ThreatIntelRegistry.didChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.feedsLoaded = self.lookupProvider() != nil
                // New feeds: check right away instead of waiting for the next tick.
                if self.isRunning { Task { await self.checkNow() } }
            }
        }
    }

    /// Starts the background loop (idempotent). Never runs in the XCTest host.
    func start() {
        guard loopTask == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        isRunning = true
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isEnabled() { await self.checkNow() }
                let interval = self.interval
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.25))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    /// One check of every active connection. Returns the new hits (already reported).
    @discardableResult
    func checkNow() async -> [NetThreatHit] {
        guard let lookup = lookupProvider() else {
            feedsLoaded = false
            return []
        }
        feedsLoaded = true
        let scanner = self.scanner
        let found: [NetThreatHit] = await BackgroundWork.run(qos: .utility) {
            let endpoints = scanner.remoteEndpoints()
            let matches = NetThreatMatcher.matches(in: endpoints.records, lookup: lookup)
            let now = Date()
            return matches.map { result in
                NetThreatHit(process: scanner.processInfo(pid: result.record.pid), remoteAddress: result.record.remoteAddress ?? "",
                             remotePort: result.record.remotePort, host: result.host, match: result.match, firstSeen: now)
            }
        }
        lastCheck = Date()
        return report(found, notify: isEnabled())
    }

    /// Records hits from any source (the background check, the Connections tab). Each process + indicator pair is
    /// reported once per run: an activity event always, a notification when `notify`. Returns the new hits.
    @discardableResult
    func report(_ found: [NetThreatHit], notify: Bool) -> [NetThreatHit] {
        var fresh: [NetThreatHit] = []
        for hit in found where reportedIDs.insert(hit.id).inserted {
            fresh.append(hit)
        }
        guard !fresh.isEmpty else { return [] }
        hits.insert(contentsOf: fresh, at: 0)
        if hits.count > 100 { hits.removeLast(hits.count - 100) }
        for hit in fresh {
            let summary = NetThreatMatcher.summary(of: hit.match)
            eventLog.post(ProtectionEvent(kind: .maliciousConnection, severity: .threat,
                                          title: "“\(hit.process.displayName)” connected to a known malware server",
                                          detail: hit.remoteText + " · " + summary,
                                          path: hit.process.appBundlePath ?? hit.process.executablePath,
                                          section: .network))
            guard notify else { continue }
            let notifications = self.notifications
            let body = "\(hit.process.displayName) (pid \(hit.process.pid)) connected to \(hit.remoteText). \(summary)."
            Task {
                await notifications.post(title: "Connection to a known malicious server", body: body,
                                         identifier: "network.shield." + hit.id, section: .network)
            }
        }
        return fresh
    }

    /// Hits whose process is still running.
    var activeHits: [NetThreatHit] {
        hits.filter { PortProcessWatch.isRunning($0.process.identity) }
    }
}
