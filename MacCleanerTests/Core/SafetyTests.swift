import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Safety policy")
struct CoreSafetyPolicyTests {
    @Test func essentialFoldersAreNeverRemovable() throws {
        let home = try TemporaryTree("Home")
        try home.makeDirectory("Documents")
        try home.makeDirectory("Library/Caches")
        let policy = makePolicy(home: home.root)
        for purpose in DeletionPurpose.allCases {
            #expect(!policy.evaluate(path: "/", purpose: purpose).isAllowed)
            #expect(!policy.evaluate(path: home.root, purpose: purpose).isAllowed)
            #expect(!policy.evaluate(path: home.path("Documents"), purpose: purpose).isAllowed)
            #expect(!policy.evaluate(path: home.path("Library"), purpose: purpose).isAllowed)
            #expect(!policy.evaluate(path: home.path("Library/Caches"), purpose: purpose).isAllowed)
            #expect(!policy.evaluate(path: "/System/Library/CoreServices", purpose: purpose).isAllowed)
            #expect(!policy.evaluate(path: "/usr/bin/true", purpose: purpose).isAllowed)
        }
    }

    @Test func cachesAreJunkButDocumentsAreNot() throws {
        let home = try TemporaryTree("Home")
        let cache = try home.makeFile("Library/Caches/com.example.app/data.bin")
        let document = try home.makeFile("Documents/report.pages")
        let policy = makePolicy(home: home.root)
        #expect(policy.evaluate(path: cache, purpose: .junk).isAllowed)
        #expect(!policy.evaluate(path: document, purpose: .junk).isAllowed)
        #expect(policy.evaluate(path: document, purpose: .userFile).isAllowed)
        #expect(!policy.evaluate(path: cache, purpose: .userFile).isAllowed, "Library data isn't a personal file")
    }

    @Test func credentialsAndBookmarksAreProtected() throws {
        let home = try TemporaryTree("Home")
        let names = ["Login Data", "Bookmarks", "logins.json", "key4.db", "places.sqlite", "login.keychain-db"]
        let policy = makePolicy(home: home.root)
        for name in names {
            let file = try home.makeFile("Library/Application Support/Browser/Default/\(name)")
            for purpose in DeletionPurpose.allCases {
                #expect(!policy.evaluate(path: file, purpose: purpose).isAllowed, "\(name) must be protected for \(purpose)")
            }
        }
        let keychain = try home.makeFile("Library/Keychains/x.db")
        #expect(!policy.evaluate(path: keychain, purpose: .applicationData).isAllowed)
    }

    @Test func relativeComponentsAndSymlinkedParentsAreRejected() throws {
        let home = try TemporaryTree("Home")
        try home.makeFile("Library/Caches/real/file")
        symlink(home.path("Library/Caches/real"), home.path("Library/Caches/alias"))
        let policy = makePolicy(home: home.root)
        #expect(!policy.evaluate(path: home.path("Library/Caches/real/../real/file"), purpose: .junk).isAllowed)
        #expect(!policy.evaluate(path: home.path("Library/Caches/alias/file"), purpose: .junk).isAllowed)
        // The symlink itself may be removed (only the link, never its target).
        #expect(policy.evaluate(path: home.path("Library/Caches/alias"), purpose: .junk).isAllowed)
    }

    @Test func lockedItemsAreRejected() throws {
        let home = try TemporaryTree("Home")
        let file = try home.makeFile("Library/Caches/com.example/locked")
        chflags(file, UInt32(UF_IMMUTABLE))
        let verdict = makePolicy(home: home.root).evaluate(path: file, purpose: .junk)
        #expect(!verdict.isAllowed)
    }

    @Test func applicationsOnlyFromApplicationFolders() throws {
        let home = try TemporaryTree("Home")
        try home.makeDirectory("Applications/Tool.app/Contents")
        try home.makeDirectory("Documents/Other.app/Contents")
        let policy = makePolicy(home: home.root)
        #expect(policy.evaluate(path: home.path("Applications/Tool.app"), purpose: .application).isAllowed)
        #expect(!policy.evaluate(path: home.path("Documents/Other.app"), purpose: .application).isAllowed)
        #expect(!policy.evaluate(path: home.path("Applications/Tool.app/Contents"), purpose: .application).isAllowed)
    }

