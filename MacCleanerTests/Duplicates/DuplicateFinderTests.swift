import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Duplicate finder engine")
struct DuplicateFinderEngineTests {
    @Test func identicalFilesAreGroupedAndSameSizeDifferentContentIsNot() async throws {
        let fixture = try DuplicateTestFixture()
        let original = duplicateTestData(count: 300_000, seed: 1)
        var differentTail = original
        differentTail[differentTail.count - 1] ^= 0xFF
        var differentHead = original
        differentHead[0] ^= 0xFF
        let a = try fixture.write("photos/a.bin", original)
        let b = try fixture.write("backup/b.bin", original)
        let c = try fixture.write("c.bin", differentTail)
        let d = try fixture.write("d.bin", differentHead)

        let result = try await fixture.scan()

        #expect(result.filesExamined == 4)
        #expect(result.filesCompared == 4)
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(Set(group.files.map(\.path)) == [a, b])
        #expect(group.contentSize == Int64(original.count))
        #expect(group.digest.count == 64)
        let grouped = Set(result.groups.flatMap { $0.files.map(\.path) })
        #expect(!grouped.contains(c))
        #expect(!grouped.contains(d))
    }

    @Test func partialHashCollisionIsResolvedByFullHash() async throws {
        let fixture = try DuplicateTestFixture()
        let edge = duplicateTestData(count: DuplicateHasher.edgeLength, seed: 7)
        let tail = duplicateTestData(count: DuplicateHasher.edgeLength, seed: 8)
        let first = try fixture.write("first.bin", edge + duplicateTestData(count: 250_000, seed: 2) + tail)
        let second = try fixture.write("second.bin", edge + duplicateTestData(count: 250_000, seed: 3) + tail)

        let cancellation = DuplicateCancellation()
        let partialFirst = try DuplicateHasher.partialDigest(of: fixture.target(first), cancellation: cancellation)
        let partialSecond = try DuplicateHasher.partialDigest(of: fixture.target(second), cancellation: cancellation)
        #expect(partialFirst.digest == partialSecond.digest, "Same first and last 64 KiB must collide in the partial stage")
        #expect(!partialFirst.coversWholeFile)

        let fullFirst = try DuplicateHasher.fullDigest(of: fixture.target(first), cancellation: cancellation)
        let fullSecond = try DuplicateHasher.fullDigest(of: fixture.target(second), cancellation: cancellation)
        #expect(fullFirst.digest != fullSecond.digest)

        let result = try await fixture.scan()
        #expect(result.filesCompared == 2)
        #expect(result.groups.isEmpty)
    }

