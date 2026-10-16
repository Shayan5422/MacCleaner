import Foundation
import Testing
@testable import MacCleaner

struct WebShieldHistoryReaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func chromiumSource(_ path: String) -> WebShieldHistorySource {
        WebShieldHistorySource(id: "chrome|Default", browserID: "chrome", browserName: "Google Chrome", profileName: nil, engine: .chromium, databasePath: path)
    }

    private func makeChromium(_ directory: GuardianTestDirectory, visits: Int = 3) throws -> (path: String, database: GuardianTestDatabase) {
        let path = directory.path("Chrome/Default/History")
        let database = try GuardianTestDatabase(path: path)
        try database.execute(GuardianHistoryFixtures.chromiumSchema)
        for id in 1...max(1, visits) {
            try GuardianHistoryFixtures.addChromiumVisit(database, id: id, url: "https://example.com/page\(id)", date: now.addingTimeInterval(Double(id)))
        }
        return (path, database)
    }

    @Test func firstReadOnlyRemembersWhereHistoryEnds() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory)
        chromium.database.close()
        let result = try WebShieldHistoryReader.read(source: chromiumSource(chromium.path), cursor: nil, scratchDirectory: directory.path("scratch"), now: now)
        #expect(result.visits.isEmpty)
        #expect(result.cursor.lastVisitID == 3)
        #expect(result.cursor.lastVisitTime == GuardianHistoryFixtures.chromiumTime(now.addingTimeInterval(3)))
        #expect(!result.cursor.fileSignature.isEmpty)
    }

    @Test func laterReadsReturnOnlyNewVisitsAndSkipUnchangedFiles() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory)
        let scratch = directory.path("scratch")
        let source = chromiumSource(chromium.path)
        let baseline = try WebShieldHistoryReader.read(source: source, cursor: nil, scratchDirectory: scratch, now: now).cursor

        try GuardianHistoryFixtures.addChromiumVisit(chromium.database, id: 4, url: "http://evil.example/download.zip", date: now.addingTimeInterval(10))
        try GuardianHistoryFixtures.addChromiumVisit(chromium.database, id: 5, url: "https://example.com/page1", date: now.addingTimeInterval(11))
        let second = try WebShieldHistoryReader.read(source: source, cursor: baseline, scratchDirectory: scratch, now: now)
        #expect(second.visits.map(\.id) == [4, 5])
        #expect(second.visits.first?.url == "http://evil.example/download.zip")
        #expect(second.cursor.lastVisitID == 5)

        let third = try WebShieldHistoryReader.read(source: source, cursor: second.cursor, scratchDirectory: scratch, now: now)
        #expect(third.skipped)
        #expect(third.visits.isEmpty)
        // Working copies are deleted after every read.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch))?.isEmpty == true)
    }

    @Test func readingNeverChangesTheBrowsersFiles() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory)
        try chromium.database.execute("PRAGMA journal_mode = TRUNCATE;")
        chromium.database.close()
        let before = try Data(contentsOf: URL(fileURLWithPath: chromium.path))
        let signature = WebShieldHistoryReader.fileSignature(chromium.path)
        let folder = (chromium.path as NSString).deletingLastPathComponent
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()

        _ = try WebShieldHistoryReader.read(source: chromiumSource(chromium.path), cursor: nil, scratchDirectory: directory.path("scratch"), now: now)
        _ = try WebShieldHistoryReader.read(source: chromiumSource(chromium.path),
                                            cursor: WebShieldCursor(lastVisitID: 1, lastVisitTime: 0, fileSignature: "", updatedAt: now),
                                            scratchDirectory: directory.path("scratch"), now: now)

        #expect(try Data(contentsOf: URL(fileURLWithPath: chromium.path)) == before)
        #expect(WebShieldHistoryReader.fileSignature(chromium.path) == signature)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == namesBefore)
    }

    @Test func readsWhileTheBrowserHoldsAnExclusiveLock() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory)
        let source = chromiumSource(chromium.path)
        let baseline = try WebShieldHistoryReader.read(source: source, cursor: nil, scratchDirectory: directory.path("scratch"), now: now).cursor
        // Like Chrome: exclusive locking mode, so other connections can't even read the file.
        try chromium.database.execute("PRAGMA locking_mode = EXCLUSIVE;")
        try GuardianHistoryFixtures.addChromiumVisit(chromium.database, id: 4, url: "https://new.example/", date: now.addingTimeInterval(20))
        #expect(throws: (any Error).self) {
            let direct = try PrivacySQLiteDatabase(path: chromium.path, readOnly: true, busyTimeoutMilliseconds: 50)
            _ = try direct.integer("SELECT COUNT(*) FROM visits")
        }
        let result = try WebShieldHistoryReader.read(source: source, cursor: baseline, scratchDirectory: directory.path("scratch"), now: now)
        #expect(result.visits.map(\.url) == ["https://new.example/"])
    }

    @Test func firefoxVisitsStillInTheWriteAheadLogAreRead() throws {
        let directory = try GuardianTestDirectory()
        let path = directory.path("Firefox/Profiles/abcd.default-release/places.sqlite")
        let database = try GuardianTestDatabase(path: path)
        try database.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
        try database.execute(GuardianHistoryFixtures.firefoxSchema)
        try GuardianHistoryFixtures.addFirefoxVisit(database, id: 1, url: "https://example.org/", date: now)
        let source = WebShieldHistorySource(id: "firefox|abcd.default-release", browserID: "firefox", browserName: "Firefox", profileName: nil, engine: .firefox, databasePath: path)
        let baseline = try WebShieldHistoryReader.read(source: source, cursor: nil, scratchDirectory: directory.path("scratch"), now: now).cursor
        #expect(baseline.lastVisitID == 1)

        try GuardianHistoryFixtures.addFirefoxVisit(database, id: 2, url: "https://bad.example.net/x", date: now.addingTimeInterval(5))
        // Not checkpointed: the new visit exists only in places.sqlite-wal.
        #expect(FileManager.default.fileExists(atPath: path + "-wal"))
        let result = try WebShieldHistoryReader.read(source: source, cursor: baseline, scratchDirectory: directory.path("scratch"), now: now)
        #expect(result.visits.map(\.url) == ["https://bad.example.net/x"])
        #expect(WebShieldHistoryReader.date(ofVisitTime: result.visits[0].time, engine: .firefox) == now.addingTimeInterval(5))
    }

    @Test func safariHistoryIsRead() throws {
        let directory = try GuardianTestDirectory()
        let path = directory.path("Safari/History.db")
        let database = try GuardianTestDatabase(path: path)
        try database.execute(GuardianHistoryFixtures.safariSchema)
        try GuardianHistoryFixtures.addSafariVisit(database, id: 1, url: "https://apple.com/", date: now)
        let source = WebShieldHistorySource(id: "safari", browserID: "safari", browserName: "Safari", profileName: nil, engine: .safari, databasePath: path)
        let baseline = try WebShieldHistoryReader.read(source: source, cursor: nil, scratchDirectory: directory.path("scratch"), now: now).cursor
        try GuardianHistoryFixtures.addSafariVisit(database, id: 2, url: "http://203.0.113.9/bins/payload", date: now.addingTimeInterval(30))
        let result = try WebShieldHistoryReader.read(source: source, cursor: baseline, scratchDirectory: directory.path("scratch"), now: now)
        #expect(result.visits.map(\.url) == ["http://203.0.113.9/bins/payload"])
        let date = try #require(WebShieldHistoryReader.date(ofVisitTime: result.visits[0].time, engine: .safari))
        #expect(abs(date.timeIntervalSince(now.addingTimeInterval(30))) < 0.001)
    }

    @Test func clearedHistoryIsReadByTime() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory, visits: 5)
        let source = chromiumSource(chromium.path)
        let baseline = try WebShieldHistoryReader.read(source: source, cursor: nil, scratchDirectory: directory.path("scratch"), now: now).cursor
        #expect(baseline.lastVisitID == 5)
        // The person cleared history; visit numbers start over.
        try chromium.database.execute("DELETE FROM visits; DELETE FROM urls;")
        try GuardianHistoryFixtures.addChromiumVisit(chromium.database, id: 1, url: "https://after-clear.example/", date: now.addingTimeInterval(100))
        let result = try WebShieldHistoryReader.read(source: source, cursor: baseline, scratchDirectory: directory.path("scratch"), now: now)
        #expect(result.visits.map(\.url) == ["https://after-clear.example/"])
        #expect(result.cursor.lastVisitID == 1)
    }

    @Test func largeBacklogsAreReadInBatches() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory, visits: 1)
        let source = chromiumSource(chromium.path)
        let baseline = try WebShieldHistoryReader.read(source: source, cursor: nil, scratchDirectory: directory.path("scratch"), now: now).cursor
        try chromium.database.execute("BEGIN;")
        for id in 2...(WebShieldHistoryReader.maximumVisitsPerRead + 6) {
            try GuardianHistoryFixtures.addChromiumVisit(chromium.database, id: id, url: "https://example.com/\(id)", date: now.addingTimeInterval(Double(id)))
        }
        try chromium.database.execute("COMMIT;")
        let first = try WebShieldHistoryReader.read(source: source, cursor: baseline, scratchDirectory: directory.path("scratch"), now: now)
        #expect(first.visits.count == WebShieldHistoryReader.maximumVisitsPerRead)
        #expect(first.cursor.fileSignature.isEmpty) // forces the next read
        let second = try WebShieldHistoryReader.read(source: source, cursor: first.cursor, scratchDirectory: directory.path("scratch"), now: now)
        #expect(second.visits.count == 5)
        #expect(second.visits.last?.id == Int64(WebShieldHistoryReader.maximumVisitsPerRead + 6))
    }

    @Test func missingAndForeignDatabasesAreReported() throws {
        let directory = try GuardianTestDirectory()
        #expect(throws: WebShieldReadError.missing) {
            _ = try WebShieldHistoryReader.read(source: chromiumSource(directory.path("none")), cursor: nil, scratchDirectory: directory.path("scratch"))
        }
        let path = directory.path("Other/History")
        let database = try GuardianTestDatabase(path: path)
        try database.execute("CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT);")
        #expect(throws: WebShieldReadError.unexpectedSchema) {
            _ = try WebShieldHistoryReader.read(source: chromiumSource(path), cursor: nil, scratchDirectory: directory.path("scratch"))
        }
    }

    @Test func blockedHistoryAsksForFullDiskAccess() throws {
        let directory = try GuardianTestDirectory()
        let chromium = try makeChromium(directory)
        chromium.database.close()
        let folder = (chromium.path as NSString).deletingLastPathComponent
        chmod(folder, 0o000)
        defer { chmod(folder, 0o755) }
        #expect(throws: WebShieldReadError.needsFullDiskAccess) {
            _ = try WebShieldHistoryReader.read(source: chromiumSource(chromium.path), cursor: nil, scratchDirectory: directory.path("scratch"))
        }
    }

    @Test func rowParsing() {
        #expect(WebShieldHistoryReader.parseRow("12 13370000000000000 https://a.example/path with space") ==
                WebShieldVisit(id: 12, time: 13_370_000_000_000_000, url: "https://a.example/path with space"))
        #expect(WebShieldHistoryReader.parseRow("12 13370000000000000 ")?.url == "")
        #expect(WebShieldHistoryReader.parseRow("garbage") == nil)
    }
}