    @Test func personalFilesNeverAllowPermanentDeletion() {
        #expect(!DeletionPurpose.userFile.allowsPermanentDeletion)
        #expect(!DeletionPurpose.application.allowsPermanentDeletion)
        #expect(!DeletionPurpose.applicationData.allowsPermanentDeletion)
        #expect(DeletionPurpose.junk.allowsPermanentDeletion)
    }
}

@Suite("Safe remover")
struct CoreSafeRemoverTests {
    @Test func removesNestedTree() throws {
        let tree = try TemporaryTree()
        for index in 0..<30 { try tree.makeFile("victim/a\(index % 4)/b\(index % 3)/f\(index)", size: 5_000) }
        let snapshot = FileSnapshot.capture(path: tree.path("victim"))
        let result = try SafeRemover.remove(path: tree.path("victim"), expected: snapshot)
        #expect(result.removedRoot)
        #expect(result.bytesFreed > 0)
        #expect(!FileManager.default.fileExists(atPath: tree.path("victim")))
    }

    @Test func neverFollowsSymlinksInsideTheTree() throws {
        let tree = try TemporaryTree()
        let outside = try TemporaryTree()
        let precious = try outside.makeFile("precious.txt")
        try tree.makeFile("victim/file")
        symlink(outside.root, tree.path("victim/link"))
        try SafeRemover.remove(path: tree.path("victim"), expected: nil)
        #expect(FileManager.default.fileExists(atPath: precious), "the symlink's target must survive")
        #expect(!FileManager.default.fileExists(atPath: tree.path("victim")))
    }

    @Test func refusesItemReplacedAfterScan() throws {
        let tree = try TemporaryTree()
        try tree.makeDirectory("victim")
        let snapshot = FileSnapshot.capture(path: tree.path("victim"))
        try FileManager.default.removeItem(atPath: tree.path("victim"))
        try tree.makeDirectory("victim")
        #expect(throws: SafeRemover.RemovalError.self) {
            try SafeRemover.remove(path: tree.path("victim"), expected: snapshot)
        }
        #expect(FileManager.default.fileExists(atPath: tree.path("victim")))
    }

    @Test func keepsFoldersWhoseContentsCannotBeRemoved() throws {
        let tree = try TemporaryTree()
        let locked = try tree.makeFile("victim/locked")
        try tree.makeFile("victim/other")
        chflags(locked, UInt32(UF_IMMUTABLE))
        #expect(throws: SafeRemover.RemovalError.self) {
            try SafeRemover.remove(path: tree.path("victim"), expected: nil)
        }
        #expect(FileManager.default.fileExists(atPath: locked))
        #expect(!FileManager.default.fileExists(atPath: tree.path("victim/other")))
    }
}

@Suite("Cleanup engine")
struct CoreCleanupEngineTests {
    private func makeEngine(home: String, historyDirectory: String) -> (CleanupEngine, HistoryStore) {
        let history = HistoryStore(directory: URL(fileURLWithPath: historyDirectory))
        let logger = ActivityLogger(directory: URL(fileURLWithPath: historyDirectory))
        return (CleanupEngine(policy: makePolicy(home: home), history: history, logger: logger), history)
    }

    @Test func deletesJunkAndRecordsHistory() async throws {
        let home = try TemporaryTree("Home")
        let support = try TemporaryTree("Support")
        let cache = try home.makeFile("Library/Caches/com.example.app/blob", size: 120_000)
        let folder = (cache as NSString).deletingLastPathComponent
        let (engine, history) = makeEngine(home: home.root, historyDirectory: support.root)
        let item = CleanupItem(path: folder, purpose: .junk, snapshot: FileSnapshot.capture(path: folder), estimatedBytes: 120_000, category: "Caches")

        let report = await engine.clean([item], options: CleanupOptions(title: "Test", method: .deletePermanently))
        #expect(report.removed.count == 1)
        #expect(report.removed.first?.method == .deletePermanently)
        #expect(!FileManager.default.fileExists(atPath: folder))
        let entries = await history.allEntries()
        #expect(entries.first?.itemCount == 1)
    }

