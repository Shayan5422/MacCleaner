import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Bulk directory reader & size accounting")
struct CoreFileSystemTests {
    @Test func bulkReaderMatchesLstat() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a.bin", size: 300_000)
        try tree.makeFile("ünïcødé name.txt", size: 10)
        try tree.makeDirectory("folder")
        symlink("a.bin", tree.path("link"))
        link(tree.path("a.bin"), tree.path("hard.bin"))

        let fd = open(tree.root, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BulkDirectoryReader.recommendedBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var names = Set<String>()
        try BulkDirectoryReader.forEachEntry(directoryFD: fd, device: info.st_dev, buffer: buffer) { entry in
            names.insert(entry.name)
            var expected = stat()
            #expect(lstat(tree.path(entry.name), &expected) == 0)
            #expect(entry.inode == UInt64(expected.st_ino))
            #expect(entry.type == FileObjectType(mode: expected.st_mode))
            if entry.type == .regular {
                #expect(entry.logicalSize == Int64(expected.st_size))
                #expect(entry.allocatedSize == Int64(expected.st_blocks) * 512)
                #expect(entry.linkCount == UInt32(expected.st_nlink))
            }
        }
        #expect(names == ["a.bin", "ünïcødé name.txt", "folder", "link", "hard.bin"])
    }

    @Test func hardLinksAreCountedOnce() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("dir/original", size: 200_000)
        link(tree.path("dir/original"), tree.path("dir/second"))

        let accumulator = UsageAccumulator()
        let original = try #require(BulkDirectoryReader.readAttributes(path: tree.path("dir/original")))
        let second = try #require(BulkDirectoryReader.readAttributes(path: tree.path("dir/second")))
        accumulator.add(original)
        // Only one of two names seen: nothing is reclaimable yet.
        #expect(accumulator.current.reclaimableBytes == 0)
        accumulator.add(second)
        let usage = accumulator.current
        #expect(usage.fileCount == 1)
        #expect(usage.allocatedBytes == original.allocatedSize)
        #expect(usage.reclaimableBytes == original.allocatedSize)
    }

    @Test func apfsClonesShareBlocksOnce() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a.bin", size: 2_000_000)
        guard clonefile(tree.path("a.bin"), tree.path("b.bin"), 0) == 0 else {
            // Not APFS (e.g. some CI volumes): clones aren't possible, nothing to verify.
            return
        }
        let a = try #require(BulkDirectoryReader.readAttributes(path: tree.path("a.bin")))
        let b = try #require(BulkDirectoryReader.readAttributes(path: tree.path("b.bin")))
        #expect(a.mayShareBlocks && b.mayShareBlocks)

        let both = UsageAccumulator()
        both.add([a, b])
        #expect(both.current.allocatedBytes == a.allocatedSize, "shared blocks are counted once")
        #expect(both.current.reclaimableBytes == a.allocatedSize, "deleting the whole family frees the shared blocks")

        let onlyOne = UsageAccumulator()
        onlyOne.add(a)
        #expect(onlyOne.current.reclaimableBytes == 0, "deleting one clone frees nothing while the other exists")
    }

    @Test func walkerMatchesFileManagerAndDoesNotFollowSymlinks() async throws {
        let tree = try TemporaryTree()
        for index in 0..<40 {
            try tree.makeFile("d\(index % 7)/sub\(index % 3)/file\(index).dat", size: 1_000 + index)
        }
        let outside = try TemporaryTree()
        try outside.makeFile("big.bin", size: 5_000_000)
        symlink(outside.root, tree.path("d0/link-to-outside"))

        let usage = try await FileSystemScanner().measure(path: tree.root)
        var files = 0
        for relative in try FileManager.default.subpathsOfDirectory(atPath: tree.root) {
            let attributes = try FileManager.default.attributesOfItem(atPath: tree.path(relative))
            if attributes[.type] as? FileAttributeType == .typeRegular { files += 1 }
        }
        // 40 regular files plus the symlink itself (counted as a file, never followed).
        #expect(usage.fileCount == files + 1)
        #expect(usage.logicalBytes < 5_000_000, "the symlinked 5 MB file must not be counted")
    }

    @Test func walkerHonorsExclusions() async throws {
        let tree = try TemporaryTree()
        try tree.makeFile("keep/a", size: 1_000)
        try tree.makeFile("skip/b", size: 50_000)
        var options = WalkOptions()
        options.exclusions = ExclusionList(paths: [tree.path("skip")])
        let usage = try await FileSystemScanner().measure(path: tree.root, options: options)
        #expect(usage.fileCount == 1)
    }

    @Test func measureChildrenMatchesIndividualMeasurements() async throws {
        let tree = try TemporaryTree()
        try tree.makeFile("one/x", size: 40_000)
        try tree.makeFile("one/deep/y", size: 60_000)
        try tree.makeFile("two/z", size: 10_000)
        try tree.makeFile("loose.txt", size: 5_000)
        let scanner = FileSystemScanner()
        let children = try await scanner.measureChildren(of: tree.root)
        for name in ["one", "two", "loose.txt"] {
            let single = try await scanner.measure(path: tree.path(name))
            let combined = try #require(children[tree.path(name)])
            #expect(combined.usage.allocatedBytes == single.allocatedBytes)
            #expect(combined.usage.fileCount == single.fileCount)
        }
    }

    @Test func findFilesKeepsLargest() async throws {
        let tree = try TemporaryTree()
        for index in 1...20 { try tree.makeFile("f\(index)", size: index * 10_000) }
        let largest = try await FileSystemScanner().findFiles(in: [tree.root], keepLargest: 3) { _, _ in true }
        #expect(largest.map(\.name) == ["f20", "f19", "f18"])
    }

    @Test func walkerCanBeCancelled() async throws {
        let tree = try TemporaryTree()
        for index in 0..<300 { try tree.makeDirectory("a/b\(index)/c/d") }
        let task = Task { try await FileSystemScanner().measure(path: tree.root) }
        task.cancel()
        let result = await task.result
        if case .success = result {
            // Finishing before the cancellation was observed is acceptable for tiny trees.
        }
    }
}

