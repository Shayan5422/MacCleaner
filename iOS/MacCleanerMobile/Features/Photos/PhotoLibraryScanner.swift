import os
import Photos
import UIKit

/// How far a scan has come, for the progress card.
struct PhotoScanProgress: Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case reading, comparing, measuring, grouping
    }

    var stage: Stage
    var completed = 0
    var total = 0

    var title: String {
        switch stage {
        case .reading: return "Reading your library…"
        case .comparing: return "Comparing photos…"
        case .measuring: return "Measuring sizes…"
        case .grouping: return "Finding duplicates…"
        }
    }

    var message: String {
        switch stage {
        case .reading: return "Looking through your photos and videos"
        case .comparing: return "\(NumberFormatting.count(completed)) of \(NumberFormatting.count(total, "photo")) compared"
        case .measuring: return "\(NumberFormatting.count(completed)) of \(NumberFormatting.count(total, "item")) measured"
        case .grouping: return "Putting copies and similar shots together"
        }
    }

    /// The whole scan's progress. Comparing photos is most of the work on a first scan.
    var fraction: Double? {
        let part = total > 0 ? Double(completed) / Double(total) : 0
        switch stage {
        case .reading: return nil
        case .comparing: return 0.02 + 0.83 * part
        case .measuring: return 0.85 + 0.13 * part
        case .grouping: return 0.98
        }
    }
}

/// Reads the photo library and works out what can be cleaned up. It runs off the main actor, only
/// reads (it never changes the library) and never downloads anything from iCloud: photos are compared
/// by the small thumbnails already on the device.
struct PhotoLibraryScanner: Sendable {
    var cacheURL = PhotoScanCache.defaultURL
    var thresholds = PhotoGrouping.Thresholds.standard
    /// Thumbnails requested at once.
    var thumbnailConcurrency = 6
    /// Assets whose resources are looked up at once.
    var sizeConcurrency = 4
    /// Thumbnails are requested at about this size, in pixels: enough for a 9 × 8 hash, small enough
    /// that Photos serves them from its own thumbnail store.
    var thumbnailSize = CGSize(width: 64, height: 64)

    /// - Parameter isLimited: only the photos the person shared with the app are visible.
    @concurrent
    func scan(isLimited: Bool, progress: @escaping @Sendable (PhotoScanProgress) -> Void) async throws -> PhotoScanResult {
        progress(PhotoScanProgress(stage: .reading))
        var items: [MediaItem] = []
        let library = PhotoLibrarySnapshot.fetch(into: &items)
        var cache = PhotoScanCache.load(from: cacheURL)
        do {
            try Task.checkCancellation()
            let uncompared = try await addFingerprints(to: &items, library: library, cache: &cache, progress: progress)

            progress(PhotoScanProgress(stage: .grouping))
            let clusters = PhotoGrouping.clusters(of: items, thresholds: thresholds)
            try Task.checkCancellation()
            try await addSizes(to: &items, ids: PhotoGrouping.itemsNeedingSizes(items, clusters: clusters).map(\.id),
                               library: library, cache: &cache, progress: progress)

            progress(PhotoScanProgress(stage: .grouping))
            let result = PhotoGrouping.result(items: items, clusters: clusters, date: Date(), isLimited: isLimited,
                                              uncomparedCount: uncompared, thresholds: thresholds)
            // With limited access the rest of the library is only out of sight, so its entries stay.
            if !isLimited { cache.prune(keeping: Set(items.map(\.id))) }
            try? cache.save(to: cacheURL)
            return result
        } catch {
            // Keep what was worked out so far: the next scan picks up from there.
            try? cache.save(to: cacheURL)
            throw error
        }
    }

    // MARK: Fingerprints

