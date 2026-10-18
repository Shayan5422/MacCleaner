import Observation
import Photos
import SwiftUI

/// The photo library cleanup, for photos and videos: access, scans, what's selected and deleting it.
@MainActor
@Observable
final class PhotoCleanupModel {
    /// What a deletion did, for the banner afterwards.
    struct DeletionReport: Equatable, Identifiable {
        var id = UUID()
        var count: Int
        /// "photo", "video" or "item".
        var noun: String
        var size: MediaByteTotal

        var title: String { "\(NumberFormatting.count(count, noun)) moved to Recently Deleted" }

        var message: String {
            let pronoun = count == 1 ? "It stays" : "They stay"
            return "\(pronoun) in \(PhotosRecentlyDeleted.location()) for \(PhotosRecentlyDeleted.days) days. Empty it there to free \(size.text) now."
        }
    }

    private(set) var access: PhotoAccess
    private(set) var result: PhotoScanResult?
    /// Set while a scan runs.
    private(set) var progress: PhotoScanProgress?
    private(set) var lastScanDate: Date?
    /// What's selected for deletion, in every category.
    var selection: Set<String> = []
    private(set) var isDeleting = false
    private(set) var lastDeletion: DeletionReport?
    /// A problem to tell the person about.
    var errorMessage: String?
    /// Items were deleted in this session: they wait in Recently Deleted for 30 days.
    private(set) var hasDeletedItems = false

    @ObservationIgnored private let scanner: PhotoLibraryScanner
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID: UUID?
    /// Deleted while a scan was running, so they're left out of its result.
    @ObservationIgnored private var deletedDuringScan: Set<String> = []
    /// The person stopped a scan: screens don't start one on their own again in this session.
    @ObservationIgnored private var scanWasCancelled = false
    @ObservationIgnored private var revalidation: Task<Void, Never>?
    @ObservationIgnored private var observer: PhotoLibraryObserver?

    private static let lastScanKey = "photos.lastScanDate"

    init(scanner: PhotoLibraryScanner = PhotoLibraryScanner(), defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.defaults = defaults
        access = .current
        lastScanDate = defaults.object(forKey: Self.lastScanKey) as? Date
    }

    // MARK: For the rest of the app

    /// What the last scan found that could be freed in photos, or nil before the first scan.
    var photoReclaimableBytes: Int64? { result?.photoReclaimable.bytes }
    /// The same for videos.
    var videoReclaimableBytes: Int64? { result?.videoReclaimable.bytes }
    /// One line for the Overview, e.g. "1,204 similar photos and 18 large videos".
    var summary: String? { result?.summary }

    var isScanning: Bool { progress != nil }

    // MARK: Access

    /// Reads the access again, for when the person comes back from Settings.
    func refreshAccess() {
        let current = PhotoAccess.current
        guard current != access else { return }
        let wasLimited = access == .limited
        access = current
        if !current.canRead {
            cancelScan()
            result = nil
            selection = []
        } else if wasLimited, current == .full, result?.isLimited ?? false {
            // Full access now: the last scan only saw part of the library.
            startScan()
        }
    }

    /// Shows iOS's prompt; scans right away when the person allows full access.
    func requestAccess() async {
        access = await PhotoLibraryEditor.requestAccess()
        if access == .full { startScan() }
    }

    /// When a Photos or Videos screen appears. A library that was scanned before is scanned again
    /// right away (quick, thanks to the cache); a first scan waits for the person to start it.
    func screenAppeared() {
        refreshAccess()
        if result == nil, !isScanning, !scanWasCancelled, access.canRead, lastScanDate != nil { startScan() }
    }

    // MARK: Scanning

