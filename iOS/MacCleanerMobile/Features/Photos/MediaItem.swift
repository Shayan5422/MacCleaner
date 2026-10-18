import Foundation

/// What a scan knows about one photo or video, copied out of PhotoKit so that grouping, totals and
/// selection work without it (and in tests).
struct MediaItem: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case photo, video
    }

    /// The asset's `localIdentifier`.
    var id: String
    var kind: Kind
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date?
    /// Seconds; zero for photos.
    var duration: TimeInterval = 0
    var isFavorite = false
    /// Edited in Photos or another app.
    var hasAdjustments = false
    var isScreenshot = false
    var isScreenRecording = false
    var isLivePhoto = false
    /// Frames of one burst share this identifier.
    var burstIdentifier: String?
    /// The camera suggested this frame of a burst, or the person picked it.
    var isBurstPick = false
    /// The frame Photos shows for the whole burst.
    var representsBurst = false
    /// Everything deleting the asset would free: the photo or video, its edited version and a Live Photo's movie.
    var size = MediaSize.unknown
    /// Set for photos the scan could compare.
    var fingerprint: ImageFingerprint?

    var pixelCount: Int { pixelWidth * pixelHeight }

    /// A frame of a burst that the library hides behind the burst's cover photo.
    var isHiddenBurstFrame: Bool { burstIdentifier != nil && !representsBurst }

    /// Whether the scan compares this photo with others for duplicates and similar shots. Screenshots
    /// and burst frames have their own categories: screenshots of one app look alike to a 64-bit hash
    /// without being copies of each other.
    var isComparable: Bool { kind == .photo && !isScreenshot && !isHiddenBurstFrame }
}

/// The size of an asset on disk.
struct MediaSize: Sendable, Hashable, Codable {
    var bytes: Int64
    /// Photos didn't report the size, so it's worked out from the pixels or the duration.
    var isEstimated: Bool

    static let unknown = MediaSize(bytes: 0, isEstimated: true)

    /// "2.4 MB", or "about 2.4 MB" for an estimate.
    var text: String { MediaByteTotal(bytes: bytes, isEstimated: isEstimated).text }
}

/// A sum of sizes that remembers whether any part of it was estimated.
struct MediaByteTotal: Sendable, Hashable {
    var bytes: Int64 = 0
    var isEstimated = false

    init(bytes: Int64 = 0, isEstimated: Bool = false) {
        self.bytes = bytes
        self.isEstimated = isEstimated
    }

    init<Items: Sequence>(_ items: Items) where Items.Element == MediaItem {
        for item in items { add(item.size) }
    }

    mutating func add(_ size: MediaSize) {
        bytes += size.bytes
        isEstimated = isEstimated || size.isEstimated
    }

    static func + (lhs: MediaByteTotal, rhs: MediaByteTotal) -> MediaByteTotal {
        MediaByteTotal(bytes: lhs.bytes + rhs.bytes, isEstimated: lhs.isEstimated || rhs.isEstimated)
    }

    /// "1.2 GB", or "about 1.2 GB" when part of it is an estimate.
    var text: String {
        let formatted = ByteFormatting.string(bytes)
        return isEstimated && bytes > 0 ? "about \(formatted)" : formatted
    }
}

/// Photos that belong together: copies of one photo, shots taken moments apart, or the frames of a burst.
struct MediaGroup: Identifiable, Sendable, Hashable {
    var id: String
    /// Keepers first, then the others by date.
    var items: [MediaItem]
    /// What stays when the person accepts the suggestion: the best photo, or the frames of a burst
    /// the camera or the person picked.
    var keeperIDs: Set<String>

    /// Copies or look-alikes: the best one is kept (see `PhotoKeepRanking`).
    init(lookalikes: [MediaItem]) {
        let best = PhotoKeepRanking.best(of: lookalikes)
        let others = lookalikes.filter { $0.id != best?.id }.sorted(by: MediaItem.chronologically)
        items = (best.map { [$0] } ?? []) + others
        keeperIDs = best.map { [$0.id] } ?? []
        id = "lookalikes:" + (best?.id ?? "")
    }

    /// The frames of one burst. Frames the camera suggested or the person picked are kept, and so is
    /// the cover; if nothing was picked, the best frame is.
    init(burst identifier: String, frames: [MediaItem]) {
        var keepers = Set(frames.filter { $0.isBurstPick || $0.representsBurst }.map(\.id))
        if keepers.isEmpty, let best = PhotoKeepRanking.best(of: frames) { keepers = [best.id] }
        keeperIDs = keepers
        items = frames.sorted(by: MediaItem.chronologically)
        id = "burst:" + identifier
    }

    /// The items the suggestion would delete.
    var extras: [MediaItem] { items.filter { !keeperIDs.contains($0.id) } }

    var date: Date? { items.compactMap(\.creationDate).min() }
}

extension MediaItem {
    /// Oldest first; items without a date last; the identifier breaks ties so the order never changes.
    static func chronologically(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }

    /// Newest first, for screenshots and recordings.
    static func newestFirst(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }

    /// Biggest first, for videos.
    static func largestFirst(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        lhs.size.bytes != rhs.size.bytes ? lhs.size.bytes > rhs.size.bytes : newestFirst(lhs, rhs)
    }
}

/// Which photo of a group to keep.
enum PhotoKeepRanking {
    /// Whether `lhs` is the better one to keep: a favorite first, then an edited photo, more pixels, a
    /// larger file, and finally the older one (usually the original the copies were made from).
    static func isBetter(_ lhs: MediaItem, than rhs: MediaItem) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.hasAdjustments != rhs.hasAdjustments { return lhs.hasAdjustments }
        if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
        if lhs.size.bytes != rhs.size.bytes { return lhs.size.bytes > rhs.size.bytes }
        return MediaItem.chronologically(lhs, rhs)
    }

    static func best(of items: [MediaItem]) -> MediaItem? {
        items.min { isBetter($0, than: $1) }
    }

    static func ranked(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { isBetter($0, than: $1) }
    }
}
