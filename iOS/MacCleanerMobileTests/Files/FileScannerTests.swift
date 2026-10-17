import Foundation
import Testing
@testable import MacCleanerMobile

/// A folder in the test's temporary directory, removed by `remove()`.
struct FileTestFolder {
    let url: URL
    let rootID = UUID()

    init(name: String = "Picked") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileCleanupTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var root: FileScanRoot { FileScanRoot(id: rootID, url: url, name: url.lastPathComponent) }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @discardableResult
    func write(_ data: Data, to path: String, created: Date? = nil, modified: Date? = nil) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        var attributes: [FileAttributeKey: Any] = [:]
        if let created { attributes[.creationDate] = created }
        if let modified { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path) }
        return file
    }

    /// A file of `size` bytes that takes no space on disk.
    @discardableResult
    func sparse(_ size: UInt64, at path: String, modified: Date? = nil) throws -> URL {
        let file = try write(Data(), to: path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: size)
        try handle.close()
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
    }

    static func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

struct FileScannerTests {
    @Test func findsLargeOldDuplicateFilesAndEmptyFolders() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let twoYearsAgo = Date().addingTimeInterval(-2 * 365 * 24 * 3600)
        let lastWeek = Date().addingTimeInterval(-7 * 24 * 3600)

        try folder.sparse(60_000_000, at: "Videos/Trip.mov")
        try folder.sparse(2_000_000, at: "Documents/Tax 2022.pdf", modified: twoYearsAgo)
        try folder.write(FileTestFolder.randomData(2_000), to: "Documents/Tiny old note.txt", modified: twoYearsAgo)

        // Same size and content: duplicates. The older copy is kept.
        let content = FileTestFolder.randomData(200_000)
        try folder.write(content, to: "Scan.pdf", created: Date())
        try folder.write(content, to: "Archive/Scan.pdf", created: lastWeek)
        // Same size, different content from the first byte, and from after the first 64 KB.
        try folder.write(FileTestFolder.randomData(200_000), to: "Other.pdf")
        var sameStart = content
        sameStart.replaceSubrange(150_000..<150_010, with: Data(repeating: 0, count: 10))
        try folder.write(sameStart, to: "Edited Scan.pdf")
        // Identical but below the minimum size for comparing.
        let small = FileTestFolder.randomData(50_000)
        try folder.write(small, to: "a.txt")
        try folder.write(small, to: "b.txt")

        try folder.folder("Empty")
        try folder.folder("Nested/Inner")
        try folder.write(Data("x".utf8), to: "Only DS_Store/.DS_Store")
        try folder.write(Data("[core]".utf8), to: "Repository/.git/config")
        try folder.write(Data("x".utf8), to: "With File/a.txt")
        try folder.sparse(80_000_000, at: ".Hidden Video.mov")
        try folder.write(FileTestFolder.randomData(70_000), to: "Report.rtfd/TXT.rtf")

        let result = try await FileScanner().scan([folder.root])

        #expect(result.largeFiles.map(\.name) == ["Trip.mov"])
        #expect(result.largeFiles.first?.size == 60_000_000)
        #expect(result.largeFiles.first?.displayPath == "Picked/Videos/Trip.mov")
        #expect(result.largeFiles.first?.location == "Picked › Videos")
        #expect(result.oldFiles.map(\.name) == ["Tax 2022.pdf"])

        #expect(result.duplicateGroups.count == 1)
        let group = try #require(result.duplicateGroups.first)
        #expect(group.files.map(\.displayPath) == ["Picked/Archive/Scan.pdf", "Picked/Scan.pdf"])
        #expect(group.keeper.displayPath == "Picked/Archive/Scan.pdf")
        #expect(group.extras.map(\.name) == ["Scan.pdf"])
        #expect(result.total(of: .duplicates).count == 1)

        #expect(result.emptyFolders.map(\.displayPath) == ["Picked/Empty", "Picked/Nested", "Picked/Only DS_Store"])
        #expect(result.emptyFolders.allSatisfy { $0.kind == .folder })

