import Foundation
import Testing
@testable import MacCleanerMobile

struct FileDeleterTests {
    @Test func trashingInAFolderWithoutRecentlyDeletedLeavesTheFile() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let file = try folder.write(Data("hello".utf8), to: "note.txt")

        let outcome = await FileDeleter.standard.trash([file])

        // The app's own container has no trash: the file stays and the failure says why.
        let exists = FileManager.default.fileExists(atPath: file.path)
        #expect(outcome.deleted.contains(file) == !exists)
        if let failure = outcome.failures.first {
            #expect(failure.url == file)
            #expect(failure.trashUnsupported)
            #expect(failure.reason == "This location doesn't have Recently Deleted.")
        }
        #expect(outcome.deleted.count + outcome.failures.count == 1)
    }

    @Test func trashingWhereSupportedMovesTheItems() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let trash = folder.url.deletingLastPathComponent().appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let deleter = FileDeleter(moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }, removePermanently: { _ in Issue.record("Nothing is deleted permanently while trashing") })
        let file = try folder.write(Data("hello".utf8), to: "note.txt")
        try folder.folder("Empty")
        let emptyFolder = folder.url.appendingPathComponent("Empty")

        let outcome = await deleter.trash([file, emptyFolder])

        #expect(outcome.deleted == [file, emptyFolder])
        #expect(outcome.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("note.txt").path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Empty").path))
    }

    @Test func permanentDeletionRemovesFilesAndReportsMissingOnes() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let file = try folder.write(FileTestFolder.randomData(1_000), to: "big.bin")
        try folder.folder("Empty/Inner")
        let emptyFolder = folder.url.appendingPathComponent("Empty")
        let missing = folder.url.appendingPathComponent("gone.bin")

        let outcome = await FileDeleter.standard.deletePermanently([file, emptyFolder, missing])

        #expect(outcome.deleted == [file, emptyFolder])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: emptyFolder.path))
        #expect(outcome.failures.map(\.url) == [missing])
        #expect(outcome.failures.first?.trashUnsupported == false)
        #expect(outcome.failures.first?.reason == "It isn't there anymore.")
    }

    @Test func failuresAreSortedIntoTrashUnsupportedAndOthers() {
        let unsupported = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(FileDeleter.isTrashUnsupported(unsupported))
        #expect(!FileDeleter.isTrashUnsupported(denied))
        #expect(FileDeleter.reason(for: denied) == "Mac Cleaner isn't allowed to change it.")
    }

    @Test func countsNameWhatWasDeleted() {
        let file = FileScanItem(url: URL(fileURLWithPath: "/a"), kind: .file, rootID: UUID(), displayPath: "R/a", size: 1, contentSize: 1)
        let folder = FileScanItem(url: URL(fileURLWithPath: "/b"), kind: .folder, rootID: UUID(), displayPath: "R/b", size: 0, contentSize: 0)
        #expect(FileCleanupModel.count(1, of: [file]) == "1 file")
        #expect(FileCleanupModel.count(2, of: [folder, folder]) == "2 folders")
        #expect(FileCleanupModel.count(2, of: [file, folder]) == "2 items")
    }
}
