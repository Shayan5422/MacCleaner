import CoreServices
import Darwin
import Foundation

/// What to scan and how.
struct StorageScanRequest: Sendable {
    /// Folder to walk. For the startup disk use `VolumeInfo.scanRootPath` (`/System/Volumes/Data`).
    var rootPath: String
    /// Name shown for the root node ("Macintosh HD", "Documents").
    var displayName: String
    var exclusions = ExclusionList()
    /// Files that use at least this many bytes on disk get their own node.
    var fileNodeThreshold: Int64 = StorageTreeBuilder.defaultFileNodeThreshold
    /// Bytes the walk is expected to find (a volume's used space), for a progress estimate.
    var expectedBytes: Int64?
    /// Spotlight "last opened" dates are read for the largest files that look unused for this
    /// many days (based on modification and access times). `nil` skips the lookup.
    var lastOpenedLookupAgeDays: Int? = 30
    var lastOpenedLookupLimit = 3_000
    var maxConcurrency = WalkOptions.defaultConcurrency

    init(rootPath: String, displayName: String, exclusions: ExclusionList = ExclusionList()) {
        self.rootPath = PathUtilities.normalize(rootPath)
        self.displayName = displayName
        self.exclusions = StorageTreeBuilder.walkExclusions(exclusions, rootPath: self.rootPath)
    }
}

/// Live state of a running scan.
struct StorageScanProgress: Sendable {
    enum Phase: Sendable, Equatable {
        case reading
        case summarizing
        case readingDates
    }

    var phase: Phase
    var directoriesRead: Int
    var itemsSeen: Int
    var bytesCounted: Int64
    var unreadableCount: Int
    var currentPath: String
    /// Estimated completion, when the expected size is known.
    var fraction: Double?
}

/// Builds a `StorageTree` with `ParallelDirectoryWalker`.
///
/// * Folders always get a node; files only when they use at least
///   `fileNodeThreshold` bytes. Smaller files of a folder are combined into one
///   node, which keeps memory bounded on volumes with millions of files.
/// * Hard links and APFS clones are de-duplicated across the whole tree with
///   the same rules as `UsageAccumulator`: a hard-linked file's storage is
///   counted at the first name found, and blocks shared by a clone family are
///   counted once. Reclaimable space of a family is attributed to the lowest
///   folder that contains all of its members, so every folder's
///   `reclaimableSize` matches what `UsageAccumulator` would report for it.
/// * Packages are measured as a whole and become leaves.
/// * Cloud folders that haven't been downloaded (dataless directories) are not
///   listed, so scanning never triggers downloads.
/// * APFS snapshots and other volumes are never entered (the walk stays on the
///   root's volume), so their storage is never counted.
final class StorageTreeBuilder: @unchecked Sendable {
    static let defaultFileNodeThreshold: Int64 = 1_000_000

    let request: StorageScanRequest
    let walkProgress = WalkProgress()

    private let collector = StorageStatsCollector()
    private let registry = StorageSharingRegistry()
    private let packages = StoragePackageList()
    private let state = StorageBuilderState()

    init(request: StorageScanRequest) {
        self.request = request
    }

    /// Thread-safe snapshot for progress displays (poll every ~150 ms).
    var progress: StorageScanProgress {
        let walk = walkProgress.snapshot
        let bytes = collector.countedBytes
        let phase = state.phase
        var fraction: Double?
        if phase == .reading, let expected = request.expectedBytes, expected > 0 {
            fraction = min(0.99, Double(bytes) / Double(expected))
        }
        return StorageScanProgress(
            phase: phase,
            directoriesRead: walk.directoriesRead,
            itemsSeen: walk.entriesSeen,
            bytesCounted: bytes,
            unreadableCount: walk.unreadableDirectories,
            currentPath: walk.currentPath,
            fraction: fraction
        )
    }

    /// Walks the tree and returns it fully aggregated. Cancelling the calling task stops the walk.
    func build() async throws -> StorageTree {
        let started = Date()
        let rootPath = request.rootPath
        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw WalkError.cannotOpen(rootPath, errno) }
        guard FileObjectType(mode: info.st_mode) == .directory else { throw WalkError.notADirectory(rootPath) }