struct WebShieldSourcesTests {
    @Test func findsChromiumProfilesFirefoxProfilesAndSafari() throws {
        let directory = try GuardianTestDirectory()
        let home = directory.root
        let support = home + "/Library/Application Support/Google/Chrome"
        for profile in ["Default", "Profile 1", "Profile 2"] {
            try directory.write("{}", to: "Library/Application Support/Google/Chrome/\(profile)/Preferences")
        }
        try directory.write("", to: "Library/Application Support/Google/Chrome/Default/History")
        try directory.write("", to: "Library/Application Support/Google/Chrome/Profile 1/History")
        try directory.write(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#,
                            to: "Library/Application Support/Google/Chrome/Local State")
        let chrome = WebShieldSources.discover(browser: .chrome, home: home)
        #expect(chrome.access == .readable)
        #expect(chrome.sources.map(\.id) == ["chrome|Default", "chrome|Profile 1"])
        #expect(chrome.sources.map(\.profileName) == ["Personal", "Work"])
        #expect(chrome.sources.first?.databasePath == support + "/Default/History")

        try directory.write("[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abcd.default-release\nDefault=1\n",
                            to: "Library/Application Support/Firefox/profiles.ini")
        try directory.write("", to: "Library/Application Support/Firefox/Profiles/abcd.default-release/places.sqlite")
        let firefox = WebShieldSources.discover(browser: .firefox, home: home)
        #expect(firefox.sources.map(\.id) == ["firefox|abcd.default-release"])
        #expect(firefox.sources.first?.profileName == nil)

        #expect(WebShieldSources.discover(browser: .safari, home: home).access == .noHistory)
        try directory.write("", to: "Library/Safari/History.db")
        #expect(WebShieldSources.discover(browser: .safari, home: home).sources.count == 1)
        #expect(WebShieldSources.discover(browser: .brave, home: home).access == .noHistory)
    }

