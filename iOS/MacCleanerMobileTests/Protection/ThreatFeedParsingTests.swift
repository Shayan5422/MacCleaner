import Foundation
import Testing
@testable import MacCleanerMobile

struct HostsFileTests {
    private let hostsFile = """
    ################################################################
    # abuse.ch URLhaus Host file                                   #
    # Last updated: 2026-10-17 21:05:12 (UTC)                      #
    ################################################################
    #
    127.0.0.1\tmalware-one.example.com

    0.0.0.0 Malware-Two.TEST.net.
    127.0.0.1   localhost
    127.0.0.1 localhost.localdomain
    ::1 ip6-localhost
    0.0.0.0 printer.local
    127.0.0.1\tmalware-one.example.com
    0.0.0.0 bad_sub-domain.evil.org # reported twice
    0.0.0.0 1.2.3.4
    0.0.0.0 not a host!
    plain-host.evil.biz
    0.0.0.0 first.evil.io second.evil.io\r
    # 0.0.0.0 commented.evil.com
    """

    @Test func readsHostNamesInLowerCaseWithoutDuplicates() {
        let hosts = ThreatFeedParser.hosts(Data(hostsFile.utf8))
        #expect(hosts == [
            "malware-one.example.com", "malware-two.test.net", "bad_sub-domain.evil.org", "plain-host.evil.biz",
            "first.evil.io", "second.evil.io",
        ])
    }

    @Test func skipsCommentsLocalNamesAndAddresses() {
        let hosts = Set(ThreatFeedParser.hosts(Data(hostsFile.utf8)))
        for skipped in ["localhost", "localhost.localdomain", "ip6-localhost", "printer.local", "1.2.3.4", "commented.evil.com"] {
            #expect(!hosts.contains(skipped))
        }
    }

    @Test func emptyAndCommentOnlyFilesGiveNothing() {
        #expect(ThreatFeedParser.hosts(Data()).isEmpty)
        #expect(ThreatFeedParser.hosts(Data("# nothing here\n\n#\n".utf8)).isEmpty)
    }
}

struct AddressListTests {
    @Test func readsNormalizedAddressesWithoutDuplicates() {
        let list = """
        ################################################################
        # abuse.ch URLhaus Database Dump (CSV - online URLs only)      #
        ################################################################
        http://198.51.100.7:4321/i
        HTTP://Evil.Example.COM:80/Payload.EXE?ID=1#fragment
        http://evil.example.com/Payload.EXE?ID=1
        https://user:secret@evil.example.com:443/a
        not a url
        mailto:someone@example.com

        """
        #expect(ThreatFeedParser.addresses(Data(list.utf8)) == [
            "http://198.51.100.7:4321/i",
            "http://evil.example.com/Payload.EXE?ID=1",
            "https://evil.example.com/a",
        ])
    }
}

struct ThreatFoxParsingTests {
    private let export = """
    {
      "1601001": [{"ioc_value": "c2.Evil-Domain.com", "ioc_type": "domain", "threat_type": "botnet_cc",
                   "malware": "win.vidar", "malware_printable": "Vidar", "first_seen_utc": "2026-10-17 08:30:00",
                   "last_seen_utc": null, "confidence_level": 100, "is_compromised": false, "reference": "", "tags": "Vidar"}],
      "1601002": [{"ioc_value": "https://steamcommunity.com/profiles/76561199000000000", "ioc_type": "url",
                   "threat_type": "botnet_cc", "malware_printable": "Vidar", "first_seen_utc": "2026-10-17 09:00:00",
                   "confidence_level": 75}],
      "1601003": [{"ioc_value": "198.51.100.20:443", "ioc_type": "ip:port", "threat_type": "botnet_cc",
                   "malware_printable": "Cobalt Strike", "first_seen_utc": "2026-10-16 23:59:59", "confidence_level": "50"}],
      "1601004": [{"ioc_value": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "ioc_type": "sha256_hash",
                   "threat_type": "payload", "malware_printable": "AgentTesla"}],
      "1601005": [{"ioc_value": "hacked-shop.example.org", "ioc_type": "domain", "threat_type": "payload_delivery",
                   "malware_printable": "Unknown malware", "first_seen_utc": "2026-10-17 10:00:00", "confidence_level": 50,
                   "is_compromised": true}],
      "1601006": [{"ioc_value": "203.0.113.9/bins/x86", "ioc_type": "url", "threat_type": "payload_delivery",
                   "malware_printable": "Mirai", "first_seen_utc": "2026-10-17 11:00:00", "confidence_level": 100}],
      "1601007": [{"ioc_value": "not a domain", "ioc_type": "domain"}]
    }
    """

