import Foundation
import Testing
@testable import MacCleanerMobile

/// The model with fixture answers instead of the network.
@MainActor
struct ProtectionModelTests {
    private let storage = temporaryProtectionStorage()
    private let suite = "ProtectionModelTests-\(UUID().uuidString)"

    private static let catalog = """
    {"PublicAssetSets": {"iOS": [
       {"ProductVersion": "27.0.1", "PostingDate": "2026-10-08", "SupportedDevices": ["iPhone18,3"]},
       {"ProductVersion": "26.7.1", "PostingDate": "2026-10-08", "SupportedDevices": ["iPhone18,3"]}]},
     "AssetSets": {"iOS": []}}
    """

    private func model(_ transport: FixtureTransport, version: [Int]) throws -> ProtectionModel {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return ProtectionModel(storage: storage, transport: transport, defaults: defaults,
                               device: DeviceInfo(modelIdentifier: "iPhone18,3", systemVersion: version, isPad: false), allowsNetwork: true)
    }

    private func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: storage.directory.deletingLastPathComponent())
    }

    @Test func readsApplesCatalogAtMostEveryTwelveHours() async throws {
        defer { cleanUp() }
        var answers = FeedFixtures.answers()
        answers[SoftwareCatalog.url] = .init(status: 200, body: Self.catalog)
        let transport = FixtureTransport(answers)

        let first = try model(transport, version: [27, 0, 0])
        await first.refresh()
        #expect(first.systemUpToDate == false)
        #expect(first.availableSystemVersion == "27.0.1")
        #expect(first.softwareCheckedAt != nil)
        #expect(transport.requests(to: SoftwareCatalog.url).count == 1)

        // The next launch, after updating, reads the saved copy.
        let second = try model(transport, version: [27, 0, 1])
        await second.refresh()
        #expect(second.software == .upToDate(newerMajorRelease: nil))
        #expect(second.systemUpToDate == true)
        #expect(second.availableSystemVersion == nil)
        #expect(transport.requests(to: SoftwareCatalog.url).count == 1)
        // Safari protection isn't on, so no list was downloaded.
        #expect(transport.requests.count == 1)
    }

    @Test func offlineMeansTheVersionCouldntBeChecked() async throws {
        defer { cleanUp() }
        let protection = try model(FixtureTransport([:]), version: [27, 0, 0])
        await protection.refresh()
        #expect(protection.software == .couldNotCheck(.offline))
        #expect(protection.systemUpToDate == nil)
    }

    @Test func checkingALinkDownloadsTheMissingListsOnce() async throws {
        defer { cleanUp() }
        let transport = FixtureTransport(FeedFixtures.answers())
        let protection = try model(transport, version: [27, 0, 1])

        let listed = await protection.checkLink("https://cdn.malware-host.example.com/x")
        guard case .checked(_, .listed(let match)) = listed else {
            Issue.record("Expected a listed verdict, got \(listed)")
            return
        }
        #expect(match.scope == .host("malware-host.example.com"))
        #expect(transport.requests.count == 3)
        #expect(protection.feedState.blocklist?.siteCount == 3)

        let example = try #require(CheckedLink("example.com"))
        let router = try #require(CheckedLink("10.0.0.1"))
        #expect(await protection.checkLink("example.com") == .checked(example, .notListed))
        #expect(transport.requests.count == 3)
        #expect(await protection.checkLink("not a link") == .invalid)
        #expect(await protection.checkLink("10.0.0.1") == .checked(router, .localAddress))
    }

    @Test func aLinkCheckWithoutListsSaysWhy() async throws {
        defer { cleanUp() }
        let protection = try model(FixtureTransport([:]), version: [27, 0, 1])
        #expect(await protection.checkLink("example.com")
            == .listsUnavailable("No internet connection. The lists update when you're back online."))
    }
}