        let root = StorageNode(name: request.displayName, kind: .directory, parent: nil, inode: UInt64(info.st_ino))
        root.modificationTime = UInt32(clamping: max(0, info.st_mtimespec.tv_sec))
        root.folderHint = StorageCategory.folderHint(
            name: (rootPath as NSString).lastPathComponent,
            parentPath: (rootPath as NSString).deletingLastPathComponent,
            inherited: nil
        )

        var options = WalkOptions()
        options.crossesVolumes = false
        options.includesHiddenItems = true
        options.descendsIntoPackages = true
        options.exclusions = request.exclusions
        options.maxConcurrency = request.maxConcurrency

        let handlers = WalkHandlers<StorageWalkContext>(
            didRead: { [self] job, entries in
                switch job.context {
                case .directory(let node): readDirectory(node, entries: entries)
                case .package(let accumulator): readPackageContents(accumulator, entries: entries)
                }
            },
            descend: { [self] entry, parent in descend(into: entry, parent: parent) },
            didFail: { [self] job, code in
                switch job.context {
                case .directory(let node): node.flags.insert(.unreadable)
                case .package(let accumulator): accumulator.markUnreadable()
                }
                collector.addUnreadable(path: PathUtilities.firmlinkCanonical(job.path), isRoot: job.depth == 0, code: code)
            }
        )
        let walker = ParallelDirectoryWalker<StorageWalkContext>(options: options, progress: walkProgress, handlers: handlers)
        let summary = try await walker.walk(rootPath: rootPath, rootContext: .directory(root))
        if summary.wasCancelled { throw CancellationError() }
        try Task.checkCancellation()
        if let code = collector.rootFailureCode, root.children.isEmpty {
            throw WalkError.cannotOpen(rootPath, code)
        }

        state.phase = .summarizing
        let lookupCutoff: UInt32? = request.lastOpenedLookupAgeDays.map {
            StorageNode.time(Date().timeIntervalSince1970 - Double($0) * 86_400)
        }
        let limit = request.lastOpenedLookupLimit
        let packages = self.packages
        let registry = self.registry
        let finalized = await BackgroundWork.run(qos: .userInitiated) {
            for accumulator in packages.all { accumulator.finalize() }
            registry.finalize()
            StorageTreeBuilder.aggregate(root)
            return StorageTreeBuilder.collectIndex(root: root, rootPath: rootPath, lookupCutoff: lookupCutoff, lookupLimit: limit)
        }
        try Task.checkCancellation()

        if !finalized.lookupCandidates.isEmpty {
            state.phase = .readingDates
            try await StorageSpotlight.applyLastOpenedDates(to: finalized.lookupCandidates)
        }

