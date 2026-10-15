import Foundation

/// An app's current listing in the App Store, from Apple's public lookup service.
struct UpdatesAppStoreRecord: Sendable, Hashable {
    var trackID: Int
    var bundleIdentifier: String?
    var name: String?
    var version: String?
    var releaseDate: Date?
    var releaseNotes: String?
    var minimumOSVersion: String?
    var webURL: URL?
    /// "mac-software" for Mac apps, "software" for iPhone and iPad apps.
    var kind: String?

    /// Opens the app's page in the App Store app.
    var storeURL: URL? { URL(string: "macappstore://apps.apple.com/app/id\(trackID)") }
}

/// Builds lookup requests for `https://itunes.apple.com/lookup` and parses the answers.
///
/// Apple documents this endpoint for the iTunes Search API. It returns only public
/// catalog data and needs no account; requests are rate limited (about 20 per minute),
/// so apps are looked up in batches by their App Store ID whenever it's known.
enum UpdatesAppStoreLookup {
    static let endpoint = "https://itunes.apple.com/lookup"
    static let batchSize = 50

    /// Looks up several apps by App Store ID (`kMDItemAppStoreAdamID` / iTunesMetadata `itemId`).
    static func lookupURL(trackIDs: [Int], country: String?) -> URL? {
        guard !trackIDs.isEmpty else { return nil }
        var components = URLComponents(string: endpoint)
        var items = [URLQueryItem(name: "id", value: trackIDs.map(String.init).joined(separator: ","))]
        if let country = sanitizedCountry(country) { items.append(URLQueryItem(name: "country", value: country)) }
        components?.queryItems = items
        return components?.url
    }

    /// Looks up a Mac app by bundle identifier when its App Store ID isn't known.
    static func lookupURL(bundleIdentifier: String, country: String?) -> URL? {
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "entity", value: "desktopSoftware"),
        ]
        if let country = sanitizedCountry(country) { items.append(URLQueryItem(name: "country", value: country)) }
        components?.queryItems = items
        return components?.url
    }

    /// The App Store region to ask. Prices and availability differ by region; versions don't.
    static func currentCountryCode() -> String? {
        sanitizedCountry(Locale.current.region?.identifier)
    }

    static func sanitizedCountry(_ code: String?) -> String? {
        guard let code = code?.lowercased(), code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    static func parse(_ data: Data) throws -> [UpdatesAppStoreRecord] {
        let response: LookupResponse
        do {
            response = try JSONDecoder().decode(LookupResponse.self, from: data)
        } catch {
            throw UpdatesCheckError.invalidFeed("the App Store's answer couldn't be read.")
        }
        return response.results.compactMap { result in
            guard let trackID = result.trackId else { return nil }
            return UpdatesAppStoreRecord(
                trackID: trackID,
                bundleIdentifier: result.bundleId,
                name: result.trackName,
                version: result.version?.trimmingCharacters(in: .whitespacesAndNewlines),
                releaseDate: result.currentVersionReleaseDate.flatMap(parseDate),
                releaseNotes: result.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
                minimumOSVersion: result.minimumOsVersion,
                webURL: result.trackViewUrl.flatMap(URL.init(string:)),
                kind: result.kind
            )
        }
    }

    /// Compares the installed app with its App Store listing.
    static func evaluate(record: UpdatesAppStoreRecord, installedVersion: String?, isMacApp: Bool, systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> (status: UpdatesStatus, detail: String) {
        guard let storeVersion = record.version, !storeVersion.isEmpty else {
            return (.unknown, "The App Store listing doesn't include a version number.")
        }
        guard let installedVersion, !installedVersion.isEmpty else {
            return (.unknown, "The installed app doesn't declare its version, so it can't be compared.")
        }
        guard UpdatesVersionComparator.isNewer(storeVersion, than: installedVersion) else {
            return (.upToDate, "You have the version currently offered in the App Store (\(storeVersion)).")
        }
        // The minimum OS of a Mac listing is a macOS version; iPhone/iPad listings name an iOS version.
        if isMacApp, let minimum = record.minimumOSVersion, !minimum.isEmpty {
            let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
            if UpdatesVersionComparator.compare(minimum, system) == .orderedDescending {
                return (.incompatible, "Version \(storeVersion) requires macOS \(minimum) or later.")
            }
        }
        return (.updateAvailable, "Version \(storeVersion) is available in the App Store.")
    }

    private static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private struct LookupResponse: Decodable {
        var resultCount: Int?
        var results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        var trackId: Int?
        var trackName: String?
        var bundleId: String?
        var version: String?
        var currentVersionReleaseDate: String?
        var releaseNotes: String?
        var minimumOsVersion: String?
        var trackViewUrl: String?
        var kind: String?
    }
}