    /// Fingerprints every photo that can be compared, from the cache or from a thumbnail. Returns how
    /// many couldn't be compared because no thumbnail is on the device.
    private func addFingerprints(to items: inout [MediaItem], library: PhotoLibrarySnapshot, cache: inout PhotoScanCache,
                                 progress: @escaping @Sendable (PhotoScanProgress) -> Void) async throws -> Int {
        let comparable = items.indices.filter { items[$0].isComparable }
        var pending: [Int] = []
        for index in comparable {
            if let cached = cache.fingerprint(for: items[index].id, modified: items[index].modificationDate) {
                items[index].fingerprint = cached
            } else {
                pending.append(index)
            }
        }

        let total = comparable.count
        var completed = total - pending.count
        var uncompared = 0
        var reporter = ProgressThrottle()
        progress(PhotoScanProgress(stage: .comparing, completed: completed, total: total))

        let manager = PHImageManager.default()
        let size = thumbnailSize
        var queue = pending.makeIterator()
        try await withThrowingTaskGroup(of: (index: Int, fingerprint: ImageFingerprint?).self) { group in
            func enqueue(_ index: Int, into group: inout ThrowingTaskGroup<(index: Int, fingerprint: ImageFingerprint?), Error>) {
                let asset = library.asset(for: items[index].id)
                group.addTask {
                    guard let asset, let image = await Self.thumbnail(of: asset, size: size, manager: manager) else { return (index, nil) }
                    return (index, Self.fingerprint(of: image))
                }
            }
            for _ in 0..<max(1, thumbnailConcurrency) {
                guard let index = queue.next() else { break }
                enqueue(index, into: &group)
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                if let fingerprint = outcome.fingerprint {
                    items[outcome.index].fingerprint = fingerprint
                    cache.store(fingerprint, for: items[outcome.index].id, modified: items[outcome.index].modificationDate)
                } else {
                    uncompared += 1
                }
                if reporter.shouldReport(force: completed == total) {
                    progress(PhotoScanProgress(stage: .comparing, completed: completed, total: total))
                }
                if let index = queue.next() { enqueue(index, into: &group) }
            }
        }
        return uncompared
    }

    /// A small image of the photo from what's on the device; nil when there's nothing to look at
    /// without downloading from iCloud.
    private static func thumbnail(of asset: PHAsset, size: CGSize, manager: PHImageManager) async -> UIImage? {
        // Photos' own small thumbnails are the quickest. A photo without one yet (Photos makes them
        // in the background, and the fast format then reports a missing resource) is rendered small
        // from the original on the device instead.
        if let image = await requestImage(of: asset, size: size, deliveryMode: .fastFormat, manager: manager) { return image }
        return await requestImage(of: asset, size: size, deliveryMode: .highQualityFormat, manager: manager)
    }