        return StorageTree(
            root: root,
            rootPath: rootPath,
            device: Int32(info.st_dev),
            scanDate: Date(),
            duration: Date().timeIntervalSince(started),
            fileNodeThreshold: request.fileNodeThreshold,
            statistics: collector.snapshot,
            searchIndex: finalized.searchIndex
        )
    }

    // MARK: - Walk handlers (run on walker threads)

    private func descend(into entry: RawDirectoryEntry, parent job: DirectoryJob<StorageWalkContext>) -> StorageWalkContext? {
        switch job.context {
        case .package(let accumulator):
            if entry.isDataless {
                collector.addNotDownloadedFolder()
                return nil
            }
            return .package(accumulator)

        case .directory(let parentNode):
            let isPackage = StoragePackages.isPackage(name: entry.name)
            let node = StorageNode(name: entry.name, kind: isPackage ? .package : .directory, parent: parentNode, inode: entry.inode)
            node.modificationTime = StorageNode.time(entry.modificationTime)
            node.accessTime = StorageNode.time(entry.accessTime)
            if entry.name.hasPrefix(".") || entry.isHiddenFlagSet { node.flags.insert(.hidden) }
            if parentNode.isInHiddenLocation { node.flags.insert(.inHiddenFolder) }
            // Only the thread reading `parentNode` appends to its children (see WalkHandlers).
            parentNode.children.append(node)

            if isPackage {
                node.category = parentNode.folderHint ?? StorageCategory.packageCategory(name: entry.name)
                collector.addPackage()
            } else {
                node.folderHint = StorageCategory.folderHint(name: entry.name, parentPath: job.path, inherited: parentNode.folderHint)
            }
            if entry.isDataless {
                // Listing a placeholder folder would make the cloud provider download its contents.
                node.flags.insert(.cloudOnly)
                collector.addNotDownloadedFolder()
                return nil
            }
            if isPackage {
                let accumulator = StoragePackageAccumulator(node: node)
                packages.append(accumulator)
                return .package(accumulator)
            }
            return .directory(node)
        }
    }

    private func readDirectory(_ directory: StorageNode, entries: [RawDirectoryEntry]) {
        let threshold = request.fileNodeThreshold
        let hint = directory.folderHint
        var tally = StorageLocalTally()
        tally.directories = 1

        var largeCount = 0
        var smallCount = 0
        var directoryCount = 0
        for entry in entries {
            switch entry.type {
            case .directory: directoryCount += 1
            case .regular where !entry.isDataless && entry.allocatedSize >= threshold: largeCount += 1
            default: smallCount += 1
            }
        }
        directory.children.reserveCapacity(directory.children.count + largeCount + (smallCount > 0 ? 1 : 0) + directoryCount)

        let insideHidden = directory.isInHiddenLocation
        let smallNode = smallCount > 0 ? StorageNode(name: "", kind: .smallFiles, parent: directory, inode: 0) : nil
        if insideHidden { smallNode?.flags.insert(.inHiddenFolder) }
        var smallHistogram = smallNode == nil ? [] : [Int64](repeating: 0, count: StorageCategory.allCases.count)
        var fileNodes: [StorageNode] = []
        fileNodes.reserveCapacity(largeCount)
        var shared: [StorageSharingRegistry.Item] = []
        var sharedCategories: [StorageCategory] = []

        for entry in entries where entry.type != .directory {
            let isLarge = entry.type == .regular && !entry.isDataless && entry.allocatedSize >= threshold
            let owner: StorageNode
            let category: StorageCategory
            if isLarge {
                owner = StorageNode(name: entry.name, kind: .file, parent: directory, inode: entry.inode)
                owner.modificationTime = StorageNode.time(entry.modificationTime)
                owner.accessTime = StorageNode.time(entry.accessTime)
                if entry.name.hasPrefix(".") || entry.isHiddenFlagSet { owner.flags.insert(.hidden) }
                if insideHidden { owner.flags.insert(.inHiddenFolder) }
                category = hint ?? StorageCategory.classify(fileName: entry.name, logicalSize: entry.logicalSize)
                owner.category = category
                fileNodes.append(owner)
            } else if let smallNode {
                owner = smallNode
                owner.modificationTime = max(owner.modificationTime, StorageNode.time(entry.modificationTime))
                category = entry.type == .regular
                    ? (hint ?? StorageCategory.classify(fileName: entry.name, logicalSize: entry.logicalSize))
                    : .other
            } else {
                continue
            }

            guard entry.type == .regular else {
                // Symlinks and special files: an item without data blocks.
                owner.itemCount += 1
                tally.add(files: 1, counted: 0, logical: 0, category: category)
                continue
            }
            if entry.isDataless {
                tally.cloudOnlyFiles += 1
                tally.cloudOnlyLogicalBytes += entry.logicalSize
            }
            if StorageSharingRegistry.isShared(entry) {
                shared.append(StorageSharingRegistry.Item(entry: entry, owner: owner))
                sharedCategories.append(category)
                continue
            }
            let measured = StorageSharingRegistry.Measured(
                counted: entry.allocatedSize, logical: entry.logicalSize, reclaimable: entry.allocatedSize, files: 1
            )
            apply(measured, to: owner, category: category, isSmall: !isLarge, smallHistogram: &smallHistogram, tally: &tally)
        }

        if !shared.isEmpty {
            let results = registry.register(shared)
            for index in results.indices {
                let owner = shared[index].owner
                apply(results[index], to: owner, category: sharedCategories[index], isSmall: owner.kind == .smallFiles,
                      smallHistogram: &smallHistogram, tally: &tally)
            }
        }

        directory.children.append(contentsOf: fileNodes)
        if let smallNode {
            var best = 0
            for index in smallHistogram.indices where smallHistogram[index] > smallHistogram[best] { best = index }
            smallNode.category = StorageCategory(rawValue: UInt8(best)) ?? .other
            directory.children.append(smallNode)
        }
        collector.merge(tally)
    }

    private func readPackageContents(_ accumulator: StoragePackageAccumulator, entries: [RawDirectoryEntry]) {
        let category = accumulator.node.category
        var tally = StorageLocalTally()
        tally.directories = 1
        var sum = StorageSharingRegistry.Measured()
        var latest: UInt32 = 0
        var shared: [StorageSharingRegistry.Item] = []

        for entry in entries where entry.type != .directory {
            latest = max(latest, StorageNode.time(entry.modificationTime))
            guard entry.type == .regular else {
                sum.files += 1
                tally.add(files: 1, counted: 0, logical: 0, category: category)
                continue
            }
            if entry.isDataless {
                tally.cloudOnlyFiles += 1
                tally.cloudOnlyLogicalBytes += entry.logicalSize
            }
            if StorageSharingRegistry.isShared(entry) {
                shared.append(StorageSharingRegistry.Item(entry: entry, owner: accumulator.node))
                continue
            }
            sum.counted += entry.allocatedSize
            sum.logical += entry.logicalSize
            sum.reclaimable += entry.allocatedSize
            sum.files += 1
            tally.add(files: 1, counted: entry.allocatedSize, logical: entry.logicalSize, category: category)
        }
        if !shared.isEmpty {
            for measured in registry.register(shared) {
                sum.counted += measured.counted
                sum.logical += measured.logical
                sum.reclaimable += measured.reclaimable
                sum.files += measured.files
                tally.add(files: measured.files, counted: measured.counted, logical: measured.logical, category: category)
                tally.hardLinkExtraNames += measured.isExtraHardLinkName ? 1 : 0
                tally.hardLinkBytesNotRecounted += measured.hardLinkBytesAvoided
                tally.cloneBytesNotRecounted += measured.cloneBytesAvoided
            }
        }
        accumulator.add(sum, latestModification: latest)
        collector.merge(tally)
    }

    private func apply(
        _ measured: StorageSharingRegistry.Measured,
        to owner: StorageNode,
        category: StorageCategory,
        isSmall: Bool,
        smallHistogram: inout [Int64],
        tally: inout StorageLocalTally
    ) {
        owner.size += measured.counted
        owner.logicalSize += measured.logical
        owner.reclaimableSize += measured.reclaimable
        owner.itemCount += measured.files
        if !isSmall {
            if measured.isExtraHardLinkName { owner.flags.insert(.sharedHardLink) }
            if measured.cloneBytesAvoided > 0 { owner.flags.insert(.sharedClone) }
        } else if !smallHistogram.isEmpty {
            smallHistogram[Int(category.rawValue)] += max(measured.counted, 1)
        }
        tally.add(files: measured.files, counted: measured.counted, logical: measured.logical, category: category)
        tally.hardLinkExtraNames += measured.isExtraHardLinkName ? 1 : 0
        tally.hardLinkBytesNotRecounted += measured.hardLinkBytesAvoided
        tally.cloneBytesNotRecounted += measured.cloneBytesAvoided
    }

    // MARK: - After the walk

    /// Post-order pass: folder sizes are the sums of their children; children are sorted
    /// largest first; each folder's `category` becomes the kind using most of its space.
    /// Iterative, so very deep trees can't overflow the stack.
    static func aggregate(_ root: StorageNode) {
        let categoryCount = StorageCategory.allCases.count
        var histograms = [Int64](repeating: 0, count: categoryCount)
        var stack: [(node: StorageNode, next: Int)] = [(root, 0)]

        while let top = stack.last {
            let level = stack.count - 1
            if top.next < top.node.children.count {
                stack[level].next += 1
                let child = top.node.children[top.next]
                if child.kind == .directory {
                    stack.append((child, 0))
                    histograms.append(contentsOf: repeatElement(0, count: categoryCount))
                } else {
                    histograms[level * categoryCount + Int(child.category.rawValue)] += child.size
                }
                continue
            }

            let node = top.node
            var size: Int64 = 0
            var logical: Int64 = 0
            var reclaimable: Int64 = node.reclaimableSize // shared storage attributed by the registry
            var items = 0
            for child in node.children {
                size += child.size
                logical += child.logicalSize
                reclaimable += child.reclaimableSize
                items += child.itemCount
            }
            node.size = size
            node.logicalSize = logical
            node.reclaimableSize = min(reclaimable, size)
            node.itemCount = items
            if node.children.count > 1 {
                node.children.sort { $0.size > $1.size }
            }

            let base = level * categoryCount
            var best = Int(StorageCategory.other.rawValue)
            var bestBytes: Int64 = 0
            for index in 0..<categoryCount where histograms[base + index] > bestBytes {
                best = index
                bestBytes = histograms[base + index]
            }
            node.category = StorageCategory(rawValue: UInt8(best)) ?? .other
            if level > 0 {
                let parentBase = (level - 1) * categoryCount
                for index in 0..<categoryCount { histograms[parentBase + index] += histograms[base + index] }
            }
            histograms.removeLast(categoryCount)
            stack.removeLast()
        }
    }

    struct FinalizedIndex: Sendable {
        var searchIndex: [StorageNode]
        var lookupCandidates: [(node: StorageNode, path: String)]
    }

    /// Collects searchable nodes and the files whose Spotlight "last opened" date is worth reading.
    static func collectIndex(root: StorageNode, rootPath: String, lookupCutoff: UInt32?, lookupLimit: Int) -> FinalizedIndex {
        var index: [StorageNode] = []
        var candidates: [StorageNode] = []
        var stack: [StorageNode] = [root]
        while let node = stack.popLast() {
            for child in node.children {
                switch child.kind {
                case .directory:
                    if child.size >= 1_000_000 { index.append(child) }
                    stack.append(child)
                case .file, .package:
                    index.append(child)
                    if let lookupCutoff, child.lastUsedTime < lookupCutoff, !child.isCloudOnly { candidates.append(child) }
                case .smallFiles:
                    break
                }
            }
        }
        candidates.sort { $0.size > $1.size }
        if candidates.count > lookupLimit { candidates.removeLast(candidates.count - lookupLimit) }
        let withPaths = candidates
            .map { (node: $0, path: StorageTree.rawPath(of: $0, root: root, rootPath: rootPath)) }
            .filter { !$0.path.isEmpty }
        return FinalizedIndex(searchIndex: index, lookupCandidates: withPaths)
    }

    /// Exclusions are stored in canonical form (`/Users/...`). When walking the data volume
    /// directly, the walker sees `/System/Volumes/Data/Users/...`, so both forms are added.
    static func walkExclusions(_ exclusions: ExclusionList, rootPath: String) -> ExclusionList {
        let dataRoot = "/System/Volumes/Data"
        guard PathUtilities.isSameOrDescendant(rootPath, of: dataRoot) else { return exclusions }
        var expanded = exclusions
        for path in exclusions.paths where !path.hasPrefix(dataRoot + "/") && path.hasPrefix("/") && path != "/" {
            expanded.add(dataRoot + path)
        }
        return expanded
    }
}

