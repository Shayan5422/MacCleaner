import Foundation
import Photos

/// How much space an asset takes: what PhotoKit reports, or an estimate when it doesn't say.
enum MediaSizing {
    /// Typical bytes per pixel of iPhone photos: HEIC is about 0.2, JPEG about 0.35.
    static let photoBytesPerPixel = 0.3
    /// Bytes per pixel and second of iPhone video (HEVC at 30 fps: 1080p is about 1 MB a second, 4K about 4).
    static let videoBytesPerPixelSecond = 0.5
    /// Assumed when Photos doesn't know the dimensions: a 12-megapixel photo and a 1080p video.
    static let fallbackPhotoPixels = 4032 * 3024
    static let fallbackVideoPixels = 1920 * 1080

    /// A guess from the pixels (photos) or the pixels and duration (videos).
    static func estimate(kind: MediaItem.Kind, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval) -> MediaSize {
        let known = pixelWidth > 0 && pixelHeight > 0
        switch kind {
        case .photo:
            let pixels = Double(known ? pixelWidth * pixelHeight : fallbackPhotoPixels)
            return MediaSize(bytes: Int64(pixels * photoBytesPerPixel), isEstimated: true)
        case .video:
            let pixels = Double(known ? pixelWidth * pixelHeight : fallbackVideoPixels)
            let seconds = max(1, duration.isFinite ? duration : 1)
            return MediaSize(bytes: Int64(pixels * videoBytesPerPixelSecond * seconds), isEstimated: true)
        }
    }

    static func estimate(for item: MediaItem) -> MediaSize {
        estimate(kind: item.kind, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, duration: item.duration)
    }

    /// The total of what Photos reports for the item's resources, or `fallback` when it reports nothing.
    static func total(of resourceSizes: [Int64?], fallback: MediaSize) -> MediaSize {
        let known = resourceSizes.compactMap { $0 }.filter { $0 > 0 }
        return known.isEmpty ? fallback : MediaSize(bytes: known.reduce(0, +), isEstimated: false)
    }

    /// Everything deleting the asset frees: the original, the edited version, a Live Photo's movie.
    static func measure(_ asset: PHAsset, item: MediaItem) -> MediaSize {
        let sizes = PHAssetResource.assetResources(for: asset).map(fileSize(of:))
        return total(of: sizes, fallback: estimate(for: item))
    }

    static func fileSize(of resource: PHAssetResource) -> Int64? {
        if #available(iOS 27, *), let size = resource.dataSize {
            return Int64(size)
        }
        // Before iOS 27 the size isn't public API, but PHAssetResource has answered "fileSize" through
        // key-value coding since iOS 9 and photo apps commonly read it. Asking first means an iOS
        // without it falls back to the estimate instead of raising an exception.
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }
}
