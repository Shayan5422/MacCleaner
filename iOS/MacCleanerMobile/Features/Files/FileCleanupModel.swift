import Observation
import SwiftUI

/// A confirmation shown at the top of the Files page after a change.
struct FileNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Large, old and duplicate files and empty folders in folders the person picks, and deleting them.
@MainActor
@Observable
final class FileCleanupModel {
    /// A picked folder, resolved from its bookmark.
    struct Folder: Identifiable, Equatable {
        var saved: SavedFolder
        /// Nil until resolved, or when the folder can't be opened anymore.
        var url: URL?
        var location: String
        /// The bookmark couldn't be resolved: the person has to pick the folder again.
        var needsReselection = false

        var id: UUID { saved.id }
        var name: String { saved.name }
    }

    private(set) var folders: [Folder] = []
    /// Non-nil while a scan runs.
    private(set) var progress: FileScanProgress?
    private(set) var result: FileScanResult?
    /// Files were moved to Recently Deleted in this session.
    private(set) var hasDeletedItems = false
    private(set) var isDeleting = false
    /// Items that couldn't be moved to Recently Deleted, waiting for the person to decide about deleting them permanently.
    private(set) var pendingPermanentDeletion: [FileScanItem] = []
    /// What else happened to the deletion, said in the permanent-deletion question.
    private(set) var pendingNote: String?
    var notice: FileNotice?
    var errorMessage: String?
    /// "iPhone" or "iPad", for sentences.
    let deviceWord: String

    private let store: FolderBookmarkStore
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let access = FolderAccessSession()
    @ObservationIgnored private var isPrepared = false

    init() {
        store = .standard
        deviceWord = DeviceInfo.current().deviceWord
        folders = store.load().map { Folder(saved: $0, url: nil, location: "") }
    }

    // MARK: Summary

    /// What deleting the large, old and duplicate files found by the last scan would free, or nil before a scan.
    var reclaimableBytes: Int64? { result?.reclaimableBytes }

    /// "2.1 GB in 14 files", or nil before a scan.
    var summary: String? {
        guard let result else { return nil }
        let count = result.reclaimableFileCount
        if count > 0 { return "\(ByteFormatting.string(result.reclaimableBytes)) in \(NumberFormatting.count(count, "file"))" }
        if !result.emptyFolders.isEmpty { return NumberFormatting.count(result.emptyFolders.count, "empty folder") }
        return "Nothing to clean up"
    }

    var isScanning: Bool { progress != nil }
    var availableFolders: [Folder] { folders.filter { $0.url != nil } }

    // MARK: Folders