    @Test func protectedFoldersNeedFullDiskAccess() throws {
        let directory = try GuardianTestDirectory()
        let support = try directory.makeDirectory("Library/Application Support/Google/Chrome")
        try directory.write("{}", to: "Library/Application Support/Google/Chrome/Default/Preferences")
        chmod(support, 0o000)
        defer { chmod(support, 0o755) }
        #expect(WebShieldSources.discover(browser: .chrome, home: directory.root).access == .needsFullDiskAccess)
    }
}

struct WebShieldMatcherTests {
    private let lookup = GuardianFakeLookup(
        urls: ["http://203.0.113.9/bins/payload": GuardianFakeLookup.entry("http://203.0.113.9/bins/payload")],
        hosts: ["evil.example": GuardianFakeLookup.entry("evil.example", type: "payload_delivery", malware: "AMOS Stealer")],
        ips: ["198.51.100.7": GuardianFakeLookup.entry("198.51.100.7:443", type: "botnet_cc")]
    )

    @Test func hostExtraction() {
        #expect(WebShieldMatcher.host(of: "https://Download.Evil.Example./a?b=c")?.host == "download.evil.example")
        #expect(WebShieldMatcher.host(of: "http://user:pass@evil.example:8080/x")?.host == "evil.example")
        #expect(WebShieldMatcher.host(of: "http://user:pass@evil.example:8080/x")?.port == 8080)
        #expect(WebShieldMatcher.host(of: "https://[2001:db8::1]/")?.host == "2001:db8::1")
        #expect(WebShieldMatcher.host(of: "https://bad host.example/x y")?.host == "bad host.example")
        #expect(WebShieldMatcher.host(of: "chrome://settings") == nil)
        #expect(WebShieldMatcher.host(of: "file:///Users/test/a.html") == nil)
        #expect(WebShieldMatcher.host(of: "about:blank") == nil)
    }

