import SwiftUI

/// The kinds of clutter a scan looks for.
enum PhotoCategory: String, CaseIterable, Identifiable, Sendable {
    case duplicates, similar, screenshots, bursts, largeVideos, screenRecordings

    static let photoCategories: [PhotoCategory] = [.duplicates, .similar, .screenshots, .bursts]
    static let videoCategories: [PhotoCategory] = [.largeVideos, .screenRecordings]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: return "Duplicates"
        case .similar: return "Similar Photos"
        case .screenshots: return "Screenshots"
        case .bursts: return "Bursts"
        case .largeVideos: return "Large Videos"
        case .screenRecordings: return "Screen Recordings"
        }
    }

    var symbol: String {
        switch self {
        case .duplicates: return "square.on.square"
        case .similar: return "photo.stack"
        case .screenshots: return "camera.viewfinder"
        case .bursts: return "square.stack.3d.down.right"
        case .largeVideos: return "video"
        case .screenRecordings: return "record.circle"
        }
    }

    var tint: Color {
        switch self {
        case .duplicates: return Color(red: 0.36, green: 0.40, blue: 0.92)
        case .similar: return MobileSection.photos.tint
        case .screenshots: return Color(red: 0.18, green: 0.55, blue: 0.96)
        case .bursts: return Color(red: 0.96, green: 0.55, blue: 0.13)
        case .largeVideos: return MobileSection.videos.tint
        case .screenRecordings: return Color(red: 0.62, green: 0.36, blue: 0.90)
        }
    }

    /// What the category holds and what's selected at first, for the top of its screen.
    var explanation: String {
        switch self {
        case .duplicates:
            return "Copies of the same photo. In each set the best copy stays: a favorite or an edited one first, then the highest resolution. The other copies are selected, but never a favorite."
        case .similar:
            return "Shots that look almost the same, taken within a few minutes of each other. The best shot of each set stays and the others are selected, but never a favorite."
        case .screenshots:
            return "Screenshots are often needed only for a moment. Nothing is selected: choose the ones you're done with."
        case .bursts:
            return "A burst keeps every frame behind one photo. The frames you or the camera picked stay; the others are selected, but never a favorite."
        case .largeVideos:
            return "Videos of 100 MB or more, biggest first."
        case .screenRecordings:
            return "Recordings of your screen, biggest first."
        }
    }

    var isGrouped: Bool { self == .duplicates || self == .similar || self == .bursts }
    var kind: MediaItem.Kind { self == .largeVideos || self == .screenRecordings ? .video : .photo }

    /// For one line about the whole library: "18 large videos".
    func countText(_ count: Int) -> String {
        switch self {
        case .duplicates: return NumberFormatting.count(count, "duplicate")
        case .similar: return NumberFormatting.count(count, "similar photo")
        case .screenshots: return NumberFormatting.count(count, "screenshot")
        case .bursts: return NumberFormatting.count(count, "burst photo")
        case .largeVideos: return NumberFormatting.count(count, "large video")
        case .screenRecordings: return NumberFormatting.count(count, "screen recording")
        }
    }

    /// For the category's row: "7 extra copies in 5 sets".
    func detailText(candidates: Int, groups: Int) -> String {
        switch self {
        case .duplicates:
            return "\(NumberFormatting.count(candidates, "extra copy", plural: "extra copies")) in \(NumberFormatting.count(groups, "set"))"
        case .similar:
            return "\(NumberFormatting.count(candidates, "extra shot")) in \(NumberFormatting.count(groups, "set"))"
        case .bursts:
            return "\(NumberFormatting.count(candidates, "extra frame")) in \(NumberFormatting.count(groups, "burst"))"
        case .screenshots:
            return NumberFormatting.count(candidates, "screenshot")
        case .largeVideos:
            return NumberFormatting.count(candidates, "video")
        case .screenRecordings:
            return NumberFormatting.count(candidates, "recording")
        }
    }

    /// The noun for a selection in this category: "Delete 3 photos".
    var itemNoun: String { kind == .video ? "video" : "photo" }
}

/// What one scan of the library found.
struct PhotoScanResult: Sendable {
    /// Videos this size or larger are "large".
    static let largeVideoBytes: Int64 = 100_000_000
    /// Smaller videos are listed under the large ones, biggest first, down to this size.
    static let otherVideoMinimumBytes: Int64 = 10_000_000
    static let otherVideoLimit = 25

