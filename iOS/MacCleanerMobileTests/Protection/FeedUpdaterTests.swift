import Foundation
import Testing
@testable import MacCleanerMobile

/// Small versions of the three abuse.ch exports.
enum FeedFixtures {
    static let hosts = "# URLhaus\n127.0.0.1\tmalware-host.example.com\n127.0.0.1\tsecond.example.net\n"
    static let threatFox = """
    {"1": [{"ioc_value": "c2.evil-domain.com", "ioc_type": "domain", "threat_type": "botnet_cc", "confidence_level": 100,
            "first_seen_utc": "2026-10-17 08:30:00"}],
     "2": [{"ioc_value": "https://t.me/somechannel", "ioc_type": "url", "threat_type": "botnet_cc", "confidence_level": 100}]}
    """
    static let online = "# URLhaus\nhttp://45.95.169.105:4321/i\n"

    static func answers() -> [URL: FixtureTransport.Answer] {
        [
            ThreatFeed.urlhausHosts.url: .init(status: 200, body: hosts, headers: ["ETag": "\"hosts-1\"", "Last-Modified": "Fri, 16 Oct 2026 10:00:00 GMT"]),
            ThreatFeed.threatFox.url: .init(status: 200, body: threatFox, headers: ["ETag": "\"tf-1\""]),
            ThreatFeed.urlhausOnline.url: .init(status: 200, body: online),
        ]
    }
}

struct FeedUpdaterTests {
    private let storage = temporaryProtectionStorage()

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.directory.deletingLastPathComponent())
    }

    @Test func downloadsTheListsAndWritesSafarisRules() async throws {
        defer { cleanUp() }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let updater = FeedUpdater(storage: storage, transport: FixtureTransport(FeedFixtures.answers()), now: { clock.now })
        let outcome = await updater.update(ThreatFeed.allCases, manual: false, allowsConstrainedNetwork: false)

        #expect(outcome.problems.isEmpty)
        #expect(outcome.rulesChanged)
        #expect(outcome.listsChanged)
        #expect(outcome.state[.urlhausHosts].etag == "\"hosts-1\"")
        #expect(outcome.state[.urlhausHosts].entryCount == 2)
        #expect(outcome.state[.threatFox].entryCount == 2)
        #expect(outcome.state[.urlhausOnline].lastChecked == clock.now)
        #expect(outcome.state.blocklist == BlocklistInfo(siteCount: 3, linkCount: 1, omittedCount: 0, builtAt: clock.now))

        let json = try Data(contentsOf: try #require(storage.blockerListURL))
        let rules = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: [String: String]]])
        #expect(rules.count == 4)
        #expect(storage.loadState() == outcome.state)
        #expect(storage.urlhausHosts() == ["malware-host.example.com", "second.example.net"])
        #expect(storage.urlhausAddresses() == ["http://45.95.169.105:4321/i"])
        let index = await storage.loadLinkIndex(at: clock.now)
        #expect(index.entryCount == 6)
    }

    @Test func waitsTwelveHoursThenAsksWithTheETag() async throws {
        defer { cleanUp() }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let transport = FixtureTransport(FeedFixtures.answers())
        let updater = FeedUpdater(storage: storage, transport: transport, now: { clock.now })
        _ = await updater.update(ThreatFeed.safariFeeds, manual: false, allowsConstrainedNetwork: false)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })

        clock.advance(hours: 6)
        let early = await updater.update(ThreatFeed.safariFeeds, manual: false, allowsConstrainedNetwork: false)
        #expect(transport.requests.count == 2)
        #expect(!early.rulesChanged)

        clock.advance(hours: 6)
        transport.answer(ThreatFeed.urlhausHosts.url, with: .init(status: 304, body: ""))
        transport.answer(ThreatFeed.threatFox.url, with: .init(status: 304, body: ""))
        let later = await updater.update(ThreatFeed.safariFeeds, manual: false, allowsConstrainedNetwork: false)
        let conditional = transport.requests.suffix(2)
        #expect(conditional.first?.value(forHTTPHeaderField: "If-None-Match") == "\"hosts-1\"")
        #expect(conditional.first?.value(forHTTPHeaderField: "If-Modified-Since") == "Fri, 16 Oct 2026 10:00:00 GMT")
        #expect(conditional.last?.value(forHTTPHeaderField: "If-None-Match") == "\"tf-1\"")
        #expect(conditional.allSatisfy { !$0.allowsConstrainedNetworkAccess })
        #expect(!later.rulesChanged)
        #expect(!later.listsChanged)
        #expect(later.state[.urlhausHosts].lastChecked == clock.now)
        #expect(later.state[.urlhausHosts].entryCount == 2)
    }

    @Test func aFailureIsReportedAndKeepsTheOldList() async throws {
        defer { cleanUp() }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let transport = FixtureTransport(FeedFixtures.answers())
        let updater = FeedUpdater(storage: storage, transport: transport, now: { clock.now })
        _ = await updater.update([.urlhausHosts], manual: false, allowsConstrainedNetwork: false)

        clock.advance(hours: 1)
        transport.answer(ThreatFeed.urlhausHosts.url, with: .init(status: 429, body: "slow down"))
        let limited = await updater.update([.urlhausHosts], manual: true, allowsConstrainedNetwork: true)
        #expect(limited.problems == ["abuse.ch is limiting downloads right now. Try again later."])
        #expect(limited.state[.urlhausHosts].failures == 1)
        #expect(storage.urlhausHosts().count == 2)

        transport.answer(ThreatFeed.urlhausHosts.url, with: .init(status: 200, body: "<html>maintenance</html>" + String(repeating: " ", count: 2_000)))
        clock.advance(hours: 1)
        let garbled = await updater.update([.urlhausHosts], manual: true, allowsConstrainedNetwork: true)
        #expect(garbled.problems == ["The URLhaus host list couldn't be read."])
        #expect(storage.urlhausHosts().count == 2)
    }

    @Test func offlineIsntAProblemToShow() async {
        defer { cleanUp() }
        let updater = FeedUpdater(storage: storage, transport: FixtureTransport([:]), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let outcome = await updater.update(ThreatFeed.allCases, manual: false, allowsConstrainedNetwork: false)
        #expect(outcome.offline)
        #expect(outcome.problems.isEmpty)
        #expect(!outcome.rulesChanged)
        #expect(outcome.state[.threatFox].lastError == "No internet connection.")
    }
}
