import Foundation
import Testing
@testable import MacCleanerMobile

/// Grouping on fake asset records: dimensions, dates and hashes, no PhotoKit.
struct PhotoGroupingTests {
    typealias Fixture = PhotoFixtures

    private func idSets(_ groups: [[MediaItem]]) -> Set<Set<String>> {
        Set(groups.map { Set($0.map(\.id)) })
    }

    // MARK: Duplicates

    @Test func copiesNeedTheSamePixelSizeAndANearlyEqualHash() {
        let hash: UInt64 = 0x0123_4567_89AB_CDEF
        let items = [
            Fixture.photo("original", hash: hash),
            // Saved again a year later, three bits apart.
            Fixture.photo("copy", minutes: 60 * 24 * 365, hash: Fixture.flip(hash, bits: [1, 30, 62])),
            Fixture.photo("smaller", width: 2016, height: 1512, hash: hash),
            Fixture.photo("four bits off", hash: Fixture.flip(hash, bits: [0, 9, 18, 27])),
            Fixture.photo("not compared", hash: nil),
        ]
        #expect(idSets(PhotoGrouping.duplicateClusters(items)) == [["original", "copy"]])
    }

    @Test func theSliceIndexFindsEveryCopyWithinTheDistance() {
        // 400 unrelated photos, every third with a copy up to 3 bits off (in any of the four slices).
        var random = SyntheticImages.Random(seed: 42)
        var items: [MediaItem] = []
        var expected: Set<Set<String>> = []
        for index in 0..<400 {
            let hash = random.next()
            items.append(Fixture.photo("p\(index)", minutes: Double(index), hash: hash))
            if index % 3 == 0 {
                let flips = (0..<(index / 3 % 4)).map { $0 * 16 + Int(random.next() % 16) }
                items.append(Fixture.photo("p\(index)-copy", minutes: Double(index) + 0.5, hash: Fixture.flip(hash, bits: flips)))
                expected.insert(["p\(index)", "p\(index)-copy"])
            }
        }
        let groups = PhotoGrouping.duplicateClusters(items.shuffled())
        #expect(idSets(groups) == expected)
        for group in groups {
            for first in group {
                for second in group where second.id != first.id {
                    #expect(PhotoGrouping.isDuplicate(first, second))
                }
            }
        }
    }

    @Test func copiesMustAgreeInDetailToo() {
        let detail = DetailHash(bits: [0xF0F0, 0, 0, 0], strong: [.max, .max, .max, .max])
        var different = detail
        different.bits = [0x0F0F, 0xFF, 0, 0]
        let items = [
            Fixture.photo("gravel", hash: 0xABCD, detail: detail),
            Fixture.photo("other gravel", minutes: 1, hash: 0xABCD, detail: different),
            Fixture.photo("copy", minutes: 60 * 24, hash: 0xABCD, detail: detail),
        ]
        #expect(PhotoGrouping.isDuplicate(items[0], items[2]))
        #expect(!PhotoGrouping.isDuplicate(items[0], items[1]))
        // The look-alike taken a minute later isn't a copy, but it's still a similar shot.
        let clusters = PhotoGrouping.clusters(of: items)
        #expect(clusters.duplicates.map(Set.init) == [["gravel", "copy"]])
        #expect(clusters.similar.isEmpty)
        let withoutCopy = PhotoGrouping.clusters(of: Array(items.prefix(2)))
        #expect(withoutCopy.duplicates.isEmpty)
        #expect(withoutCopy.similar.map(Set.init) == [["gravel", "other gravel"]])
    }

    @Test func copiesOfCopiesAllMatch() {
        let hash: UInt64 = 0xFEDC_BA98_7654_3210
        let items = [
            Fixture.photo("a", hash: hash),
            Fixture.photo("b", minutes: 1, hash: Fixture.flip(hash, bits: [5, 6])),
            Fixture.photo("c", minutes: 2, hash: Fixture.flip(hash, bits: [5])),
        ]
        #expect(idSets(PhotoGrouping.duplicateClusters(items)) == [["a", "b", "c"]])
    }

