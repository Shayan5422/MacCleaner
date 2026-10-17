import Foundation
@testable import MacCleanerMobile

/// Fake asset records (dimensions, dates, hashes, sizes), so grouping runs without PhotoKit.
enum PhotoFixtures {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    static func photo(_ id: String, width: Int = 4032, height: Int = 3024, minutes: Double = 0, hash: UInt64?,
                      luma: UInt8 = 120, detail: DetailHash? = nil, bytes: Int64 = 3_000_000, estimated: Bool = false,
                      favorite: Bool = false, edited: Bool = false) -> MediaItem {
        var item = MediaItem(id: id, kind: .photo, pixelWidth: width, pixelHeight: height,
                             creationDate: start.addingTimeInterval(minutes * 60), modificationDate: start)
        item.fingerprint = hash.map { ImageFingerprint(hash: $0, luma: luma, detail: detail) }
        item.size = MediaSize(bytes: bytes, isEstimated: estimated)
        item.isFavorite = favorite
        item.hasAdjustments = edited
        return item
    }

    static func screenshot(_ id: String, minutes: Double = 0, hash: UInt64 = 0x1234, bytes: Int64 = 900_000) -> MediaItem {
        var item = photo(id, width: 1179, height: 2556, minutes: minutes, hash: hash, bytes: bytes)
        item.isScreenshot = true
        return item
    }

    static func burstFrame(_ id: String, burst: String = "burst", seconds: Double, picked: Bool = false, cover: Bool = false,
                           bytes: Int64 = 2_000_000, favorite: Bool = false) -> MediaItem {
        var item = photo(id, minutes: seconds / 60, hash: 0xABCD, bytes: bytes, favorite: favorite)
        item.burstIdentifier = burst
        item.isBurstPick = picked
        item.representsBurst = cover
        return item
    }

    static func video(_ id: String, megabytes: Double, minutes: Double = 0, screenRecording: Bool = false,
                      estimated: Bool = false) -> MediaItem {
        var item = MediaItem(id: id, kind: .video, pixelWidth: 1920, pixelHeight: 1080,
                             creationDate: start.addingTimeInterval(minutes * 60), modificationDate: start)
        item.duration = 30
        item.isScreenRecording = screenRecording
        item.size = MediaSize(bytes: Int64(megabytes * 1_000_000), isEstimated: estimated)
        return item
    }

    /// `hash` with these bits flipped.
    static func flip(_ hash: UInt64, bits: [Int]) -> UInt64 {
        bits.reduce(hash) { $0 ^ (1 << UInt64($1)) }
    }
}
