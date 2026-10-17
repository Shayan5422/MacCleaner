import Foundation

/// Finds duplicates, similar shots and bursts among scanned items. Works on `MediaItem`s only, so it
/// runs in tests without PhotoKit.
enum PhotoGrouping {
    /// Tuned on synthetic pictures (see PerceptualHashTests): copies that are re-rendered, up to 15%
    /// brighter or darker, or slightly noisy stay within 3 bits; shots of one scene a few percent
    /// apart (camera moved, 5% crop, subject moved) within 10; unrelated scenes average 32 and never
    /// came within 5. Different textures can come within 3 bits too, but differ in 77 or more bits of
    /// the detail hash, where copies differ in at most 3.
    struct Thresholds: Sendable, Equatable {
        /// Most bits two copies of one photo may differ in. Copies also need the same pixel size.
        var duplicateDistance = 3
        /// Most clear-cut bits of the detail hash two copies may differ in.
        var duplicateDetailDistance = 6
        /// Most bits two similar shots may differ in.
        var similarDistance = 10
        /// Similar shots are taken at most this many seconds apart.
        var similarWindow: TimeInterval = 180
        /// Most the average brightness (0…255) of two copies may differ. The hash ignores brightness,
        /// so this keeps a black frame from matching a white one.
        var duplicateLumaTolerance = 32
        var similarLumaTolerance = 48

        static let standard = Thresholds()
    }

    /// Who belongs together, by asset identifier.
    struct Clusters: Sendable, Equatable {
        var duplicates: [[String]] = []
        var similar: [[String]] = []

        var memberIDs: Set<String> { Set((duplicates + similar).flatMap { $0 }) }
    }

    static func clusters(of items: [MediaItem], thresholds: Thresholds = .standard) -> Clusters {
        let duplicates = duplicateClusters(items, thresholds: thresholds)
        let taken = Set(duplicates.flatMap { $0 }.map(\.id))
        let similar = similarClusters(items.filter { !taken.contains($0.id) }, thresholds: thresholds)
        return Clusters(duplicates: duplicates.map { $0.map(\.id) }, similar: similar.map { $0.map(\.id) })
    }

    static func isDuplicate(_ first: MediaItem, _ second: MediaItem, thresholds: Thresholds = .standard) -> Bool {
        guard let one = first.fingerprint, let other = second.fingerprint,
              first.pixelWidth == second.pixelWidth, first.pixelHeight == second.pixelHeight,
              one.distance(to: other) <= thresholds.duplicateDistance,
              abs(Int(one.luma) - Int(other.luma)) <= thresholds.duplicateLumaTolerance else { return false }
        guard let detail = one.detail, let otherDetail = other.detail else { return true }
        return detail.distance(to: otherDetail) <= thresholds.duplicateDetailDistance
    }

    static func isSimilar(_ first: MediaItem, _ second: MediaItem, thresholds: Thresholds = .standard) -> Bool {
        guard let one = first.fingerprint, let other = second.fingerprint,
              let firstDate = first.creationDate, let secondDate = second.creationDate else { return false }
        return abs(firstDate.timeIntervalSince(secondDate)) <= thresholds.similarWindow
            && one.distance(to: other) <= thresholds.similarDistance
            && abs(Int(one.luma) - Int(other.luma)) <= thresholds.similarLumaTolerance
    }

