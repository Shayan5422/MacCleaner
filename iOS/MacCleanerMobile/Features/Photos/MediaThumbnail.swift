import Photos
import SwiftUI

/// Loads thumbnails and previews from the photo library for the screens.
@MainActor
final class MediaImageLoader {
    static let shared = MediaImageLoader()

    private let manager = PHCachingImageManager()
    private var assets: [String: PHAsset] = [:]

    func asset(for id: String) -> PHAsset? {
        if let asset = assets[id] { return asset }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        assets[id] = asset
        return asset
    }

    /// Looks up many assets in one go, for a screen that's about to show them.
    func prefetch(_ ids: [String]) {
        let missing = ids.filter { assets[$0] == nil }
        guard !missing.isEmpty else { return }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        for index in 0..<found.count {
            let asset = found.object(at: index)
            assets[asset.localIdentifier] = asset
        }
    }

    /// After a scan the assets may have changed, so they're looked up again.
    func forgetAssets() {
        assets = [:]
    }

    /// A quick, rough image first and then a sharp one. Without network access only what's on the
    /// device is used; previews may fetch a screen-sized version from iCloud (never the original).
    func images(for id: String, pixelSize: CGSize, contentMode: PHImageContentMode, allowsNetwork: Bool = false) -> AsyncStream<UIImage> {
        guard let asset = asset(for: id) else { return AsyncStream { $0.finish() } }
        return Self.request(asset, manager: manager, pixelSize: pixelSize, contentMode: contentMode, allowsNetwork: allowsNetwork)
    }

    /// Outside the main actor: Photos calls the handler on the calling thread or on the main thread.
    private nonisolated static func request(_ asset: PHAsset, manager: PHCachingImageManager, pixelSize: CGSize,
                                            contentMode: PHImageContentMode, allowsNetwork: Bool) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowsNetwork
            let requestID = manager.requestImage(for: asset, targetSize: pixelSize, contentMode: contentMode, options: options) { image, info in
                if let image { continuation.yield(image) }
                if (info?[PHImageResultIsDegradedKey] as? Bool) != true { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(requestID) }
        }
    }
}

/// A photo or video from the library, loaded when it appears.
struct MediaThumbnail: View {
    var id: String
    /// The longest side the image is shown at, in points.
    var points: CGFloat
    var contentMode: ContentMode = .fill
    var allowsNetwork = false

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if contentMode == .fill {
                Rectangle().fill(Color(.tertiarySystemFill))
            }
        }
        .task(id: "\(id)@\(Int(points))") {
            let side = max(1, points * displayScale)
            let stream = MediaImageLoader.shared.images(for: id, pixelSize: CGSize(width: side, height: side),
                                                        contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
                                                        allowsNetwork: allowsNetwork)
            for await next in stream { image = next }
        }
        .accessibilityHidden(true)
    }
}

/// A square thumbnail that fills its cell, cropped like the Photos grid.
struct MediaSquareThumbnail: View {
    var id: String
    var points: CGFloat = 130

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { MediaThumbnail(id: id, points: points) }
            .clipped()
            .contentShape(Rectangle())
    }
}
