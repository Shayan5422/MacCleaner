import Foundation
import Testing
@testable import MacCleaner

/// A transport that answers from memory, so the checker never touches the network.
enum AppUpdateTestTransport {
    static func json(_ body: String, status: Int = 200, headers: [String: String] = [:], record: (@Sendable (URLRequest) -> Void)? = nil) -> AppUpdateTransport {
        AppUpdateTransport(
            fetch: { request, _ in
                record?(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (Data(body.utf8), response)
            },
            download: { _, _, _, _ in throw AppUpdateError.network("Downloads aren't used in this test.") }
        )
    }

    static func failing(_ error: Error) -> AppUpdateTransport {
        AppUpdateTransport(
            fetch: { _, _ in throw error },
            download: { _, _, _, _ in throw error }
        )
    }
}

/// The real v1.0.0 release, as GitHub's API returned it (shortened notes).
enum AppUpdateFixtures {
    static func releaseJSON(
        tag: String = "v1.0.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetVersion: String = "1.0.0",
        dmgDigest: String = "sha256:6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157",
        dmgURL: String? = nil
    ) -> String {
        let base = "https://github.com/Shayan5422/MacCleaner/releases/download/\(tag)"
        return """
        {
          "tag_name": "\(tag)",
          "name": "Mac Cleaner \(assetVersion)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-10-15T22:51:10Z",
          "html_url": "https://github.com/Shayan5422/MacCleaner/releases/tag/\(tag)",
          "body": "The first public release of **Mac Cleaner**.\\n\\n## Highlights\\n\\n- **Smart Scan** — one scan.\\n- **Uninstaller** — removes apps.",
          "assets": [
            {"name": "Mac-Cleaner-\(assetVersion).dmg", "size": 9346057, "browser_download_url": "\(dmgURL ?? "\(base)/Mac-Cleaner-\(assetVersion).dmg")", "digest": "\(dmgDigest)"},
            {"name": "Mac-Cleaner-\(assetVersion).sha256", "size": 176, "browser_download_url": "\(base)/Mac-Cleaner-\(assetVersion).sha256", "digest": "sha256:471f34590026f7c6215a7c838b92d201beb4c7e253819d040b8cccf6c50feab3"},
            {"name": "Mac-Cleaner-\(assetVersion).zip", "size": 9180433, "browser_download_url": "\(base)/Mac-Cleaner-\(assetVersion).zip"},
            {"name": "Source.tar.gz", "size": 10, "browser_download_url": "\(base)/Source.tar.gz"}
          ]
        }
        """
    }
}

struct AppVersionTests {
    @Test(arguments: [
        ("1.10.0", "1.9.9"), ("2.0", "1.99.99"), ("v1.2.1", "1.2"), ("1.0.0.1", "1.0.0"), ("10", "9.9"),
    ])
    func newerVersionsAreNewer(newer: String, older: String) {
        #expect(AppVersion.isNewer(newer, than: older))
        #expect(!AppVersion.isNewer(older, than: newer))
        #expect(AppVersion.compare(newer, older) == .orderedDescending)
    }

    @Test func missingComponentsCountAsZero() {
        #expect(AppVersion.compare("1.2", "1.2.0") == .orderedSame)
        #expect(AppVersion.compare("v1.0.0", "1") == .orderedSame)
        #expect(!AppVersion.isNewer("1.2.0", than: "1.2"))
    }

    @Test(arguments: ["", "1.2.0-beta", "latest", "1..2", "1.2.x", "v", "1.2.3.4.5", "1234567890.0", " 1. 2"])
    func malformedVersionsAreRejected(text: String) {
        #expect(AppVersion.components(text) == nil)
        #expect(AppVersion.compare(text, "1.0") == nil)
        #expect(!AppVersion.isNewer(text, than: "0.1"))
    }

    @Test func normalizesTags() {
        #expect(AppVersion.normalized("v1.10.0") == "1.10.0")
        #expect(AppVersion.normalized("V2.0") == "2.0")
        #expect(AppVersion.normalized(" 1.0.0\n") == "1.0.0")
        #expect(AppVersion.normalized("01.002.0") == "1.2.0")
    }
}

struct AppUpdateCheckerTests {
    @Test func parsesTheReleaseAndItsAssets() throws {
        let release = try #require(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON().utf8)))
        #expect(release.version == "1.0.0")
        #expect(release.tagName == "v1.0.0")
        #expect(release.name == "Mac Cleaner 1.0.0")
        #expect(release.pageURL.absoluteString == "https://github.com/Shayan5422/MacCleaner/releases/tag/v1.0.0")
        #expect(release.notes?.contains("## Highlights") == true)
        #expect(release.publishedAt == ISO8601DateFormatter().date(from: "2026-10-15T22:51:10Z"))
        #expect(release.diskImage?.name == "Mac-Cleaner-1.0.0.dmg")
        #expect(release.diskImage?.size == 9_346_057)
        #expect(release.diskImage?.digest == "6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157")
        #expect(release.checksums?.name == "Mac-Cleaner-1.0.0.sha256")
        #expect(release.archive?.name == "Mac-Cleaner-1.0.0.zip")
        #expect(release.canInstall)
    }

