import Foundation

/// HTTPS-only client for update checks: no cookies, no cache, short timeouts,
/// bounded response size, and redirects that would leave HTTPS are refused.
final class UpdatesHTTPClient: Sendable {
    static let shared = UpdatesHTTPClient()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        configuration.httpAdditionalHeaders = ["User-Agent": "Mac Cleaner/\(version) (update check)"]
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL, accept: String, maxBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw UpdatesCheckError.insecureURL }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: UpdatesHTTPSOnlyRedirects.shared)
            guard let http = response as? HTTPURLResponse else {
                throw UpdatesCheckError.underlying("The server's response wasn't understood.")
            }
            switch http.statusCode {
            case 200..<300: break
            case 403, 429: throw UpdatesCheckError.rateLimited
            default: throw UpdatesCheckError.httpStatus(http.statusCode)
            }
            if http.expectedContentLength > Int64(maxBytes) { throw UpdatesCheckError.tooLarge }
            var data = Data()
            data.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(maxBytes))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw UpdatesCheckError.tooLarge }
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UpdatesCheckError.wrap(error)
        }
    }
}

/// Refuses redirects that leave HTTPS.
private final class UpdatesHTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = UpdatesHTTPSOnlyRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}

/// An App Store app to look up.
struct UpdatesAppStoreTarget: Sendable, Hashable {
    var path: String
    var trackID: Int?
    var bundleIdentifier: String?
    var installedVersion: String?
    /// iPhone and iPad apps installed on a Mac with Apple silicon are listed under iOS.
    var isMacApp: Bool
    /// App Store region recorded in the app's metadata, if any.
    var storefront: String?
}

/// Runs the supported update checks. Every result says where it came from; apps
/// without a reliable source get "unknown", never a guess.
struct UpdatesChecker: Sendable {
    var client: UpdatesHTTPClient = .shared
    /// Bundle-identifier lookups are slower and rate limited; IDs are preferred.
    var maximumBundleLookups = 15

    // MARK: Sparkle

    func checkSparkle(feed: URL, installedBuild: String?, installedVersion: String?, now: Date = Date()) async -> UpdatesCheckResult {
        let installedLabel = installedVersion ?? installedBuild ?? "—"
        var result = UpdatesCheckResult(status: .unknown, source: .sparkle, detail: "", checkedAt: now, installedVersionAtCheck: installedLabel)
        do {
            let data = try await client.fetch(feed, accept: "application/rss+xml, application/xml, text/xml, */*", maxBytes: 8 * 1024 * 1024)
            let items = try UpdatesAppcast.parse(data)
            let evaluation = UpdatesAppcast.evaluate(items: items, installedBuild: installedBuild, installedVersion: installedVersion)
            guard let best = evaluation.best ?? evaluation.newerIncompatible else {
                result.detail = "The developer's update feed doesn't list any update for this Mac."
                return result
            }
            result.status = evaluation.status
            result.releaseNotesURL = [best.releaseNotesURL, best.fullReleaseNotesURL, best.infoURL]
                .compactMap { $0 }.first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
            result.releaseDate = best.publicationDate
            result.isCritical = best.isCritical
            result.releaseNotesHTML = best.descriptionHTML
            switch evaluation.status {
            case .updateAvailable:
                result.latestVersion = best.displayVersion
                var detail = "Version \(best.displayVersion) is available from the developer."
                if best.isInformational { detail += " It's announced for download from the developer's website." }
                if let interval = best.phasedRolloutInterval, let date = best.publicationDate,
                   now.timeIntervalSince(date) < interval * 7 {
                    detail += " It's being released gradually, so the app may not offer it to you yet."
                }
                result.detail = detail
            case .incompatible:
                let newer = evaluation.newerIncompatible
                result.latestVersion = newer?.displayVersion
                if let minimum = newer?.minimumSystemVersion {
                    result.minimumSystemVersion = minimum
                    result.detail = "Version \(newer?.displayVersion ?? "") requires macOS \(minimum) or later."
                } else {
                    result.detail = "Version \(newer?.displayVersion ?? "") isn't compatible with this Mac."
                }
            default:
                result.latestVersion = evaluation.best?.displayVersion
                result.detail = "You have the latest version in the developer's update feed."
                if let newer = evaluation.newerIncompatible, let minimum = newer.minimumSystemVersion {
                    result.detail += " Version \(newer.displayVersion) needs macOS \(minimum) or later."
                }
            }
        } catch is CancellationError {
            result.status = .notChecked
            result.detail = "The check was cancelled."
        } catch {
            result.status = .failed
            result.detail = UpdatesCheckError.wrap(error).localizedDescription
        }
        return result
    }