    /// Resolves the saved bookmarks the first time the Files page opens.
    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true
        #if DEBUG
        if let sample = await FileSampleData.createIfRequested() { addFolders([sample]) }
        #endif
        await resolveFolders()
    }

    /// Adds folders from the document picker. A folder that's already in the list replaces its old entry,
    /// which is how a folder that can't be opened anymore is picked again.
    func addFolders(_ urls: [URL]) {
        var saved = folders.map(\.saved)
        var failed: [String] = []
        for url in urls {
            do {
                let bookmark = try FolderBookmarkStore.makeBookmark(for: url)
                let folder = SavedFolder(name: url.lastPathComponent, bookmark: bookmark)
                let path = FileScanner.canonicalPath(url)
                if let index = folders.firstIndex(where: { $0.url.map(FileScanner.canonicalPath) == path || ($0.needsReselection && $0.name == folder.name) }) {
                    saved[index] = SavedFolder(id: saved[index].id, name: folder.name, bookmark: bookmark, addedAt: saved[index].addedAt)
                    folders[index] = Folder(saved: saved[index], url: url, location: FolderBookmarkStore.locationName(for: url, deviceWord: deviceWord))
                } else {
                    saved.append(folder)
                    folders.append(Folder(saved: folder, url: url, location: FolderBookmarkStore.locationName(for: url, deviceWord: deviceWord)))
                }
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        persist(saved)
        if !failed.isEmpty {
            errorMessage = "Mac Cleaner couldn't keep access to \(failed.joined(separator: ", ")). Try adding it again."
        }
        // Results on screen don't include the new folder yet.
        if result != nil, failed.count < urls.count { scan() }
    }

    /// Takes a folder off the list. Nothing in it is deleted. A scan that's running stops, since it includes the folder.
    func removeFolder(_ folder: Folder) {
        cancelScan()
        if let url = folder.url { access.close(url) }
        folders.removeAll { $0.id == folder.id }
        persist(folders.map(\.saved))
        result = result?.removingRoot(folder.id)
        if folders.isEmpty { result = nil }
    }

    private func resolveFolders() async {
        let saved = folders.map(\.saved)
        let resolutions = await Self.resolve(saved)
        var changed = false
        for (folder, resolution) in zip(saved, resolutions) {
            guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { continue }
            switch resolution {
            case .resolved(let url, let refreshed):
                folders[index].url = url
                folders[index].location = FolderBookmarkStore.locationName(for: url, deviceWord: deviceWord)
                folders[index].needsReselection = false
                if let refreshed {
                    folders[index].saved.bookmark = refreshed
                    changed = true
                }
            case .unavailable:
                folders[index].url = nil
                folders[index].needsReselection = true
            }
        }
        if changed { persist(folders.map(\.saved)) }
    }

    @concurrent
    private static func resolve(_ folders: [SavedFolder]) async -> [FolderBookmarkStore.Resolution] {
        folders.map(FolderBookmarkStore.resolve)
    }

    private func persist(_ saved: [SavedFolder]) {
        do {
            try store.save(saved)
        } catch {
            errorMessage = "The folder list couldn't be saved: \(error.localizedDescription)"
        }
    }

    // MARK: Scan

    func scan() {
        guard progress == nil else { return }
        let roots = availableFolders.compactMap { folder in folder.url.map { FileScanRoot(id: folder.id, url: $0, name: folder.name) } }
        guard !roots.isEmpty else { return }
        access.closeAll()
        access.open(roots.map(\.url))
        notice = nil
        progress = FileScanProgress()
        let scanner = FileScanner()
        let (updates, continuation) = AsyncStream.makeStream(of: FileScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        scanTask = Task {
            let reporter = Task {
                for await update in updates where progress != nil {
                    progress = update
                }
            }
            do {
                let result = try await scanner.scan(roots) { continuation.yield($0) }
                continuation.finish()
                await reporter.value
                self.result = result
            } catch {
                continuation.finish()
                await reporter.value
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            progress = nil
            scanTask = nil
        }
    }

    /// Stops the scan; the previous results, if any, stay.
    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: Delete

    /// Moves the items to Recently Deleted. Items that changed since the scan are left alone; items whose location
    /// has no Recently Deleted end up in `pendingPermanentDeletion` for the person to decide.
    /// From the Duplicates list, a copy is only deleted while another copy of it stays.
    func delete(_ items: [FileScanItem], fromDuplicates: Bool = false) async {
        guard !isDeleting, !items.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        let groups = fromDuplicates ? result?.duplicateGroups ?? [] : []
        let (ready, changed) = await Self.check(items, keepingACopyIn: groups)
        let outcome = await FileDeleter.standard.trash(ready.map(\.url))
        let deleted = apply(outcome, to: ready)
        if !deleted.isEmpty {
            hasDeletedItems = true
            notice = FileNotice(title: "Moved \(Self.count(deleted.count, of: deleted)) to Recently Deleted",
                                message: "To get \(deleted.count == 1 ? "it" : "them") back, open Files and go to Browse › Recently Deleted.")
        }
        let unsupported = Set(outcome.failures.filter(\.trashUnsupported).map(\.url))
        let problems = Self.problems(changed: changed, failures: outcome.failures.filter { !$0.trashUnsupported })
        // One prompt at a time: what else went wrong is said in the permanent-deletion question when there is one.
        if unsupported.isEmpty {
            if !problems.isEmpty { errorMessage = problems.joined(separator: "\n\n") }
        } else {
            pendingNote = problems.isEmpty ? nil : problems.joined(separator: " ")
            pendingPermanentDeletion = ready.filter { unsupported.contains($0.url) }
        }
    }

    /// Deletes items the person confirmed for permanent deletion (from `pendingPermanentDeletion`).
    func deletePermanently(_ items: [FileScanItem]) async {
        pendingPermanentDeletion = []
        pendingNote = nil
        guard !isDeleting, !items.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        let (ready, changed) = await Self.check(items, keepingACopyIn: [])
        let outcome = await FileDeleter.standard.deletePermanently(ready.map(\.url))
        let deleted = apply(outcome, to: ready)
        if !deleted.isEmpty {
            notice = FileNotice(title: "Deleted \(Self.count(deleted.count, of: deleted)) permanently",
                                message: deleted.count == 1 ? "It's gone from this location." : "They're gone from this location.")
        }
        let problems = Self.problems(changed: changed, failures: outcome.failures)
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n\n") }
    }

    /// The person chose to keep the items that can't go to Recently Deleted.
    func keepPendingItems() {
        pendingPermanentDeletion = []
        pendingNote = nil
    }

    /// Removes what was deleted from the results; returns the deleted items.
    private func apply(_ outcome: FileDeleter.Outcome, to items: [FileScanItem]) -> [FileScanItem] {
        guard !outcome.deleted.isEmpty else { return [] }
        let deleted = Set(outcome.deleted)
        result = result?.removing(deleted)
        return items.filter { deleted.contains($0.url) }
    }

    /// Sentences about items that changed since the scan or couldn't be deleted.
    private static func problems(changed: [FileScanItem], failures: [FileDeleter.Failure]) -> [String] {
        var lines: [String] = []
        if !changed.isEmpty {
            lines.append("\(count(changed.count, of: changed)) changed since the scan, so \(changed.count == 1 ? "it was" : "they were") left alone. Scan again to see the latest.")
        }
        if let failure = failures.first {
            let name = failure.url.lastPathComponent
            lines.append(failures.count == 1 ? "“\(name)” couldn't be deleted. \(failure.reason)"
                                              : "\(NumberFormatting.count(failures.count, "item")) couldn't be deleted. \(failure.reason)")
        }
        return lines
    }

    /// "3 files", "1 folder", "2 items" for a mix.
    nonisolated static func count(_ count: Int, of items: [FileScanItem]) -> String {
        let kinds = Set(items.map { $0.kind == .folder })
        if kinds == [true] { return NumberFormatting.count(count, "folder") }
        if kinds == [false] { return NumberFormatting.count(count, "file") }
        return NumberFormatting.count(count, "item")
    }

    /// Splits the items into those still as the scan found them and those that changed. An item in one of `groups`
    /// is only deleted while another copy in its group stays and is unchanged.
    @concurrent
    private static func check(_ items: [FileScanItem], keepingACopyIn groups: [FileDuplicateGroup]) async -> (ready: [FileScanItem], changed: [FileScanItem]) {
        let deleting = Set(items.map(\.url))
        var ready: [FileScanItem] = [], changed: [FileScanItem] = []
        for item in items {
            var isSafe = isUnchanged(item)
            if isSafe, let group = groups.first(where: { $0.files.contains(item) }) {
                isSafe = group.files.contains { !deleting.contains($0.url) && isUnchanged($0) }
            }
            if isSafe { ready.append(item) } else { changed.append(item) }
        }
        return (ready, changed)
    }

    /// Whether the item on disk is still the one the scan found.
    nonisolated static func isUnchanged(_ item: FileScanItem) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileSizeKey, .fileSizeKey, .isDirectoryKey]
        // A new URL: the scan's URL caches the values it read then.
        let url = URL(fileURLWithPath: item.url.path, isDirectory: item.kind != .file)
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        switch item.kind {
        case .folder:
            return values.isDirectory == true && FileScanner.isEffectivelyEmpty(item.url)
        case .package:
            return values.contentModificationDate == item.modificationDate
        case .file:
            return Int64(values.totalFileSize ?? values.fileSize ?? -1) == item.contentSize && values.contentModificationDate == item.modificationDate
        }
    }
}
