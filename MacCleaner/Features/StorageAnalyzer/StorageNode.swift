import Darwin
import Foundation

/// One item in a storage tree: a folder, a file, a package, or the combined
/// "smaller items" of a folder.
///
/// Memory is bounded on volumes with millions of files: folders always get a
/// node, files get one only when they use at least the builder's threshold
/// (1 MB by default), and the rest of a folder's files are combined into a
/// single `.smallFiles` node. Packages (apps, Photos libraries…) are leaves
/// that carry the size of everything inside them.
///
/// Concurrency: nodes are created and filled by `StorageTreeBuilder` on walker
/// threads. A node's fields are written only by the thread that reads its
/// folder (or under the builder's locks), and the walker's job queue publishes
/// them to other threads. After the build, the tree is handed to the main
/// actor and only mutated there (see the `@MainActor` methods of
/// `StorageTree`). `name` and `kind` never change, so background searches may
/// read them at any time.
final class StorageNode: @unchecked Sendable, Identifiable {
    enum Kind: UInt8, Sendable {
        case directory
        case file
        /// A bundle Finder shows as one file (`.app`, `.photoslibrary`…), measured as a whole.
        case package
        /// Every file of a folder that is smaller than the node threshold, combined.
        case smallFiles
    }

    struct Flags: OptionSet, Sendable, Hashable {
        let rawValue: UInt8
        /// The folder couldn't be read (permissions, privacy protection, I/O error).
        static let unreadable = Flags(rawValue: 1 << 0)
        /// Dot-file or `UF_HIDDEN`.
        static let hidden = Flags(rawValue: 1 << 1)
        /// A cloud placeholder (dataless): its contents aren't stored on this Mac.
        static let cloudOnly = Flags(rawValue: 1 << 2)
        /// Another name of this hard-linked file was counted first; its storage isn't counted again here.
        static let sharedHardLink = Flags(rawValue: 1 << 3)
        /// Shares APFS clone blocks with a file counted elsewhere.
        static let sharedClone = Flags(rawValue: 1 << 4)
        /// `accessTime` includes Spotlight's "last opened" date.
        static let spotlightDate = Flags(rawValue: 1 << 5)
        /// Removed from the tree after a deletion, move or exclusion.
        static let detached = Flags(rawValue: 1 << 6)
        /// Somewhere below a hidden folder (as found at scan time).
        static let inHiddenFolder = Flags(rawValue: 1 << 7)
    }

    let name: String
    let kind: Kind
    /// Depth at scan time (the root is 0).
    let depth: UInt16
    /// Inode at scan time, used to re-identify the item before it is removed or moved.
    let inode: UInt64
    private(set) weak var parent: StorageNode?

    /// Children, largest first once the build has finished.
    var children: [StorageNode] = []
    /// Bytes on disk, counting storage shared by hard links and APFS clones only once in the whole tree.
    var size: Int64 = 0
    var logicalSize: Int64 = 0
    /// Conservative estimate of the space freed by deleting this item (see `UsageAccumulator`).
    var reclaimableSize: Int64 = 0
    /// Number of files (hard links counted once). For `.smallFiles`, the number of combined items.
    var itemCount: Int = 0
    /// Seconds since 1970.
    var modificationTime: UInt32 = 0
    /// Seconds since 1970; the later of the access time and Spotlight's "last opened" date. Approximate.
    var accessTime: UInt32 = 0
    /// For files and packages, their kind. For folders, the kind that uses most of their space.
    var category: StorageCategory = .other
    var flags: Flags = []
    /// Category implied by the folder's location (inside `node_modules`, an iOS backup…).
    var folderHint: StorageCategory?