    @Test func draftsPrereleasesAndMalformedTagsAreNeverOffered() {
        #expect(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(draft: true).utf8)) == nil)
        #expect(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(prerelease: true).utf8)) == nil)
        #expect(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(tag: "v1.1.0-beta.1").utf8)) == nil)
        #expect(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(tag: "nightly").utf8)) == nil)
        #expect(AppUpdateChecker.parseLatestRelease(Data("not json".utf8)) == nil)
        #expect(AppUpdateChecker.parseLatestRelease(Data("{}".utf8)) == nil)
    }

    @Test func assetsMustMatchTheReleaseVersionAndUseHTTPS() throws {
        // Assets named for another version aren't this release's disk image.
        let mismatched = try #require(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(tag: "v1.1.0", assetVersion: "1.0.0").utf8)))
        #expect(mismatched.version == "1.1.0")
        #expect(mismatched.diskImage == nil)
        #expect(!mismatched.canInstall)

        // A short tag matches longer asset versions ("1.1" == "1.1.0").
        let short = try #require(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(tag: "v1.0", assetVersion: "1.0.0").utf8)))
        #expect(short.diskImage != nil)

        let insecure = try #require(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(dmgURL: "http://example.com/Mac-Cleaner-1.0.0.dmg").utf8)))
        #expect(insecure.diskImage == nil)

        let badDigest = try #require(AppUpdateChecker.parseLatestRelease(Data(AppUpdateFixtures.releaseJSON(dmgDigest: "md5:abc").utf8)))
        #expect(badDigest.diskImage?.digest == nil)
    }

    @Test func evaluatesResponses() {
        let body = Data(AppUpdateFixtures.releaseJSON().utf8)
        guard case .updateAvailable(let release) = AppUpdateChecker.evaluate(status: 200, data: body, currentVersion: "0.9.0") else {
            Issue.record("Expected an update")
            return
        }
        #expect(release.version == "1.0.0")
        #expect(AppUpdateChecker.evaluate(status: 200, data: body, currentVersion: "1.0.0") == .upToDate(latest: "1.0.0"))
        #expect(AppUpdateChecker.evaluate(status: 200, data: body, currentVersion: "1.2.0") == .upToDate(latest: "1.0.0"))
        #expect(AppUpdateChecker.evaluate(status: 200, data: Data(AppUpdateFixtures.releaseJSON(prerelease: true).utf8), currentVersion: "0.9") == .upToDate(latest: nil))
        #expect(AppUpdateChecker.evaluate(status: 404, data: Data(), currentVersion: "1.0.0") == .noReleases)
        if case .failed(let message) = AppUpdateChecker.evaluate(status: 403, data: Data(), currentVersion: "1.0.0", rateLimitRemaining: "0") {
            #expect(message.contains("limit"))
        } else {
            Issue.record("A rate-limited answer must fail")
        }
        if case .failed = AppUpdateChecker.evaluate(status: 503, data: Data(), currentVersion: "1.0.0") {} else {
            Issue.record("A server error must fail")
        }
        #expect(!AppUpdateCheckResult.failed("x").isConclusive)
        #expect(AppUpdateCheckResult.noReleases.isConclusive)
    }

    @Test func theRequestIdentifiesOnlyTheAppVersion() {
        let request = AppUpdateChecker.request(currentVersion: "1.0.0")
        #expect(request.url == URL(string: "https://api.github.com/repos/Shayan5422/MacCleaner/releases/latest"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MacCleaner/1.0.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.timeoutInterval == 10)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let configuration = AppUpdateTransport.configuration(timeout: 10)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.timeoutIntervalForRequest == 10)
    }

    @Test func checkUsesTheInjectedTransport() async {
        let seen = RequestRecorder()
        let checker = AppUpdateChecker(currentVersion: "0.9.0", transport: AppUpdateTestTransport.json(AppUpdateFixtures.releaseJSON()) { seen.add($0) })
        let result = await checker.check()
        guard case .updateAvailable(let release) = result else {
            Issue.record("Expected an update, got \(result)")
            return
        }
        #expect(release.version == "1.0.0")
        #expect(seen.requests.map(\.url) == [AppUpdateChecker.endpoint])

        let offline = AppUpdateChecker(currentVersion: "1.0.0", transport: AppUpdateTestTransport.failing(AppUpdateError.network("Your Mac appears to be offline.")))
        #expect(await offline.check() == .failed("Your Mac appears to be offline."))
    }

    @Test func liveTransportRefusesPlainHTTP() async {
        let request = URLRequest(url: URL(string: "http://api.github.com/repos/Shayan5422/MacCleaner/releases/latest")!)
        await #expect(throws: AppUpdateError.insecureURL) {
            _ = try await AppUpdateTransport.live.fetch(request, 1000)
        }
        await #expect(throws: AppUpdateError.insecureURL) {
            try await AppUpdateTransport.live.download(URL(string: "http://example.com/a.dmg")!, FileManager.default.temporaryDirectory.appendingPathComponent("never.dmg"), 10) { _, _ in }
        }
    }
}

/// Collects requests a test transport saw.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func add(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    var requests: [URLRequest] { lock.withLock { stored } }
}
