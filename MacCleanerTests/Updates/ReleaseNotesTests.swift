import Foundation
import Testing
@testable import MacCleaner

struct ReleaseNotesTests {
    @Test func readsGitHubMarkdown() {
        let notes = """
        The first public release of **Mac Cleaner** — a fast,
        honest cleaner.

        ![Mac Cleaner](https://raw.githubusercontent.com/Shayan5422/MacCleaner/main/docs/images/smart-scan.png)

        ## Highlights

        - **Smart Scan** — one scan.
          - nested detail
        * Uninstaller
        - [x] Done item

        1. Download the disk image.
        2) Open it.

        ---

        ```
        6b77…  Mac-Cleaner-1.0.0.dmg
        ```

        > Requires macOS 14.
        """
        let document = ReleaseNotesDocument.markdown(notes)
        #expect(document.blocks == [
            .paragraph("The first public release of **Mac Cleaner** — a fast, honest cleaner."),
            .heading("Highlights", level: 2),
            .bullet("**Smart Scan** — one scan.", depth: 0),
            .bullet("nested detail", depth: 1),
            .bullet("Uninstaller", depth: 0),
            .bullet("Done item", depth: 0),
            .numbered("Download the disk image.", number: "1"),
            .numbered("Open it.", number: "2"),
            .rule,
            .code("6b77…  Mac-Cleaner-1.0.0.dmg"),
            .paragraph("Requires macOS 14."),
        ])
    }

    @Test func readsSparkleHTML() {
        let html = """
        <html><head><title>Release</title><style>h2 { color: red }</style><script>alert(1)</script></head>
        <body>
          <h2>Version 2.1</h2>
          <p>Fixes &amp; improvements&nbsp;for <b>everyone</b>.<br>Second line.</p>
          <ul>
            <li>Faster <a href="https://example.com/docs">sync</a></li>
            <li>No more <a href="javascript:alert(1)">crashes</a></li>
          </ul>
          <!-- hidden comment -->
          <pre>brew upgrade
        --cask notely</pre>
        </body></html>
        """
        let document = ReleaseNotesDocument.html(html)
        #expect(document.blocks == [
            .heading("Version 2.1", level: 2),
            .paragraph("Fixes & improvements for **everyone**."),
            .paragraph("Second line."),
            .bullet("Faster [sync](https://example.com/docs)", depth: 0),
            .bullet("No more crashes", depth: 0),
            .code("brew upgrade\n--cask notely"),
        ])
        #expect(ReleaseNotesDocument.looksLikeHTML(html))
        #expect(!ReleaseNotesDocument.looksLikeHTML("## Heading\n- item"))
    }

    @Test func keepsAppStoreTextAsWritten() {
        let text = """
        What's new:
        • Fixed a crash when *dragging* files
        - Added [beta] support

        Thanks for using the app!
        """
        let document = ReleaseNotesDocument.plainText(text)
        #expect(document.blocks.count == 4)
        #expect(document.blocks[0] == .paragraph("What's new:"))
        if case .bullet(let item, _) = document.blocks[1] {
            #expect(String(ReleaseNotesDocument.attributed(item).characters) == "Fixed a crash when *dragging* files")
        } else {
            Issue.record("Expected a list item")
        }
        if case .bullet(let item, _) = document.blocks[2] {
            #expect(String(ReleaseNotesDocument.attributed(item).characters) == "Added [beta] support")
        } else {
            Issue.record("Expected a list item")
        }
    }

    @Test func onlyWebLinksStayClickable() {
        let web = ReleaseNotesDocument.attributed("See [the notes](https://example.com/notes).")
        #expect(web.runs.contains { $0.link == URL(string: "https://example.com/notes") })
        let local = ReleaseNotesDocument.attributed("Open [this](file:///etc/passwd) or [that](x-apple.systempreferences:com.apple.preference).")
        #expect(!local.runs.contains { $0.link != nil })
        #expect(String(local.characters) == "Open this or that.")
    }

    @Test func decodesEntities() {
        #expect(ReleaseNotesDocument.decodeEntities("Fish &amp; Chips &lt;3 &#8212; &#x2603; &quot;hi&quot;") == "Fish & Chips <3 — ☃ \"hi\"")
        #expect(ReleaseNotesDocument.decodeEntities("&amp;lt;") == "&lt;")
    }

    @Test func detectsTheFormat() {
        #expect(ReleaseNotesDocument.detect("<ul><li>One</li></ul>").blocks == [.bullet("One", depth: 0)])
        #expect(ReleaseNotesDocument.detect("- One").blocks == [.bullet("One", depth: 0)])
        #expect(ReleaseNotesDocument.detect("   \n\n  ").isEmpty)
    }
}

struct UpdatesAppcastDescriptionTests {
    @Test func keepsTheItemDescriptionAsReleaseNotes() throws {
        let feed = """
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <description>The channel's description isn't an item's.</description>
            <item>
              <title>Version 2.0</title>
              <description><![CDATA[<h2>New</h2><ul><li>Faster</li></ul>]]></description>
              <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0" length="1" type="application/octet-stream"/>
            </item>
          </channel>
        </rss>
        """
        let items = try UpdatesAppcast.parse(Data(feed.utf8))
        let item = try #require(items.first)
        #expect(item.descriptionHTML == "<h2>New</h2><ul><li>Faster</li></ul>")
        #expect(ReleaseNotesDocument.detect(item.descriptionHTML ?? "").blocks == [.heading("New", level: 2), .bullet("Faster", depth: 0)])
    }
}