    // MARK: App Store

    /// Looks up App Store apps in batches. Apps not found in any region get "unknown".
    func checkAppStore(_ targets: [UpdatesAppStoreTarget], now: Date = Date()) async -> [String: UpdatesCheckResult] {
        guard !targets.isEmpty else { return [:] }
        var records: [String: UpdatesAppStoreRecord] = [:] // by path
        var pending = targets
        var failure: UpdatesCheckError?
        var bundleLookups = 0

        // The person's region first, then regions recorded by installed apps, then the default (US) store.
        var countries: [String?] = [UpdatesAppStoreLookup.currentCountryCode()]
        for storefront in Set(targets.compactMap { UpdatesAppStoreLookup.sanitizedCountry($0.storefront) }).sorted() where !countries.contains(storefront) {
            countries.append(storefront)
        }
        if !countries.contains(where: { $0 == nil }) { countries.append(nil) }

        countryLoop: for country in countries {
            if pending.isEmpty || Task.isCancelled { break }
            // Batched lookups by App Store ID.
            let withID = pending.filter { $0.trackID != nil }
            for chunk in stride(from: 0, to: withID.count, by: UpdatesAppStoreLookup.batchSize).map({ Array(withID[$0..<min($0 + UpdatesAppStoreLookup.batchSize, withID.count)]) }) {
                guard let url = UpdatesAppStoreLookup.lookupURL(trackIDs: chunk.compactMap(\.trackID), country: country) else { continue }
                do {
                    let found = try UpdatesAppStoreLookup.parse(try await client.fetch(url, accept: "application/json", maxBytes: 4 * 1024 * 1024))
                    let byID = Dictionary(found.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
                    for target in chunk {
                        if let id = target.trackID, let record = byID[id] { records[target.path] = record }
                    }
                } catch is CancellationError {
                    break countryLoop
                } catch {
                    failure = UpdatesCheckError.wrap(error)
                    if case .rateLimited = failure { break countryLoop }
                }
            }
            pending.removeAll { records[$0.path] != nil }

            // Bundle identifier lookups for Mac apps without a known ID.
            for target in pending where target.trackID == nil && target.isMacApp {
                guard let bundleID = target.bundleIdentifier, bundleLookups < maximumBundleLookups,
                      let url = UpdatesAppStoreLookup.lookupURL(bundleIdentifier: bundleID, country: country) else { continue }
                bundleLookups += 1
                do {
                    let found = try UpdatesAppStoreLookup.parse(try await client.fetch(url, accept: "application/json", maxBytes: 2 * 1024 * 1024))
                    if let record = found.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                        records[target.path] = record
                    }
                } catch is CancellationError {
                    break countryLoop
                } catch {
                    failure = UpdatesCheckError.wrap(error)
                    if case .rateLimited = failure { break countryLoop }
                }
            }
            pending.removeAll { records[$0.path] != nil }
        }

        var results: [String: UpdatesCheckResult] = [:]
        for target in targets {
            let installed = target.installedVersion ?? "—"
            var result = UpdatesCheckResult(status: .unknown, source: .appStore, detail: "", checkedAt: now, installedVersionAtCheck: installed)
            if let record = records[target.path] {
                let evaluation = UpdatesAppStoreLookup.evaluate(record: record, installedVersion: target.installedVersion, isMacApp: target.isMacApp)
                result.status = evaluation.status
                result.detail = evaluation.detail
                result.latestVersion = record.version
                result.storeURL = record.storeURL
                result.releaseNotesText = record.releaseNotes
                result.releaseDate = record.releaseDate
                if target.isMacApp { result.minimumSystemVersion = record.minimumOSVersion }
            } else if Task.isCancelled {
                result.status = .notChecked
                result.detail = "The check was cancelled."
            } else if let failure {
                result.status = .failed
                result.detail = failure.localizedDescription
            } else if target.trackID == nil && bundleLookups >= maximumBundleLookups {
                result.detail = "Not checked this time to stay within the App Store's request limits. Check again in a minute."
            } else {
                result.detail = "The app isn't listed in the App Store for your region, or it's no longer offered there."
            }
            results[target.path] = result
        }
        return results
    }