    func startScan() {
        guard scanTask == nil, access.canRead else { return }
        errorMessage = nil
        scanWasCancelled = false
        deletedDuringScan = []
        let id = UUID()
        scanID = id
        progress = PhotoScanProgress(stage: .reading)
        let scanner = scanner
        let isLimited = access == .limited
        let (updates, continuation) = AsyncStream.makeStream(of: PhotoScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let listener = Task { [weak self] in
            for await update in updates where self?.scanID == id {
                self?.progress = update
            }
        }
        scanTask = Task { [weak self] in
            do {
                let result = try await scanner.scan(isLimited: isLimited) { continuation.yield($0) }
                continuation.finish()
                listener.cancel()
                self?.scanFinished(result)
            } catch {
                continuation.finish()
                listener.cancel()
                self?.scanStopped(error)
            }
        }
    }

    func cancelScan() {
        guard let scanTask else { return }
        scanWasCancelled = true
        scanTask.cancel()
    }

    private func scanFinished(_ scanned: PhotoScanResult) {
        endScan()
        MediaImageLoader.shared.forgetAssets()
        let result = scanned.removing(deletedDuringScan)
        deletedDuringScan = []
        self.result = result
        selection = result.suggestedSelection
        lastScanDate = result.date
        defaults.set(result.date, forKey: Self.lastScanKey)
        observeLibrary()
    }

    private func scanStopped(_ error: any Error) {
        endScan()
        if !(error is CancellationError) {
            errorMessage = "The scan stopped: \(error.localizedDescription)"
        }
    }

    private func endScan() {
        scanTask = nil
        scanID = nil
        progress = nil
    }

    // MARK: Selection

    func isSelected(_ item: MediaItem) -> Bool { selection.contains(item.id) }

    func toggle(_ item: MediaItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func setSelected(_ items: [MediaItem], _ selected: Bool) {
        let ids = items.map(\.id)
        if selected {
            selection.formUnion(ids)
        } else {
            selection.subtract(ids)
        }
    }

    /// The selected ones among `items`, in order.
    func selected(in items: [MediaItem]) -> [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    // MARK: Deleting

    /// Deletes the items after iOS's own confirmation. They go to Recently Deleted; if the person
    /// declines in iOS's alert, nothing changes.
    func delete(_ items: [MediaItem]) async {
        guard !items.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        let ids = items.map(\.id)
        do {
            try await PhotoLibraryEditor.delete(ids)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return
        } catch {
            errorMessage = "Nothing was deleted: \(error.localizedDescription)"
            return
        }

        let remaining = await PhotoLibraryEditor.existing(ids)
        let deleted = items.filter { !remaining.contains($0.id) }
        guard !deleted.isEmpty else { return }
        let deletedIDs = Set(deleted.map(\.id))
        result = result?.removing(deletedIDs)
        selection.subtract(deletedIDs)
        if isScanning { deletedDuringScan.formUnion(deletedIDs) }
        hasDeletedItems = true
        let kinds = Set(deleted.map(\.kind))
        let noun = kinds.count > 1 ? "item" : (kinds.first == .video ? "video" : "photo")
        lastDeletion = DeletionReport(count: deleted.count, noun: noun, size: MediaByteTotal(deleted))
    }

    func dismissDeletionReport() {
        lastDeletion = nil
    }

    // MARK: Library changes

    /// Drops items from the results when they're deleted or hidden elsewhere, or leave the limited selection.
    private func observeLibrary() {
        guard observer == nil else { return }
        let observer = PhotoLibraryObserver { [weak self] in
            Task { @MainActor [weak self] in self?.libraryChanged() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    private func libraryChanged() {
        revalidation?.cancel()
        revalidation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.dropMissingItems()
        }
    }

    private func dropMissingItems() async {
        guard let ids = result?.allItems.map(\.id), !ids.isEmpty, !isDeleting, !isScanning else { return }
        let existing = await PhotoLibraryEditor.existing(ids)
        let missing = Set(ids).subtracting(existing)
        guard !missing.isEmpty, let current = result else { return }
        result = current.removing(missing)
        selection.subtract(missing)
    }
}