        let all = result.largeFiles + result.oldFiles + result.duplicateGroups.flatMap(\.files)
        #expect(!all.contains { $0.name.hasPrefix(".") })
        // The package is one item; nothing inside it is listed.
        #expect(result.itemCount == 11)
    }

    @Test func packagesCountAsOneItem() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        try folder.sparse(30_000_000, at: "Keynote.key/Data/movie.mov")
        try folder.sparse(30_000_000, at: "Keynote.key/Data/photo.heic")
        var options = FileScanOptions()
        options.largeFileMinimum = 50_000_000
        let result = try await FileScanner(options: options).scan([folder.root])
        #expect(result.itemCount == 1)
        let package = try #require(result.largeFiles.first)
        #expect(package.name == "Keynote.key")
        #expect(package.kind == .package)
        #expect(package.size == 60_000_000)
        #expect(result.emptyFolders.isEmpty)
    }

    @Test func smallIdenticalFilesUseTheQuickDigestOnly() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let small = FileTestFolder.randomData(5_000)
        let created = Date().addingTimeInterval(-3600)
        try folder.write(small, to: "Notes/Copy of plan.txt", created: created)
        try folder.write(small, to: "plan.txt", created: created)
        var options = FileScanOptions()
        options.duplicateMinimum = 1_000
        let result = try await FileScanner(options: options).scan([folder.root])
        let group = try #require(result.duplicateGroups.first)
        // Same age: the shorter path is kept.
        #expect(group.keeper.name == "plan.txt")
        #expect(group.reclaimableBytes > 0)
    }

    @Test func nestedFoldersAreScannedOnce() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        try folder.sparse(60_000_000, at: "Inner/Big.mov")
        let inner = FileScanRoot(id: UUID(), url: folder.url.appendingPathComponent("Inner"), name: "Inner")
        let result = try await FileScanner().scan([inner, folder.root])
        #expect(result.largeFiles.count == 1)
        #expect(result.duplicateGroups.isEmpty)
        #expect(FileScanner.outermost([inner, folder.root]).map(\.id) == [folder.rootID])
    }

    @Test func aCancelledScanStops() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        for index in 0..<600 {
            try folder.write(Data([UInt8(index % 256)]), to: "file \(index).txt")
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileScanner().scan([folder.root])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func reportsProgress() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let content = FileTestFolder.randomData(120_000)
        try folder.write(content, to: "a.bin")
        try folder.write(content, to: "b.bin")
        let updates = FileScanProgressLog()
        _ = try await FileScanner().scan([folder.root]) { updates.append($0) }
        let last = try #require(updates.all.last)
        #expect(last.stage == .comparing)
        #expect(last.toCompare == 2)
        #expect(last.compared == 2)
        #expect(last.fraction == 1)
    }

    @Test func resultsDropDeletedItems() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let content = FileTestFolder.randomData(150_000)
        try folder.write(content, to: "one.bin", created: Date().addingTimeInterval(-60))
        try folder.write(content, to: "two.bin")
        try folder.sparse(70_000_000, at: "big.mov", modified: Date().addingTimeInterval(-800 * 24 * 3600))
        let result = try await FileScanner().scan([folder.root])
        // The big, old file counts once.
        #expect(result.reclaimableFileCount == 2)
        #expect(result.reclaimableBytes == 70_000_000 + (result.duplicateGroups.first?.reclaimableBytes ?? 0))

        let afterDelete = result.removing([folder.url.appendingPathComponent("two.bin")])
        #expect(afterDelete.duplicateGroups.isEmpty)
        #expect(afterDelete.largeFiles.count == 1)
        #expect(result.removingRoot(folder.rootID).largeFiles.isEmpty)
    }

    @Test func emptinessIsCheckedAgainBeforeDeleting() throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        try folder.folder("A/B/C")
        try folder.write(Data(), to: "A/.DS_Store")
        #expect(FileScanner.isEffectivelyEmpty(folder.url.appendingPathComponent("A")))
        try folder.write(Data("x".utf8), to: "A/B/.hidden")
        #expect(!FileScanner.isEffectivelyEmpty(folder.url.appendingPathComponent("A")))
    }

    @Test func itemsThatChangedSinceTheScanAreNoticed() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let file = try folder.write(FileTestFolder.randomData(1_500_000), to: "Old.pdf", modified: Date().addingTimeInterval(-500 * 24 * 3600))
        try folder.folder("Empty")
        let result = try await FileScanner().scan([folder.root])
        let old = try #require(result.oldFiles.first)
        let empty = try #require(result.emptyFolders.first)
        #expect(FileCleanupModel.isUnchanged(old))
        #expect(FileCleanupModel.isUnchanged(empty))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more".utf8))
        try handle.close()
        try folder.write(Data("x".utf8), to: "Empty/new.txt")
        #expect(!FileCleanupModel.isUnchanged(old))
        #expect(!FileCleanupModel.isUnchanged(empty))
    }
}

/// Progress updates collected from the scanner's background task.
final class FileScanProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [FileScanProgress] = []

    func append(_ update: FileScanProgress) { lock.withLock { updates.append(update) } }
    var all: [FileScanProgress] { lock.withLock { updates } }
}
