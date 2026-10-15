import Darwin
import Foundation
import Testing
@testable import MacCleaner

/// Temporary folders for file system tests. Everything lives under the system temporary directory.
enum StorageFixture {
    static func makeTemporaryDirectory(_ label: String = "StorageAnalyzerTests") throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths match what the walker and SafetyPolicy see.
        return PathUtilities.resolvedPath(base.path) ?? base.path
    }

    /// Writes `bytes` of random (incompressible) data.
    static func writeFile(_ path: String, bytes: Int) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, bytes) }
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Sets both the access and modification time.
    static func setDates(_ path: String, daysAgo: Double) {
        let seconds = Int(Date().timeIntervalSince1970 - daysAgo * 86_400)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        _ = utimes(path, &times)
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func build(_ root: String, exclusions: ExclusionList = ExclusionList()) async throws -> StorageTree {
        var request = StorageScanRequest(rootPath: root, displayName: "Test", exclusions: exclusions)
        request.lastOpenedLookupAgeDays = nil
        return try await StorageTreeBuilder(request: request).build()
    }
}

@Suite("Storage tree builder", .serialized)
struct StorageTreeBuilderTests {
    @Test func folderSizesAreTheSumOfTheirContentsAndMatchUsageAccumulator() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/a/big1.bin", bytes: 2_500_000)
        try StorageFixture.writeFile(root + "/a/b/big2.bin", bytes: 1_200_000)
        for index in 0..<20 { try StorageFixture.writeFile(root + "/a/b/small\(index).txt", bytes: 4_000) }
        try StorageFixture.writeFile(root + "/c/big3.bin", bytes: 3_000_000)
        try StorageFixture.writeFile(root + "/top.bin", bytes: 1_100_000)

        let tree = try await StorageFixture.build(root)
        let usage = try await FileSystemScanner().measure(path: root)
        #expect(tree.root.size == usage.allocatedBytes)
        #expect(tree.root.logicalSize == usage.logicalBytes)
        #expect(tree.root.reclaimableSize == usage.reclaimableBytes)
        #expect(tree.root.itemCount == usage.fileCount)
        #expect(tree.statistics.countedBytes == usage.allocatedBytes)

        var stack = [tree.root]
        while let node = stack.popLast() {
            #expect(node.size == node.children.reduce(0) { $0 + $1.size })
            #expect(zip(node.children, node.children.dropFirst()).allSatisfy { $0.size >= $1.size }, "Children are sorted largest first")
            stack.append(contentsOf: node.children.filter { $0.kind == .directory })
        }