    /// Copies: the same pixel size and nearly the same hash, taken at any time. Every photo in a set is
    /// a copy of every other one; a chain of small differences (a time-lapse, frames of a video saved
    /// as photos) doesn't make the first and the last photo copies of each other.
    static func duplicateClusters(_ items: [MediaItem], thresholds: Thresholds = .standard) -> [[MediaItem]] {
        // Oldest first, so the original starts its set and later copies join it.
        let candidates = items
            .filter { $0.isComparable && $0.fingerprint != nil && $0.pixelCount > 0 }
            .sorted(by: MediaItem.chronologically)
        let neighbors = duplicateNeighbors(candidates, thresholds: thresholds)

        var groups: [[Int]] = []
        var groupOf = [Int?](repeating: nil, count: candidates.count)
        for index in candidates.indices where !neighbors[index].isEmpty {
            // Only a set that already holds one of its copies can take this photo, and only if every
            // member is a copy of it.
            var best: (group: Int, distance: Int)?
            for group in Set(neighbors[index].compactMap { groupOf[$0] })
            where groups[group].allSatisfy({ neighbors[index].contains($0) }) {
                let farthest = groups[group].compactMap { member in
                    candidates[member].fingerprint.flatMap { candidates[index].fingerprint?.distance(to: $0) }
                }.max() ?? 0
                // The closest set wins; the older set breaks a tie, so the result never depends on hashing order.
                if let current = best, (current.distance, current.group) <= (farthest, group) { continue }
                best = (group, farthest)
            }
            if let best {
                groups[best.group].append(index)
                groupOf[index] = best.group
            } else {
                groupOf[index] = groups.count
                groups.append([index])
            }
        }
        return groups.filter { $0.count > 1 }.map { $0.map { candidates[$0] } }
    }

    /// For each photo, the others that count as copies of it. Hashes at most d bits apart agree exactly
    /// on at least one of d + 1 slices of the 64 bits, so only photos of the same size that share a
    /// slice need a closer look.
    private static func duplicateNeighbors(_ candidates: [MediaItem], thresholds: Thresholds) -> [Set<Int>] {
        var bySize: [PixelSize: [Int]] = [:]
        for (index, item) in candidates.enumerated() {
            bySize[PixelSize(width: item.pixelWidth, height: item.pixelHeight), default: []].append(index)
        }
        let sliceCount = min(64, max(1, thresholds.duplicateDistance + 1))
        var neighbors = [Set<Int>](repeating: [], count: candidates.count)
        for indices in bySize.values where indices.count > 1 {
            var buckets: [SliceKey: [Int]] = [:]
            for index in indices {
                guard let hash = candidates[index].fingerprint?.hash else { continue }
                for slice in 0..<sliceCount {
                    buckets[SliceKey(slice: slice, bits: bits(of: hash, slice: slice, of: sliceCount)), default: []].append(index)
                }
            }
            for bucket in buckets.values where bucket.count > 1 {
                for (position, first) in bucket.enumerated() {
                    for second in bucket[(position + 1)...]
                    where !neighbors[first].contains(second) && isDuplicate(candidates[first], candidates[second], thresholds: thresholds) {
                        neighbors[first].insert(second)
                        neighbors[second].insert(first)
                    }
                }
            }
        }
        return neighbors
    }

    /// Shots taken within `similarWindow` of each other whose hashes are all within `similarDistance`
    /// of each other. Every pair has to match, not just neighbors, so a slowly changing series (a walk,
    /// a sunset) never turns into one long group where all but one photo would be selected.
    static func similarClusters(_ items: [MediaItem], thresholds: Thresholds = .standard) -> [[MediaItem]] {
        let candidates = items
            .filter { $0.isComparable && $0.fingerprint != nil && $0.creationDate != nil }
            .sorted(by: MediaItem.chronologically)
        var open: [[MediaItem]] = []
        var finished: [[MediaItem]] = []
        for item in candidates {
            guard let date = item.creationDate, let fingerprint = item.fingerprint else { continue }
            // A group whose first shot is too long ago can't take this photo or any later one.
            var stillOpen: [[MediaItem]] = []
            for group in open {
                if let start = group.first?.creationDate, date.timeIntervalSince(start) > thresholds.similarWindow {
                    if group.count > 1 { finished.append(group) }
                } else {
                    stillOpen.append(group)
                }
            }
            open = stillOpen

            var best: (index: Int, distance: Int)?
            for (index, group) in open.enumerated() where group.allSatisfy({ isSimilar($0, item, thresholds: thresholds) }) {
                let farthest = group.compactMap { $0.fingerprint?.distance(to: fingerprint) }.max() ?? 0
                if farthest < (best?.distance ?? .max) { best = (index, farthest) }
            }
            if let best {
                open[best.index].append(item)
            } else {
                open.append([item])
            }
        }
        return finished + open.filter { $0.count > 1 }
    }