    @Test func smallFilesAreHashedCompletelyInThePartialStage() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 100_000, seed: 4)
        var differentMiddle = content
        differentMiddle[50_000] ^= 0x01
        let a = try fixture.write("a.dat", content)
        try fixture.write("b.dat", differentMiddle)
        let c = try fixture.write("c.dat", content)

        let partial = try DuplicateHasher.partialDigest(of: fixture.target(a), cancellation: DuplicateCancellation())
        #expect(partial.coversWholeFile)

        let result = try await fixture.scan()
        #expect(result.groups.count == 1)
        #expect(Set(result.groups.first?.files.map(\.path) ?? []) == [a, c])
    }

    @Test func hardLinksAreCollapsedAndNotCountedAsReclaimable() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 200_000, seed: 5)
        let linked = try fixture.write("a/linked.bin", content)
        let alias = try fixture.hardLink(linked, "b/alias.bin")
        let copy = try fixture.write("c/copy.bin", content)

        let result = try await fixture.scan()

        // Two names of one inode are one file: the group has two members, not three.
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(group.files.count == 2)
        let linkedMember = try #require(group.files.first { $0.path != copy })
        #expect(linkedMember.isHardLinked)
        #expect(Set([linkedMember.path] + linkedMember.hardLinkPaths) == [linked, alias])
        #expect(linkedMember.exclusiveSize == 0)

        #expect(result.hardLinkSets.count == 1)
        #expect(Set(result.hardLinkSets.first?.paths ?? []) == [linked, alias])

        // Removing the hard-linked name frees nothing; removing the independent copy frees its blocks.
        let copyMember = try #require(group.files.first { $0.path == copy })
        #expect(DuplicateSpaceEstimator.reclaimableBytes([linkedMember]) == 0)
        #expect(DuplicateSpaceEstimator.reclaimableBytes([copyMember]) == copyMember.allocatedSize)
        #expect(copyMember.allocatedSize > 0)
    }

    @Test func hardLinksAloneAreNotDuplicates() async throws {
        let fixture = try DuplicateTestFixture()
        let original = try fixture.write("original.bin", duplicateTestData(count: 150_000, seed: 6))
        let alias = try fixture.hardLink(original, "nested/alias.bin")

        let result = try await fixture.scan()

        #expect(result.groups.isEmpty)
        #expect(result.filesCompared == 0)
        #expect(Set(result.hardLinkSets.first?.paths ?? []) == [original, alias])
    }

    @Test func apfsClonesAreReportedButFreeLittleSpace() async throws {
        let fixture = try DuplicateTestFixture()
        let size = 2 * 1024 * 1024
        let original = try fixture.write("movie.bin", duplicateTestData(count: size, seed: 9))
        guard let clone = fixture.clone(original, "movie copy.bin") else {
            // The temporary volume doesn't support clones (not APFS); nothing to verify.
            return
        }

        let result = try await fixture.scan()

        let group = try #require(result.groups.first)
        #expect(Set(group.files.map(\.path)) == [original, clone])
        let cloneMember = try #require(group.files.first { $0.path == clone })
        #expect(cloneMember.sharedCloneBytes > 0)
        #expect(cloneMember.isMostlySharedClone)
        // Removing one clone frees only its private blocks.
        let reclaimable = DuplicateSpaceEstimator.reclaimableBytes([cloneMember])
        #expect(reclaimable < Int64(size / 10))
        #expect(group.reclaimableBytes(rule: .oldest, context: DuplicateKeepContext(downloadsFolder: fixture.path("Downloads"))) < Int64(size / 10))
    }

    @Test func emptyFilesAreIgnored() async throws {
        let fixture = try DuplicateTestFixture()
        for index in 0..<5 { try fixture.write("empty-\(index).txt", Data()) }
        let content = duplicateTestData(count: 4_096, seed: 10)
        try fixture.write("one.txt", content)
        try fixture.write("two.txt", content)

        let result = try await fixture.scan(minimumSize: 0)

        #expect(result.filesExamined == 2)
        #expect(result.groups.count == 1)
        #expect(result.groups.allSatisfy { $0.files.allSatisfy { $0.logicalSize > 0 } })
    }

    @Test func minimumSizeAndKindFiltersLimitTheScan() async throws {
        let fixture = try DuplicateTestFixture()
        let small = duplicateTestData(count: 2_000, seed: 11)
        let large = duplicateTestData(count: 50_000, seed: 12)
        try fixture.write("small-1.jpg", small)
        try fixture.write("small-2.jpg", small)
        try fixture.write("large-1.jpg", large)
        try fixture.write("large-2.jpg", large)
        try fixture.write("large-1.txt", large)

        let bySize = try await fixture.scan(minimumSize: 10_000)
        #expect(bySize.groups.count == 1)
        #expect(bySize.groups.first?.files.count == 3)

        let imagesOnly = try await fixture.scan(minimumSize: 10_000, kinds: .images)
        #expect(imagesOnly.groups.first?.files.map(\.fileExtension).allSatisfy { $0 == "jpg" } == true)
        #expect(imagesOnly.groups.first?.files.count == 2)
    }

    @Test func dependencyFoldersAndPackagesAreSkipped() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 20_000, seed: 13)
        let kept = try fixture.write("docs/report.pdf", content)
        try fixture.write("project/node_modules/lib/report.pdf", content)
        try fixture.write("Library.photoslibrary/originals/report.pdf", content)
        let other = try fixture.write("other/report.pdf", content)

        let result = try await fixture.scan()

        #expect(result.groups.count == 1)
        #expect(Set(result.groups.first?.files.map(\.path) ?? []) == [kept, other])
    }

    @Test func exclusionsAndHiddenFilesAreRespected() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 25_000, seed: 17)
        let visible = try fixture.write("Visible/report.pdf", content)
        let other = try fixture.write("Other/report.pdf", content)
        try fixture.write("Excluded/report.pdf", content)
        try fixture.write(".hidden-folder/report.pdf", content)
        try fixture.write("Visible/.report-backup.pdf", content)

        var options = fixture.options()
        options.exclusions = ExclusionList(paths: [fixture.path("Excluded")])
        let result = try await DuplicateFinder(policy: fixture.policy).findDuplicates(options: options)
        #expect(Set(result.groups.first?.files.map(\.path) ?? []) == [visible, other])

        options.includeHiddenFiles = true
        let withHidden = try await DuplicateFinder(policy: fixture.policy).findDuplicates(options: options)
        #expect(withHidden.groups.first?.files.count == 4)
    }

    @Test func nestedAndMissingRootsAreHandled() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 25_000, seed: 18)
        try fixture.write("Parent/Child/a.bin", content)
        try fixture.write("Parent/b.bin", content)

        let prepared = DuplicateFileCollector.prepareRoots([fixture.path("Parent"), fixture.path("Parent/Child"), fixture.path("Missing")])
        #expect(prepared.roots == [fixture.path("Parent")])
        #expect(prepared.unavailable.map(\.path) == [fixture.path("Missing")])

        var options = fixture.options()
        options.roots = [fixture.path("Parent"), fixture.path("Parent/Child"), fixture.path("Missing")]
        let result = try await DuplicateFinder(policy: fixture.policy).findDuplicates(options: options)
        // Files under the nested root are seen once, so they aren't duplicates of themselves.
        #expect(result.filesExamined == 2)
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.files.count == 2)
        #expect(result.unavailableRoots.count == 1)
    }

    @Test func lockedCopiesAreProtectedAndNeverSelected() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 30_000, seed: 14)
        let locked = try fixture.write("locked.bin", content)
        let free = try fixture.write("free.bin", content)
        let third = try fixture.write("third.bin", content)
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)

        let result = try await fixture.scan()
        let group = try #require(result.groups.first)
        let lockedMember = try #require(group.files.first { $0.path == locked })
        #expect(lockedMember.isProtected)
        #expect(group.files.filter { $0.path != locked }.allSatisfy { !$0.isProtected })

        for rule in DuplicateKeepRule.allCases {
            let marked = group.ruleMarkedIDs(rule: rule, context: DuplicateKeepContext(downloadsFolder: fixture.path("Downloads")))
            #expect(!marked.contains(locked))
        }
        var marks = DuplicateMarkSet()
        #expect(marks.setMarked(true, member: lockedMember, in: group.files) == .refusedProtected)
        #expect(Set([free, third]).isSubset(of: Set(group.files.map(\.path))))
    }

    @Test func comparingFilesDoesNotUpdateTheirAccessTimes() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 400_000, seed: 16)
        let paths = [try fixture.write("one.bin", content), try fixture.write("two.bin", content)]
        let accessed: Int = 1_000_000_000 // 2001, long before the files were modified
        for path in paths {
            // Open and read each new file once first, as any existing file has been. On some
            // Macs the first open of a newly written file updates its access time no matter
            // which I/O policy the reader uses (for example when a security agent scans it).
            _ = FileManager.default.contents(atPath: path)
            var info = stat()
            #expect(lstat(path, &info) == 0)
            var times = [
                timeval(tv_sec: accessed, tv_usec: 0),
                timeval(tv_sec: info.st_mtimespec.tv_sec, tv_usec: Int32(info.st_mtimespec.tv_nsec / 1_000)),
            ]
            #expect(utimes(path, &times) == 0)
        }

        let result = try await fixture.scan()
        #expect(result.groups.count == 1, "Both files must have been read completely")

        for path in paths {
            var info = stat()
            #expect(lstat(path, &info) == 0)
            #expect(info.st_atimespec.tv_sec == accessed, "Reading for comparison must not change the last-opened date")
        }
    }

    @Test func scanningCanBeCancelled() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 400_000, seed: 15)
        for index in 0..<40 { try fixture.write("copies/copy-\(index).bin", content) }
        let finder = DuplicateFinder(policy: fixture.policy)
        let options = fixture.options()
        let task = Task { try await finder.findDuplicates(options: options) }
        task.cancel()
        do {
            _ = try await task.value
            // Finishing before the cancellation was observed is also acceptable.
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@Suite("Duplicate removal planning")
struct DuplicateRemovalPlannerTests {
    @Test func plannerVerifiesKeptAndMarkedCopiesBeforeTrashing() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 80_000, seed: 20)
        let keep = try fixture.write("keep.bin", content)
        let remove = try fixture.write("remove.bin", content)
        let result = try await fixture.scan()
        let group = try #require(result.groups.first)
        let marked: Set<String> = [remove]

        let plan = DuplicateRemovalPlanner.plan(groups: [group.files], marked: marked, category: "Duplicate files")
        #expect(plan.items.map(\.path) == [remove])
        #expect(plan.items.first?.purpose == .userFile)
        #expect(plan.items.first?.snapshot == group.files.first { $0.path == remove }?.snapshot)
        #expect((plan.items.first?.estimatedBytes ?? 0) > 0)
        #expect(!plan.hasExclusions)

        // Everything marked: the planner refuses to remove the last copy.
        let everything = DuplicateRemovalPlanner.plan(groups: [group.files], marked: [keep, remove], category: "Duplicate files")
        #expect(everything.items.isEmpty)
        #expect(everything.groupsWithoutKeptCopy == 1)

        // The kept copy changed after the scan: nothing in the group is removed.
        try fixture.setDates(keep, created: Date(timeIntervalSince1970: 1_000_000), modified: Date(timeIntervalSince1970: 2_000_000))
        let keptChanged = DuplicateRemovalPlanner.plan(groups: [group.files], marked: marked, category: "Duplicate files")
        #expect(keptChanged.items.isEmpty)
        #expect(keptChanged.groupsWithoutKeptCopy == 1)
    }

    @Test func plannerLeavesOutMarkedCopiesThatChanged() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 80_000, seed: 21)
        try fixture.write("keep.bin", content)
        let remove = try fixture.write("remove.bin", content)
        let result = try await fixture.scan()
        let group = try #require(result.groups.first)

        try Data("edited".utf8).write(to: URL(fileURLWithPath: remove))
        try fixture.setDates(remove, created: Date(timeIntervalSince1970: 1_000_000), modified: Date(timeIntervalSince1970: 3_000_000))
        let plan = DuplicateRemovalPlanner.plan(groups: [group.files], marked: [remove], category: "Duplicate files")
        #expect(plan.items.isEmpty)
        #expect(plan.changedFiles == 1)
        #expect(plan.exclusionSummary != nil)
    }
}