    var date: Date
    /// Only the photos the person shared with the app (limited access) were checked.
    var isLimited: Bool
    var photoCount: Int
    var videoCount: Int
    /// Photos that couldn't be compared, because there's no copy on this device to look at (they're in iCloud only).
    var uncomparedCount: Int
    var duplicates: [MediaGroup]
    var similar: [MediaGroup]
    var bursts: [MediaGroup]
    /// Newest first.
    var screenshots: [MediaItem]
    /// Biggest first.
    var largeVideos: [MediaItem]
    /// Biggest first.
    var screenRecordings: [MediaItem]
    /// The next-biggest videos below the large-video size, so the biggest ones are easy to find even
    /// without huge videos. Not counted as reclaimable.
    var otherVideos: [MediaItem]

    func groups(in category: PhotoCategory) -> [MediaGroup] {
        switch category {
        case .duplicates: return duplicates
        case .similar: return similar
        case .bursts: return bursts
        default: return []
        }
    }

    /// Everything shown in the category, keepers included.
    func items(in category: PhotoCategory) -> [MediaItem] {
        switch category {
        case .duplicates, .similar, .bursts: return groups(in: category).flatMap(\.items)
        case .screenshots: return screenshots
        case .largeVideos: return largeVideos
        case .screenRecordings: return screenRecordings
        }
    }

    /// What could go: the extras of each group, or everything in a flat category.
    func candidates(in category: PhotoCategory) -> [MediaItem] {
        category.isGrouped ? groups(in: category).flatMap(\.extras) : items(in: category)
    }

    func reclaimable(in category: PhotoCategory) -> MediaByteTotal {
        MediaByteTotal(candidates(in: category))
    }

    var photoReclaimable: MediaByteTotal {
        PhotoCategory.photoCategories.map(reclaimable(in:)).reduce(MediaByteTotal(), +)
    }

    var videoReclaimable: MediaByteTotal {
        PhotoCategory.videoCategories.map(reclaimable(in:)).reduce(MediaByteTotal(), +)
    }

    /// What's selected right after a scan: the extra copies and shots in each duplicate or similar set,
    /// and the burst frames nobody picked (Photos already hides those behind the burst's cover, and
    /// the picked frames stay). Never a favorite. Screenshots and videos start unselected: each is its
    /// own content, so only the person can tell which ones they're done with.
    var suggestedSelection: Set<String> {
        let groups = duplicates + similar + bursts
        return Set(groups.flatMap(\.extras).filter { !$0.isFavorite }.map(\.id))
    }

    /// One line for the Overview and the Clean tab: the two categories that free the most space,
    /// e.g. "1,204 similar photos and 18 large videos".
    var summary: String {
        let found = PhotoCategory.allCases.compactMap { category -> (category: PhotoCategory, count: Int, bytes: Int64)? in
            let candidates = candidates(in: category)
            return candidates.isEmpty ? nil : (category, candidates.count, MediaByteTotal(candidates).bytes)
        }
        guard !found.isEmpty else { return "Nothing to clean up" }
        let order = PhotoCategory.allCases
        let top = found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.count > $1.count }
            .prefix(2)
            .sorted { (order.firstIndex(of: $0.category) ?? 0) < (order.firstIndex(of: $1.category) ?? 0) }
        return top.map { $0.category.countText($0.count) }.joined(separator: " and ")
    }

    var isEmpty: Bool { PhotoCategory.allCases.allSatisfy { candidates(in: $0).isEmpty } && otherVideos.isEmpty }

    /// Every asset the result refers to.
    var allItems: [MediaItem] {
        PhotoCategory.allCases.flatMap { items(in: $0) } + otherVideos
    }

    /// The result after these assets were deleted: groups lose them (and are dropped once nothing is
    /// left to compare), and a group whose kept photo went picks a new best one.
    func removing(_ removed: Set<String>) -> PhotoScanResult {
        guard !removed.isEmpty else { return self }
        var result = self
        let known = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let gone = removed.compactMap { known[$0] }
        result.photoCount = max(0, photoCount - gone.filter { $0.kind == .photo }.count)
        result.videoCount = max(0, videoCount - gone.filter { $0.kind == .video }.count)

        func lookalikes(_ groups: [MediaGroup]) -> [MediaGroup] {
            groups.compactMap { group in
                let left = group.items.filter { !removed.contains($0.id) }
                return left.count >= 2 ? MediaGroup(lookalikes: left) : nil
            }
        }
        result.duplicates = lookalikes(duplicates)
        result.similar = lookalikes(similar)
        result.bursts = bursts.compactMap { group in
            let left = group.items.filter { !removed.contains($0.id) }
            guard left.count >= 2, let identifier = left.first?.burstIdentifier else { return nil }
            let burst = MediaGroup(burst: identifier, frames: left)
            return burst.extras.isEmpty ? nil : burst
        }
        result.screenshots.removeAll { removed.contains($0.id) }
        result.largeVideos.removeAll { removed.contains($0.id) }
        result.screenRecordings.removeAll { removed.contains($0.id) }
        result.otherVideos.removeAll { removed.contains($0.id) }
        return result
    }
}