    @Test func keepsDomainsAddressesAndServers() throws {
        let indicators = try ThreatFeedParser.threatFox(Data(export.utf8))
        let byID = Dictionary(uniqueKeysWithValues: indicators.map { ($0.id ?? "", $0) })
        #expect(indicators.count == 5)
        #expect(byID["1601004"] == nil)
        #expect(byID["1601007"] == nil)

        let domain = try #require(byID["1601001"])
        #expect(domain.kind == .domain)
        #expect(domain.value == "c2.evil-domain.com")
        #expect(domain.threatType == "botnet_cc")
        #expect(domain.malware == "Vidar")
        #expect(domain.confidence == 100)
        #expect(domain.firstSeen == Date(timeIntervalSince1970: 1_792_225_800))
        #expect(!domain.isCompromised)

        #expect(byID["1601002"]?.kind == .url)
        #expect(byID["1601002"]?.value == "https://steamcommunity.com/profiles/76561199000000000")
        #expect(byID["1601003"]?.kind == .ipPort)
        #expect(byID["1601003"]?.value == "198.51.100.20:443")
        #expect(byID["1601003"]?.confidence == 50)
    }

    @Test func readsCompromisedSitesAndUnknownFamilies() throws {
        let indicators = try ThreatFeedParser.threatFox(Data(export.utf8))
        let hacked = try #require(indicators.first { $0.id == "1601005" })
        #expect(hacked.isCompromised)
        #expect(hacked.malware == nil)
    }

    @Test func addsASchemeToBareAddresses() throws {
        let indicators = try ThreatFeedParser.threatFox(Data(export.utf8))
        #expect(indicators.first { $0.id == "1601006" }?.value == "http://203.0.113.9/bins/x86")
    }

    @Test func readsTheAPIShapeToo() throws {
        let api = #"{"query_status": "ok", "data": [{"id": "42", "ioc": "evil.example.net", "ioc_type": "domain", "threat_type": "botnet_cc"}]}"#
        let indicators = try ThreatFeedParser.threatFox(Data(api.utf8))
        #expect(indicators.map(\.value) == ["evil.example.net"])
        #expect(indicators.first?.id == "42")
    }

    @Test func throwsOnWhatIsntTheExport() {
        #expect(throws: ThreatFeedError.self) { try ThreatFeedParser.threatFox(Data("<html>rate limited</html>".utf8)) }
        #expect(throws: ThreatFeedError.self) { try ThreatFeedParser.threatFox(Data("[1, 2]".utf8)) }
    }
}

struct ThreatFoxStoreTests {
    private func ioc(_ value: String, firstSeen: Date?) -> ThreatFoxIOC {
        ThreatFoxIOC(id: "1", kind: .domain, value: value, threatType: "botnet_cc", malware: "Vidar", confidence: 100, firstSeen: firstSeen)
    }

    @Test func keepsTheFirstSightingAndTheLatestDownload() {
        let early = Date(timeIntervalSince1970: 1_000)
        var store = ThreatFoxStore()
        store.merge([ioc("evil.example.com", firstSeen: early)], seenAt: Date(timeIntervalSince1970: 5_000))
        store.merge([ioc("evil.example.com", firstSeen: Date(timeIntervalSince1970: 2_000))], seenAt: Date(timeIntervalSince1970: 9_000))
        let entry = store.entries.values.first
        #expect(store.count == 1)
        #expect(entry?.ioc.firstSeen == early)
        #expect(entry?.lastSeen == Date(timeIntervalSince1970: 9_000))
    }

    @Test func dropsIndicatorsAfterThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var store = ThreatFoxStore()
        store.merge([ioc("old.example.com", firstSeen: nil)], seenAt: now.addingTimeInterval(-31 * 86_400))
        store.merge([ioc("new.example.com", firstSeen: nil)], seenAt: now.addingTimeInterval(-86_400))
        #expect(store.current(at: now).map(\.ioc.value) == ["new.example.com"])
        store.expire(before: now.addingTimeInterval(-ThreatFoxStore.retention))
        #expect(store.entries.values.map(\.ioc.value) == ["new.example.com"])
    }

    @Test func survivesSavingAndReading() {
        var store = ThreatFoxStore()
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        store.merge([
            ThreatFoxIOC(id: "7", kind: .url, value: "http://evil.example.com/a\tb", threatType: "payload_delivery", malware: nil,
                         confidence: 75, firstSeen: Date(timeIntervalSince1970: 1_799_990_000), isCompromised: true),
            ThreatFoxIOC(id: nil, kind: .ipPort, value: "198.51.100.20:443", threatType: "botnet_cc", malware: "Cobalt Strike",
                         confidence: nil, firstSeen: nil),
        ], seenAt: seen)
        let decoded = ThreatFoxStore.decode(store.encoded())
        #expect(decoded.count == 2)
        let address = decoded.entries.values.first { $0.ioc.kind == .url }
        #expect(address?.ioc.value == "http://evil.example.com/a b")
        #expect(address?.ioc.isCompromised == true)
        #expect(address?.ioc.confidence == 75)
        #expect(address?.lastSeen == seen)
        let server = decoded.entries.values.first { $0.ioc.kind == .ipPort }
        #expect(server?.ioc.malware == "Cobalt Strike")
        #expect(server?.ioc.firstSeen == nil)
        #expect(server?.ioc.id == nil)
    }
}
