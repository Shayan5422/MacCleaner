import Foundation

/// A folder to scan.
struct FileScanRoot: Sendable, Identifiable, Hashable {
    var id: UUID
    var url: URL
    var name: String
}

/// What counts as large, old and worth comparing.
struct FileScanOptions: Sendable {
    var largeFileMinimum: Int64 = 50_000_000
    var oldFileMinimum: Int64 = 1_000_000
    /// Files not changed since this date are old.
    var oldFileCutoff: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    /// Smaller files aren't compared: they free little and are often parts of projects.
    var duplicateMinimum: Int64 = 100_000
}

/// Lists the picked folders and finds large, old and duplicate files and empty folders.
///
/// Hidden items and the contents of packages are skipped (a package counts as one item), symbolic links aren't
/// followed, and files that are only in iCloud are skipped without being downloaded. Runs off the main actor and
/// stops when its task is cancelled.
struct FileScanner: Sendable {
    var options = FileScanOptions()

    static let resourceKeys: [URLResourceKey] = [
        .fileSizeKey, .totalFileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .creationDateKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .contentTypeKey,
    ]
    /// Files the system leaves in folders; a folder with only these counts as empty.
    static let ignorableNames: Set<String> = [".DS_Store", ".localized"]

    @concurrent
    func scan(_ roots: [FileScanRoot], progress: @escaping @Sendable (FileScanProgress) -> Void = { _ in }) async throws -> FileScanResult {
        var listing = Listing()
        var state = FileScanProgress()
        for root in Self.outermost(roots) {
            try list(root, into: &listing, state: &state, progress: progress)
        }
        progress(state)

        var result = FileScanResult()
        result.itemCount = listing.items.count
        result.cloudOnlyCount = listing.cloudOnlyCount
        result.unreadableCount = listing.unreadableCount
        result.largeFiles = listing.items.filter { $0.size >= options.largeFileMinimum }.sorted { $0.size > $1.size }
        result.oldFiles = listing.items
            .filter { item in item.size >= options.oldFileMinimum && item.modificationDate.map { $0 < options.oldFileCutoff } == true }
            .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        result.emptyFolders = listing.emptyFolders()
        result.duplicateGroups = try duplicates(among: listing.items.filter { $0.kind == .file && $0.contentSize >= options.duplicateMinimum },
                                                state: &state, progress: progress)
        result.date = Date()
        return result
    }

    // MARK: Listing

    private struct Listing {
        var items: [FileScanItem] = []
        /// Plain folders by canonical path.
        var folders: [String: FileScanItem] = [:]
        /// Folders that hold something other than empty folders.
        var occupied: Set<String> = []
        var cloudOnlyCount = 0
        var unreadableCount = 0

        /// Marks a folder and the folders above it, up to the picked folder, as not empty.
        mutating func markOccupied(_ folderPath: String, below rootPath: String) {
            var path = folderPath
            while path.count > rootPath.count, path.hasPrefix(rootPath), occupied.insert(path).inserted {
                path = (path as NSString).deletingLastPathComponent
            }
        }

        /// Empty folders, outermost only: deleting one deletes the empty folders inside it.
        func emptyFolders() -> [FileScanItem] {
            folders.filter { path, _ in
                guard !occupied.contains(path) else { return false }
                let parent = (path as NSString).deletingLastPathComponent
                return folders[parent] == nil || occupied.contains(parent)
            }
            .map(\.value)
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
        }
    }