// MARK: - Walk context and helpers

/// Caller data carried by each directory job.
enum StorageWalkContext: Sendable {
    /// A folder with its own node.
    case directory(StorageNode)
    /// A folder inside a package: its contents add to the package's totals.
    case package(StoragePackageAccumulator)
}

/// Per-directory totals, merged into the shared collector once per directory.
struct StorageLocalTally {
    var directories = 0
    var files = 0
    var bytes: Int64 = 0
    var logical: Int64 = 0
    var categoryBytes = [Int64](repeating: 0, count: StorageCategory.allCases.count)
    var categoryCounts = [Int](repeating: 0, count: StorageCategory.allCases.count)
    var hardLinkExtraNames = 0
    var hardLinkBytesNotRecounted: Int64 = 0
    var cloneBytesNotRecounted: Int64 = 0
    var cloudOnlyFiles = 0
    var cloudOnlyLogicalBytes: Int64 = 0

    mutating func add(files: Int, counted: Int64, logical: Int64, category: StorageCategory) {
        self.files += files
        bytes += counted
        self.logical += logical
        categoryBytes[Int(category.rawValue)] += counted
        categoryCounts[Int(category.rawValue)] += files
    }
}

/// Thread-safe scan totals.
final class StorageStatsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = StorageScanStatistics()
    private var rootFailure: Int32?

    func merge(_ tally: StorageLocalTally) {
        lock.withLock {
            stats.directoryCount += tally.directories
            stats.fileCount += tally.files
            stats.countedBytes += tally.bytes
            stats.logicalBytes += tally.logical
            for index in tally.categoryBytes.indices {
                stats.categoryBytes[index] += tally.categoryBytes[index]
                stats.categoryCounts[index] += tally.categoryCounts[index]
            }
            stats.hardLinkExtraNames += tally.hardLinkExtraNames
            stats.hardLinkBytesNotRecounted += tally.hardLinkBytesNotRecounted
            stats.cloneBytesNotRecounted += tally.cloneBytesNotRecounted
            stats.cloudOnlyFileCount += tally.cloudOnlyFiles
            stats.cloudOnlyLogicalBytes += tally.cloudOnlyLogicalBytes
        }
    }

    func addUnreadable(path: String, isRoot: Bool, code: Int32) {
        lock.withLock {
            stats.unreadableCount += 1
            if stats.unreadablePaths.count < 200 { stats.unreadablePaths.append(path) }
            if isRoot { rootFailure = code }
        }
    }

    func addNotDownloadedFolder() {
        lock.withLock { stats.notDownloadedFolders += 1 }
    }

    func addPackage() {
        lock.withLock { stats.packageCount += 1 }
    }

    var countedBytes: Int64 { lock.withLock { stats.countedBytes } }
    var rootFailureCode: Int32? { lock.withLock { rootFailure } }
    var snapshot: StorageScanStatistics { lock.withLock { stats } }
}

