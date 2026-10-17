import CoreGraphics
import Foundation
import Testing
@testable import MacCleanerMobile

/// dHash on synthetic pictures. The counts are the tuning behind `PhotoGrouping.Thresholds`, with a
/// little room so they don't depend on Core Graphics rounding.
struct PerceptualHashTests {
    static let seeds: [UInt64] = (1...40).map { UInt64($0) * 7919 }
    static let originals: [UInt64: ImageFingerprint] = Dictionary(uniqueKeysWithValues: seeds.compactMap { seed in
        PerceptualHash.fingerprint(of: SyntheticImages.scene(seed: seed, width: 320, height: 240)).map { (seed, $0) }
    })

    let thresholds = PhotoGrouping.Thresholds.standard

    private func fingerprint(_ seed: UInt64, _ variation: SyntheticImages.Variation = .none,
                             width: Int = 320, height: Int = 240) throws -> ImageFingerprint {
        try #require(PerceptualHash.fingerprint(of: SyntheticImages.scene(seed: seed, width: width, height: height, variation: variation)))
    }

    /// How many of the 40 scenes stay within `limit` bits of the original after `variation`.
    private func countWithin(_ limit: Int, _ variation: SyntheticImages.Variation) throws -> Int {
        try Self.seeds.filter { seed in
            let original = try #require(Self.originals[seed])
            return try original.distance(to: fingerprint(seed, variation)) <= limit
        }.count
    }

    @Test func identicalImagesHashTheSame() throws {
        #expect(Self.originals.count == Self.seeds.count)
        for seed in Self.seeds.prefix(10) {
            #expect(try fingerprint(seed) == Self.originals[seed])
        }
    }

    @Test func smallerCopiesStayWithinTheDuplicateDistance() throws {
        // A half-size copy, like a photo saved again from a message.
        let close = try Self.seeds.filter { seed in
            let original = try #require(Self.originals[seed])
            return try original.distance(to: fingerprint(seed, width: 160, height: 120)) <= thresholds.duplicateDistance
        }
        #expect(close.count >= 36)
    }

    @Test func brighterOrDarkerCopiesStayWithinTheDuplicateDistance() throws {
        #expect(try countWithin(thresholds.duplicateDistance, .brightness(1.10)) >= 36)
        #expect(try countWithin(thresholds.duplicateDistance, .brightness(0.85)) >= 36)
    }

    @Test func noiseCropsAndSmallMovesStayWithinTheSimilarDistance() throws {
        #expect(try countWithin(thresholds.similarDistance, .noise(12)) >= 38)
        #expect(try countWithin(thresholds.similarDistance, .crop(0.02)) >= 38)
        #expect(try countWithin(thresholds.similarDistance, .crop(0.05)) >= 36)
        #expect(try countWithin(thresholds.similarDistance, .shift(0.03)) >= 34)
        #expect(try countWithin(thresholds.similarDistance, .moveSubject(0.10)) >= 36)
    }

    @Test func biggerChangesLeaveTheSimilarDistance() throws {
        // A camera moved by a tenth of the frame is a different picture.
        #expect(try countWithin(thresholds.similarDistance, .shift(0.10)) <= 8)
    }

    @Test func differentImagesAreFarApart() throws {
        let prints = Self.seeds.compactMap { Self.originals[$0] }
        var distances: [Int] = []
        for first in prints.indices {
            for second in prints.indices where second > first {
                distances.append(prints[first].distance(to: prints[second]))
            }
        }
        #expect(distances.count == 780)
        #expect(distances.allSatisfy { $0 > thresholds.duplicateDistance })
        #expect(distances.filter { $0 <= thresholds.similarDistance }.count <= distances.count / 100)
        #expect(distances.sorted()[distances.count / 2] >= 24)
    }

