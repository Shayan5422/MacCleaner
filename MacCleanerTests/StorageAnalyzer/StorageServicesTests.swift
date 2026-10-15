import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Storage large & old files Smart Scan", .serialized)
struct StorageSmartScanTests {
    @Test func findsLargeAndOldFilesButNeverLibraryOrPackages() async throws {
        let home = try StorageFixture.makeTemporaryDirectory("StorageFakeHome")
        defer { StorageFixture.remove(home) }
        try StorageFixture.writeFile(home + "/Downloads/big.mov", bytes: 3_000_000)
        try StorageFixture.writeFile(home + "/Documents/old-report.pdf", bytes: 1_200_000)
        StorageFixture.setDates(home + "/Documents/old-report.pdf", daysAgo: 400)
        try StorageFixture.writeFile(home + "/Documents/recent.pdf", bytes: 1_200_000)
        try StorageFixture.writeFile(home + "/Library/Caches/huge.cache", bytes: 4_000_000)
        try StorageFixture.writeFile(home + "/Machines/VM.utm/Data/disk.img", bytes: 3_500_000)
        try StorageFixture.writeFile(home + "/Code/project/node_modules/dep/blob.bin", bytes: 3_200_000)
        try StorageFixture.writeFile(home + "/Box Sync/shared.bin", bytes: 3_100_000)

        var preferences = ScanPreferences()
        preferences.largeFileThresholdBytes = 2_000_000
        preferences.oldFileAgeDays = 180
        var provider = LargeFilesSmartScanProvider(home: home, policy: SafetyPolicy(home: home))
        provider.oldFileMinimumBytes = 1_000_000
        let contribution = try await provider.smartScan(context: SmartScanContext(preferences: preferences, reportProgress: { _, _ in }))

        let large = contribution.candidates.filter { $0.categoryID == LargeFilesSmartScanProvider.largeCategoryID }
        let old = contribution.candidates.filter { $0.categoryID == LargeFilesSmartScanProvider.oldCategoryID }
        #expect(large.map(\.title) == ["big.mov"])
        #expect(old.map(\.title) == ["old-report.pdf"])
        #expect(contribution.candidates.allSatisfy { $0.safety == .review && $0.purpose == .userFile && !$0.isSelectedByDefault })
        #expect(large.first?.detail?.hasPrefix("Video · ") == true)
        #expect(old.first?.detail?.hasPrefix("Document · ") == true)
        let paths = contribution.candidates.map(\.path)
        #expect(!paths.contains { $0.contains("/Library/") || $0.contains(".utm/") || $0.contains("node_modules") || $0.contains("Box Sync") })
        #expect(contribution.area == .largeFiles)
        #expect(contribution.summary?.contains("1 large file") == true)
    }
}

@Suite("Storage relocation", .serialized)
struct StorageRelocationTests {
    private func item(_ path: String) throws -> StorageRelocator.Item {
        let snapshot = try #require(FileSnapshot.capture(path: path))
        return StorageRelocator.Item(path: path, name: (path as NSString).lastPathComponent, snapshot: snapshot, estimatedBytes: 0)
    }

    @Test func destinationsAreValidated() throws {
        let home = try StorageFixture.makeTemporaryDirectory("StorageRelocationHome")
        defer { StorageFixture.remove(home) }
        try StorageFixture.makeDirectory(home + "/Archive")
        try StorageFixture.makeDirectory(home + "/.Trash/inside")
        #expect(StorageRelocator.destinationProblem(home + "/Archive", home: home) == nil)
        #expect(StorageRelocator.destinationProblem(home + "/missing", home: home) != nil)
        #expect(StorageRelocator.destinationProblem(home + "/.Trash/inside", home: home) != nil)
        #expect(StorageRelocator.destinationProblem("/usr", home: home) != nil)
    }

    @Test func checksRefuseUnsafeOrImpossibleMoves() throws {
        let home = try StorageFixture.makeTemporaryDirectory("StorageRelocationHome")
        defer { StorageFixture.remove(home) }
        let policy = SafetyPolicy(home: home)
        try StorageFixture.writeFile(home + "/Shoots/movie.mov", bytes: 10_000)
        try StorageFixture.writeFile(home + "/Shoots/sub/inner.txt", bytes: 100)
        try StorageFixture.writeFile(home + "/Archive/movie.mov", bytes: 10)
        try StorageFixture.writeFile(home + "/Library/Preferences/app.plist", bytes: 10)
        try StorageFixture.makeDirectory(home + "/Empty")

        let checks = StorageRelocator.check(
            items: [try item(home + "/Shoots/movie.mov"), try item(home + "/Shoots"), try item(home + "/Library/Preferences/app.plist")],
            destination: home + "/Archive", policy: policy
        )
        #expect(checks[0].problem?.contains("already exists") == true)
        #expect(checks[1].problem == nil)
        #expect(checks[1].mode == .move)
        #expect(checks[2].problem != nil, "SafetyPolicy doesn't allow user-file actions in ~/Library")

        // Protected top-level folders (here ~/Documents) are refused like any removal.
        try StorageFixture.makeDirectory(home + "/Documents")
        let protected = StorageRelocator.check(items: [try item(home + "/Documents")], destination: home + "/Archive", policy: policy)
        #expect(protected[0].problem != nil)

        let intoItself = StorageRelocator.check(items: [try item(home + "/Shoots")], destination: home + "/Shoots/sub", policy: policy)
        #expect(intoItself[0].problem?.contains("into itself") == true)
        let sameFolder = StorageRelocator.check(items: [try item(home + "/Shoots/movie.mov")], destination: home + "/Shoots", policy: policy)
        #expect(sameFolder[0].problem?.contains("already in this folder") == true)
    }