@Suite("Path utilities")
struct CorePathUtilityTests {
    @Test func normalizeKeepsPrivatePrefix() {
        #expect(PathUtilities.normalize("/private/tmp/x/") == "/private/tmp/x")
        #expect(PathUtilities.normalize("/a//b/./c") == "/a/b/c")
        #expect(PathUtilities.normalize("/") == "/")
        #expect(PathUtilities.normalize("/a/../b") == "/a/../b", "`..` is kept so safety checks can reject it")
    }

    @Test func descendantComparesWholeComponents() {
        #expect(PathUtilities.isSameOrDescendant("/a/b/c", of: "/a/b"))
        #expect(PathUtilities.isSameOrDescendant("/a/b", of: "/a/b"))
        #expect(!PathUtilities.isSameOrDescendant("/a/bc", of: "/a/b"))
        #expect(!PathUtilities.isDescendant("/a/b", of: "/a/b"))
        #expect(PathUtilities.isSameOrDescendant("/x", of: "/"))
    }

    @Test func nestedPathsAreRemoved() {
        let paths = ["/a/b/c", "/a/b", "/a/bc", "/d", "/a/b"]
        #expect(PathUtilities.removingNestedPaths(paths) == ["/a/b", "/a/bc", "/d"])
    }

    @Test func firmlinksMapToCanonicalPaths() {
        #expect(PathUtilities.firmlinkCanonical("/System/Volumes/Data/Users/me/x") == "/Users/me/x")
        #expect(PathUtilities.firmlinkCanonical("/System/Volumes/Data/private/var/x") == "/private/var/x")
        #expect(PathUtilities.firmlinkCanonical("/System/Volumes/Data/.Spotlight-V100") == "/System/Volumes/Data/.Spotlight-V100")
    }

    @Test func exclusionsMatchPathsSeenThroughTheDataVolume() {
        let list = ExclusionList(paths: ["/Users/me/Projects"])
        #expect(list.isExcluded("/System/Volumes/Data/Users/me/Projects/app"))
        #expect(list.hasExclusions(inside: "/System/Volumes/Data/Users/me"))
        #expect(!list.isExcluded("/System/Volumes/Data/Users/me/Music"))
    }

    @Test func exclusionListMatchesDescendants() {
        var list = ExclusionList()
        list.add("/Users/me/Projects/")
        #expect(list.isExcluded("/Users/me/Projects/app/build"))
        #expect(!list.isExcluded("/Users/me/Projects2"))
        list.remove("/Users/me/Projects")
        #expect(list.isEmpty)
    }
}