    @Test func aChainOfSmallChangesIsNotOneSetOfCopies() {
        // Each frame is 2 bits from the one before, like a time-lapse: the first and the third are 4 apart.
        let hash: UInt64 = 0xFEDC_BA98_7654_3210
        let items = [
            Fixture.photo("a", hash: hash),
            Fixture.photo("b", minutes: 1, hash: Fixture.flip(hash, bits: [5, 6])),
            Fixture.photo("c", minutes: 2, hash: Fixture.flip(hash, bits: [5, 6, 40, 41])),
            Fixture.photo("d", minutes: 3, hash: Fixture.flip(hash, bits: [5, 6, 40, 41, 50, 51])),
        ]
        // The oldest frame starts a set; the third can't join it and starts the next.
        #expect(idSets(PhotoGrouping.duplicateClusters(items)) == [["a", "b"], ["c", "d"]])
    }

    // MARK: Similar

    @Test func similarShotsAreTakenWithinAFewMinutes() {
        let hash: UInt64 = 0xF0F0_F0F0_0F0F_0F0F
        let items = [
            Fixture.photo("first", minutes: 0, hash: hash),
            Fixture.photo("a minute later", minutes: 1, hash: Fixture.flip(hash, bits: Array(0..<8))),
            Fixture.photo("half an hour later", minutes: 30, hash: Fixture.flip(hash, bits: Array(0..<6))),
            Fixture.photo("too different", minutes: 2, hash: Fixture.flip(hash, bits: Array(20..<40))),
        ]
        #expect(idSets(PhotoGrouping.similarClusters(items)) == [["first", "a minute later"]])
    }

    @Test func similarSetsDontChain() {
        // Each shot is 6 bits from the one before, so the first and the third are 12 apart.
        let first: UInt64 = 0
        let second = Fixture.flip(first, bits: Array(0..<6))
        let third = Fixture.flip(second, bits: Array(6..<12))
        let items = [
            Fixture.photo("a", minutes: 0, hash: first),
            Fixture.photo("b", minutes: 1, hash: second),
            Fixture.photo("c", minutes: 2, hash: third),
        ]
        let groups = idSets(PhotoGrouping.similarClusters(items))
        #expect(groups == [["a", "b"]])
        #expect(!groups.contains { $0.contains("a") && $0.contains("c") })
    }

    @Test func aShotJoinsTheCloserSet() {
        let items = [
            Fixture.photo("x", minutes: 0, hash: 0),
            // 11 bits from x: a set of its own.
            Fixture.photo("y", minutes: 0.1, hash: Fixture.flip(0, bits: Array(0..<11))),
            // Fits both: 4 bits from x, 7 from y.
            Fixture.photo("z", minutes: 0.2, hash: Fixture.flip(0, bits: Array(0..<4))),
            // Fits both: at most 9 bits from x's set, 2 from y's.
            Fixture.photo("w", minutes: 0.3, hash: Fixture.flip(0, bits: Array(0..<9))),
        ]
        #expect(idSets(PhotoGrouping.similarClusters(items)) == [["x", "z"], ["y", "w"]])
    }

    @Test func photosWithoutADateAreNeverSimilar() {
        var undated = Fixture.photo("undated", hash: 7)
        undated.creationDate = nil
        #expect(PhotoGrouping.similarClusters([undated, Fixture.photo("dated", hash: 7)]).isEmpty)
    }

    @Test func duplicatesArentAlsoSimilar() {
        let hash: UInt64 = 0xAAAA_5555_AAAA_5555
        let items = [
            Fixture.photo("one", hash: hash),
            Fixture.photo("two", minutes: 1, hash: hash),
            Fixture.photo("three", minutes: 2, hash: Fixture.flip(hash, bits: Array(0..<7))),
        ]
        let clusters = PhotoGrouping.clusters(of: items)
        #expect(clusters.duplicates.map(Set.init) == [["one", "two"]])
        #expect(clusters.similar.isEmpty)
    }