    init(name: String, kind: Kind, parent: StorageNode?, inode: UInt64) {
        self.name = name
        self.kind = kind
        self.parent = parent
        self.depth = parent.map { $0.depth &+ 1 } ?? 0
        self.inode = inode
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    var isFolder: Bool { kind == .directory }
    var isLeaf: Bool { kind != .directory }
    /// Files, packages and folders can be acted on; combined small items can't.
    var isActionable: Bool { kind != .smallFiles && !flags.contains(.detached) }
    var isHidden: Bool { flags.contains(.hidden) }
    /// Hidden itself or inside a hidden folder, as found at scan time.
    var isInHiddenLocation: Bool { !flags.isDisjoint(with: [.hidden, .inHiddenFolder]) }
    var isCloudOnly: Bool { flags.contains(.cloudOnly) }
    var isUnreadable: Bool { flags.contains(.unreadable) }

    var modificationDate: Date? { modificationTime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(modificationTime)) }
    var lastOpenedDate: Date? { accessTime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(accessTime)) }

    /// Most recent of "modified" and "last opened" — the date "old files" are judged by.
    var lastUsedTime: UInt32 { max(modificationTime, accessTime) }

    /// Display name; combined small items get a descriptive one.
    var displayName: String {
        guard kind == .smallFiles else { return name }
        return "\(NumberFormatting.count(itemCount)) smaller item\(itemCount == 1 ? "" : "s")"
    }

    var kindDescription: String {
        switch kind {
        case .directory: return isCloudOnly ? "Folder (not downloaded)" : "Folder"
        case .package: return category == .other ? "Package" : category.singularTitle
        case .smallFiles: return "Items under 1 MB"
        case .file: return category.singularTitle
        }
    }

    /// Ancestors from the root down to (not including) this node.
    var ancestors: [StorageNode] {
        var result: [StorageNode] = []
        var current = parent
        while let node = current {
            result.append(node)
            current = node.parent
        }
        return result.reversed()
    }

    /// Whether `self` is `other` or one of its descendants.
    func isDescendant(of other: StorageNode) -> Bool {
        var current: StorageNode? = self
        while let node = current {
            if node === other { return true }
            current = node.parent
        }
        return false
    }

    /// Re-parents during build or tree updates. Callers keep `children` arrays consistent.
    func setParent(_ newParent: StorageNode?) {
        parent = newParent
    }

    static func time(_ seconds: Double) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(UInt32.max) ? UInt32.max : UInt32(seconds)
    }
}

/// Totals collected while building a tree.
struct StorageScanStatistics: Sendable {
    var directoryCount = 0
    var fileCount = 0
    var packageCount = 0
    /// Bytes on disk with hard links and clones counted once.
    var countedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var unreadableCount = 0
    /// First unreadable folders (capped), for display.
    var unreadablePaths: [String] = []
    var categoryBytes = [Int64](repeating: 0, count: StorageCategory.allCases.count)
    var categoryCounts = [Int](repeating: 0, count: StorageCategory.allCases.count)
    /// Extra names of hard-linked files whose storage was already counted.
    var hardLinkExtraNames = 0
    var hardLinkBytesNotRecounted: Int64 = 0
    /// Clone blocks shared with a file counted earlier.
    var cloneBytesNotRecounted: Int64 = 0
    var cloudOnlyFileCount = 0
    var cloudOnlyLogicalBytes: Int64 = 0
    /// Cloud folders whose contents haven't been downloaded (not listed, to avoid triggering downloads).
    var notDownloadedFolders = 0

    func bytes(for category: StorageCategory) -> Int64 { categoryBytes[Int(category.rawValue)] }
    func count(for category: StorageCategory) -> Int { categoryCounts[Int(category.rawValue)] }

    var duplicateBytesAvoided: Int64 { hardLinkBytesNotRecounted + cloneBytesNotRecounted }
}

/// A scanned folder or volume as a tree of `StorageNode`s.
final class StorageTree: @unchecked Sendable {
    let root: StorageNode
    /// The folder that was walked (on the startup disk, `/System/Volumes/Data`).
    let rootPath: String
    let device: Int32
    let scanDate: Date
    let duration: TimeInterval
    /// Files at least this large have their own node.
    let fileNodeThreshold: Int64
    private(set) var statistics: StorageScanStatistics
    /// Files, packages and folders of at least 1 MB, for search. Holds strong references,
    /// so entries may be detached after deletions; filter with `isAttached`.
    private(set) var searchIndex: [StorageNode]
    /// Bumped on every mutation so views can refresh layouts.
    private(set) var version = 0