        let b = try #require(tree.node(atPath: root + "/a/b"))
        let bUsage = try await FileSystemScanner().measure(path: root + "/a/b")
        #expect(b.size == bUsage.allocatedBytes)
        #expect(b.itemCount == 21)
    }

    @Test func smallFilesAreCombinedIntoOneNodePerFolder() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        for index in 0..<30 { try StorageFixture.writeFile(root + "/mixed/note\(index).txt", bytes: 2_000) }
        try StorageFixture.writeFile(root + "/mixed/large1.mov", bytes: 1_500_000)
        try StorageFixture.writeFile(root + "/mixed/large2.mov", bytes: 1_200_000)
        try StorageFixture.writeFile(root + "/onlyLarge/large.zip", bytes: 1_300_000)

        let tree = try await StorageFixture.build(root)
        let mixed = try #require(tree.node(atPath: root + "/mixed"))
        let combined = mixed.children.filter { $0.kind == .smallFiles }
        #expect(combined.count == 1)
        #expect(combined.first?.itemCount == 30)
        #expect(combined.first?.displayName == "30 smaller items")
        #expect(combined.first?.category == .documents)
        #expect(mixed.children.filter { $0.kind == .file }.count == 2)
        #expect(mixed.children.filter { $0.kind == .file }.allSatisfy { $0.category == .videos })

        let onlyLarge = try #require(tree.node(atPath: root + "/onlyLarge"))
        #expect(onlyLarge.children.count == 1)
        #expect(onlyLarge.children.first?.kind == .file)
        #expect(onlyLarge.category == .archives)

        // Small files still count in the exact per-kind totals.
        #expect(tree.statistics.count(for: .documents) == 30)
        #expect(tree.statistics.count(for: .videos) == 2)
    }

    @Test func hardLinksAreCountedOnce() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/one/original.bin", bytes: 3_000_000)
        try StorageFixture.makeDirectory(root + "/two")
        try #require(link(root + "/one/original.bin", root + "/two/link.bin") == 0)

        let tree = try await StorageFixture.build(root)
        let usage = try await FileSystemScanner().measure(path: root)
        var info = stat()
        try #require(lstat(root + "/one/original.bin", &info) == 0)
        let fileBytes = Int64(info.st_blocks) * 512

        #expect(tree.root.size == usage.allocatedBytes)
        #expect(tree.root.size == fileBytes, "Two names, one file: storage counted once")
        #expect(tree.root.itemCount == 1)
        #expect(tree.statistics.hardLinkExtraNames == 1)
        #expect(tree.statistics.hardLinkBytesNotRecounted == fileBytes)

        let one = try #require(tree.node(atPath: root + "/one"))
        let two = try #require(tree.node(atPath: root + "/two"))
        #expect(one.size + two.size == fileBytes)
        // Removing either folder alone frees nothing: the other name keeps the data.
        #expect(one.reclaimableSize == 0)
        #expect(two.reclaimableSize == 0)
        // Both names are inside the root, so removing the root frees the file.
        #expect(tree.root.reclaimableSize == usage.reclaimableBytes)
        #expect(tree.root.reclaimableSize >= fileBytes)
        let names = [one, two].flatMap(\.children)
        #expect(names.filter { $0.flags.contains(.sharedHardLink) }.count == 1)
    }

    @Test func apfsClonesShareTheirBlocksOnce() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/source/original.bin", bytes: 4_000_000)
        try StorageFixture.makeDirectory(root + "/copies")
        try #require(clonefile(root + "/source/original.bin", root + "/copies/clone.bin", 0) == 0, "clonefile requires APFS")

        let tree = try await StorageFixture.build(root)
        let usage = try await FileSystemScanner().measure(path: root)
        var info = stat()
        try #require(lstat(root + "/source/original.bin", &info) == 0)
        let fileBytes = Int64(info.st_blocks) * 512

        #expect(tree.root.size == usage.allocatedBytes)
        #expect(tree.root.reclaimableSize == usage.reclaimableBytes)
        #expect(tree.root.size < fileBytes * 3 / 2, "Shared clone blocks are counted once, not twice")
        #expect(tree.statistics.cloneBytesNotRecounted > 0)
        #expect(tree.root.itemCount == 2, "Clones are separate files")

        // Deleting one copy frees only its private blocks; deleting both frees everything.
        let source = try #require(tree.node(atPath: root + "/source"))
        let copies = try #require(tree.node(atPath: root + "/copies"))
        #expect(source.reclaimableSize < fileBytes / 2)
        #expect(copies.reclaimableSize < fileBytes / 2)
        #expect(tree.root.reclaimableSize >= fileBytes)
    }

    @Test func packagesAreLeavesWithTheirFullSize() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/Tool.app/Contents/MacOS/Tool", bytes: 2_000_000)
        try StorageFixture.writeFile(root + "/Tool.app/Contents/Resources/data.bin", bytes: 1_500_000)
        try StorageFixture.writeFile(root + "/Tool.app/Contents/Info.plist", bytes: 500)
        try StorageFixture.writeFile(root + "/Machine.utm/Data/disk.img", bytes: 1_200_000)

        let tree = try await StorageFixture.build(root)
        let app = try #require(tree.node(atPath: root + "/Tool.app"))
        #expect(app.kind == .package)
        #expect(app.children.isEmpty)
        #expect(app.category == .applications)
        #expect(app.itemCount == 3)
        let appUsage = try await FileSystemScanner().measure(path: root + "/Tool.app")
        #expect(app.size == appUsage.allocatedBytes)

        let machine = try #require(tree.node(atPath: root + "/Machine.utm"))
        #expect(machine.kind == .package, "Virtual machine bundles are never split into their disk files")
        #expect(machine.category == .diskImages)
        #expect(tree.statistics.packageCount == 2)
    }

    @Test func unreadableFoldersAreReported() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer {
            chmod(root + "/locked", 0o755)
            StorageFixture.remove(root)
        }
        try StorageFixture.writeFile(root + "/locked/secret.bin", bytes: 1_100_000)
        try StorageFixture.writeFile(root + "/open/visible.bin", bytes: 1_100_000)
        try #require(chmod(root + "/locked", 0) == 0)

        let tree = try await StorageFixture.build(root)
        #expect(tree.statistics.unreadableCount == 1)
        #expect(tree.statistics.unreadablePaths.first == root + "/locked")
        let locked = try #require(tree.node(atPath: root + "/locked"))
        #expect(locked.isUnreadable)
        #expect(locked.size == 0)
        #expect(tree.node(atPath: root + "/open/visible.bin") != nil)
    }

    @Test func excludedFoldersAreSkipped() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/keep/a.bin", bytes: 1_500_000)
        try StorageFixture.writeFile(root + "/skip/b.bin", bytes: 2_500_000)

        let tree = try await StorageFixture.build(root, exclusions: ExclusionList(paths: [root + "/skip"]))
        #expect(tree.node(atPath: root + "/skip") == nil)
        let keep = try #require(tree.node(atPath: root + "/keep"))
        #expect(tree.root.size == keep.size)
    }

    @Test func exclusionsAlsoMatchTheDataVolumeForm() {
        let expanded = StorageTreeBuilder.walkExclusions(ExclusionList(paths: ["/Users/someone/Movies"]), rootPath: "/System/Volumes/Data")
        #expect(expanded.isExcluded("/System/Volumes/Data/Users/someone/Movies/clip.mov"))
        #expect(expanded.isExcluded("/Users/someone/Movies"))
        let unchanged = StorageTreeBuilder.walkExclusions(ExclusionList(paths: ["/Users/someone/Movies"]), rootPath: "/Users/someone")
        #expect(unchanged.paths == ["/Users/someone/Movies"])
    }

    @Test func pathsAndSnapshotsRoundTrip() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/x/y/file.bin", bytes: 1_100_000)

        let tree = try await StorageFixture.build(root)
        let node = try #require(tree.node(atPath: root + "/x/y/file.bin"))
        #expect(node.kind == .file)
        #expect(tree.path(of: node) == root + "/x/y/file.bin")
        #expect(tree.snapshot(of: node) == FileSnapshot.capture(path: root + "/x/y/file.bin"))
        let folder = try #require(tree.node(atPath: root + "/x"))
        #expect(tree.snapshot(of: folder) == FileSnapshot.capture(path: root + "/x"))
        #expect(tree.node(atPath: "/definitely/not/here") == nil)
        #expect(node.ancestors.map(\.name) == ["Test", "x", "y"])
        #expect(node.isDescendant(of: folder))
    }

    @MainActor
    @Test func removingAndMovingKeepSizesConsistent() async throws {
        let root = try StorageFixture.makeTemporaryDirectory()
        defer { StorageFixture.remove(root) }
        try StorageFixture.writeFile(root + "/a/file1.bin", bytes: 2_000_000)
        try StorageFixture.writeFile(root + "/b/file2.bin", bytes: 3_000_000)

        let tree = try await StorageFixture.build(root)
        let a = try #require(tree.node(atPath: root + "/a"))
        let b = try #require(tree.node(atPath: root + "/b"))
        let file1 = try #require(tree.node(atPath: root + "/a/file1.bin"))
        let file2 = try #require(tree.node(atPath: root + "/b/file2.bin"))
        let before = tree.root.size

        tree.remove(file1)
        #expect(tree.root.size == before - file1.size)
        #expect(a.size == 0)
        #expect(!tree.isAttached(file1))
        #expect(tree.node(atPath: root + "/a/file1.bin") == nil)
        #expect(tree.path(of: file1).isEmpty)

        let moved = try #require(tree.move(file2, into: a, newName: "renamed.bin"))
        #expect(a.size == moved.size)
        #expect(b.size == 0)
        #expect(tree.root.size == before - file1.size, "Moving within the tree doesn't change the total")
        #expect(tree.node(atPath: root + "/a/renamed.bin") === moved)
        #expect(tree.root.children.first === a, "Folders are re-sorted after sizes change")
        #expect(tree.version == 2)
    }
}