    @Test func copiesAgreeInDetail() throws {
        for variation in [SyntheticImages.Variation.noise(4), .brightness(1.10)] {
            let close = try Self.seeds.filter { seed in
                let original = try #require(Self.originals[seed]?.detail)
                let copy = try #require(fingerprint(seed, variation).detail)
                return original.distance(to: copy) <= thresholds.duplicateDetailDistance
            }
            #expect(close.count >= 38)
        }
        let halfSize = try Self.seeds.filter { seed in
            let original = try #require(Self.originals[seed]?.detail)
            return try original.distance(to: #require(fingerprint(seed, width: 160, height: 120).detail)) <= thresholds.duplicateDetailDistance
        }
        #expect(halfSize.count >= 38)
    }

    @Test func texturesThatLookAlikeAtNineByEightDifferInDetail() throws {
        let seeds: [UInt64] = (1...30).map { UInt64($0) * 104_729 }
        let prints = try seeds.map { try #require(PerceptualHash.fingerprint(of: SyntheticImages.texture(seed: $0))) }
        var lookAlikes = 0
        for first in prints.indices {
            for second in prints.indices where second > first && prints[first].distance(to: prints[second]) <= thresholds.duplicateDistance {
                lookAlikes += 1
                let detail = try #require(prints[first].detail).distance(to: #require(prints[second].detail))
                #expect(detail > thresholds.duplicateDetailDistance * 4)
            }
        }
        // The 64-bit hash alone would call many of these different textures copies.
        #expect(lookAlikes >= 50)

        // A real copy of a texture still agrees in detail.
        for seed in seeds.prefix(10) {
            let original = try #require(PerceptualHash.fingerprint(of: SyntheticImages.texture(seed: seed))?.detail)
            let copy = try #require(PerceptualHash.fingerprint(of: SyntheticImages.texture(seed: seed, width: 160, height: 120, variation: .noise(4)))?.detail)
            #expect(original.distance(to: copy) <= thresholds.duplicateDetailDistance)
        }
    }

    @Test func detailBitsCountOnlyWhereTheyAreClearCut() {
        // Cells falling by 10 levels in the first row (clear), by 1 level in the second (a near-tie).
        var cells = [Int](repeating: 100, count: PerceptualHash.detailColumns * PerceptualHash.detailRows)
        for column in 0..<PerceptualHash.detailColumns {
            cells[column] = 300 - column * 10
            cells[PerceptualHash.detailColumns + column] = 300 - column
        }
        let detail = PerceptualHash.detailHash(cellSums: cells, pixelsPerCell: 1)
        #expect(detail.bits[0] == 0xFFFF_FFFF_0000_0000)
        #expect(detail.strong[0] == 0xFFFF_0000_0000_0000)
        #expect(detail.bits[1...].allSatisfy { $0 == 0 } && detail.strong[1...].allSatisfy { $0 == 0 })

        // A flipped near-tie doesn't count; a flipped clear-cut bit does.
        var nearTieFlipped = detail
        nearTieFlipped.bits[0] ^= 1 << 47
        nearTieFlipped.strong[0] = detail.strong[0]
        #expect(detail.distance(to: nearTieFlipped) == 0)
        var clearFlipped = detail
        clearFlipped.bits[0] ^= 1 << 63
        #expect(detail.distance(to: clearFlipped) == 1)
    }

    @Test func flatImagesAreToldApartByBrightness() throws {
        let black = try #require(PerceptualHash.fingerprint(of: SyntheticImages.flat(gray: 0.05)))
        let white = try #require(PerceptualHash.fingerprint(of: SyntheticImages.flat(gray: 0.95)))
        #expect(black.hash == 0 && white.hash == 0)
        #expect(black.luma < 40 && white.luma > 215)
        let dark = PhotoFixtures.photo("dark", hash: black.hash, luma: black.luma)
        let bright = PhotoFixtures.photo("bright", hash: white.hash, luma: white.luma)
        #expect(!PhotoGrouping.isDuplicate(dark, bright))
        #expect(PhotoGrouping.isDuplicate(dark, PhotoFixtures.photo("also dark", hash: 0, luma: black.luma + 10)))
    }

    @Test func eachBitComparesACellWithItsRightNeighbor() {
        // Brightness falls from left to right in every row: every bit is set.
        let falling = (0..<8).flatMap { _ in (0..<9).map { 900 - $0 * 100 } }
        #expect(PerceptualHash.fingerprint(cellSums: falling, pixelsPerCell: 1).hash == .max)
        let rising = (0..<8).flatMap { _ in (0..<9).map { $0 * 10 } }
        #expect(PerceptualHash.fingerprint(cellSums: rising, pixelsPerCell: 1).hash == 0)
        // Only the top row falls: the eight most significant bits.
        let topRow = (0..<8).flatMap { row in (0..<9).map { row == 0 ? 90 - $0 * 10 : 5 } }
        #expect(PerceptualHash.fingerprint(cellSums: topRow, pixelsPerCell: 1).hash == 0xFF00_0000_0000_0000)
    }

    @Test func lumaIsTheAverageBrightness() {
        let cells = [Int](repeating: 64 * 100, count: 72)
        #expect(PerceptualHash.fingerprint(cellSums: cells, pixelsPerCell: 64).luma == 100)
    }

    @Test func hammingDistanceCountsDifferingBits() {
        #expect(PerceptualHash.hammingDistance(0, 0) == 0)
        #expect(PerceptualHash.hammingDistance(0, .max) == 64)
        #expect(PerceptualHash.hammingDistance(0b1011, 0b0110) == 3)
        #expect(PerceptualHash.hammingDistance(0x8000_0000_0000_0001, 1) == 1)
        let first = ImageFingerprint(hash: 0xDEAD_BEEF, luma: 1)
        let second = ImageFingerprint(hash: 0xBEEF_DEAD, luma: 9)
        #expect(first.distance(to: second) == second.distance(to: first))
        #expect(first.distance(to: first) == 0)
    }
}