    init(
        root: StorageNode,
        rootPath: String,
        device: Int32,
        scanDate: Date,
        duration: TimeInterval,
        fileNodeThreshold: Int64,
        statistics: StorageScanStatistics,
        searchIndex: [StorageNode]
    ) {
        self.root = root
        self.rootPath = rootPath
        self.device = device
        self.scanDate = scanDate
        self.duration = duration
        self.fileNodeThreshold = fileNodeThreshold
        self.statistics = statistics
        self.searchIndex = searchIndex
    }

    // MARK: - Paths

    /// Path as walked (may start with `/System/Volumes/Data`). Empty for detached nodes.
    /// Combined small items resolve to their folder.
    func rawPath(of node: StorageNode) -> String {
        Self.rawPath(of: node, root: root, rootPath: rootPath)
    }

    static func rawPath(of node: StorageNode, root: StorageNode, rootPath: String) -> String {
        if node === root { return rootPath }
        var components: [String] = []
        var current: StorageNode? = node.kind == .smallFiles ? node.parent : node
        while let item = current, item !== root {
            if item.flags.contains(.detached) { return "" }
            components.append(item.name)
            current = item.parent
        }
        guard current === root else { return "" }
        var path = rootPath
        for component in components.reversed() { path = PathUtilities.join(path, component) }
        return path
    }

    /// Canonical path for display and actions (`/Users/...` instead of `/System/Volumes/Data/Users/...`).
    func path(of node: StorageNode) -> String {
        let raw = rawPath(of: node)
        return raw.isEmpty ? raw : PathUtilities.firmlinkCanonical(raw)
    }

    var displayRootPath: String { PathUtilities.firmlinkCanonical(rootPath) }

    /// Whether `node` is still part of the tree.
    func isAttached(_ node: StorageNode) -> Bool {
        var current: StorageNode? = node
        while let item = current {
            if item === root { return true }
            if item.flags.contains(.detached) { return false }
            current = item.parent
        }
        return false
    }

    /// Converts a canonical or raw path to the walked form, or nil when it is outside the tree.
    func walkedPath(for path: String) -> String? {
        let normalized = PathUtilities.normalize(path)
        if PathUtilities.isSameOrDescendant(normalized, of: rootPath) { return normalized }
        let dataRoot = "/System/Volumes/Data"
        if PathUtilities.isSameOrDescendant(rootPath, of: dataRoot), !normalized.hasPrefix(dataRoot + "/") {
            let candidate = dataRoot + normalized
            if PathUtilities.isSameOrDescendant(candidate, of: rootPath) { return candidate }
        }
        return nil
    }

    /// Finds the node for a path inside the tree.
    func node(atPath path: String) -> StorageNode? {
        guard let walked = walkedPath(for: path) else { return nil }
        if walked == rootPath { return root }
        let prefixLength = rootPath == "/" ? 1 : rootPath.utf8.count + 1
        let relative = String(decoding: walked.utf8.dropFirst(prefixLength), as: UTF8.self)
        var current = root
        for component in relative.split(separator: "/") {
            guard let next = current.children.first(where: { $0.kind != .smallFiles && $0.name == component }) else { return nil }
            current = next
        }
        return current
    }

    /// Identity captured at scan time, for `CleanupItem` and relocation checks.
    func snapshot(of node: StorageNode) -> FileSnapshot {
        let type: FileObjectType = node.kind == .file ? .regular : .directory
        return FileSnapshot(identity: FileIdentity(device: device, inode: node.inode), type: type)
    }

    // MARK: - Updates after cleanup (main actor only)

    /// Removes a node (deleted or excluded) and subtracts its size from every ancestor.
    @MainActor
    func remove(_ node: StorageNode) {
        guard node !== root, let parent = node.parent, isAttached(node) else { return }
        parent.children.removeAll { $0 === node }
        node.setParent(nil)
        node.flags.insert(.detached)
        adjustAncestors(from: parent, by: node, sign: -1)
        adjustStatistics(for: node, sign: -1)
        version += 1
    }

