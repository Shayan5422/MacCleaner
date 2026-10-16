import Darwin
import Foundation
import Testing
@testable import MacCleaner

/// A threat feed stand-in: lists the given addresses and hosts.
struct NetFakeThreatLookup: ThreatIntelLookup {
    var ips: [String: ThreatIntelMatch] = [:]
    var hosts: [String: ThreatIntelMatch] = [:]

    func match(ip: String, port: UInt16?) -> ThreatIntelMatch? { ips[ip] }
    func match(host: String) -> ThreatIntelMatch? { hosts[host] }
    func match(url: String) -> ThreatIntelMatch? { nil }

    static func entry(_ indicator: String, malware: String? = "AMOS Stealer") -> ThreatIntelMatch {
        ThreatIntelMatch(indicator: indicator, threatType: "botnet_cc", malware: malware, confidence: 90,
                         source: "ThreatFox (abuse.ch)", firstSeen: Date(timeIntervalSince1970: 1_790_000_000),
                         reference: URL(string: "https://threatfox.abuse.ch/ioc/1/"))
    }
}

private func record(_ transport: NetTransport = .tcp, local: String = "192.168.1.81", localPort: UInt16 = 50000,
                    remote: String?, remotePort: UInt16? = 443, state: NetTCPState? = .established,
                    pid: Int32 = 4242) -> NetSocketRecord {
    NetSocketRecord(transport: transport, family: remote?.contains(":") == true ? .ipv6 : .ipv4, localAddress: local,
                    localPort: localPort, remoteAddress: remote, remotePort: remote == nil ? nil : remotePort,
                    state: transport == .udp ? nil : state, pid: pid, effectivePID: nil, source: .descriptor)
}

private func process(_ pid: Int32 = 4242, name: String = "curl", user: Bool = true) -> NetProcessInfo {
    NetProcessInfo(pid: pid, startTime: 7, uid: user ? 501 : 0, name: name, executablePath: "/usr/bin/" + name,
                   appBundlePath: nil, appName: nil, isCurrentUser: user, hasExited: false)
}

@Suite struct NetSocketParsingTests {
    @Test func tcpListParsesEveryStateWithBothEnds() throws {
        var list = PortPCBListBuilder()
        list.append(port: 52000, family: AF_INET, ipv4: [192, 168, 1, 81], pid: 900, state: 4,
                    remotePort: 443, remoteIPv4: [140, 82, 112, 3])
        list.append(port: 8080, family: AF_INET, ipv4: [0, 0, 0, 0], pid: 901, state: 1)
        list.append(port: 52001, family: AF_INET6,
                    ipv6: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x81], pid: 902, state: 10,
                    remotePort: 80, remoteIPv6: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02],
                    effectivePID: 77)
        let records = try #require(list.finish().withUnsafeBytes { NetSocketReader.parsePCBList($0, transport: .tcp) })
        #expect(records.count == 3)
        #expect(records[0].localAddress == "192.168.1.81" && records[0].localPort == 52000)
        #expect(records[0].remoteAddress == "140.82.112.3" && records[0].remotePort == 443)
        #expect(records[0].state == .established && records[0].pid == 900 && records[0].source == .kernelList)
        #expect(records[1].isListening && records[1].remoteAddress == nil && records[1].localAddress == "*")
        #expect(records[2].family == .ipv6 && records[2].remoteAddress == "2001:db8::2" && records[2].state == .timeWait)
        #expect(records[2].effectivePID == 77, "the app a daemon worked for")
    }

    @Test func udpListHasNoTCPRecords() throws {
        var list = PortPCBListBuilder()
        list.append(port: 5353, family: AF_INET, ipv4: [0, 0, 0, 0], pid: 300, state: nil)
        list.append(port: 61000, family: AF_INET, ipv4: [192, 168, 1, 81], pid: 301, state: nil,
                    remotePort: 3478, remoteIPv4: [17, 253, 1, 2])
        let records = try #require(list.finish().withUnsafeBytes { NetSocketReader.parsePCBList($0, transport: .udp) })
        #expect(records.map(\.localPort) == [5353, 61000])
        #expect(records.allSatisfy { $0.transport == .udp && $0.state == nil })
        #expect(records[0].remoteAddress == nil)
        #expect(records[1].remoteAddress == "17.253.1.2" && records[1].remotePort == 3478)
    }

    @Test func malformedListsAreRejected() {
        #expect([UInt8](repeating: 0, count: 8).withUnsafeBytes { NetSocketReader.parsePCBList($0, transport: .tcp) } == nil)
        var header = [UInt8](repeating: 0, count: 48)
        header[0] = 24
        header[24] = 24
        #expect(header.withUnsafeBytes { NetSocketReader.parsePCBList($0, transport: .udp) } == nil,
                "a list without PCBs is a filtered view, not an empty Mac")
    }

    @Test func mergeKeepsExactOwnersAndAddsTheRest() {
        let mine = record(remote: "140.82.112.3", pid: 10)
        let duplicate = NetSocketRecord(transport: .tcp, family: .ipv4, localAddress: mine.localAddress,
                                        localPort: mine.localPort, remoteAddress: mine.remoteAddress,
                                        remotePort: mine.remotePort, state: .established, pid: 99, effectivePID: nil,
                                        source: .kernelList)
        let rootOnly = record(local: "192.168.1.81", localPort: 50001, remote: "17.57.144.10", pid: 1)
        let merged = NetSocketReader.merge(descriptor: [mine], kernel: [duplicate, rootOnly])
        #expect(merged.map(\.pid) == [10, 1], "the descriptor owner wins; other users' sockets come from the kernel list")
        #expect(NetSocketReader.merge(descriptor: [mine], kernel: nil).count == 1)
    }
}

