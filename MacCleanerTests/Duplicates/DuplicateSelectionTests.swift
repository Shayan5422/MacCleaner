import Foundation
import Testing
@testable import MacCleaner

@Suite("Duplicate selection rules")
struct DuplicateSelectionRuleTests {
    private let context = DuplicateKeepContext(downloadsFolder: "/Users/test/Downloads", preferredFolder: "/Users/test/Archive")

    /// Groups covering the interesting cases: plain copies, Downloads copies, a preferred
    /// folder, protected and app-library copies, a fully protected group, and a pair.
    private var groups: [DuplicateGroup] {
        [
            DuplicateGroup(digest: "a", contentSize: 1_000, files: [
                duplicateTestFile("/Users/test/Documents/Reports/report.pdf", inode: 1, created: 300),
                duplicateTestFile("/Users/test/Downloads/report.pdf", inode: 2, created: 100),
                duplicateTestFile("/Users/test/Archive/2024/report.pdf", inode: 3, created: 200),
            ]),
            DuplicateGroup(digest: "b", contentSize: 2_000, files: [
                duplicateTestFile("/Users/test/Downloads/song.m4a", inode: 4, created: 50, size: 2_000),
                duplicateTestFile("/Users/test/Music/Music/Media.localized/song.m4a", inode: 5, created: 60, size: 2_000, managedLibraryName: "Music"),
                duplicateTestFile("/Users/test/Desktop/song.m4a", inode: 6, created: 70, size: 2_000, protectionReason: "The item is locked."),
            ]),
            DuplicateGroup(digest: "c", contentSize: 3_000, files: [
                duplicateTestFile("/Volumes/Backup/a.mov", inode: 7, created: 10, size: 3_000, protectionReason: "Protected"),
                duplicateTestFile("/Volumes/Backup/b.mov", inode: 8, created: 20, size: 3_000, protectionReason: "Protected"),
            ]),
            DuplicateGroup(digest: "d", contentSize: 4_000, files: [
                duplicateTestFile("/Users/test/Pictures/x.jpg", inode: 9, created: 500, size: 4_000),
                duplicateTestFile("/Users/test/Pictures/Old/x.jpg", inode: 10, created: 500, size: 4_000),
            ]),
        ]
    }

    @Test(arguments: DuplicateKeepRule.allCases)
    func everyRuleKeepsAtLeastOneCopyPerGroup(rule: DuplicateKeepRule) {
        var marks = DuplicateMarkSet()
        for group in groups {
            marks.replaceMarks(in: group.files, with: group.ruleMarkedIDs(rule: rule, context: context))
        }
        for group in groups {
            #expect(marks.keepsAtLeastOne(of: group.files), "Rule \(rule) marked every copy of group \(group.digest)")
            let keeper = group.keeper(rule: rule, context: context)
            #expect(keeper != nil)
            #expect(keeper.map { !marks.contains($0.id) } == true, "The kept copy must never be marked")
            for file in group.files where file.isProtected || file.managedLibraryName != nil {
                #expect(!marks.contains(file.id), "Protected and app-library copies are never selected automatically")
            }
        }
    }

    @Test(arguments: DuplicateKeepRule.allCases)
    func manualMarkingNeverRemovesTheLastCopy(rule: DuplicateKeepRule) {
        for group in groups {
            var marks = DuplicateMarkSet()
            marks.replaceMarks(in: group.files, with: group.ruleMarkedIDs(rule: rule, context: context))
            // Try to mark everything that is still kept.
            for file in group.files where !marks.contains(file.id) {
                let outcome = marks.setMarked(true, member: file, in: group.files)
                #expect(outcome != .marked || marks.keepsAtLeastOne(of: group.files))
            }
            #expect(marks.keepsAtLeastOne(of: group.files))
        }
    }

    @Test func markingTheLastKeptCopyIsRefused() throws {
        let group = try #require(groups.last)
        var marks = DuplicateMarkSet()
        #expect(marks.setMarked(true, member: group.files[0], in: group.files) == .marked)
        #expect(marks.setMarked(true, member: group.files[1], in: group.files) == .refusedLastCopy)
        #expect(marks.count == 1)
        #expect(marks.setMarked(false, member: group.files[0], in: group.files) == .unmarked)
        #expect(marks.setMarked(true, member: group.files[1], in: group.files) == .marked)
    }

