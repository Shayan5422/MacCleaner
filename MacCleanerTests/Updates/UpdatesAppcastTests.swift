import Foundation
import Testing
@testable import MacCleaner

struct UpdatesAppcastTests {
    private static let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    /// Attributes on <enclosure>, a beta channel, a newer item for a newer macOS,
    /// delta updates and a Windows enclosure.
    private static let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>Notely Changelog</title>
        <item>
          <title>Version 2.1</title>
          <pubDate>Mon, 06 Oct 2025 10:00:00 +0000</pubDate>
          <sparkle:releaseNotesLink>https://example.com/notes/2.1.html</sparkle:releaseNotesLink>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Notely-2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1" length="1000" type="application/octet-stream" sparkle:edSignature="abc"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/Notely-200-210.delta" sparkle:version="999" sparkle:shortVersionString="9.9" sparkle:deltaFrom="200" length="10" type="application/octet-stream"/>
          </sparkle:deltas>
          <sparkle:criticalUpdate sparkle:version="150"></sparkle:criticalUpdate>
        </item>
        <item>
          <title>Version 2.2 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/Notely-2.2b1.zip" sparkle:version="220" sparkle:shortVersionString="2.2b1" length="1000" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 3.0</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Notely-3.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0" length="1000" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 5.0 for Windows</title>
          <enclosure url="https://example.com/Notely-5.0.exe" sparkle:version="500" sparkle:shortVersionString="5.0" sparkle:os="windows" length="1000" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 2.0</title>
          <enclosure url="https://example.com/Notely-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0" length="1000" type="application/octet-stream"/>
        </item>
      </channel>
    </rss>
    """

    /// Versions given as elements instead of enclosure attributes (also valid Sparkle).
    private static let elementFeed = """
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title><![CDATA[Release 1.5]]></title>
          <sparkle:version>1500</sparkle:version>
          <sparkle:shortVersionString>1.5</sparkle:shortVersionString>
          <link>https://example.com/download</link>
          <sparkle:fullReleaseNotesLink>https://example.com/changelog</sparkle:fullReleaseNotesLink>
          <enclosure url="https://example.com/App-1.5.dmg" length="5" type="application/x-apple-diskimage"/>
        </item>
        <item>
          <title>Info only</title>
          <sparkle:version>1600</sparkle:version>
          <sparkle:shortVersionString>1.6</sparkle:shortVersionString>
          <link>https://example.com/news</link>
          <sparkle:informationalUpdate>
            <sparkle:version>1400</sparkle:version>
          </sparkle:informationalUpdate>
        </item>
      </channel>
    </rss>
    """

    @Test func parsesItemsIgnoringDeltas() throws {
        let items = try UpdatesAppcast.parse(Data(Self.feed.utf8))
        #expect(items.count == 5)
        let first = try #require(items.first)
        #expect(first.version == "210")
        #expect(first.shortVersion == "2.1")
        #expect(first.minimumSystemVersion == "13.0")
        #expect(first.releaseNotesURL == URL(string: "https://example.com/notes/2.1.html"))
        #expect(first.downloadURL == URL(string: "https://example.com/Notely-2.1.zip"))
        #expect(first.isCritical)
        #expect(first.publicationDate != nil)
        #expect(items[1].channel == "beta")
        #expect(items[3].operatingSystem == "windows")
    }

    @Test func bestItemFollowsSparkleRules() throws {
        let items = try UpdatesAppcast.parse(Data(Self.feed.utf8))
        let best = UpdatesAppcast.bestItem(in: items, systemVersion: Self.sonoma, isAppleSilicon: true)
        // Not the beta channel (2.2), not 3.0 (needs macOS 99), not the Windows build (5.0), not the delta.
        #expect(best?.shortVersion == "2.1")
    }

    @Test func evaluationAgainstInstalledVersions() throws {
        let items = try UpdatesAppcast.parse(Data(Self.feed.utf8))
        let outdated = UpdatesAppcast.evaluate(items: items, installedBuild: "200", installedVersion: "2.0", systemVersion: Self.sonoma)
        #expect(outdated.status == .updateAvailable)
        #expect(outdated.best?.displayVersion == "2.1")
        #expect(outdated.newerIncompatible?.displayVersion == "3.0")

        let current = UpdatesAppcast.evaluate(items: items, installedBuild: "210", installedVersion: "2.1", systemVersion: Self.sonoma)
        #expect(current.status == .incompatible, "2.1 is current for this Mac, but 3.0 needs a newer macOS")

        let newerThanFeed = UpdatesAppcast.evaluate(items: [items[0]], installedBuild: "211", installedVersion: "2.1.1", systemVersion: Self.sonoma)
        #expect(newerThanFeed.status == .upToDate)
    }

    @Test func elementVersionsAndInformationalUpdates() throws {
        let items = try UpdatesAppcast.parse(Data(Self.elementFeed.utf8))
        #expect(items.count == 2)
        #expect(items[0].version == "1500")
        #expect(items[0].shortVersion == "1.5")
        #expect(items[0].title == "Release 1.5")
        #expect(items[0].fullReleaseNotesURL == URL(string: "https://example.com/changelog"))
        // The version list inside <sparkle:informationalUpdate> isn't the item's version.
        #expect(items[1].version == "1600")
        #expect(items[1].isInformational)
        #expect(items[1].downloadURL == nil)

        let best = UpdatesAppcast.bestItem(in: items, systemVersion: Self.sonoma)
        #expect(best?.shortVersion == "1.6")
        #expect(UpdatesAppcast.evaluate(items: items, installedBuild: "1500", installedVersion: "1.5", systemVersion: Self.sonoma).status == .updateAvailable)
    }

    @Test func appleSiliconOnlyBuildsArentOfferedToIntel() {
        var item = UpdatesAppcastItem(version: "2", shortVersion: "2.0", downloadURL: URL(string: "https://example.com/a.zip"))
        item.hardwareRequirements = ["arm64"]
        #expect(UpdatesAppcast.bestItem(in: [item], systemVersion: Self.sonoma, isAppleSilicon: false) == nil)
        #expect(UpdatesAppcast.bestItem(in: [item], systemVersion: Self.sonoma, isAppleSilicon: true) != nil)
    }

    @Test func invalidDocumentsThrow() {
        #expect(throws: UpdatesCheckError.self) { try UpdatesAppcast.parse(Data("<rss><channel><item>".utf8)) }
        #expect(throws: UpdatesCheckError.self) { try UpdatesAppcast.parse(Data("<html><body>Not found</body></html>".utf8)) }
    }

    @Test func emptyFeedHasNoBestItem() throws {
        let items = try UpdatesAppcast.parse(Data("<rss version=\"2.0\"><channel><title>Empty</title></channel></rss>".utf8))
        #expect(items.isEmpty)
        #expect(UpdatesAppcast.bestItem(in: items) == nil)
    }

    @Test func rfc822DatesAreParsed() {
        #expect(UpdatesAppcast.parseDate("Mon, 06 Oct 2025 10:00:00 +0000") != nil)
        #expect(UpdatesAppcast.parseDate("Mon, 6 Oct 2025 10:00:00 +0000") != nil)
        #expect(UpdatesAppcast.parseDate("2025-10-06") != nil)
        #expect(UpdatesAppcast.parseDate("yesterday") == nil)
    }
}
