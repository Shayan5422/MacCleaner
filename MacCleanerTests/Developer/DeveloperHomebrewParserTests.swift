import Foundation
import Testing
@testable import MacCleaner

@Suite("Developer – Homebrew output")
struct DeveloperHomebrewParserTests {
    static let dryRun = """
    Warning: Skipping aom: most recent version 3.15.1 not installed
    Would remove: /opt/homebrew/Cellar/abseil/20260107.0 (806 files, 12.8MB)
    Would remove: /opt/homebrew/Cellar/ca-certificates/2026-05-14 (4 files, 200.6KB)
    Would remove: /Users/me/Library/Caches/Homebrew/ca-certificates--2026-08-13 (112.2KB)
    Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--node--22.1.0.arm64_sequoia.bottle.tar.gz (1.5GB)
    Would remove: /opt/homebrew/Caskroom/some-app/1.0 (1 file, 512B)
    Would remove (empty directory): /opt/homebrew/lib/python3.13/site-packages/numpy/ma
    Would remove (empty directory): /opt/homebrew/lib/python3.13/site-packages/numpy/linalg
    Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.6 (1,707 files, 34.6MB)
    ==> Would autoremove 2 unneeded formulae:
    llvm@20
    z3
    ==> This operation would free approximately 1.7GB of disk space.
    """

    @Test func parsesEntriesSizesAndTotal() throws {
        let plan = DeveloperHomebrewParser.parseCleanupDryRun(Self.dryRun)
        #expect(plan.entries.count == 6)
        #expect(plan.emptyDirectoryCount == 2)
        #expect(plan.autoremoveFormulae == ["llvm@20", "z3"])

        let abseil = try #require(plan.entries.first)
        #expect(abseil.path == "/opt/homebrew/Cellar/abseil/20260107.0")
        #expect(abseil.fileCount == 806)
        #expect(abseil.bytes == Int64((12.8 * 1_048_576).rounded()))

        let ruby = try #require(plan.entries.last)
        #expect(ruby.fileCount == 1_707)
        #expect(ruby.path == "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.6")

        let download = try #require(plan.entries.first { $0.path.hasSuffix(".tar.gz") })
        #expect(download.fileCount == nil)
        #expect(download.bytes == Int64((1.5 * 1_073_741_824).rounded()))

        #expect(plan.entries.first { $0.path.hasSuffix("1.0") }?.bytes == 512)
        #expect(plan.reportedTotalBytes == Int64((1.7 * 1_073_741_824).rounded()))
        #expect(plan.estimatedBytes == plan.reportedTotalBytes)
        #expect(plan.oldVersionCount == 3)
        #expect(plan.entries(inside: "/Users/me/Library/Caches/Homebrew").count == 2)
        #expect(!plan.isEmpty)
    }

    @Test func fallsBackToTheSumWithoutATotalLine() {
        let output = """
        Would remove: /opt/homebrew/Cellar/a/1.0 (2 files, 1KB)
        Would remove: /opt/homebrew/Cellar/b/2.0 (3 files, 2KB)
        """
        let plan = DeveloperHomebrewParser.parseCleanupDryRun(output)
        #expect(plan.reportedTotalBytes == nil)
        #expect(plan.estimatedBytes == 3 * 1024)
    }

    @Test func handlesNothingToClean() {
        let plan = DeveloperHomebrewParser.parseCleanupDryRun("")
        #expect(plan.isEmpty)
        #expect(plan.estimatedBytes == 0)
    }

    @Test func keepsPathsThatContainParentheses() {
        let entry = DeveloperHomebrewParser.parseEntry("/Users/me/Library/Caches/Homebrew/Cask/Tool (Beta)--1.0.dmg (20.5MB)")
        #expect(entry.path == "/Users/me/Library/Caches/Homebrew/Cask/Tool (Beta)--1.0.dmg")
        #expect(entry.bytes == Int64((20.5 * 1_048_576).rounded()))
    }

    @Test func parsesHomebrewSizesInBinaryUnits() {
        #expect(DeveloperHomebrewParser.parseSize("512B") == 512)
        #expect(DeveloperHomebrewParser.parseSize("1KB") == 1024)
        #expect(DeveloperHomebrewParser.parseSize("2MB") == Int64(2 * 1_048_576))
        #expect(DeveloperHomebrewParser.parseSize("1.5GB") == Int64(1.5 * 1_073_741_824))
        #expect(DeveloperHomebrewParser.parseSize("lots") == nil)
    }
}