@Suite struct NetAddressTests {
    @Test func scopes() {
        #expect(NetAddress.scope("127.0.0.1") == .loopback)
        #expect(NetAddress.scope("::1") == .loopback)
        #expect(NetAddress.scope("10.1.2.3") == .privateNetwork)
        #expect(NetAddress.scope("172.20.0.1") == .privateNetwork)
        #expect(NetAddress.scope("172.32.0.1") == .publicInternet)
        #expect(NetAddress.scope("192.168.1.254") == .privateNetwork)
        #expect(NetAddress.scope("169.254.10.1") == .linkLocal)
        #expect(NetAddress.scope("100.100.1.1") == .sharedCGNAT)
        #expect(NetAddress.scope("224.0.0.251") == .multicast)
        #expect(NetAddress.scope("0.0.0.0") == .unspecified)
        #expect(NetAddress.scope("fe80::1%en0") == .linkLocal)
        #expect(NetAddress.scope("fd0f:ee:b0::1") == .privateNetwork)
        #expect(NetAddress.scope("ff02::fb") == .multicast)
        #expect(NetAddress.scope("::ffff:8.8.8.8") == .publicInternet, "v4-mapped addresses are judged by their IPv4")
        #expect(NetAddress.scope("2606:4700:4700::1111") == .publicInternet)
        #expect(NetAddress.scope("not an address") == nil)
    }

    @Test func routableAndEndpoints() {
        #expect(NetAddress.isRoutable("140.82.112.3"))
        #expect(NetAddress.isRoutable("192.168.1.6"), "a compromised device on the network can be a C&C server too")
        #expect(!NetAddress.isRoutable("127.0.0.1"))
        #expect(!NetAddress.isRoutable("fe80::1"))
        #expect(!NetAddress.isRoutable("*"))
        #expect(NetAddress.endpoint("1.2.3.4", port: 443) == "1.2.3.4:443")
        #expect(NetAddress.endpoint("2001:db8::1", port: 443) == "[2001:db8::1]:443")
        #expect(NetAddress.endpoint("1.2.3.4", port: nil) == "1.2.3.4")
    }
}

@Suite struct NetThreatMatchingTests {
    @Test func matchesByAddressThenHostName() {
        let lookup = NetFakeThreatLookup(ips: ["185.1.2.3": NetFakeThreatLookup.entry("185.1.2.3:443")],
                                         hosts: ["evil.example": NetFakeThreatLookup.entry("evil.example", malware: nil)])
        let records = [
            record(remote: "185.1.2.3", pid: 1),
            record(remote: "185.1.2.3", remotePort: 8443, pid: 2),
            record(remote: "93.184.216.34", pid: 3),
            record(remote: "127.0.0.1", pid: 4),
            record(.udp, remote: nil, pid: 5),
        ]
        let matches = NetThreatMatcher.matches(in: records, hosts: ["93.184.216.34": "evil.example"], lookup: lookup)
        #expect(matches.map(\.record.pid) == [1, 2, 3])
        #expect(matches[2].host == "evil.example")
        #expect(NetThreatMatcher.matches(in: records, lookup: lookup).count == 2, "host names only count when looked up")
    }

    @Test func plainWordsForTheFeeds() {
        let entry = NetFakeThreatLookup.entry("185.1.2.3:443")
        #expect(NetThreatMatcher.summary(of: entry) == "ThreatFox: botnet C&C (AMOS Stealer) · 90% confidence")
        #expect(NetThreatMatcher.threatTypeTitle("payload_delivery") == "malware delivery")
        #expect(NetThreatMatcher.threatTypeTitle("some_new_type") == "some new type")
        #expect(NetThreatMatcher.feedName("URLhaus (abuse.ch)") == "URLhaus")
    }
}

