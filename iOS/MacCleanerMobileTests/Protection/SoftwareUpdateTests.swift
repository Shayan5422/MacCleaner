import Foundation
import Testing
@testable import MacCleanerMobile

/// Apple's catalog, shortened: the "iOS" sets also hold watchOS, tvOS and HomePod releases, and a
/// version can appear once per build.
private let catalog = """
{
  "PublicAssetSets": {
    "iOS": [
      {"ProductVersion": "27.0.1", "Build": "24A446", "PostingDate": "2026-10-12", "ExpirationDate": "2027-01-15",
       "SupportedDevices": ["iPad16,3", "iPhone17,1", "iPhone18,3"]},
      {"ProductVersion": "27.0.1", "Build": "24A6446", "PostingDate": "2026-10-08", "ExpirationDate": "2027-01-15",
       "SupportedDevices": ["iPhone18,3"]},
      {"ProductVersion": "26.7.1", "Build": "23H30", "PostingDate": "2026-10-08", "SupportedDevices": ["iPhone12,1", "iPhone17,1", "iPhone18,3"]},
      {"ProductVersion": "9.6.4", "Build": "20U512", "PostingDate": "2026-09-28", "SupportedDevices": ["Watch4,1"]},
      {"ProductVersion": "27.1", "Build": "24A94425", "PostingDate": "2026-10-12", "SupportedDevices": ["iPhone19,4"]},
      {"Build": "no version", "SupportedDevices": ["iPhone18,3"]}
    ],
    "macOS": [{"ProductVersion": "27.0", "SupportedDevices": ["J414cAP"]}]
  },
  "AssetSets": {
    "iOS": [
      {"ProductVersion": "27.0", "Build": "24A437", "PostingDate": "2026-09-14", "SupportedDevices": ["iPhone18,3"]},
      {"ProductVersion": "26.6.2", "PostingDate": "2026-09-08", "SupportedDevices": ["iPhone12,1", "iPhone18,3"]},
      {"ProductVersion": "27.0.10", "PostingDate": "2026-12-01", "SupportedDevices": ["iPhone17,1"]}
    ]
  },
  "PublicBackgroundSecurityImprovements": {
    "iOS": [{"ProductVersion": "26.3.1", "ProductVersionExtra": "(a)", "SupportedDevices": ["iPhone18,3"]}]
  }
}
"""

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func version(_ text: String) -> SystemVersion { SystemVersion(text)! }

struct SoftwareCatalogTests {
    private let data = Data(catalog.utf8)

    @Test func readsOneModelsReleasesNewestFirst() throws {
        let releases = try SoftwareCatalog.releases(in: data, model: "iPhone18,3")
        #expect(releases.map(\.version.description) == ["27.0.1", "27.0", "26.7.1", "26.6.2"])
    }

    @Test func keepsTheFirstPostingDateOfAVersion() throws {
        let releases = try SoftwareCatalog.releases(in: data, model: "iPhone18,3")
        #expect(releases.first?.postingDate == day(2026, 10, 8))
    }

    @Test func picksTheNewestVersionAcrossBothSets() throws {
        let releases = try SoftwareCatalog.releases(in: data, model: "iPhone17,1")
        #expect(releases.first?.version == version("27.0.10"))
        #expect(releases.map(\.version.description) == ["27.0.10", "27.0.1", "26.7.1"])
    }

    @Test func otherModelsAndPlatformsDontMix() throws {
        #expect(try SoftwareCatalog.releases(in: data, model: "iPhone19,4").map(\.version.description) == ["27.1"])
        #expect(try SoftwareCatalog.releases(in: data, model: "iPhone99,1").isEmpty)
        #expect(try SoftwareCatalog.releases(in: data, model: "J414cAP").isEmpty)
    }

    @Test func modelNamesMatchWithoutCase() throws {
        #expect(try SoftwareCatalog.releases(in: data, model: "IPHONE18,3").count == 4)
    }

    @Test func unreadableCatalogsThrow() {
        #expect(throws: ThreatFeedError.self) { try SoftwareCatalog.releases(in: Data("<html>".utf8), model: "iPhone18,3") }
        #expect(throws: ThreatFeedError.self) { try SoftwareCatalog.releases(in: Data(#"{"other": []}"#.utf8), model: "iPhone18,3") }
    }
}

