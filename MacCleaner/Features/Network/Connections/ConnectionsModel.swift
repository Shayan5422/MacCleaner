import AppKit
import Foundation
import Observation

/// One row of the flat connections table, with sort keys that are never optional.
struct NetConnectionRow: Identifiable, Hashable, Sendable {
    let connection: NetConnection
    let processName: String
    let pid: Int32
    let local: String
    let remote: String
    /// Resolved host name, else the remote address; "" without a peer.
    let remoteSortKey: String
    let stateTitle: String
    let transportTitle: String
    let firstSeen: Date

    var id: String { connection.id }
}

/// Connections of one process (the grouped view).
struct NetProcessConnections: Identifiable, Hashable, Sendable {
    let process: NetProcessInfo
    let connections: [NetConnection]

    var id: String { "\(process.pid)@\(process.startTime)" }
    var establishedCount: Int { connections.filter { $0.transport == .tcp && $0.state?.isActive == true }.count }
    var listeningCount: Int { connections.filter(\.isListening).count }
    var udpCount: Int { connections.filter { $0.transport == .udp }.count }
}

/// A stop the person asked for from the Connections tab, shown for confirmation with its plan.
struct NetStopConfirmation: Identifiable, Sendable {
    let id = UUID()
    let process: NetProcessInfo
    let plan: PortKillPlan
    let category: PortListenerCategory
}

/// State of the Connections tab: every process's network connections, checked against the threat feeds.
@MainActor
@Observable
final class ConnectionsModel {
    enum Grouping: String, CaseIterable, Identifiable {
        case byProcess = "By Process"
        case flat = "All Connections"
        var id: String { rawValue }
    }

    // MARK: State (read by UI)

    private(set) var scan: NetConnectionScan = .empty
    private(set) var hasScanned = false
    private(set) var isScanning = false
    /// Remote address → host name (reverse DNS, only when turned on in Settings).
    private(set) var hostNames: [String: String] = [:]
    /// Executable path → code signature.
    private(set) var signatures: [String: CodeSignatureInfo] = [:]
    /// Connections of the latest scan whose remote end is a known malicious server.
    private(set) var threatHits: [NetThreatHit] = []
    private(set) var isVisible = false
    var filter: NetConnectionFilter = .established
    var grouping: Grouping = .byProcess
    var searchText = ""
    /// Also list other users' and macOS's processes.
    var showSystemProcesses = true { didSet { if showSystemProcesses != oldValue { refreshNow() } } }
    var sortOrder: [KeyPathComparator<NetConnectionRow>] = [KeyPathComparator(\.processName)]
    var expandedProcessIDs: Set<String> = []
    var selection: Set<NetConnectionRow.ID> = []
    /// A Stop waiting for the person's confirmation.
    var pendingStop: NetStopConfirmation?
    /// Result of the last action.
    var banner: PortBanner? { didSet { scheduleBannerDismissal() } }
    private(set) var busyProcessIDs: Set<String> = []

    let preferences: NetworkPreferences
    let shield: NetShield
    @ObservationIgnored private let ports: PortsModel
    @ObservationIgnored private let scanner: NetConnectionScanner
    @ObservationIgnored private let lookupProvider: @Sendable () -> (any ThreatIntelLookup)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var visibilityClaims = 0
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored var refreshInterval: TimeInterval = 3

    init(preferences: NetworkPreferences, shield: NetShield, ports: PortsModel,
         scanner: NetConnectionScanner = NetConnectionScanner(),
         lookupProvider: @escaping @Sendable () -> (any ThreatIntelLookup)? = { ThreatIntelRegistry.shared.lookup }) {
        self.preferences = preferences
        self.shield = shield
        self.ports = ports
        self.scanner = scanner
        self.lookupProvider = lookupProvider
    }

    /// Feeds downloaded on the Antivirus page; without them nothing can be flagged.
    var feedsLoaded: Bool { shield.feedsLoaded }

    // MARK: Visibility & polling

    func acquireVisibility() {
        visibilityClaims += 1
        guard visibilityClaims == 1 else { return }
        isVisible = true
        startPolling()
    }