    @Test func screenshotsAndHiddenBurstFramesArentCompared() {
        var frame = Fixture.photo("frame", hash: 0x1234)
        frame.burstIdentifier = "burst"
        let items = [
            Fixture.screenshot("shot 1", hash: 0x1234),
            Fixture.screenshot("shot 2", minutes: 1, hash: 0x1234),
            frame,
        ]
        let clusters = PhotoGrouping.clusters(of: items)
        #expect(clusters.duplicates.isEmpty)
        #expect(clusters.similar.isEmpty)
    }

    // MARK: Bursts

    @Test func burstsKeepThePickedFrames() throws {
        let frames = [
            Fixture.burstFrame("f1", seconds: 0),
            Fixture.burstFrame("f2", seconds: 0.1, picked: true, cover: true),
            Fixture.burstFrame("f3", seconds: 0.2),
            Fixture.burstFrame("f4", seconds: 0.3, picked: true),
            Fixture.burstFrame("f5", seconds: 0.4),
        ]
        let groups = PhotoGrouping.burstGroups(frames.shuffled())
        let burst = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(burst.keeperIDs == ["f2", "f4"])
        #expect(burst.extras.map(\.id) == ["f1", "f3", "f5"])
        #expect(burst.items.map(\.id) == ["f1", "f2", "f3", "f4", "f5"])
    }

    @Test func burstsWithNothingExtraArentListed() {
        let allPicked = [
            Fixture.burstFrame("a1", burst: "a", seconds: 0, picked: true, cover: true),
            Fixture.burstFrame("a2", burst: "a", seconds: 0.1, picked: true),
        ]
        let single = [Fixture.burstFrame("b1", burst: "b", seconds: 5, cover: true)]
        #expect(PhotoGrouping.burstGroups(allPicked + single).isEmpty)
    }

    @Test func aBurstWithoutPicksKeepsItsBestFrame() throws {
        // With limited access the cover can be out of sight.
        let frames = [
            Fixture.burstFrame("small", seconds: 0, bytes: 1_000_000),
            Fixture.burstFrame("large", seconds: 0.1, bytes: 3_000_000),
            Fixture.burstFrame("medium", seconds: 0.2, bytes: 2_000_000),
        ]
        let burst = try #require(PhotoGrouping.burstGroups(frames).first)
        #expect(burst.keeperIDs == ["large"])
    }

    // MARK: Results

    /// Two favorites and a plain copy; two similar shots; a screenshot; a burst; four videos.
    private var library: [MediaItem] {
        let copies: UInt64 = 0xFFFF_0000_FFFF_0000
        let shots: UInt64 = 0x0F0F_0F0F_F0F0_F0F0
        return [
            Fixture.photo("favorite edited", hash: copies, bytes: 3_000_000, favorite: true, edited: true),
            Fixture.photo("favorite copy", minutes: 60, hash: copies, bytes: 3_000_000, favorite: true),
            Fixture.photo("plain copy", minutes: 120, hash: copies, bytes: 2_000_000),
            Fixture.photo("sharp shot", width: 3024, height: 4032, minutes: 500, hash: shots, bytes: 4_000_000),
            Fixture.photo("blurry shot", width: 3024, height: 4032, minutes: 501, hash: Fixture.flip(shots, bits: Array(0..<6)), bytes: 2_500_000),
            Fixture.photo("unrelated", minutes: 900, hash: 0x1357_9BDF_2468_ACE0),
            Fixture.screenshot("screenshot", bytes: 1_000_000),
            Fixture.burstFrame("frame 1", seconds: 0, picked: true, cover: true),
            Fixture.burstFrame("frame 2", seconds: 0.1, bytes: 1_500_000),
            Fixture.video("big", megabytes: 150),
            Fixture.video("medium", megabytes: 50),
            Fixture.video("tiny", megabytes: 5),
            Fixture.video("recording", megabytes: 200, screenRecording: true),
        ]
    }

