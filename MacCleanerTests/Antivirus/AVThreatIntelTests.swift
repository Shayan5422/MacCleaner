import Foundation
import Testing
@testable import MacCleaner

@Suite("Antivirus feeds and threat intelligence")
struct AVThreatIntelTests {
    // Excerpts of the real abuse.ch exports (CC0).
    static let malwareBazaarSample = """
    ################################################################
    # MalwareBazaar recent malware samples (SHA256 hashes)         #
    ################################################################
    #
    # sha256_hash
    88e78e39dcca285d6fb6d44176e5bd78989213081fa5844bf5326267190f7a88
    9C4E2B42AFA26B4F2548C4F8EC9D8AAC5BF60DA336CE0DD6FA008A2857235FE7
    88e78e39dcca285d6fb6d44176e5bd78989213081fa5844bf5326267190f7a88
    not-a-hash
    06ee9828f0f1174326dc54602ba339853e0642d351b236f402ab385cdac77b02\r
    """

    static let urlhausSample = "http://103.19.49.134:37431/bin.sh\r\nhttps://cdn.discordapp.com/attachments/1/2/bundle.zip?ex=6ad35640&is=6ad204c0\r\nHTTP://Example.COM:80/Path#frag\r\nhttps://raw.githubusercontent.com/someone/repo/main/payload.sh\r\nnot a url\r\n"

    static let hostsSample = """
    # abuse.ch URLhaus Host file
    127.0.0.1\t123.ywxww.net
    127.0.0.1\tadmin.byte.in.ua
    127.0.0.1\tlocalhost
    """

    static let threatFoxSample = """
    {
        "1969891": [{"ioc_value": "https://dg.888idrcatchy.org/u3", "ioc_type": "url", "threat_type": "botnet_cc", "malware_printable": "Vidar",
                     "first_seen_utc": "2026-10-16 13:38:48", "confidence_level": 100, "is_compromised": false}],
        "1969000": [{"ioc_value": "45.92.16.135:25674", "ioc_type": "ip:port", "threat_type": "botnet_cc", "malware_printable": "Remcos",
                     "first_seen_utc": "2026-10-16 13:21:32", "confidence_level": 100, "is_compromised": false}],
        "1968000": [{"ioc_value": "gugogijy.workers.dev", "ioc_type": "domain", "threat_type": "payload_delivery", "malware_printable": "php.shin_webshell",
                     "first_seen_utc": "2026-10-16 13:12:59", "confidence_level": 50, "is_compromised": true}],
        "1967000": [{"ioc_value": "evil-c2.example", "ioc_type": "domain", "threat_type": "botnet_cc", "malware_printable": "AMOS",
                     "first_seen_utc": "2026-10-16 13:12:59", "confidence_level": 75, "is_compromised": false}],
        "1966000": [{"ioc_value": "BEA41CA1327EC0015306CDC058E7C3806803E5447266C84D347ACA3732F59982", "ioc_type": "sha256_hash", "threat_type": "payload"}],
        "1965000": [{"ioc_value": "9b32572ea80935ca6944cffc999dd466", "ioc_type": "md5_hash", "threat_type": "payload"}],
        "1964000": [{"ioc_value": "[2001:db8::1]:8443", "ioc_type": "ip:port", "threat_type": "botnet_cc", "malware_printable": "Sliver"}]
    }
    """

