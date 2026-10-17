import Foundation
import Photos

/// What the app may see of the photo library.
enum PhotoAccess: Sendable, Equatable {
    case notDetermined, full, limited, denied, restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }

    static var current: PhotoAccess {
        PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    var canRead: Bool { self == .full || self == .limited }
}

/// Talks to the photo library outside the main actor: PhotoKit runs change blocks and calls back on
/// its own queues, so these closures mustn't belong to the main actor.
enum PhotoLibraryEditor {
    /// Asks for read and write access. iOS shows its prompt only the first time.
    @concurrent
    static func requestAccess() async -> PhotoAccess {
        PhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    /// Moves the assets to Recently Deleted. iOS asks the person to confirm first, and this throws
    /// `PHPhotosError.userCancelled` when they don't.
    @concurrent
    static func delete(_ ids: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }

    /// The ones of these assets that are still in the library (and visible to the app).
    @concurrent
    static func existing(_ ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
        }
        return found
    }
}

/// Calls back when the library changes elsewhere: in Photos, in another app, or in the limited selection.
final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

/// Where deleted photos wait, in the words of this version of Photos.
enum PhotosRecentlyDeleted {
    static let days = 30

    /// iOS 17 lists it under Albums; iOS 18 under Utilities on the single library page; from iOS 26,
    /// Photos has a Collections tab again, and Utilities is in it.
    static func location(systemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        switch systemMajorVersion {
        case ..<18: return "Photos › Albums › Recently Deleted"
        case ..<26: return "Photos › Utilities › Recently Deleted"
        default: return "Photos › Collections › Utilities › Recently Deleted"
        }
    }
}
