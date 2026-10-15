import Darwin
import Foundation

/// Removes the local copy of cloud files while keeping them in the cloud
/// ("Remove Download" in Finder). Nothing is deleted: the file stays in the
/// provider's storage and on other devices, and downloads again when opened.
///
/// Uses `FileManager.evictUbiquitousItem(at:)`, which works for iCloud Drive
/// and for File Provider domains that support eviction. Items that haven't
/// finished uploading, have conflicts, or live outside a detected cloud folder
/// are refused.
enum CloudDownloadRemover {
    struct Outcome: Identifiable, Sendable {
        enum Result: Sendable, Equatable {
            /// The local copy is gone; the item is now cloud-only.
            case removed
            /// macOS accepted the request; the provider will finish it shortly.
            case requested
            case alreadyCloudOnly
            case failed(String)
        }

        var item: CloudFileItem
        var result: Result
        /// The person can try "Remove Download" in Finder's context menu instead.
        var canUseFinder: Bool

        var id: String { item.id }
        var succeeded: Bool {
            switch result {
            case .removed, .requested, .alreadyCloudOnly: return true
            case .failed: return false
            }
        }
    }

    /// Checks that cost nothing and never touch the provider. Returns a reason when the item can't be evicted.
    static func preflightProblem(for item: CloudFileItem, locations: [CloudLocation]) -> String? {
        let path = PathUtilities.normalize(item.path)
        guard let location = locations.first(where: { PathUtilities.isDescendant(path, of: $0.path) }) else {
            return "This item isn't in a cloud storage folder."
        }
        guard location.supportsRemoveDownload else {
            return "\(location.providerName) manages this folder with its own app, which doesn't support Remove Download through macOS. Use \(location.providerName)'s option to make files online-only."
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return "The item no longer exists." }
        guard FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)) == item.identity else {
            return "The item changed after the scan. Scan again to review it."
        }
        let type = FileObjectType(mode: info.st_mode)
        guard type == .regular || (type == .directory && item.isPackage) else { return "Only files and packages can have their download removed." }
        return nil
    }

    /// Evicts one item. Blocking: call from a background thread.
    static func removeDownload(of item: CloudFileItem, locations: [CloudLocation]) -> Outcome {
        if let problem = preflightProblem(for: item, locations: locations) {
            return Outcome(item: item, result: .failed(problem), canUseFinder: false)
        }
        var info = stat()
        if lstat(item.path, &info) == 0, info.st_flags & FileFlags.dataless != 0 {
            return Outcome(item: item, result: .alreadyCloudOnly, canUseFinder: false)
        }

        let url = URL(fileURLWithPath: item.path)
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return Outcome(item: item, result: .failed("macOS couldn't report the item's sync status."), canUseFinder: true)
        }
        guard values.isUbiquitousItem == true else {
            return Outcome(item: item, result: .failed("macOS doesn't report this item as synced by a cloud provider, so its download can't be removed from here."), canUseFinder: true)
        }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return Outcome(item: item, result: .alreadyCloudOnly, canUseFinder: false)
        }
        if values.ubiquitousItemHasUnresolvedConflicts == true {
            return Outcome(item: item, result: .failed("The item has unresolved sync conflicts. Resolve them first so no version is lost."), canUseFinder: false)
        }
        if values.ubiquitousItemIsUploading == true || values.ubiquitousItemIsUploaded == false {
            return Outcome(item: item, result: .failed("The item hasn't finished uploading. Removing its download now could lose changes, so it was left alone."), canUseFinder: false)
        }

        do {
            try FileManager.default.evictUbiquitousItem(at: url)
        } catch {
            return Outcome(item: item, result: .failed(describe(error)), canUseFinder: true)
        }

        // Eviction can complete asynchronously; check for a short while.
        for _ in 0..<10 {
            if isCloudOnly(path: item.path) { return Outcome(item: item, result: .removed, canUseFinder: false) }
            usleep(200_000)
        }
        return Outcome(item: item, result: .requested, canUseFinder: false)
    }

    static func isCloudOnly(path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0, info.st_flags & FileFlags.dataless != 0 { return true }
        var url = URL(fileURLWithPath: path)
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFeatureUnsupportedError {
            return "This cloud provider doesn't let other apps remove downloads."
        }
        return nsError.localizedDescription
    }
}