struct SystemVersionTests {
    @Test func comparesEachNumber() {
        #expect(version("27.0.10") > version("27.0.9"))
        #expect(version("27.1") > version("27.0.9"))
        #expect(version("26.7.1") < version("27.0"))
        #expect(version("10.0") > version("9.9.9"))
        #expect(!(version("27.0.1") < version("27.0.1")))
    }

    @Test func missingPartsCountAsZero() {
        #expect(version("27.0") == version("27.0.0"))
        #expect(version("27") == version("27.0"))
        #expect(Set([version("27.0"), version("27.0.0"), version("27")]).count == 1)
        #expect(SystemVersion([27, 0, 0]) == version("27"))
    }

    @Test func rejectsWhatIsntAVersion() {
        #expect(SystemVersion("27.0.1a") == nil)
        #expect(SystemVersion("") == nil)
        #expect(SystemVersion("27..1") == nil)
        #expect(SystemVersion("-1.0") == nil)
    }

    @Test func printsLikeSettings() {
        #expect(SystemVersion([27, 0, 0]).description == "27.0")
        #expect(version("27.0.1").description == "27.0.1")
        #expect(version("27").description == "27.0")
        #expect(version("27").major == 27)
    }
}

struct SoftwareUpdateStateTests {
    private let releases = try! SoftwareCatalog.releases(in: Data(catalog.utf8), model: "iPhone18,3")

    @Test func anOlderPatchNeedsTheUpdate() {
        #expect(SoftwareUpdateState.evaluate(running: version("27.0"), releases: releases)
            == .updateAvailable(version("27.0.1"), postingDate: day(2026, 10, 8)))
    }

    @Test func theNewestVersionIsUpToDate() {
        #expect(SoftwareUpdateState.evaluate(running: version("27.0.1"), releases: releases) == .upToDate(newerMajorRelease: nil))
    }

    @Test func thePreviousMajorIsUpToDateWhileAppleStillPatchesIt() {
        // Like Settings: iOS 26.7.1 is up to date, with iOS 27 also available.
        #expect(SoftwareUpdateState.evaluate(running: version("26.7.1"), releases: releases)
            == .upToDate(newerMajorRelease: version("27.0.1")))
    }

    @Test func anOldPatchOfThePreviousMajorNeedsItsLatestPatch() {
        #expect(SoftwareUpdateState.evaluate(running: version("26.6"), releases: releases)
            == .updateAvailable(version("26.7.1"), postingDate: day(2026, 10, 8)))
    }

    @Test func aMajorAppleNoLongerPatchesNeedsTheNewestVersion() {
        #expect(SoftwareUpdateState.evaluate(running: version("25.4.1"), releases: releases)
            == .updateAvailable(version("27.0.1"), postingDate: day(2026, 10, 8)))
    }

    @Test func aBetaNewerThanTheCatalogIsUpToDate() {
        #expect(SoftwareUpdateState.evaluate(running: version("27.1"), releases: releases) == .upToDate(newerMajorRelease: nil))
    }

    @Test func noReleasesMeansTheModelIsUnknown() {
        #expect(SoftwareUpdateState.evaluate(running: version("27.0"), releases: []) == .couldNotCheck(.unknownModel))
        #expect(SoftwareUpdateState.couldNotCheck(.offline).isUpToDate == nil)
    }

    @Test func theCacheLastsTwelveHoursForTheSameModel() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = SoftwareCatalogCache(fetchedAt: fetched, model: "iPhone18,3", releases: releases)
        #expect(cache.isFresh(for: "iPhone18,3", at: fetched.addingTimeInterval(11 * 3600)))
        #expect(!cache.isFresh(for: "iPhone18,3", at: fetched.addingTimeInterval(12 * 3600)))
        #expect(!cache.isFresh(for: "iPhone17,1", at: fetched.addingTimeInterval(60)))
        #expect(!cache.isFresh(for: "iPhone18,3", at: fetched.addingTimeInterval(-60)))
    }

    @Test func theCacheSurvivesEncoding() throws {
        let cache = SoftwareCatalogCache(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "iPhone18,3", releases: releases)
        let decoded = try JSONDecoder().decode(SoftwareCatalogCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded == cache)
    }
}