@Suite("Duplicate Smart Scan provider")
struct DuplicateSmartScanProviderTests {
    @Test func offersEveryCopyExceptTheOldestForReview() async throws {
        let fixture = try DuplicateTestFixture()
        let content = duplicateTestData(count: 1_200_000, seed: 30)
        let oldest = try fixture.write("Archive/song.m4a", content)
        let newer = try fixture.write("Inbox/song.m4a", content)
        let newest = try fixture.write("Inbox/song copy.m4a", content)
        try fixture.write("tiny-1.txt", duplicateTestData(count: 10_000, seed: 31))
        try fixture.write("tiny-2.txt", duplicateTestData(count: 10_000, seed: 31))
        try fixture.setDates(oldest, created: Date(timeIntervalSince1970: 1_000_000_000))
        try fixture.setDates(newer, created: Date(timeIntervalSince1970: 1_100_000_000))
        try fixture.setDates(newest, created: Date(timeIntervalSince1970: 1_200_000_000))

        let provider = DuplicatesSmartScanProvider(roots: [fixture.root], policy: fixture.policy)
        let context = SmartScanContext(preferences: ScanPreferences(), reportProgress: { _, _ in })
        let contribution = try await provider.smartScan(context: context)

        #expect(contribution.area == .duplicates)
        #expect(Set(contribution.candidates.map(\.path)) == [newer, newest])
        #expect(contribution.candidates.allSatisfy { $0.safety == .review && !$0.isSelectedByDefault })
        #expect(contribution.candidates.allSatisfy { $0.purpose == .userFile })
        #expect(contribution.candidates.allSatisfy { $0.detail?.hasPrefix("Duplicate of song.m4a in ") == true })
        #expect(contribution.candidates.allSatisfy { $0.usage.reclaimableBytes > 0 })
        #expect(contribution.summary?.contains("2 duplicate files") == true)
    }
}