    /// Bursts that have frames nobody picked.
    static func burstGroups(_ items: [MediaItem]) -> [MediaGroup] {
        let frames = Dictionary(grouping: items.filter { $0.kind == .photo && $0.burstIdentifier != nil }) { $0.burstIdentifier ?? "" }
        return frames.compactMap { identifier, frames in
            guard frames.count > 1 else { return nil }
            let group = MediaGroup(burst: identifier, frames: frames)
            return group.extras.isEmpty ? nil : group
        }
    }

    /// Items whose size the result needs: members of a group (the keeper is picked partly by size),
    /// burst frames, screenshots and every video (to find the large ones).
    static func itemsNeedingSizes(_ items: [MediaItem], clusters: Clusters) -> [MediaItem] {
        let members = clusters.memberIDs
        let bursts = Set(burstGroups(items).flatMap(\.items).map(\.id))
        return items.filter { $0.kind == .video || $0.isScreenshot || members.contains($0.id) || bursts.contains($0.id) }
    }

    /// The result from items whose fingerprints and sizes are known.
    static func result(items: [MediaItem], clusters: Clusters? = nil, date: Date = Date(), isLimited: Bool = false,
                       uncomparedCount: Int = 0, thresholds: Thresholds = .standard) -> PhotoScanResult {
        let clusters = clusters ?? self.clusters(of: items, thresholds: thresholds)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func lookalikes(_ clusters: [[String]]) -> [MediaGroup] {
            clusters.map { MediaGroup(lookalikes: $0.compactMap { byID[$0] }) }
                .filter { $0.items.count > 1 }
                .sorted(by: newestGroupFirst)
        }

        let photos = items.filter { $0.kind == .photo }
        let videos = items.filter { $0.kind == .video }
        let otherVideos = videos.filter { !$0.isScreenRecording }.sorted(by: MediaItem.largestFirst)
        return PhotoScanResult(
            date: date,
            isLimited: isLimited,
            photoCount: photos.filter { !$0.isHiddenBurstFrame }.count,
            videoCount: videos.count,
            uncomparedCount: uncomparedCount,
            duplicates: lookalikes(clusters.duplicates),
            similar: lookalikes(clusters.similar),
            bursts: burstGroups(photos).sorted(by: newestGroupFirst),
            screenshots: photos.filter(\.isScreenshot).sorted(by: MediaItem.newestFirst),
            largeVideos: otherVideos.filter { $0.size.bytes >= PhotoScanResult.largeVideoBytes },
            screenRecordings: videos.filter(\.isScreenRecording).sorted(by: MediaItem.largestFirst),
            otherVideos: Array(otherVideos
                .filter { $0.size.bytes < PhotoScanResult.largeVideoBytes && $0.size.bytes >= PhotoScanResult.otherVideoMinimumBytes }
                .prefix(PhotoScanResult.otherVideoLimit))
        )
    }

    private static func newestGroupFirst(_ lhs: MediaGroup, _ rhs: MediaGroup) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }

    private static func bits(of hash: UInt64, slice: Int, of sliceCount: Int) -> UInt64 {
        let start = 64 * slice / sliceCount
        let end = 64 * (slice + 1) / sliceCount
        let width = end - start
        let mask: UInt64 = width >= 64 ? .max : (1 << UInt64(width)) - 1
        return (hash >> UInt64(start)) & mask
    }

    private struct PixelSize: Hashable {
        var width: Int
        var height: Int
    }

    private struct SliceKey: Hashable {
        var slice: Int
        var bits: UInt64
    }
}