    @Test func matchesURLsThenHostsThenAddresses() {
        #expect(WebShieldMatcher.match(url: "http://203.0.113.9/bins/payload", lookup: lookup)?.match.threatType == "malware_download")
        #expect(WebShieldMatcher.match(url: "https://cdn.evil.example/update.dmg", lookup: lookup)?.host == "cdn.evil.example")
        #expect(WebShieldMatcher.match(url: "https://198.51.100.7/login", lookup: lookup)?.match.threatType == "botnet_cc")
        #expect(WebShieldMatcher.match(url: "https://example.com/", lookup: lookup) == nil)
        #expect(WebShieldMatcher.match(url: "chrome://evil.example", lookup: lookup) == nil)
    }

    @Test func listingPhrases() {
        #expect(WebShieldMatcher.listingPhrase(GuardianFakeLookup.entry("x")) == "URLhaus lists it for malware downloads")
        #expect(WebShieldMatcher.listingPhrase(GuardianFakeLookup.entry("x", type: "payload_delivery", malware: "AMOS Stealer"))
                == "URLhaus lists it for delivering malware (AMOS Stealer)")
        #expect(WebShieldMatcher.listingPhrase(GuardianFakeLookup.entry("x", type: "botnet_cc")).hasSuffix("as a malware control server"))
        #expect(WebShieldMatcher.feedName("ThreatFox (abuse.ch)") == "ThreatFox")
    }

    @Test func readPositionsBelongToTheirOwnBrowserOnly() {
        #expect(WebShieldModel.sourceID("chrome|Default", belongsTo: "chrome"))
        #expect(!WebShieldModel.sourceID("chromium|Default", belongsTo: "chrome"))
        #expect(WebShieldModel.sourceID("safari", belongsTo: "safari"))
    }

    @Test func notificationTextFollowsTheWording() {
        #expect(WebShieldModel.notificationBody(host: "evil.example", phrase: "URLhaus lists it for malware downloads")
                == "Warning: you opened a known malware site — evil.example. URLhaus lists it for malware downloads. Close the tab and don't download or open anything from it.")
    }

    @Test func scannerReturnsOnlyMatchesAndPositions() throws {
        let directory = try GuardianTestDirectory()
        let path = directory.path("Chrome/Default/History")
        let database = try GuardianTestDatabase(path: path)
        try database.execute(GuardianHistoryFixtures.chromiumSchema)
        try GuardianHistoryFixtures.addChromiumVisit(database, id: 1, url: "https://example.com/", date: Date())
        let source = WebShieldHistorySource(id: "chrome|Default", browserID: "chrome", browserName: "Google Chrome", profileName: nil, engine: .chromium, databasePath: path)
        let scratch = directory.path("scratch")
        let first = WebShieldScanner.check(sources: [source], cursors: [:], lookup: lookup, scratchDirectory: scratch)
        #expect(first.matches.isEmpty)
        let cursor = try #require(first.sources.first?.cursor)

        try GuardianHistoryFixtures.addChromiumVisit(database, id: 2, url: "https://example.com/news", date: Date())
        try GuardianHistoryFixtures.addChromiumVisit(database, id: 3, url: "https://www.evil.example/get", date: Date())
        let second = WebShieldScanner.check(sources: [source], cursors: [source.id: cursor], lookup: lookup, scratchDirectory: scratch)
        #expect(second.matches.map(\.host) == ["www.evil.example"])
        #expect(second.matches.first?.match.malware == "AMOS Stealer")
        #expect(second.sources.first?.visitsChecked == 2)
        #expect(second.sources.first?.cursor?.lastVisitID == 3)
    }
}