@MainActor
@Suite struct NetShieldTests {
    @Test func eachProcessAndIndicatorIsReportedOnce() {
        let log = ProtectionEventLog(directory: nil)
        let shield = NetShield(eventLog: log, lookupProvider: { nil })
        let hit = NetThreatHit(process: process(), remoteAddress: "185.1.2.3", remotePort: 443, host: nil,
                               match: NetFakeThreatLookup.entry("185.1.2.3:443"), firstSeen: Date())
        #expect(shield.report([hit, hit], notify: false).count == 1)
        #expect(shield.report([hit], notify: false).isEmpty, "a long-lived connection is reported once")
        let events = log.events(of: [.maliciousConnection])
        #expect(events.count == 1)
        #expect(events.first?.title == "“curl” connected to a known malware server")
        #expect(events.first?.detail == "185.1.2.3:443 · ThreatFox: botnet C&C (AMOS Stealer) · 90% confidence")
        #expect(events.first?.severity == .threat && events.first?.section == .network)
        #expect(shield.hits.count == 1)

        let other = NetThreatHit(process: process(4243), remoteAddress: "185.1.2.3", remotePort: 443, host: nil,
                                 match: NetFakeThreatLookup.entry("185.1.2.3:443"), firstSeen: Date())
        #expect(shield.report([other], notify: false).count == 1, "another process is a new hit")
    }

    @Test func noFeedsMeansNotChecked() async {
        let shield = NetShield(eventLog: ProtectionEventLog(directory: nil), lookupProvider: { nil })
        #expect(!shield.feedsLoaded)
        #expect(await shield.checkNow().isEmpty)
        #expect(shield.lastCheck == nil, "without feeds nothing was checked, so there is no 'last check'")
    }
}

@MainActor
@Suite struct NetConnectionsModelTests {
    private func connection(_ record: NetSocketRecord, _ process: NetProcessInfo) -> NetConnection {
        NetConnection(record: record, process: process, firstSeen: Date(timeIntervalSinceNow: -120))
    }

    private func makeModel(lookup: NetFakeThreatLookup?) -> (ConnectionsModel, ProtectionEventLog) {
        let preferences = PortUIFixtures.preferences()
        let log = ProtectionEventLog(directory: nil)
        let provider: @Sendable () -> (any ThreatIntelLookup)? = { lookup }
        let shield = NetShield(eventLog: log, lookupProvider: provider)
        let model = ConnectionsModel(preferences: preferences, shield: shield, ports: PortUIFixtures.model(preferences: preferences),
                                     lookupProvider: provider)
        return (model, log)
    }

    @Test func filtersGroupsRowsAndThreats() {
        let lookup = NetFakeThreatLookup(ips: ["185.1.2.3": NetFakeThreatLookup.entry("185.1.2.3:443")])
        let (model, log) = makeModel(lookup: lookup)
        let curl = process(10, name: "curl")
        let safari = process(20, name: "Safari")
        let mdns = process(30, name: "mDNSResponder", user: false)
        model.apply(NetConnectionScan(date: Date(), connections: [
            connection(record(remote: "185.1.2.3", pid: 10), curl),
            connection(record(remote: "17.253.1.2", pid: 20), safari),
            connection(record(local: "*", localPort: 3000, remote: nil, state: .listen, pid: 20), safari),
            connection(record(.udp, local: "*", localPort: 5353, remote: nil, pid: 30), mdns),
            connection(record(remote: "17.253.1.9", state: .timeWait, pid: 20), safari),
        ], kernelListAvailable: true, duration: 0))

        #expect(model.count(for: .established) == 2)
        #expect(model.count(for: .listening) == 1)
        #expect(model.count(for: .udp) == 1)
        #expect(model.count(for: .all) == 5)
        #expect(model.threatHits.map(\.process.pid) == [10])
        #expect(log.events(of: [.maliciousConnection]).count == 1, "the Connections tab reports hits to the activity feed")
        #expect(model.processGroups.first?.process.pid == 10, "a process talking to a malicious server comes first")

        model.filter = .all
        model.searchText = "safari 3000"
        #expect(model.filteredConnections.count == 1)
        model.searchText = ""
        model.grouping = .flat
        model.sortOrder = [KeyPathComparator(\NetConnectionRow.pid, order: .reverse)]
        #expect(model.rows.first?.pid == 30)
        #expect(model.rows.contains { $0.remote == "185.1.2.3:443" })
    }