@Suite("Storage categories")
struct StorageCategoryTests {
    @Test(arguments: [
        ("Holiday.MP4", StorageCategory.videos), ("song.flac", .audio), ("IMG_0001.HEIC", .images),
        ("backup.tar.gz", .archives), ("Installer.dmg", .diskImages), ("Setup.pkg", .diskImages),
        ("report.pdf", .documents), ("Budget.xlsx", .documents), ("main.swift", .developer),
        ("notes.bak", .backups), ("README", .other), (".bashrc", .other), ("photo.cr3", .images),
    ])
    func filesAreClassifiedByExtension(name: String, expected: StorageCategory) {
        #expect(StorageCategory.classify(fileName: name) == expected)
    }

    @Test func ambiguousExtensionsUseTheSize() {
        #expect(StorageCategory.classify(fileName: "index.ts", logicalSize: 4_000) == .developer)
        #expect(StorageCategory.classify(fileName: "recording.ts", logicalSize: 2_000_000_000) == .videos)
        #expect(StorageCategory.classify(fileName: "Docker.raw", logicalSize: 60_000_000_000) == .diskImages)
        #expect(StorageCategory.classify(fileName: "DSC_0001.RAW", logicalSize: 30_000_000) == .images)
    }

    @Test func packagesAreClassifiedByType() {
        #expect(StorageCategory.packageCategory(name: "Xcode.app") == .applications)
        #expect(StorageCategory.packageCategory(name: "Photos Library.photoslibrary") == .images)
        #expect(StorageCategory.packageCategory(name: "Project.xcodeproj") == .developer)
        #expect(StorageCategory.packageCategory(name: "Windows 11.pvm") == .diskImages)
        #expect(StorageCategory.packageCategory(name: "Report.pages") == .documents)
        #expect(StorageCategory.packageCategory(name: "Something.unknownbundle") == .other)
    }