    private static func requestImage(of asset: PHAsset, size: CGSize, deliveryMode: PHImageRequestOptionsDeliveryMode,
                                     manager: PHImageManager) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = false
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            // Both delivery modes call back once; the lock makes sure a second call could never resume twice.
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: image) }
            }
        }
    }

    static func fingerprint(of image: UIImage) -> ImageFingerprint? {
        guard let cgImage = image.imageOrientation == .up ? image.cgImage : upright(image) else { return nil }
        return PerceptualHash.fingerprint(of: cgImage)
    }

    /// The image with its orientation applied, so a rotated copy hashes like the original.
    private static func upright(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }

    // MARK: Sizes

    private func addSizes(to items: inout [MediaItem], ids: [String], library: PhotoLibrarySnapshot, cache: inout PhotoScanCache,
                          progress: @escaping @Sendable (PhotoScanProgress) -> Void) async throws {
        let positions = Dictionary(items.indices.map { (items[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending: [Int] = []
        for id in ids {
            guard let index = positions[id] else { continue }
            if let cached = cache.size(for: id, modified: items[index].modificationDate) {
                items[index].size = cached
            } else {
                pending.append(index)
            }
        }

        let total = ids.count
        var completed = total - pending.count
        var reporter = ProgressThrottle()
        progress(PhotoScanProgress(stage: .measuring, completed: completed, total: total))
        var queue = pending.makeIterator()
        try await withThrowingTaskGroup(of: (index: Int, size: MediaSize).self) { group in
            func enqueue(_ index: Int, into group: inout ThrowingTaskGroup<(index: Int, size: MediaSize), Error>) {
                let item = items[index]
                let asset = library.asset(for: item.id)
                group.addTask {
                    (index, asset.map { MediaSizing.measure($0, item: item) } ?? MediaSizing.estimate(for: item))
                }
            }
            for _ in 0..<max(1, sizeConcurrency) {
                guard let index = queue.next() else { break }
                enqueue(index, into: &group)
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                items[outcome.index].size = outcome.size
                cache.store(outcome.size, for: items[outcome.index].id, modified: items[outcome.index].modificationDate)
                if reporter.shouldReport(force: completed == total) {
                    progress(PhotoScanProgress(stage: .measuring, completed: completed, total: total))
                }
                if let index = queue.next() { enqueue(index, into: &group) }
            }
        }
    }
}

/// Reports at most ten times a second.
private struct ProgressThrottle {
    private var last = Date.distantPast

    mutating func shouldReport(force: Bool = false) -> Bool {
        let now = Date()
        guard force || now.timeIntervalSince(last) >= 0.1 else { return false }
        last = now
        return true
    }
}

/// The library's photos and videos as the scan found them, to look assets up again by identifier.
struct PhotoLibrarySnapshot: Sendable {
    private var photos: PHFetchResult<PHAsset>
    private var videos: PHFetchResult<PHAsset>
    /// Where each asset is in `photos` (positive) or `videos` (negative, minus one).
    private var positions: [String: Int]

    /// Photos and videos in the person's own library (not shared albums or synced from a computer,
    /// which apps can't delete), hidden ones excluded, with every frame of a burst. Their records are
    /// added to `items`.
    static func fetch(into items: inout [MediaItem]) -> PhotoLibrarySnapshot {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let photos = PHAsset.fetchAssets(with: .image, options: options)
        let videos = PHAsset.fetchAssets(with: .video, options: options)

        var positions: [String: Int] = [:]
        positions.reserveCapacity(photos.count + videos.count)
        items.reserveCapacity(items.count + photos.count + videos.count)
        for index in 0..<photos.count {
            let asset = photos.object(at: index)
            items.append(item(for: asset))
            positions[asset.localIdentifier] = index
        }
        for index in 0..<videos.count {
            let asset = videos.object(at: index)
            items.append(item(for: asset))
            positions[asset.localIdentifier] = -(index + 1)
        }
        return PhotoLibrarySnapshot(photos: photos, videos: videos, positions: positions)
    }

    func asset(for id: String) -> PHAsset? {
        guard let position = positions[id] else { return nil }
        if position >= 0 {
            return position < photos.count ? photos.object(at: position) : nil
        }
        return -position - 1 < videos.count ? videos.object(at: -position - 1) : nil
    }

    static func item(for asset: PHAsset) -> MediaItem {
        let subtypes = asset.mediaSubtypes
        var item = MediaItem(id: asset.localIdentifier, kind: asset.mediaType == .video ? .video : .photo,
                             pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                             creationDate: asset.creationDate, modificationDate: asset.modificationDate)
        item.duration = asset.mediaType == .video ? asset.duration : 0
        item.isFavorite = asset.isFavorite
        item.hasAdjustments = asset.hasAdjustments
        item.isScreenshot = subtypes.contains(.photoScreenshot)
        item.isScreenRecording = subtypes.contains(.videoScreenRecording)
        item.isLivePhoto = subtypes.contains(.photoLive)
        item.burstIdentifier = asset.burstIdentifier
        item.isBurstPick = !asset.burstSelectionTypes.isDisjoint(with: [.autoPick, .userPick])
        item.representsBurst = asset.representsBurst
        return item
    }
}