    @Test func withoutFeedsNothingIsFlagged() {
        let (model, log) = makeModel(lookup: nil)
        model.apply(NetConnectionScan(date: Date(), connections: [connection(record(remote: "185.1.2.3", pid: 10), process(10))],
                                      kernelListAvailable: false, duration: 0))
        #expect(!model.feedsLoaded)
        #expect(model.threatHits.isEmpty)
        #expect(log.events.isEmpty)
    }

    @Test func describesAHitForCopy() {
        let hit = NetThreatHit(process: process(), remoteAddress: "185.1.2.3", remotePort: 443, host: "evil.example",
                               match: NetFakeThreatLookup.entry("185.1.2.3:443"), firstSeen: Date())
        let text = ConnectionsModel.describe(hit)
        #expect(text.contains("Process: curl (pid 4242)"))
        #expect(text.contains("Remote: 185.1.2.3:443 (evil.example)"))
        #expect(text.contains("Threat: botnet C&C — AMOS Stealer"))
        #expect(text.contains("Details: https://threatfox.abuse.ch/ioc/1/"))
    }
}

// MARK: - Live (this test process's own sockets; no packet leaves the Mac)

extension PortLiveProcessTests {
    @Suite struct NetLiveSocketTests {
        /// A UDP socket "connected" to a documentation address (192.0.2.0/24, TEST-NET-1): connect() on UDP sends
        /// nothing, so the socket gets a remote end without any traffic.
        private func connectedUDPSocket(to address: String, port: UInt16) throws -> Int32 {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { throw PortTestError("socket() failed") }
            var remote = sockaddr_in()
            remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            remote.sin_family = sa_family_t(AF_INET)
            remote.sin_port = port.bigEndian
            inet_pton(AF_INET, address, &remote.sin_addr)
            let status = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard status == 0 else {
                close(fd)
                throw PortTestError("connect() failed: \(errno)")
            }
            return fd
        }

        @Test func ownSocketsAreReadWithBothEnds() throws {
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            defer { listener.close() }
            // A loopback TCP connection to our own listener.
            let client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            defer { close(client) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = listener.port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            #expect(connected == 0)
            let udp = try connectedUDPSocket(to: "192.0.2.55", port: 4444)
            defer { close(udp) }

            let me = try #require(PortSysProc.basic(pid: getpid()))
            let records = NetSocketReader.descriptorSockets(of: [me])
            #expect(records.contains { $0.transport == .tcp && $0.state == .listen && $0.localPort == listener.port })
            #expect(records.contains { $0.transport == .tcp && $0.remotePort == listener.port && $0.remoteAddress == "127.0.0.1"
                                       && $0.state == .established })
            #expect(records.contains { $0.transport == .udp && $0.remoteAddress == "192.0.2.55" && $0.remotePort == 4444 })
            #expect(records.allSatisfy { $0.pid == getpid() && $0.source == .descriptor })
        }

        @Test func scannerAttributesProcessesAndKeepsFirstSeen() throws {
            let udp = try connectedUDPSocket(to: "192.0.2.56", port: 4445)
            defer { close(udp) }
            let scanner = NetConnectionScanner()
            let first = scanner.scan(includeOtherUsers: false, now: Date(timeIntervalSince1970: 1_000))
            let mine = try #require(first.connections.first { $0.record.remoteAddress == "192.0.2.56" })
            #expect(mine.process.pid == getpid())
            #expect(mine.process.isCurrentUser)
            #expect(mine.checkableRemoteAddress == "192.0.2.56")
            let second = scanner.scan(includeOtherUsers: false, now: Date(timeIntervalSince1970: 2_000))
            let again = try #require(second.connections.first { $0.record.remoteAddress == "192.0.2.56" })
            #expect(again.firstSeen == Date(timeIntervalSince1970: 1_000), "the first time Mac Cleaner saw it")
        }

        @MainActor
        @Test func shieldFindsAKnownServerOnALiveSocket() async throws {
            let udp = try connectedUDPSocket(to: "192.0.2.57", port: 4446)
            defer { close(udp) }
            let lookup = NetFakeThreatLookup(ips: ["192.0.2.57": NetFakeThreatLookup.entry("192.0.2.57:4446")])
            let log = ProtectionEventLog(directory: nil)
            let shield = NetShield(eventLog: log, lookupProvider: { lookup })
            shield.isEnabled = { false }   // no system notification from a test
            let hits = await shield.checkNow()
            #expect(hits.count == 1)
            #expect(hits.first?.process.pid == getpid())
            #expect(hits.first?.remoteText == "192.0.2.57:4446")
            #expect(shield.lastCheck != nil)
            #expect(await shield.checkNow().isEmpty, "found once, reported once")
            #expect(log.events(of: [.maliciousConnection]).count == 1)
        }
    }
}