    @Test func resultsSortItemsIntoCategories() throws {
        let result = PhotoGrouping.result(items: library)
        let duplicates = try #require(result.duplicates.first)
        #expect(result.duplicates.count == 1)
        #expect(duplicates.keeperIDs == ["favorite edited"])
        #expect(duplicates.items.map(\.id) == ["favorite edited", "favorite copy", "plain copy"])
        #expect(result.similar.map { $0.items.map(\.id) } == [["sharp shot", "blurry shot"]])
        #expect(result.bursts.map { $0.extras.map(\.id) } == [["frame 2"]])
        #expect(result.screenshots.map(\.id) == ["screenshot"])
        #expect(result.largeVideos.map(\.id) == ["big"])
        #expect(result.screenRecordings.map(\.id) == ["recording"])
        #expect(result.otherVideos.map(\.id) == ["medium"])
        #expect(result.photoCount == 8)
        #expect(result.videoCount == 4)
    }

    @Test func extrasAreSuggestedButNeverAFavorite() {
        let result = PhotoGrouping.result(items: library)
        // Screenshots and videos are only ever selected by the person.
        #expect(result.suggestedSelection == ["plain copy", "blurry shot", "frame 2"])
    }

    @Test func totalsCountWhatCouldGo() {
        let result = PhotoGrouping.result(items: library)
        // Both copies, the blurry shot, the extra frame and the screenshot.
        #expect(result.reclaimable(in: .duplicates).bytes == 5_000_000)
        #expect(result.photoReclaimable.bytes == 5_000_000 + 2_500_000 + 1_500_000 + 1_000_000)
        // Large videos and recordings; the other videos aren't counted.
        #expect(result.videoReclaimable.bytes == 350_000_000)
        #expect(!result.photoReclaimable.isEstimated)
        #expect(result.summary == "1 large video and 1 screen recording")
    }

    @Test func summarySaysWhenTheresNothingToCleanUp() {
        let result = PhotoGrouping.result(items: [Fixture.photo("alone", hash: 1), Fixture.video("short", megabytes: 2)])
        #expect(result.summary == "Nothing to clean up")
        #expect(result.photoReclaimable.bytes == 0)
        #expect(result.isEmpty)
    }

    @Test func summaryNamesTheTwoBiggestCategoriesInOrder() {
        var items = library.filter { $0.kind == .photo }
        items.append(Fixture.video("huge", megabytes: 900))
        // Large videos free the most and duplicates next; the summary lists them in category order.
        #expect(PhotoGrouping.result(items: items).summary == "2 duplicates and 1 large video")
    }

    @Test func deletingCopiesUpdatesTheirSet() throws {
        let result = PhotoGrouping.result(items: library)
        let withoutPlain = result.removing(["plain copy"])
        #expect(withoutPlain.duplicates.first?.items.map(\.id) == ["favorite edited", "favorite copy"])
        #expect(withoutPlain.photoCount == result.photoCount - 1)

        // The kept photo went, so the best of the rest is kept now.
        let withoutKeeper = result.removing(["favorite edited"])
        #expect(withoutKeeper.duplicates.first?.keeperIDs == ["favorite copy"])

        let gone = result.removing(["favorite copy", "plain copy", "blurry shot", "frame 2", "big"])
        #expect(gone.duplicates.isEmpty)
        #expect(gone.similar.isEmpty)
        #expect(gone.bursts.isEmpty)
        #expect(gone.largeVideos.isEmpty)
        #expect(gone.videoCount == result.videoCount - 1)
        #expect(gone.photoReclaimable.bytes == 1_000_000)
    }

    @Test func sizesAreNeededOnlyWhereTheyMatter() {
        let items = library
        let needed = Set(PhotoGrouping.itemsNeedingSizes(items, clusters: PhotoGrouping.clusters(of: items)).map(\.id))
        #expect(!needed.contains("unrelated"))
        #expect(needed.isSuperset(of: ["favorite edited", "plain copy", "sharp shot", "screenshot", "frame 1", "frame 2", "tiny", "recording"]))
    }
}