    func releaseVisibility() {
        guard visibilityClaims > 0 else { return }
        visibilityClaims -= 1
        guard visibilityClaims == 0 else { return }
        isVisible = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        guard pollTask == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = max(2, self.refreshInterval)
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.25))
            }
        }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    /// One scan: sockets, then (in the background) code signatures, host names and threat checks.
    func refresh() async {
        guard !scanInFlight else { return }
        scanInFlight = true
        isScanning = true
        let scanner = self.scanner
        let includeOthers = showSystemProcesses
        let result = await BackgroundWork.run(qos: .userInitiated) { scanner.scan(includeOtherUsers: includeOthers) }
        isScanning = false
        scanInFlight = false
        apply(result)
        Task { await self.loadSignatures(for: result) }
        if preferences.reverseDNS {
            Task { await self.resolveHosts(for: result) }
        }
    }

    /// Shows a scan and checks it against the feeds (tests call it with synthetic scans).
    func apply(_ result: NetConnectionScan) {
        scan = result
        hasScanned = true
        checkThreats()
    }

    private func loadSignatures(for scan: NetConnectionScan) async {
        let paths = Set(scan.connections.compactMap(\.process.executablePath)).subtracting(signatures.keys)
        guard !paths.isEmpty else { return }
        let found = await NetSignatureCache.shared.signatures(for: Array(paths))
        signatures.merge(found) { _, new in new }
    }

    private func resolveHosts(for scan: NetConnectionScan) async {
        let addresses = Set(scan.connections.compactMap(\.checkableRemoteAddress)).subtracting(hostNames.keys)
        guard !addresses.isEmpty else { return }
        let names = await NetReverseDNS.shared.names(for: Array(addresses))
        guard !names.isEmpty, preferences.reverseDNS else { return }
        hostNames.merge(names) { _, new in new }
        // A host name may be what the feeds list.
        checkThreats()
    }

    /// Matches the latest scan against the feeds and reports new hits to the Shield (activity feed; a notification
    /// only comes from the background Shield).
    private func checkThreats() {
        guard let lookup = lookupProvider() else {
            if !threatHits.isEmpty { threatHits = [] }
            return
        }
        let byID = Dictionary(scan.connections.map { ($0.record.endpointKey + "|\($0.process.pid)", $0) },
                              uniquingKeysWith: { first, _ in first })
        let matches = NetThreatMatcher.matches(in: scan.connections.map(\.record),
                                               hosts: preferences.reverseDNS ? hostNames : [:], lookup: lookup)
        let hits = matches.compactMap { result -> NetThreatHit? in
            guard let connection = byID[result.record.endpointKey + "|\(result.record.pid)"] else { return nil }
            return NetThreatHit(process: connection.process, remoteAddress: result.record.remoteAddress ?? "",
                                remotePort: result.record.remotePort, host: result.host, match: result.match,
                                firstSeen: connection.firstSeen)
        }
        var seen = Set<String>()
        let unique = hits.filter { seen.insert($0.id).inserted }
        if unique != threatHits { threatHits = unique }
        shield.report(unique, notify: false)
    }

    // MARK: Derived

    /// Connections after the filter and search.
    var filteredConnections: [NetConnection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return scan.connections.filter { connection in
            guard filter.includes(connection) else { return false }
            guard !query.isEmpty else { return true }
            return matches(connection, query: query)
        }
    }

    func matches(_ connection: NetConnection, query: String) -> Bool {
        var haystack = [connection.process.displayName, connection.process.name, String(connection.process.pid),
                        connection.record.localAddress, String(connection.record.localPort),
                        connection.state?.title ?? "", connection.transport.title]
        if let path = connection.process.executablePath { haystack.append(path) }
        if let remote = connection.record.remoteAddress {
            haystack.append(remote)
            if let host = hostNames[remote] { haystack.append(host) }
        }
        if let port = connection.record.remotePort { haystack.append(String(port)) }
        let text = haystack.joined(separator: "\n").lowercased()
        return query.split(separator: " ").allSatisfy { token in
            let bare = token.hasPrefix(":") ? String(token.dropFirst()) : String(token)
            return text.contains(bare)
        }
    }

    /// The filtered connections grouped by process, busiest first.
    var processGroups: [NetProcessConnections] {
        let grouped = Dictionary(grouping: filteredConnections) { "\($0.process.pid)@\($0.process.startTime)" }
        let threatPIDs = Set(threatHits.map(\.process.pid))
        return grouped.values.compactMap { connections -> NetProcessConnections? in
            guard let first = connections.first else { return nil }
            let sorted = connections.sorted { lhs, rhs in
                (lhs.record.remoteAddress ?? "~", lhs.record.localPort) < (rhs.record.remoteAddress ?? "~", rhs.record.localPort)
            }
            return NetProcessConnections(process: first.process, connections: sorted)
        }
        .sorted { lhs, rhs in
            let leftThreat = threatPIDs.contains(lhs.process.pid), rightThreat = threatPIDs.contains(rhs.process.pid)
            if leftThreat != rightThreat { return leftThreat }
            if lhs.connections.count != rhs.connections.count { return lhs.connections.count > rhs.connections.count }
            return lhs.process.displayName.localizedCaseInsensitiveCompare(rhs.process.displayName) == .orderedAscending
        }
    }

    /// The filtered connections as sortable table rows.
    var rows: [NetConnectionRow] {
        filteredConnections.map { connection in
            let remote = connection.record.remoteAddress.map { address -> String in
                let endpoint = NetAddress.endpoint(address, port: connection.record.remotePort)
                if let host = hostNames[address] { return "\(host) (\(endpoint))" }
                return endpoint
            } ?? "—"
            return NetConnectionRow(
                connection: connection, processName: connection.process.displayName, pid: connection.process.pid,
                local: NetAddress.endpoint(connection.record.localAddress, port: connection.record.localPort),
                remote: remote,
                remoteSortKey: connection.record.remoteAddress.map { hostNames[$0] ?? $0 } ?? "",
                stateTitle: connection.state?.title ?? (connection.record.remoteAddress == nil ? "Open" : "Connected"),
                transportTitle: connection.transport.title + (connection.record.family == .ipv6 ? "6" : "4"),
                firstSeen: connection.firstSeen)
        }
        .sorted(using: sortOrder)
    }

    var processCount: Int { Set(scan.connections.map(\.process.pid)).count }
    var establishedCount: Int { scan.connections.filter { $0.transport == .tcp && $0.state?.isActive == true }.count }
    var listeningCount: Int { scan.connections.filter(\.isListening).count }
    var udpCount: Int { scan.connections.filter { $0.transport == .udp }.count }
    var remoteHostCount: Int { Set(scan.connections.compactMap(\.checkableRemoteAddress)).count }

    func count(for filter: NetConnectionFilter) -> Int {
        scan.connections.filter(filter.includes).count
    }

    func threatHit(for connection: NetConnection) -> NetThreatHit? {
        threatHits.first { $0.process.pid == connection.process.pid && $0.remoteAddress == connection.record.remoteAddress }
    }

    func hasThreat(_ group: NetProcessConnections) -> Bool {
        threatHits.contains { $0.process.pid == group.process.pid && $0.process.startTime == group.process.startTime }
    }

    // MARK: Actions

    /// Prepares Stop for a process: computes its stop plan (launch root and children, under the same safety rules as
    /// the Ports tab) and asks for confirmation.
    func requestStop(_ process: NetProcessInfo) {
        let key = "\(process.pid)@\(process.startTime)"
        guard !busyProcessIDs.contains(key) else { return }
        busyProcessIDs.insert(key)
        let engine = ports.engine
        Task {
            let plan = await engine.freshPlan(forProcess: process.pid, startTime: process.startTime)
            busyProcessIDs.remove(key)
            guard let plan else {
                banner = PortBanner(style: .info, message: "\(process.displayName) isn't running anymore.")
                return
            }
            guard !plan.targets.isEmpty else {
                banner = PortBanner(style: .error, message: plan.warnings.first ?? "\(process.displayName) is protected and can't be stopped.")
                return
            }
            let category = process.appBundlePath != nil ? PortListenerCategory.app
                : (process.isCurrentUser ? .service : .system)
            pendingStop = NetStopConfirmation(process: process, plan: plan, category: category)
        }
    }

    /// Runs a confirmed Stop through the Ports tab's stop machinery (identity re-checked before every signal).
    func confirmStop(_ confirmation: NetStopConfirmation, mode: PortStopMode = .graceful) {
        pendingStop = nil
        let key = "\(confirmation.process.pid)@\(confirmation.process.startTime)"
        busyProcessIDs.insert(key)
        Task {
            let result = await ports.stopProcess(confirmation.plan, title: confirmation.process.displayName,
                                                 category: confirmation.category, mode: mode,
                                                 path: confirmation.process.appBundlePath ?? confirmation.process.executablePath)
            busyProcessIDs.remove(key)
            banner = result
            await refresh()
        }
    }

    func reveal(_ process: NetProcessInfo) {
        guard let path = process.appBundlePath ?? process.executablePath else { return }
        FinderActions.reveal(path)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Plain-text description of a hit, for Copy.
    static func describe(_ hit: NetThreatHit) -> String {
        var lines = [
            "Process: \(hit.process.displayName) (pid \(hit.process.pid))",
            "Remote: \(hit.remoteText)" + (hit.host.map { " (\($0))" } ?? ""),
            "Indicator: \(hit.match.indicator)",
            "Threat: \(NetThreatMatcher.threatTypeTitle(hit.match.threatType))" + (hit.match.malware.map { " — \($0)" } ?? ""),
            "Source: \(hit.match.source)",
        ]
        if let path = hit.process.executablePath { lines.insert("Path: \(path)", at: 1) }
        if let confidence = hit.match.confidence { lines.append("Confidence: \(confidence)%") }
        if let firstSeen = hit.match.firstSeen { lines.append("First seen by the feed: \(DateFormatting.short(firstSeen))") }
        if let reference = hit.match.reference { lines.append("Details: \(reference.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    func dismissBanner() { banner = nil }

    private func scheduleBannerDismissal() {
        bannerTask?.cancel()
        guard let current = banner else { return }
        let seconds: Double = current.style == .error ? 12 : 6
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.banner?.id == current.id else { return }
            self.banner = nil
        }
    }
}