    @Test func parsesMalwareBazaarHashes() {
        let hashes = AVFeedParser.sha256Hashes(Data(Self.malwareBazaarSample.utf8))
        #expect(hashes == [
            "88e78e39dcca285d6fb6d44176e5bd78989213081fa5844bf5326267190f7a88",
            "9c4e2b42afa26b4f2548c4f8ec9d8aac5bf60da336ce0dd6fa008a2857235fe7",
            "06ee9828f0f1174326dc54602ba339853e0642d351b236f402ab385cdac77b02",
        ])
    }

    @Test func parsesURLhausAndHostsFiles() {
        let urls = AVFeedParser.urls(Data(Self.urlhausSample.utf8))
        #expect(urls.contains("http://103.19.49.134:37431/bin.sh"))
        #expect(urls.contains("http://example.com/Path"))
        #expect(urls.contains("https://cdn.discordapp.com/attachments/1/2/bundle.zip?ex=6ad35640&is=6ad204c0"))
        #expect(urls.count == 4)
        #expect(AVFeedParser.hosts(Data(Self.hostsSample.utf8)) == ["123.ywxww.net", "admin.byte.in.ua"])
    }

    @Test func parsesThreatFox() throws {
        let indicators = try AVFeedParser.threatFox(Data(Self.threatFoxSample.utf8))
        #expect(indicators.count == 6) // md5 is skipped
        let c2 = try #require(indicators.first { $0.kind == .ipPort && $0.value == "45.92.16.135:25674" })
        #expect(c2.malware == "Remcos")
        #expect(c2.confidence == 100)
        #expect(c2.firstSeen == ISO8601DateFormatter().date(from: "2026-10-16T13:21:32Z"))
        #expect(indicators.contains { $0.kind == .ipPort && $0.value == "[2001:db8::1]:8443" })
        #expect(indicators.contains { $0.kind == .sha256 && $0.value == "bea41ca1327ec0015306cdc058e7c3806803e5447266c84d347aca3732f59982" })
        #expect(indicators.first { $0.value == "gugogijy.workers.dev" }?.isCompromised == true)
    }

    @Test func normalizesAddresses() {
        #expect(AVURLNormalizer.normalize("HTTPS://Example.COM:443") == "https://example.com/")
        #expect(AVURLNormalizer.normalize("http://example.com:8080/a?b=1#c") == "http://example.com:8080/a?b=1")
        #expect(AVURLNormalizer.normalize("http://user:pass@example.com/x") == "http://example.com/x")
        #expect(AVURLNormalizer.normalize("javascript:alert(1)") == nil)
        #expect(AVURLNormalizer.normalize("http://[2001:DB8::1]/x") == "http://[2001:db8::1]/x")
        #expect(AVHostNormalizer.normalize("WWW.Example.com.") == "www.example.com")
        #expect(AVHostNormalizer.normalize("localhost") == nil)
        #expect(AVHostNormalizer.normalize("bad host.com") == nil)
        #expect(AVHostNormalizer.canonicalIP("::ffff:1.2.3.4") == "1.2.3.4")
        #expect(AVHostNormalizer.canonicalIP("2001:0db8:0000::0001") == "2001:db8::1")
        #expect(AVHostNormalizer.normalizeIPPort("1.2.3.4:443") == "1.2.3.4:443")
        #expect(AVHostNormalizer.normalizeIPPort("[2001:db8::1]:443") == "[2001:db8::1]:443")
        #expect(AVHostNormalizer.normalizeIPPort("1.2.3.4") == nil)
        #expect(AVHostNormalizer.normalizeIPPort("1.2.3.4:99999") == nil)
    }

    private func sampleIndex() throws -> AVThreatIntelIndex {
        let now = Date()
        var database = AVIntelDatabase()
        database.merge(AVFeedParser.urls(Data(Self.urlhausSample.utf8)).map {
            AVIndicator(kind: .url, value: $0, source: .urlhaus, threatType: "malware_download", firstSeen: now, lastSeen: now)
        })
        database.merge(AVFeedParser.hosts(Data(Self.hostsSample.utf8)).map {
            AVIndicator(kind: .host, value: $0, source: .urlhaus, threatType: "malware_download", firstSeen: now, lastSeen: now)
        })
        database.merge(try AVFeedParser.threatFox(Data(Self.threatFoxSample.utf8)).map { ioc in
            let kind: AVIndicator.Kind = ioc.kind == .ipPort ? .ipPort : ioc.kind == .domain ? .host : ioc.kind == .url ? .url : .sha256
            return AVIndicator(kind: kind, value: ioc.value, source: .threatFox, threatType: ioc.threatType, malware: ioc.malware,
                               confidence: ioc.confidence, firstSeen: ioc.firstSeen ?? now, lastSeen: now, isCompromised: ioc.isCompromised, reference: ioc.id)
        })
        return database.index()
    }

    @Test func looksUpAddressesPortsHostsAndURLs() throws {
        let index = try sampleIndex()
        let c2 = try #require(index.match(ip: "45.92.16.135", port: 25674))
        #expect(c2.threatType == "botnet_cc")
        #expect(c2.malware == "Remcos")
        #expect(c2.source == "ThreatFox (abuse.ch)")
        #expect(c2.reference?.absoluteString == "https://threatfox.abuse.ch/ioc/1969000/")
        #expect(index.match(ip: "45.92.16.135", port: 443) == nil)
        #expect(index.match(ip: "45.92.16.135", port: nil) != nil)
        #expect(index.match(ip: "2001:db8:0::1", port: 8443) != nil)
        #expect(index.match(ip: "103.19.49.134", port: 37431)?.threatType == "malware_download")
        #expect(index.match(ip: "8.8.8.8", port: 53) == nil)

        #expect(index.match(host: "admin.byte.in.ua") != nil)
        #expect(index.match(host: "deep.sub.evil-c2.example") != nil)
        #expect(index.match(host: "EVIL-C2.example.") != nil)
        // Hosts that only appear inside URLs (shared services) never match as a whole host.
        #expect(index.match(host: "raw.githubusercontent.com") == nil)
        #expect(index.match(host: "cdn.discordapp.com") == nil)
        // Compromised legitimate sites match by exact URL only.
        #expect(index.match(host: "gugogijy.workers.dev") == nil)
        #expect(index.match(host: "example") == nil)

        #expect(index.match(url: "https://dg.888idrcatchy.org/u3")?.malware == "Vidar")
        #expect(index.match(url: "HTTPS://DG.888idrcatchy.org:443/u3#x") != nil)
        #expect(index.match(url: "https://dg.888idrcatchy.org/other") == nil)
    }

    @Test func accumulatesExpiresAndPersistsIndicators() throws {
        let directory = try AVTestFolder()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        var database = AVIntelDatabase()
        database.merge([AVIndicator(kind: .host, value: "old.example", source: .urlhaus, threatType: "malware_download", firstSeen: first, lastSeen: first)])
        let later = first.addingTimeInterval(20 * 86_400)
        database.merge([
            AVIndicator(kind: .host, value: "old.example", source: .urlhaus, threatType: "malware_download", firstSeen: later, lastSeen: later),
            AVIndicator(kind: .url, value: "https://new.example/x", source: .threatFox, threatType: "payload_delivery", malware: "Atomic",
                        confidence: 90, firstSeen: later, lastSeen: later, reference: "42"),
        ])
        #expect(database.entries["host|old.example"]?.firstSeen == first)
        #expect(database.entries["host|old.example"]?.lastSeen == later)
        database.expire(before: later.addingTimeInterval(1))
        #expect(database.count == 0)

        database.merge([AVIndicator(kind: .url, value: "https://new.example/x", source: .threatFox, threatType: "payload_delivery", malware: "Atomic",
                                    confidence: 90, firstSeen: later, lastSeen: later, reference: "42")])
        let file = directory.child("indicators.tsv")
        try database.write(to: file)
        let loaded = AVIntelDatabase.read(from: file)
        #expect(loaded.count == 1)
        let restored = try #require(loaded.entries["url|https://new.example/x"])
        #expect(restored.malware == "Atomic")
        #expect(restored.confidence == 90)
        #expect(restored.reference == "42")
        #expect(restored.lastSeen == later)
        #expect(loaded.index(sources: [.urlhaus]).match(url: "https://new.example/x") == nil)
        #expect(loaded.index(sources: [.threatFox]).match(url: "https://new.example/x") != nil)
    }

    @Test func collectsMalwareBazaarHashesForAYear() throws {
        let directory = try AVTestFolder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var collection = AVHashCollection()
        collection.merge(["aa" + String(repeating: "0", count: 62)], seenAt: start)
        collection.merge(["bb" + String(repeating: "0", count: 62)], seenAt: start.addingTimeInterval(200 * 86_400))
        collection.expire(before: start.addingTimeInterval(100 * 86_400))
        #expect(collection.count == 1)
        try collection.write(to: directory.child("hashes.tsv"))
        #expect(AVHashCollection.read(from: directory.child("hashes.tsv")).hashes == ["bb" + String(repeating: "0", count: 62)])
    }

    @Test(.enabled(if: AVRealFiles.hasFeeds))
    func parsesTheRealExports() throws {
        let recent = AVFeedParser.sha256Hashes(try Data(contentsOf: #require(AVRealFiles.url("abusech/mb-recent.txt"))))
        #expect(recent.count > 500)
        let urls = AVFeedParser.urls(try Data(contentsOf: #require(AVRealFiles.url("abusech/urlhaus-online.txt"))))
        #expect(urls.count > 10_000)
        let hosts = AVFeedParser.hosts(try Data(contentsOf: #require(AVRealFiles.url("abusech/urlhaus-hostfile.txt"))))
        #expect(hosts.count > 300)
        let threatFox = try AVFeedParser.threatFox(Data(contentsOf: #require(AVRealFiles.url("abusech/threatfox-recent.json"))))
        #expect(threatFox.count > 5_000)
        #expect(threatFox.contains { $0.kind == .ipPort })
        let now = Date()
        var database = AVIntelDatabase()
        database.merge(urls.map { AVIndicator(kind: .url, value: $0, source: .urlhaus, threatType: "malware_download", firstSeen: now, lastSeen: now) })
        database.merge(threatFox.map { AVIndicator(kind: $0.kind == .ipPort ? .ipPort : $0.kind == .domain ? .host : $0.kind == .url ? .url : .sha256,
                                                   value: $0.value, source: .threatFox, threatType: $0.threatType, firstSeen: now, lastSeen: now) })
        let index = database.index()
        let firstIPPort = try #require(threatFox.first { $0.kind == .ipPort }).value
        let parts = firstIPPort.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) { #expect(index.match(ip: String(parts[0]), port: port) != nil) }
        #expect(index.match(host: "github.com") == nil)
    }

    @Test(.enabled(if: AVRealFiles.url("abusech/mb-full.zip") != nil))
    func extractsTheFullMalwareBazaarArchive() throws {
        let directory = try AVTestFolder()
        let data = try Data(contentsOf: #require(AVRealFiles.url("abusech/mb-full.zip")), options: [.alwaysMapped])
        let entry = try #require(try AVDefsZip.entries(in: data).first { $0.name == "full_sha256.txt" })
        let output = directory.child("full.txt")
        try AVDefsZip.extract(entry, from: data, to: output, maxOutput: 600_000_000)
        #expect(AVFeedParser.countSHA256Lines(in: output) > 1_000_000)
    }

    @Test func installsIntoTheRegistry() throws {
        let holder = AVIntelHolder()
        let index = try sampleIndex()
        holder.install(index)
        #expect(holder.index?.indicatorCount == index.indicatorCount)
        #expect(ThreatIntelRegistry.shared.lookup?.match(ip: "45.92.16.135", port: 25674) != nil)
        holder.install(nil)
        #expect(ThreatIntelRegistry.shared.lookup == nil)
    }
}