/// Collects the totals of everything inside one package. Several walker threads
/// may read folders of the same package at once, so updates are locked.
final class StoragePackageAccumulator: @unchecked Sendable {
    let node: StorageNode
    private let lock = NSLock()
    private var total = StorageSharingRegistry.Measured()
    private var latest: UInt32 = 0
    private var unreadable = false

    init(node: StorageNode) {
        self.node = node
    }

    func add(_ measured: StorageSharingRegistry.Measured, latestModification: UInt32) {
        lock.withLock {
            total.counted += measured.counted
            total.logical += measured.logical
            total.reclaimable += measured.reclaimable
            total.files += measured.files
            latest = max(latest, latestModification)
        }
    }

    func markUnreadable() {
        lock.withLock { unreadable = true }
    }

    /// Writes the totals into the node. Runs once, after the walk, on a single thread.
    func finalize() {
        lock.withLock {
            node.size = total.counted
            node.logicalSize = total.logical
            node.reclaimableSize = total.reclaimable
            node.itemCount = total.files
            node.modificationTime = max(node.modificationTime, latest)
            if unreadable { node.flags.insert(.unreadable) }
        }
    }
}

final class StoragePackageList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoragePackageAccumulator] = []

    func append(_ accumulator: StoragePackageAccumulator) {
        lock.withLock { items.append(accumulator) }
    }

    var all: [StoragePackageAccumulator] { lock.withLock { items } }
}