    @Test func sameVolumeMovesRenameWithoutOverwriting() throws {
        let home = try StorageFixture.makeTemporaryDirectory("StorageRelocationHome")
        defer { StorageFixture.remove(home) }
        try StorageFixture.writeFile(home + "/a/file.bin", bytes: 1_000)
        try StorageFixture.makeDirectory(home + "/b")
        let moving = try item(home + "/a/file.bin")
        let target = try StorageRelocator.moveOnSameVolume(moving, to: home + "/b")
        #expect(target == home + "/b/file.bin")
        #expect(FileManager.default.fileExists(atPath: target))
        #expect(!FileManager.default.fileExists(atPath: home + "/a/file.bin"))

        // A second item with the same name is refused instead of replacing the first.
        try StorageFixture.writeFile(home + "/a/file.bin", bytes: 2_000)
        #expect(throws: StorageRelocator.RelocationError.self) {
            try StorageRelocator.moveOnSameVolume(try item(home + "/a/file.bin"), to: home + "/b")
        }
        // A changed item is refused.
        let stale = StorageRelocator.Item(path: home + "/a/file.bin", name: "file.bin",
                                          snapshot: FileSnapshot(identity: FileIdentity(device: 0, inode: 1), type: .regular), estimatedBytes: 0)
        #expect(throws: StorageRelocator.RelocationError.self) {
            try StorageRelocator.moveOnSameVolume(stale, to: home + "/b")
        }
    }

    @Test func copiesAreVerifiedAgainstTheOriginal() throws {
        let home = try StorageFixture.makeTemporaryDirectory("StorageRelocationHome")
        defer { StorageFixture.remove(home) }
        try StorageFixture.writeFile(home + "/src/Folder/one.bin", bytes: 700_000)
        try StorageFixture.writeFile(home + "/src/Folder/nested/two.bin", bytes: 300_000)
        try StorageFixture.writeFile(home + "/src/Folder/.DS_Store", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: home + "/src/Folder/link", withDestinationPath: "one.bin")
        try StorageFixture.makeDirectory(home + "/dst")

        let flag = StorageCancellationFlag()
        let original = try StorageRelocator.inventory(of: home + "/src/Folder", cancellation: flag)
        #expect(original.regularFiles == 2)
        #expect(original.directories == 2)
        #expect(original.symbolicLinks == 1)
        #expect(original.dataBytes == 1_000_000)
        #expect(original.datalessFiles == 0)

        let progress = StorageCopyProgress()
        try StorageRelocator.copy(home + "/src/Folder", to: home + "/dst/Folder", progress: progress)
        let copy = try StorageRelocator.inventory(of: home + "/dst/Folder", cancellation: flag)
        #expect(copy == original)
        #expect(progress.bytesCopied >= 1_000_000)
        #expect(FileManager.default.contentsEqual(atPath: home + "/src/Folder/nested/two.bin", andPath: home + "/dst/Folder/nested/two.bin"))

        // copyfile never overwrites an existing destination.
        #expect(throws: (any Error).self) {
            try StorageRelocator.copy(home + "/src/Folder", to: home + "/dst/Folder", progress: StorageCopyProgress())
        }
    }
}

@Suite("Storage local snapshots")
struct StorageSnapshotTests {
    @Test func parsesTmutilOutput() throws {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2024-10-15-123456.local
        com.apple.os.update-5203530F8BB20B9DABC5CE76A0FFE87CCC885EE69B8A5488C24B458A7555E3AB
        com.example.custom-snapshot

        """
        let snapshots = StorageSnapshotReader.parse(output)
        #expect(snapshots.count == 3)
        #expect(snapshots[0].kind == .timeMachine)
        let date = try #require(snapshots[0].date)
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        #expect(components.year == 2024 && components.month == 10 && components.day == 15)
        #expect(components.hour == 12 && components.minute == 34 && components.second == 56)
        #expect(snapshots[1].kind == .systemUpdate)
        #expect(snapshots[2].kind == .other)
        #expect(StorageSnapshotReader.parse("Snapshots for disk /:\n").isEmpty)
    }
}