    @Test func replacingMarksWithEveryCopyStillKeepsOne() throws {
        let group = try #require(groups.first)
        var marks = DuplicateMarkSet()
        marks.replaceMarks(in: group.files, with: Set(group.files.map(\.id)))
        #expect(marks.keepsAtLeastOne(of: group.files))
        #expect(marks.count == group.files.count - 1)
    }

    @Test func keepOnlyMarksEveryOtherUnprotectedCopy() throws {
        let group = groups[1]
        var marks = DuplicateMarkSet()
        marks.keepOnly(group.files[1], in: group.files)
        #expect(!marks.contains(group.files[1].id))
        #expect(marks.contains(group.files[0].id))
        #expect(!marks.contains(group.files[2].id), "Protected copies are never marked")
    }

    @Test func repairRestoresTheInvariantAfterRegrouping() {
        let first = duplicateTestFile("/Users/test/a.jpg", inode: 20, created: 1)
        let second = duplicateTestFile("/Users/test/b.jpg", inode: 21, created: 2)
        let third = duplicateTestFile("/Users/test/c.jpg", inode: 22, created: 3)
        var marks = DuplicateMarkSet()
        marks.replaceMarks(in: [first, second, third], with: [first.id, third.id])
        // Regrouped: the two marked files now form a group of their own.
        let repaired = marks.repair(groups: [[first, third], [second]])
        #expect(repaired == 1)
        #expect(marks.keepsAtLeastOne(of: [first, third]))
    }

    @Test func rulesPickTheExpectedCopy() throws {
        let group = try #require(groups.first)
        #expect(DuplicateKeepRule.oldest.keeper(in: group.files, context: context)?.identity.inode == 2)
        #expect(DuplicateKeepRule.newest.keeper(in: group.files, context: context)?.identity.inode == 1)
        #expect(DuplicateKeepRule.shortestPath.keeper(in: group.files, context: context)?.identity.inode == 2)
        #expect(DuplicateKeepRule.outsideDownloads.keeper(in: group.files, context: context)?.identity.inode == 3)
        #expect(DuplicateKeepRule.preferredFolder.keeper(in: group.files, context: context)?.identity.inode == 3)
        // Ties on age fall back to the shortest path.
        let tie = groups[3]
        #expect(DuplicateKeepRule.oldest.keeper(in: tie.files, context: context)?.identity.inode == 9)
    }

    @Test func reclaimableExcludesTheKeptCopyAndHardLinks() {
        let files = [
            duplicateTestFile("/Users/test/a.bin", inode: 30, created: 1, size: 10_000),
            duplicateTestFile("/Users/test/b.bin", inode: 31, created: 2, size: 10_000),
            duplicateTestFile("/Users/test/c.bin", inode: 32, created: 3, size: 10_000, linkCount: 2),
        ]
        let group = DuplicateGroup(digest: "e", contentSize: 10_000, files: files)
        // Keep the oldest (a); b frees its blocks, c is hard-linked elsewhere and frees nothing.
        #expect(group.reclaimableBytes(rule: .oldest, context: context) == 10_000)
        let estimates = DuplicateSpaceEstimator.perFileEstimates(Array(files.dropFirst()))
        #expect(estimates[files[1].id] == 10_000)
        #expect(estimates[files[2].id] == 0)
    }
}

@Suite("Duplicate file kinds")
struct DuplicateFileKindTests {
    @Test func commonExtensionsAreClassified() {
        #expect(DuplicateFileKind.classify(path: "/a/IMG_0001.HEIC") == .image)
        #expect(DuplicateFileKind.classify(path: "/a/clip.mov") == .video)
        #expect(DuplicateFileKind.classify(path: "/a/song.flac") == .audio)
        #expect(DuplicateFileKind.classify(path: "/a/report.docx") == .document)
        #expect(DuplicateFileKind.classify(path: "/a/backup.zip") == .archive)
        #expect(DuplicateFileKind.classify(path: "/a/noextension") == .other)
        #expect(DuplicateKindFilter.images.includes(.image))
        #expect(!DuplicateKindFilter.images.includes(.document))
        #expect(DuplicateKindFilter.all.includes(.other))
    }
}