private final class StorageBuilderState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: StorageScanProgress.Phase = .reading

    var phase: StorageScanProgress.Phase {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// De-duplicates hard links and APFS clones across the whole tree.
///
/// The rules match `UsageAccumulator`: a hard-linked file counts once (at the
/// first name found); a clone's private blocks always count and the blocks it
/// shares with its family count once. A family's storage is only freed when
/// every member is deleted, so its reclaimable bytes go to the lowest common
/// ancestor of all members — and only when every member was found in the tree.
final class StorageSharingRegistry: @unchecked Sendable {
    struct Item {
        var entry: RawDirectoryEntry
        /// The node the file is counted in: its own node, the folder's small-files node, or a package.
        var owner: StorageNode
    }

    struct Measured: Sendable {
        var counted: Int64 = 0
        var logical: Int64 = 0
        var reclaimable: Int64 = 0
        var files = 0
        var isExtraHardLinkName = false
        var hardLinkBytesAvoided: Int64 = 0
        var cloneBytesAvoided: Int64 = 0
    }

    private struct Family {
        var seen: UInt32
        var expected: UInt32
        /// Bytes freed once every member is deleted (hard links: the file's blocks; clones: the shared blocks).
        var reclaimableWhenComplete: Int64
        var commonAncestor: StorageNode
    }

    private struct CloneKey: Hashable {
        var device: Int32
        var cloneID: UInt64
    }

    private let lock = NSLock()
    private var hardLinks: [FileIdentity: Family] = [:]
    private var clones: [CloneKey: Family] = [:]

    static func isShared(_ entry: RawDirectoryEntry) -> Bool {
        entry.linkCount > 1 || (entry.mayShareBlocks && entry.cloneID != nil && entry.privateSize != nil)
    }

    func register(_ items: [Item]) -> [Measured] {
        lock.withLock { items.map { registerLocked($0.entry, owner: $0.owner) } }
    }

    private func registerLocked(_ entry: RawDirectoryEntry, owner: StorageNode) -> Measured {
        if entry.linkCount > 1 {
            let key = entry.identity
            if var family = hardLinks[key] {
                family.seen += 1
                family.commonAncestor = Self.lowestCommonAncestor(family.commonAncestor, owner)
                hardLinks[key] = family
                return Measured(isExtraHardLinkName: true, hardLinkBytesAvoided: entry.allocatedSize)
            }
            hardLinks[key] = Family(seen: 1, expected: entry.linkCount, reclaimableWhenComplete: entry.exclusiveAllocatedSize, commonAncestor: owner)
            return Measured(counted: entry.allocatedSize, logical: entry.logicalSize, reclaimable: 0, files: 1)
        }

        guard let cloneID = entry.cloneID, let privateSize = entry.privateSize else {
            return Measured(counted: entry.allocatedSize, logical: entry.logicalSize, reclaimable: entry.allocatedSize, files: 1)
        }
        let exclusive = min(privateSize, entry.allocatedSize)
        let shared = max(0, entry.allocatedSize - exclusive)
        let key = CloneKey(device: entry.device, cloneID: cloneID)
        if var family = clones[key] {
            family.seen += 1
            family.commonAncestor = Self.lowestCommonAncestor(family.commonAncestor, owner)
            clones[key] = family
            return Measured(counted: exclusive, logical: entry.logicalSize, reclaimable: exclusive, files: 1, cloneBytesAvoided: shared)
        }
        clones[key] = Family(seen: 1, expected: entry.cloneReferenceCount, reclaimableWhenComplete: shared, commonAncestor: owner)
        return Measured(counted: exclusive + shared, logical: entry.logicalSize, reclaimable: exclusive, files: 1)
    }

    /// Attributes the reclaimable storage of complete families to their lowest common ancestor.
    /// Runs once after the walk, before sizes are aggregated.
    func finalize() {
        lock.withLock {
            for family in hardLinks.values where family.seen >= family.expected {
                family.commonAncestor.reclaimableSize += family.reclaimableWhenComplete
            }
            for family in clones.values where family.seen >= family.expected && family.reclaimableWhenComplete > 0 {
                family.commonAncestor.reclaimableSize += family.reclaimableWhenComplete
            }
            hardLinks = [:]
            clones = [:]
        }
    }

    /// Lowest common ancestor using scan-time depths. Parents never change during a build.
    static func lowestCommonAncestor(_ first: StorageNode, _ second: StorageNode) -> StorageNode {
        var a = first
        var b = second
        while a.depth > b.depth, let parent = a.parent { a = parent }
        while b.depth > a.depth, let parent = b.parent { b = parent }
        while a !== b {
            guard let parentA = a.parent, let parentB = b.parent else { return a.depth <= b.depth ? a : b }
            a = parentA
            b = parentB
        }
        return a
    }
}

// MARK: - Spotlight "last opened" dates

/// Reads Spotlight's "last opened" date (`kMDItemLastUsedDate`). Only the
/// metadata index is queried; file contents are never read.
enum StorageSpotlight {
    static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }

    /// Updates `accessTime` of the given nodes with Spotlight's date when it is more recent.
    /// Each node is written by exactly one thread.
    static func applyLastOpenedDates(to candidates: [(node: StorageNode, path: String)]) async throws {
        let flag = StorageCancellationFlag()
        try await withTaskCancellationHandler {
            await BackgroundWork.run(qos: .utility) {
                let chunkCount = min(4, max(1, candidates.count / 64))
                let chunkSize = (candidates.count + chunkCount - 1) / chunkCount
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let start = chunk * chunkSize
                    let end = min(candidates.count, start + chunkSize)
                    guard start < end else { return }
                    for index in start..<end {
                        if flag.isCancelled { return }
                        let candidate = candidates[index]
                        guard let date = lastUsedDate(path: candidate.path) else { continue }
                        let time = StorageNode.time(date.timeIntervalSince1970)
                        if time > candidate.node.accessTime { candidate.node.accessTime = time }
                        candidate.node.flags.insert(.spotlightDate)
                    }
                }
            }
            if flag.isCancelled { throw CancellationError() }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// A cancellation flag readable from GCD threads (where `Task.isCancelled` doesn't apply).
final class StorageCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
