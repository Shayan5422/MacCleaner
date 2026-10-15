import Foundation
import Testing
@testable import MacCleaner

struct UpdatesAppStoreLookupTests {
    /// Shape of an answer from https://itunes.apple.com/lookup (trimmed).
    private static let response = """
    {
      "resultCount": 2,
      "results": [
        {
          "kind": "mac-software",
          "trackId": 409183694,
          "trackName": "Keynote",
          "bundleId": "com.apple.iWork.Keynote",
          "version": "14.4",
          "currentVersionReleaseDate": "2025-03-27T15:51:25Z",
          "releaseNotes": "This update contains stability improvements.",
          "minimumOsVersion": "14.0",
          "trackViewUrl": "https://apps.apple.com/us/app/keynote/id409183694?mt=12&uo=4",
          "fileSizeBytes": "529412096",
          "price": 0.00
        },
        {
          "kind": "software",
          "trackId": 6776410855,
          "trackName": "Welna",
          "bundleId": "life.openmed.welna",
          "version": "2.6",
          "minimumOsVersion": "17.0",
          "trackViewUrl": "https://apps.apple.com/fr/app/welna/id6776410855?uo=4"
        }
      ]
    }
    """

    @Test func parsesLookupResults() throws {
        let records = try UpdatesAppStoreLookup.parse(Data(Self.response.utf8))
        #expect(records.count == 2)
        let keynote = try #require(records.first)
        #expect(keynote.trackID == 409183694)
        #expect(keynote.bundleIdentifier == "com.apple.iWork.Keynote")
        #expect(keynote.version == "14.4")
        #expect(keynote.minimumOSVersion == "14.0")
        #expect(keynote.releaseNotes == "This update contains stability improvements.")
        #expect(keynote.releaseDate != nil)
        #expect(keynote.kind == "mac-software")
        #expect(keynote.storeURL == URL(string: "macappstore://apps.apple.com/app/id409183694"))
        #expect(records[1].kind == "software")
    }

    @Test func emptyResultsAreHandled() throws {
        let records = try UpdatesAppStoreLookup.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8))
        #expect(records.isEmpty)
    }

    @Test func invalidAnswersThrow() {
        #expect(throws: UpdatesCheckError.self) { try UpdatesAppStoreLookup.parse(Data("<html>Error</html>".utf8)) }
    }

    @Test func evaluationComparesWithTheInstalledVersion() throws {
        let keynote = try #require(try UpdatesAppStoreLookup.parse(Data(Self.response.utf8)).first)
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)

        #expect(UpdatesAppStoreLookup.evaluate(record: keynote, installedVersion: "14.3", isMacApp: true, systemVersion: sonoma).status == .updateAvailable)
        #expect(UpdatesAppStoreLookup.evaluate(record: keynote, installedVersion: "14.4", isMacApp: true, systemVersion: sonoma).status == .upToDate)
        #expect(UpdatesAppStoreLookup.evaluate(record: keynote, installedVersion: "14.5", isMacApp: true, systemVersion: sonoma).status == .upToDate)
        #expect(UpdatesAppStoreLookup.evaluate(record: keynote, installedVersion: "14.3", isMacApp: true, systemVersion: ventura).status == .incompatible)
        #expect(UpdatesAppStoreLookup.evaluate(record: keynote, installedVersion: nil, isMacApp: true, systemVersion: sonoma).status == .unknown)

        // An iPhone/iPad listing's minimum OS is an iOS version and doesn't block the Mac.
        let welna = try #require(try UpdatesAppStoreLookup.parse(Data(Self.response.utf8)).last)
        #expect(UpdatesAppStoreLookup.evaluate(record: welna, installedVersion: "2.5", isMacApp: false, systemVersion: ventura).status == .updateAvailable)
    }

    @Test func lookupURLs() throws {
        let byID = try #require(UpdatesAppStoreLookup.lookupURL(trackIDs: [409183694, 747648890], country: "FR"))
        let idComponents = try #require(URLComponents(url: byID, resolvingAgainstBaseURL: false))
        #expect(byID.scheme == "https")
        #expect(idComponents.host == "itunes.apple.com")
        #expect(idComponents.path == "/lookup")
        #expect(idComponents.queryItems?.first { $0.name == "id" }?.value == "409183694,747648890")
        #expect(idComponents.queryItems?.first { $0.name == "country" }?.value == "fr")

        let byBundle = try #require(UpdatesAppStoreLookup.lookupURL(bundleIdentifier: "com.example.app", country: nil))
        let bundleComponents = try #require(URLComponents(url: byBundle, resolvingAgainstBaseURL: false))
        #expect(bundleComponents.queryItems?.first { $0.name == "bundleId" }?.value == "com.example.app")
        #expect(bundleComponents.queryItems?.first { $0.name == "entity" }?.value == "desktopSoftware")
        #expect(bundleComponents.queryItems?.contains { $0.name == "country" } == false)

        #expect(UpdatesAppStoreLookup.lookupURL(trackIDs: [], country: "us") == nil)
        #expect(UpdatesAppStoreLookup.sanitizedCountry("usa") == nil)
        #expect(UpdatesAppStoreLookup.sanitizedCountry("1a") == nil)
        #expect(UpdatesAppStoreLookup.sanitizedCountry("DE") == "de")
    }
}