    /// Moves a node into another folder of the tree (after a same-volume move, or to the Trash),
    /// keeping all sizes consistent. Returns the node at its new location.
    @discardableResult
    @MainActor
    func move(_ node: StorageNode, into directory: StorageNode, newName: String) -> StorageNode? {
        guard node !== root, let oldParent = node.parent, isAttached(node), isAttached(directory),
              directory.kind == .directory, !directory.isDescendant(of: node) else { return nil }
        oldParent.children.removeAll { $0 === node }
        node.setParent(nil)
        node.flags.insert(.detached)
        adjustAncestors(from: oldParent, by: node, sign: -1)

        // Names never change (background searches read them), so the moved item gets a new node.
        let moved = StorageNode(name: newName, kind: node.kind, parent: directory, inode: node.inode)
        moved.children = node.children
        for child in moved.children { child.setParent(moved) }
        node.children = []
        moved.size = node.size
        moved.logicalSize = node.logicalSize
        moved.reclaimableSize = node.reclaimableSize
        moved.itemCount = node.itemCount
        moved.modificationTime = node.modificationTime
        moved.accessTime = node.accessTime
        moved.category = node.category
        moved.flags = node.flags.subtracting([.detached, .inHiddenFolder])
        if directory.isInHiddenLocation { moved.flags.insert(.inHiddenFolder) }
        moved.folderHint = node.folderHint

        let index = directory.children.firstIndex { $0.size < moved.size } ?? directory.children.endIndex
        directory.children.insert(moved, at: index)
        adjustAncestors(from: directory, by: moved, sign: 1)
        if moved.kind != .smallFiles, moved.size >= 1_000_000 || moved.kind != .directory {
            searchIndex.append(moved)
        }
        version += 1
        return moved
    }

    @MainActor
    private func adjustAncestors(from start: StorageNode, by node: StorageNode, sign: Int64) {
        var current: StorageNode? = start
        while let ancestor = current {
            ancestor.size = max(0, ancestor.size + sign * node.size)
            ancestor.logicalSize = max(0, ancestor.logicalSize + sign * node.logicalSize)
            ancestor.reclaimableSize = max(0, ancestor.reclaimableSize + sign * node.reclaimableSize)
            ancestor.itemCount = max(0, ancestor.itemCount + Int(sign) * node.itemCount)
            if let parent = ancestor.parent { Self.reposition(ancestor, in: parent) }
            current = ancestor.parent
        }
    }

    /// Keeps `parent.children` ordered largest first after one child's size changed.
    @MainActor
    private static func reposition(_ child: StorageNode, in parent: StorageNode) {
        guard var index = parent.children.firstIndex(where: { $0 === child }) else { return }
        while index > 0, parent.children[index - 1].size < child.size {
            parent.children.swapAt(index, index - 1)
            index -= 1
        }
        while index + 1 < parent.children.count, parent.children[index + 1].size > child.size {
            parent.children.swapAt(index, index + 1)
            index += 1
        }
    }

    @MainActor
    private func adjustStatistics(for node: StorageNode, sign: Int64) {
        statistics.countedBytes = max(0, statistics.countedBytes + sign * node.size)
        statistics.logicalBytes = max(0, statistics.logicalBytes + sign * node.logicalSize)
        statistics.fileCount = max(0, statistics.fileCount + Int(sign) * node.itemCount)
        // Category totals are exact for files and packages; folders are re-derived from their contents.
        var stack = [node]
        while let item = stack.popLast() {
            switch item.kind {
            case .directory:
                stack.append(contentsOf: item.children)
            case .file, .package, .smallFiles:
                let index = Int(item.category.rawValue)
                statistics.categoryBytes[index] = max(0, statistics.categoryBytes[index] + sign * item.size)
                statistics.categoryCounts[index] = max(0, statistics.categoryCounts[index] + Int(sign) * item.itemCount)
            }
        }
    }
}
