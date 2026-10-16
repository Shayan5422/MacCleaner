import Foundation

/// Asks GitHub for Mac Cleaner's latest release.
///
/// One GET to the "latest release" endpoint, with nothing that identifies the Mac or
/// the person: an ephemeral session, no cookies, and `User-Agent: MacCleaner/<version>`.
/// Drafts, prereleases and releases whose tag isn't a plain version are never offered.
struct AppUpdateChecker: Sendable {
    static let endpoint = URL(string: "https://api.github.com/repos/Shayan5422/MacCleaner/releases/latest")!
    static let timeout: TimeInterval = 10
    /// Release JSON is a few kilobytes; anything far larger isn't what was asked for.
    static let maxResponseBytes = 2_000_000
    /// Asset names: `Mac-Cleaner-<version>.dmg`, `.zip` and `.sha256`.
    static let assetPrefix = "Mac-Cleaner-"

    var currentVersion: String
    var transport: AppUpdateTransport

    init(currentVersion: String = AppInfo.version, transport: AppUpdateTransport = .live) {
        self.currentVersion = currentVersion
        self.transport = transport
    }

    static func userAgent(version: String) -> String {
        "MacCleaner/\(version)"
    }

    /// The GET request: GitHub's JSON media type, the app's User-Agent, no cookies, no cache, 10 s.
    static func request(currentVersion: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent(version: currentVersion), forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Fetches and evaluates the latest release. Never throws: failures come back as `.failed`.
    func check() async -> AppUpdateCheckResult {
        do {
            let (data, response) = try await transport.fetch(Self.request(currentVersion: currentVersion), Self.maxResponseBytes)
            return Self.evaluate(status: response.statusCode, data: data, currentVersion: currentVersion,
                                 rateLimitRemaining: response.value(forHTTPHeaderField: "x-ratelimit-remaining"))
        } catch is CancellationError {
            return .failed("The check was cancelled.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Turns an HTTP status and body into a result.
    static func evaluate(status: Int, data: Data, currentVersion: String, rateLimitRemaining: String? = nil) -> AppUpdateCheckResult {
        switch status {
        case 200:
            guard data.count <= maxResponseBytes, let release = parseLatestRelease(data) else {
                // Drafts, prereleases and malformed tags are never offered.
                return .upToDate(latest: nil)
            }
            return AppVersion.isNewer(release.version, than: currentVersion)
                ? .updateAvailable(release) : .upToDate(latest: release.version)
        case 404:
            return .noReleases
        case 403, 429:
            if status == 403, rateLimitRemaining != nil, rateLimitRemaining != "0" {
                return .failed("GitHub refused the request (HTTP 403).")
            }
            return .failed("GitHub's limit for update checks was reached. Try again in an hour.")
        case 500...599:
            return .failed("GitHub isn't responding right now. Try again later.")
        default:
            return .failed("GitHub answered unexpectedly (HTTP \(status)).")
        }
    }

    /// Parses GitHub's release JSON. nil for drafts, prereleases, malformed tags or a missing release page.
    static func parseLatestRelease(_ data: Data) -> AppRelease? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = AppVersion.normalized(release.tagName),
              let pageURL = safeURL(release.htmlURL) else { return nil }
        let assets = (release.assets ?? []).compactMap { asset -> AppReleaseAsset? in
            guard let name = asset.name, let url = safeURL(asset.browserDownloadURL) else { return nil }
            return AppReleaseAsset(name: name, url: url, size: asset.size, digest: sha256Digest(asset.digest))
        }
        return AppRelease(
            version: version,
            tagName: release.tagName,
            name: release.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
            notes: release.body.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            pageURL: pageURL,
            publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            diskImage: asset(in: assets, version: version, fileExtension: "dmg"),
            archive: asset(in: assets, version: version, fileExtension: "zip"),
            checksums: asset(in: assets, version: version, fileExtension: "sha256")
        )
    }

    /// `Mac-Cleaner-<version>.<ext>` whose version matches the release ("1.2" matches "1.2.0").
    static func asset(in assets: [AppReleaseAsset], version: String, fileExtension: String) -> AppReleaseAsset? {
        assets.first { asset in
            let name = asset.name
            let suffix = "." + fileExtension
            guard name.hasPrefix(assetPrefix), name.lowercased().hasSuffix(suffix) else { return false }
            let middle = String(name.dropFirst(assetPrefix.count).dropLast(suffix.count))
            return AppVersion.compare(middle, version) == .orderedSame
        }
    }

    /// "sha256:<64 hex>" → lowercase hex; nil for anything else.
    static func sha256Digest(_ text: String?) -> String? {
        guard let text, text.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = String(text.dropFirst("sha256:".count)).lowercased()
        return AppUpdateChecksums.isSHA256(hex) ? hex : nil
    }

    /// Only https links are used from a response.
    static func safeURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// The fields of https://docs.github.com/rest/releases/releases#get-the-latest-release that are used.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String?
        let name: String?
        let body: String?
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String?
            let browserDownloadURL: String?
            let size: Int64?
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name, body, draft, prerelease, assets
            case publishedAt = "published_at"
        }
    }
}