    private func list(_ root: FileScanRoot, into listing: inout Listing, state: inout FileScanProgress,
                      progress: @Sendable (FileScanProgress) -> Void) throws {
        let rootPath = Self.canonicalPath(root.url)
        let unreadable = UnreadableFolders()
        guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: Self.resourceKeys,
                                                              options: .skipsPackageDescendants,
                                                              errorHandler: { url, _ in unreadable.add(url); return true }) else {
            listing.unreadableCount += 1
            return
        }
        let keys = Set(Self.resourceKeys)
        while let url = enumerator.nextObject() as? URL {
            state.itemsFound += 1
            if state.itemsFound.isMultiple(of: 250) {
                try Task.checkCancellation()
                progress(state)
            }
            let path = Self.canonicalPath(url)
            let parent = (path as NSString).deletingLastPathComponent
            guard let values = try? url.resourceValues(forKeys: keys) else {
                listing.markOccupied(parent, below: rootPath)
                continue
            }
            let isDirectory = values.isDirectory == true
            if url.lastPathComponent.hasPrefix(".") || values.isHidden == true {
                if !Self.ignorableNames.contains(url.lastPathComponent) { listing.markOccupied(parent, below: rootPath) }
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                listing.markOccupied(parent, below: rootPath)
                continue
            }
            let isPackage = values.isPackage == true
            if isDirectory, !isPackage {
                if values.isUbiquitousItem == true, !Self.isDownloaded(values) {
                    // Its listing may be incomplete until it's downloaded, so it's never called empty.
                    listing.markOccupied(path, below: rootPath)
                }
                listing.folders[path] = item(url, values, kind: .folder, root: root, rootPath: rootPath, size: (0, 0))
                continue
            }
            listing.markOccupied(parent, below: rootPath)
            if values.isUbiquitousItem == true, !Self.isDownloaded(values) {
                listing.cloudOnlyCount += 1
                continue
            }
            let size = isPackage ? Self.packageSize(url) : Self.size(of: values)
            listing.items.append(item(url, values, kind: isPackage ? .package : .file, root: root, rootPath: rootPath, size: size))
        }
        for url in unreadable.urls {
            listing.markOccupied(Self.canonicalPath(url), below: rootPath)
        }
        listing.unreadableCount += unreadable.urls.count
    }

    private func item(_ url: URL, _ values: URLResourceValues, kind: FileScanItem.Kind, root: FileScanRoot, rootPath: String,
                      size: (allocated: Int64, content: Int64)) -> FileScanItem {
        let path = Self.canonicalPath(url)
        let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        return FileScanItem(url: url, kind: kind, rootID: root.id, displayPath: root.name + "/" + relative,
                            size: size.allocated, contentSize: size.content, modificationDate: values.contentModificationDate,
                            creationDate: values.creationDate, typeIdentifier: values.contentType?.identifier)
    }

    /// Bytes on disk and content size. A file with no allocation (a sparse file) counts with its content size.
    static func size(of values: URLResourceValues) -> (allocated: Int64, content: Int64) {
        let content = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        return (allocated > 0 ? allocated : content, content)
    }

    /// A package's size is the sum of everything inside it.
    static func packageSize(_ url: URL) -> (allocated: Int64, content: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else {
            return (0, 0)
        }
        var total: (allocated: Int64, content: Int64) = (0, 0)
        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = size(of: values)
            total = (total.allocated + size.allocated, total.content + size.content)
        }
        return total
    }

    /// Whether a cloud item's content is on this device, so reading it won't download anything.
    static func isDownloaded(_ values: URLResourceValues) -> Bool {
        guard let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status == .current || status == .downloaded
    }

    /// The path without "/private" in front of "/var" and "/tmp", so paths compare equal however they were reached.
    static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") { path.removeFirst("/private".count) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The roots without any that are inside another root, so no file is listed twice.
    static func outermost(_ roots: [FileScanRoot]) -> [FileScanRoot] {
        var kept: [(root: FileScanRoot, path: String)] = []
        for root in roots.sorted(by: { canonicalPath($0.url).count < canonicalPath($1.url).count }) {
            let path = canonicalPath(root.url)
            if kept.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { continue }
            kept.append((root, path))
        }
        return roots.filter { root in kept.contains { $0.root.id == root.id } }
    }

    /// Whether a folder holds nothing but ignorable files and empty folders, checked again right before it's deleted.
    static func isEffectivelyEmpty(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: []) else {
            return false
        }
        return children.allSatisfy { child in
            if ignorableNames.contains(child.lastPathComponent) { return true }
            guard let values = try? child.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isPackage != true, values.isSymbolicLink != true else { return false }
            return isEffectivelyEmpty(child)
        }
    }

    // MARK: Duplicates

    /// Groups by size, then by the SHA-256 of the first 64 KB, then by the SHA-256 of the whole file.
    private func duplicates(among candidates: [FileScanItem], state: inout FileScanProgress,
                            progress: @Sendable (FileScanProgress) -> Void) throws -> [FileDuplicateGroup] {
        let sameSize = Dictionary(grouping: candidates, by: \.contentSize).values.filter { $0.count > 1 }
        state.stage = .comparing
        state.toCompare = sameSize.reduce(0) { $0 + $1.count }
        state.compared = 0
        progress(state)

        var groups: [FileDuplicateGroup] = []
        for files in sameSize {
            var byStart: [String: [FileScanItem]] = [:]
            for file in files {
                if let digest = try Self.digest(file.url, FileHasher.partialDigest) {
                    byStart[digest, default: []].append(file)
                }
                state.compared += 1
                progress(state)
            }
            for (startDigest, candidates) in byStart where candidates.count > 1 {
                let size = candidates[0].contentSize
                if size <= Int64(FileHasher.partialLength) {
                    groups.append(Self.group(candidates, id: "\(size)-\(startDigest)"))
                    continue
                }
                var byContent: [String: [FileScanItem]] = [:]
                for file in candidates {
                    if let digest = try Self.digest(file.url, FileHasher.fullDigest) {
                        byContent[digest, default: []].append(file)
                    }
                }
                for (digest, identical) in byContent where identical.count > 1 {
                    groups.append(Self.group(identical, id: "\(size)-\(digest)"))
                }
            }
        }
        return groups.sorted { $0.reclaimableBytes != $1.reclaimableBytes ? $0.reclaimableBytes > $1.reclaimableBytes : $0.id < $1.id }
    }

    /// The digest, or nil when the file can't be read. Cancellation is passed on.
    private static func digest(_ url: URL, _ hash: (URL) throws -> String) throws -> String? {
        do {
            return try hash(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    static func group(_ files: [FileScanItem], id: String) -> FileDuplicateGroup {
        FileDuplicateGroup(files: files.sorted(by: keepsBefore), id: id)
    }

    /// The copy to keep comes first: the oldest (created, else modified), then the shortest path, then the shallowest.
    static func keepsBefore(_ lhs: FileScanItem, _ rhs: FileScanItem) -> Bool {
        let lhsAge = lhs.creationDate ?? lhs.modificationDate ?? .distantFuture
        let rhsAge = rhs.creationDate ?? rhs.modificationDate ?? .distantFuture
        if lhsAge != rhsAge { return lhsAge < rhsAge }
        let lhsPath = lhs.url.path, rhsPath = rhs.url.path
        if lhsPath.count != rhsPath.count { return lhsPath.count < rhsPath.count }
        let lhsDepth = lhsPath.filter { $0 == "/" }.count, rhsDepth = rhsPath.filter { $0 == "/" }.count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhsPath < rhsPath
    }
}

/// Folders the enumerator couldn't read, collected from its error handler.
private final class UnreadableFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func add(_ url: URL) {
        lock.withLock { storage.append(url) }
    }

    var urls: [URL] { lock.withLock { storage } }
}