    @Test func folderLocationImpliesAKind() {
        #expect(StorageCategory.folderHint(name: "node_modules", parentPath: "/Users/a/project", inherited: nil) == .developer)
        #expect(StorageCategory.folderHint(name: "Backup", parentPath: "/Users/a/Library/Application Support/MobileSync", inherited: nil) == .backups)
        #expect(StorageCategory.folderHint(name: "Backup", parentPath: "/Users/a/Documents", inherited: nil) == nil)
        #expect(StorageCategory.folderHint(name: "anything", parentPath: "/x", inherited: .backups) == .backups)
    }

    @Test func extensionsAreLowercasedAndBounded() {
        #expect(StorageCategory.lowercasedExtension(of: "A.JPG") == "jpg")
        #expect(StorageCategory.lowercasedExtension(of: "archive.tar.GZ") == "gz")
        #expect(StorageCategory.lowercasedExtension(of: ".hidden") == nil)
        #expect(StorageCategory.lowercasedExtension(of: "trailing.") == nil)
        #expect(StorageCategory.lowercasedExtension(of: "noext") == nil)
    }

    @Test func virtualMachineBundlesArePackages() {
        #expect(StoragePackages.isPackage(name: "Ubuntu.utm"))
        #expect(StoragePackages.isPackage(name: "Windows 11.pvm"))
        #expect(StoragePackages.isPackage(name: "Safari.app"))
        #expect(!StoragePackages.isPackage(name: "Documents"))
    }
}
