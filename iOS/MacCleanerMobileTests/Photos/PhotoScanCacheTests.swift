import Foundation
import Testing
@testable import MacCleanerMobile

/// The hash cache: an entry holds only for the modification date it was made with.
struct PhotoScanCacheTests {
    let modified = Date(timeIntervalSince1970: 1_760_000_000.123456)
    let fingerprint = ImageFingerprint(hash: 0xFFFF_FFFF_FFFF_FFF0, luma: 77,
                                       detail: DetailHash(bits: [1, 2, 3, .max], strong: [.max, 0, 5, 1 << 63]))

    @Test func entriesHoldForTheSameModificationDate() {
        var cache = PhotoScanCache()
        cache.store(fingerprint, for: "a", modified: modified)
        cache.store(MediaSize(bytes: 1_234, isEstimated: false), for: "a", modified: modified)
        #expect(cache.fingerprint(for: "a", modified: modified) == fingerprint)
        #expect(cache.size(for: "a", modified: modified) == MediaSize(bytes: 1_234, isEstimated: false))
        #expect(cache.fingerprint(for: "b", modified: modified) == nil)
    }

    @Test func anEditInvalidatesTheEntry() {
        var cache = PhotoScanCache()
        cache.store(fingerprint, for: "a", modified: modified)
        cache.store(MediaSize(bytes: 1_234, isEstimated: false), for: "a", modified: modified)
        let edited = modified.addingTimeInterval(1)
        #expect(cache.fingerprint(for: "a", modified: edited) == nil)
        #expect(cache.size(for: "a", modified: edited) == nil)

        // The new fingerprint replaces the entry, and the old size doesn't carry over to the edited photo.
        let newFingerprint = ImageFingerprint(hash: 1, luma: 2)
        cache.store(newFingerprint, for: "a", modified: edited)
        #expect(cache.fingerprint(for: "a", modified: edited) == newFingerprint)
        #expect(cache.size(for: "a", modified: edited) == nil)
        #expect(cache.fingerprint(for: "a", modified: modified) == nil)
        #expect(cache.count == 1)
    }

    @Test func assetsWithoutAModificationDateMatchOnlyThat() {
        var cache = PhotoScanCache()
        cache.store(fingerprint, for: "a", modified: nil)
        #expect(cache.fingerprint(for: "a", modified: nil) == fingerprint)
        #expect(cache.fingerprint(for: "a", modified: modified) == nil)
    }

    @Test func estimatedSizesArentKept() {
        var cache = PhotoScanCache()
        cache.store(MediaSize(bytes: 5_000, isEstimated: true), for: "a", modified: modified)
        #expect(cache.size(for: "a", modified: modified) == nil)
        #expect(cache.count == 0)
    }

    @Test func savedCachesLoadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoScanCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Photos/scan-cache.json")
        var cache = PhotoScanCache()
        cache.store(fingerprint, for: "a", modified: modified)
        cache.store(MediaSize(bytes: 9_876_543_210, isEstimated: false), for: "b", modified: nil)
        try cache.save(to: url)

        let loaded = PhotoScanCache.load(from: url)
        #expect(loaded == cache)
        #expect(loaded.fingerprint(for: "a", modified: modified) == fingerprint)
        #expect(loaded.size(for: "b", modified: nil)?.bytes == 9_876_543_210)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func otherFormatsAndBrokenFilesLoadEmpty() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoScanCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let future = folder.appendingPathComponent("future.json")
        try Data(#"{"version": 999, "entries": {"a": {"m": 1, "h": 5, "l": 6}}}"#.utf8).write(to: future)
        #expect(PhotoScanCache.load(from: future).count == 0)

        let broken = folder.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: broken)
        #expect(PhotoScanCache.load(from: broken).count == 0)

        #expect(PhotoScanCache.load(from: folder.appendingPathComponent("missing.json")).count == 0)
    }

    @Test func pruningForgetsAssetsThatAreGone() {
        var cache = PhotoScanCache()
        for id in ["a", "b", "c"] { cache.store(fingerprint, for: id, modified: modified) }
        cache.prune(keeping: ["a", "c", "z"])
        #expect(cache.count == 2)
        #expect(cache.fingerprint(for: "b", modified: modified) == nil)
        #expect(cache.fingerprint(for: "c", modified: modified) == fingerprint)
    }
}