@MainActor
struct WebShieldModelTests {
    private func model(lookup: (any ThreatIntelLookup)?, directory: GuardianTestDirectory) -> (WebShieldModel, ProtectionEventLog, GuardianSettings) {
        let defaults = UserDefaults(suiteName: "guardian.tests." + UUID().uuidString)!
        let settings = GuardianSettings(defaults: defaults)
        // The test host is the real app: never post real notifications from tests.
        settings.webShieldNotifications = false
        let log = ProtectionEventLog(directory: nil)
        let box = GuardianLookupBox(lookup)
        let model = WebShieldModel(settings: settings, eventLog: log, storageDirectory: nil, scratchDirectory: directory.url.appendingPathComponent("scratch"),
                                   home: directory.root, lookupProvider: { box.lookup })
        return (model, log, settings)
    }

    @Test func statusReflectsSettingsAndFeeds() throws {
        let directory = try GuardianTestDirectory()
        let (noFeeds, _, settings) = model(lookup: nil, directory: directory)
        #expect(noFeeds.status == .waitingForFeeds)
        settings.webShieldEnabled = false
        #expect(noFeeds.status == .off)
        let (withFeeds, _, _) = model(lookup: GuardianFakeLookup(), directory: directory)
        #expect(withFeeds.status == .idle)
    }

    @Test func matchesBecomeOneWarningAndOneThreatEventPerSite() throws {
        let directory = try GuardianTestDirectory()
        let (shield, log, _) = model(lookup: GuardianFakeLookup(), directory: directory)
        let source = WebShieldHistorySource(id: "chrome|Default", browserID: "chrome", browserName: "Google Chrome", profileName: nil, engine: .chromium, databasePath: "/x")
        let match = WebShieldMatch(host: "evil.example", match: GuardianFakeLookup.entry("evil.example"), sourceID: source.id, visitDate: Date())
        shield.report([match, match], sources: [source])
        shield.report([match], sources: [source])
        #expect(shield.warnings.count == 1)
        #expect(shield.warnings.first?.browserName == "Google Chrome")
        #expect(log.events.count == 1)
        let event = try #require(log.events.first)
        #expect(event.kind == .maliciousSite)
        #expect(event.severity == .threat)
        #expect(event.section == .antivirus)
        #expect(event.title == "Known malware site opened: evil.example")
        #expect(event.detail == "URLhaus lists it for malware downloads · Google Chrome")
        // The visited address isn't kept: only the host and the feed's indicator.
        #expect(shield.warnings.first?.indicator == "evil.example")
    }

    @Test func checkMyDownloadsOpensTheAntivirusPage() throws {
        let directory = try GuardianTestDirectory()
        let (shield, _, _) = model(lookup: GuardianFakeLookup(), directory: directory)
        var opened: AppSection?
        shield.navigate = { opened = $0 }
        shield.checkMyDownloads()
        #expect(opened == .antivirus)
    }
}

/// Holds a lookup for a `@Sendable` provider closure.
final class GuardianLookupBox: @unchecked Sendable {
    let lookup: (any ThreatIntelLookup)?
    init(_ lookup: (any ThreatIntelLookup)?) { self.lookup = lookup }
}
