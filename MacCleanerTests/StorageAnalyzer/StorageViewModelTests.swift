import Foundation
import Testing
@testable import MacCleaner

/// App services whose history, log and settings stay in temporary locations.
@MainActor
enum StorageTestServices {
    static func make(supportDirectory: String) throws -> AppServices {
        try FileManager.default.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
        let support = URL(fileURLWithPath: supportDirectory, isDirectory: true)
        // A fresh suite that is only read: nothing is written unless a setting changes.
        let defaults = try #require(UserDefaults(suiteName: "StorageAnalyzerTests-\(UUID().uuidString)"))
        return AppServices(
            settings: SettingsManager(defaults: defaults),
            permissions: PermissionManager(),
            history: HistoryStore(directory: support),
            logger: ActivityLogger(directory: support)
        )
    }

    /// Polls `condition` on the main actor for up to `seconds`.
    static func waitUntil(seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for a condition")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
@Suite("Storage view model", .serialized)
struct StorageViewModelTests {
    @Test func scansListsSearchesFiltersAndNavigates() async throws {
        let root = try StorageFixture.makeTemporaryDirectory("StorageViewModel")
        let support = root + "-support"
        defer {
            StorageFixture.remove(root)
            StorageFixture.remove(support)
        }
        try StorageFixture.writeFile(root + "/Movies/holiday.mov", bytes: 2_000_000)
        try StorageFixture.writeFile(root + "/Movies/old.mov", bytes: 1_500_000)
        StorageFixture.setDates(root + "/Movies/old.mov", daysAgo: 800)
        try StorageFixture.writeFile(root + "/Docs/report.pdf", bytes: 1_200_000)
        try StorageFixture.writeFile(root + "/.hidden/secret.mov", bytes: 1_300_000)
        StorageFixture.setDates(root + "/.hidden/secret.mov", daysAgo: 800)

        let model = StorageAnalyzerViewModel(services: try StorageTestServices.make(supportDirectory: support))
        model.scanFolder(root)
        #expect(model.phase == .scanning)
        try await StorageTestServices.waitUntil { model.phase == .ready }

        let tree = try #require(model.tree)
        #expect(model.source?.scanPath == root)
        #expect(model.currentNode === tree.root)
        #expect(model.contentsRows.first?.name == "Movies")
        #expect(model.largestRows.isEmpty, "Nothing reaches the default 500 MB threshold")
        // Hidden items are measured, but not listed while "include hidden files" is off.
        #expect(model.oldRows.map(\.name) == ["old.mov"])
        #expect(tree.node(atPath: root + "/.hidden/secret.mov") != nil)

        model.searchText = "holi"
        #expect(model.listTab == .results)
        try await StorageTestServices.waitUntil { !model.isSearching }
        #expect(model.resultRows.map(\.name) == ["holiday.mov"])
        model.searchText = ""
        #expect(model.listTab == .contents)

        var filter = StorageFilter()
        filter.category = .videos
        model.filter = filter
        try await StorageTestServices.waitUntil { !model.isSearching }
        #expect(Set(model.resultRows.map(\.name)) == ["holiday.mov", "old.mov"])
        filter.olderThanDays = 365
        model.filter = filter
        try await StorageTestServices.waitUntil { !model.isSearching }
        #expect(model.resultRows.map(\.name) == ["old.mov"])
        model.clearSearchAndFilters()
        #expect(!model.isFiltering)

        let movies = try #require(tree.node(atPath: root + "/Movies"))
        model.open(movies)
        #expect(model.breadcrumb.map(\.name) == [tree.root.name, "Movies"])
        #expect(Set(model.contentsRows.map(\.name)) == ["holiday.mov", "old.mov"])
        #expect(model.canGoUp)
        model.goUp()
        #expect(model.currentNode === tree.root)
        #expect(!model.canGoUp)

        // Selecting from the chart resolves to actionable nodes; the root can't be trashed.
        let holiday = try #require(tree.node(atPath: root + "/Movies/holiday.mov"))
        model.select(holiday)
        #expect(model.selectedNodes.map(\.name) == ["holiday.mov"])
        #expect(model.selectedBytes == holiday.size)
        #expect(model.trashProblem(for: tree.root) != nil)
        #expect(model.canQuickLook(holiday))
    }

    @Test func aMissingFolderFailsWithAnExplanation() async throws {
        let support = try StorageFixture.makeTemporaryDirectory("StorageViewModelSupport")
        defer { StorageFixture.remove(support) }
        let model = StorageAnalyzerViewModel(services: try StorageTestServices.make(supportDirectory: support))
        model.scan(.folder(path: support + "/does-not-exist"))
        try await StorageTestServices.waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        #expect(model.tree == nil)
    }
}