    @Test func personalFilesGoToTrashEvenWhenDeletionRequested() async throws {
        let home = try TemporaryTree("Home")
        let support = try TemporaryTree("Support")
        let file = try home.makeFile("Documents/MacCleanerTest-\(UUID().uuidString).txt", size: 1_000)
        let (engine, history) = makeEngine(home: home.root, historyDirectory: support.root)
        let item = CleanupItem(path: file, purpose: .userFile, snapshot: FileSnapshot.capture(path: file), estimatedBytes: 1_000, category: "Files")

        let report = await engine.clean([item], options: CleanupOptions(title: "Test", method: .deletePermanently))
        let removed = try #require(report.removed.first)
        #expect(removed.method == .moveToTrash)
        #expect(removed.trashedPath != nil)

        // Undo puts it back.
        let entryID = try #require(report.historyEntryID)
        let restore = await history.restore(entryID: entryID)
        #expect(restore.restored == [file])
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func skipsChangedDeniedAndMissingItems() async throws {
        let home = try TemporaryTree("Home")
        let support = try TemporaryTree("Support")
        let changed = try home.makeFile("Library/Caches/changed/x")
        let snapshot = FileSnapshot.capture(path: changed)
        try FileManager.default.removeItem(atPath: changed)
        try home.makeFile("Library/Caches/changed/x")
        let document = try home.makeFile("Documents/keep.txt")
        let (engine, _) = makeEngine(home: home.root, historyDirectory: support.root)

        let items = [
            CleanupItem(path: changed, purpose: .junk, snapshot: snapshot, estimatedBytes: 1, category: "Caches"),
            CleanupItem(path: document, purpose: .junk, snapshot: nil, estimatedBytes: 1, category: "Caches"),
            CleanupItem(path: home.path("Library/Caches/missing"), purpose: .junk, snapshot: nil, estimatedBytes: 1, category: "Caches"),
        ]
        let report = await engine.clean(items, options: CleanupOptions(title: "Test", method: .deletePermanently))
        #expect(report.removed.isEmpty)
        #expect(report.skipped.count == 3)
        #expect(FileManager.default.fileExists(atPath: changed))
        #expect(FileManager.default.fileExists(atPath: document))
    }

    @Test func skipsFoldersInUseByAnotherProcess() async throws {
        let home = try TemporaryTree("Home")
        let support = try TemporaryTree("Support")
        let folder = try home.makeDirectory("Library/Caches/com.example.busy")
        try home.makeFile("Library/Caches/com.example.busy/data")
        // A child process whose working directory is inside the folder keeps it "in use".
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        try process.run()
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        let (engine, _) = makeEngine(home: home.root, historyDirectory: support.root)
        let item = CleanupItem(path: folder, purpose: .junk, snapshot: FileSnapshot.capture(path: folder), estimatedBytes: 1, category: "Caches")
        let report = await engine.clean([item], options: CleanupOptions(title: "Test", method: .deletePermanently))
        #expect(report.removed.isEmpty)
        #expect(report.skipped.first?.reason.contains("sleep") == true)
        #expect(FileManager.default.fileExists(atPath: folder))
    }

    @Test func dryRunRemovesNothing() async throws {
        let home = try TemporaryTree("Home")
        let support = try TemporaryTree("Support")
        let cache = try home.makeFile("Library/Caches/com.example.dry/x")
        let (engine, _) = makeEngine(home: home.root, historyDirectory: support.root)
        let item = CleanupItem(path: cache, purpose: .junk, snapshot: nil, estimatedBytes: 10, category: "Caches")
        let report = await engine.clean([item], options: CleanupOptions(title: "Dry", method: .deletePermanently, dryRun: true))
        #expect(report.removed.count == 1)
        #expect(report.dryRun)
        #expect(FileManager.default.fileExists(atPath: cache))
    }

    @Test func nestedItemsAreProcessedOnce() async throws {
        let home = try TemporaryTree("Home")
        let support = try TemporaryTree("Support")
        let parent = try home.makeDirectory("Library/Caches/com.example.nested")
        let child = try home.makeFile("Library/Caches/com.example.nested/inner/file")
        let (engine, _) = makeEngine(home: home.root, historyDirectory: support.root)
        let items = [
            CleanupItem(path: parent, purpose: .junk, snapshot: nil, estimatedBytes: 10, category: "Caches"),
            CleanupItem(path: child, purpose: .junk, snapshot: nil, estimatedBytes: 10, category: "Caches"),
        ]
        let report = await engine.clean(items, options: CleanupOptions(title: "Nested", method: .deletePermanently))
        #expect(report.removed.map(\.path) == [parent])
        #expect(report.skipped.isEmpty && report.failed.isEmpty)
    }
}