    // MARK: Homebrew

    struct HomebrewOutcome: Sendable {
        /// Results by app path.
        var results: [String: UpdatesCheckResult] = [:]
        var matchedCasks: [String: UpdatesHomebrewCask] = [:]
        /// Casks Homebrew lists as installed whose apps were removed or moved.
        var missingApps: [UpdatesHomebrewCask] = []
    }

    func checkHomebrew(brew: String, apps: [UninstallerApp], now: Date = Date()) async throws -> HomebrewOutcome {
        let casks = try await UpdatesHomebrew.installedCasks(brew: brew)
        let matched = UpdatesHomebrew.match(casks: casks, appPaths: apps.map(\.path))
        var outcome = HomebrewOutcome(matchedCasks: matched, missingApps: UpdatesHomebrew.casksWithMissingApps(casks, matched: matched))
        for app in apps {
            guard let cask = matched[app.path] else { continue }
            let evaluation = UpdatesHomebrew.evaluate(cask: cask, installedShortVersion: app.info.shortVersion, installedBuildVersion: app.info.buildVersion)
            var result = UpdatesCheckResult(status: evaluation.status, source: .homebrew, latestVersion: evaluation.latest, detail: evaluation.detail, checkedAt: now, installedVersionAtCheck: app.info.displayVersion)
            if evaluation.status == .updateAvailable { result.homebrewToken = cask.upgradeToken }
            result.releaseNotesURL = cask.homepage
            outcome.results[app.path] = result
        }
        return outcome
    }
}

/// Detects, from the bundle alone, how an app gets its updates.
enum UpdatesMechanismDetector {
    static func detect(_ app: UninstallerApp) -> UpdatesMechanism {
        let info = app.info
        if info.isAppStoreApp || app.isWrappediOSApp { return .appStore }
        if let feed = info.sparkleFeedURL {
            if feed.scheme?.lowercased() == "https" { return .sparkleFeed(feed) }
            return .sparkleInsecureFeed(feed.absoluteString)
        }
        let contents = info.path + "/Contents"
        let manager = FileManager.default
        if manager.fileExists(atPath: contents + "/Frameworks/Sparkle.framework") { return .sparkleInApp }
        if manager.fileExists(atPath: contents + "/Frameworks/Squirrel.framework") { return .squirrel }
        if manager.fileExists(atPath: contents + "/Resources/app-update.yml") { return .electronUpdater }
        let bundleID = info.bundleIdentifier?.lowercased() ?? ""
        if let plist = NSDictionary(contentsOfFile: contents + "/Info.plist") as? [String: Any],
           plist["KSProductID"] != nil || plist["KSUpdateURL"] != nil {
            return .googleSoftwareUpdate
        }
        if bundleID.hasPrefix("com.microsoft."),
           manager.fileExists(atPath: "/Library/Application Support/Microsoft/MAU2.0") {
            return .microsoftAutoUpdate
        }
        if bundleID.hasPrefix("com.adobe.") { return .adobeCreativeCloud }
        if bundleID.hasPrefix("com.jetbrains.") { return .jetBrains }
        if bundleID.hasPrefix("org.mozilla.") { return .mozilla }
        return .none
    }
}
