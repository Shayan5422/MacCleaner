import Foundation
import Testing
@testable import MacCleanerMobile

/// Sizes: what Photos reports wins; otherwise an estimate, and totals that include one say "about".
struct MediaSizingTests {
    typealias Fixture = PhotoFixtures

    @Test func photosAreEstimatedFromTheirPixels() {
        let size = MediaSizing.estimate(kind: .photo, pixelWidth: 4000, pixelHeight: 3000, duration: 0)
        #expect(size == MediaSize(bytes: 3_600_000, isEstimated: true))
    }

    @Test func videosAreEstimatedFromPixelsAndLength() {
        let minute = MediaSizing.estimate(kind: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 60)
        #expect(minute == MediaSize(bytes: 62_208_000, isEstimated: true))
        let fourK = MediaSizing.estimate(kind: .video, pixelWidth: 3840, pixelHeight: 2160, duration: 60)
        #expect(fourK.bytes == minute.bytes * 4)
        // A clip without a length still counts as a second.
        #expect(MediaSizing.estimate(kind: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 0).bytes == 1_036_800)
    }

    @Test func unknownDimensionsUseTypicalOnes() {
        #expect(MediaSizing.estimate(kind: .photo, pixelWidth: 0, pixelHeight: 0, duration: 0).bytes == 3_657_830)
        #expect(MediaSizing.estimate(kind: .video, pixelWidth: 0, pixelHeight: 3024, duration: 10).bytes == 10_368_000)
    }

    @Test func reportedSizesWinOverTheEstimate() {
        let fallback = MediaSize(bytes: 42, isEstimated: true)
        #expect(MediaSizing.total(of: [1_000, nil, 500], fallback: fallback) == MediaSize(bytes: 1_500, isEstimated: false))
        #expect(MediaSizing.total(of: [nil, nil], fallback: fallback) == fallback)
        #expect(MediaSizing.total(of: [], fallback: fallback) == fallback)
        #expect(MediaSizing.total(of: [0], fallback: fallback) == fallback)
    }

    @Test func totalsSayAboutWhenAnyPartIsEstimated() {
        let exact = MediaByteTotal([Fixture.photo("a", hash: 1, bytes: 1_000_000), Fixture.photo("b", hash: 1, bytes: 2_000_000)])
        #expect(!exact.isEstimated)
        #expect(exact.text == ByteFormatting.string(3_000_000))
        let rough = MediaByteTotal([Fixture.photo("a", hash: 1, bytes: 1_000_000),
                                    Fixture.photo("b", hash: 1, bytes: 2_000_000, estimated: true)])
        #expect(rough.isEstimated)
        #expect(rough.text == "about \(ByteFormatting.string(3_000_000))")
        #expect((exact + rough).isEstimated)
        // Nothing to be "about".
        #expect(MediaByteTotal(bytes: 0, isEstimated: true).text == ByteFormatting.string(0))
    }

    @Test func resultTotalsCarryTheEstimate() {
        let result = PhotoGrouping.result(items: [
            Fixture.video("measured", megabytes: 300),
            Fixture.video("guessed", megabytes: 120, estimated: true),
        ])
        #expect(result.videoReclaimable == MediaByteTotal(bytes: 420_000_000, isEstimated: true))
        #expect(result.photoReclaimable == MediaByteTotal())
        #expect(result.largeVideos.map(\.id) == ["measured", "guessed"])
    }
}
