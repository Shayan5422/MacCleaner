import Darwin
import Foundation

/// Identity of an item captured at scan time. Cleanup re-checks it right before
/// removing anything, so an item that was replaced after the scan (for example
/// by a symlink pointing somewhere else) is never deleted by mistake.
struct FileSnapshot: Sendable, Hashable, Codable {
    var identity: FileIdentity
    var type: FileObjectType

    /// Reads the current identity of `path` without following a final symlink.
    static func capture(path: String) -> FileSnapshot? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileSnapshot(
            identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)),
            type: FileObjectType(mode: info.st_mode)
        )
    }
}

/// A file found during a scan, with the metadata most features need.
struct FileRecord: Sendable, Hashable, Identifiable {
    var path: String
    var type: FileObjectType
    var identity: FileIdentity
    var linkCount: UInt32
    var logicalSize: Int64
    var allocatedSize: Int64
    /// Space freed by deleting only this file (private blocks of a clone; 0 for extra hard links).
    var exclusiveSize: Int64
    var flags: UInt32
    var modificationDate: Date
    var accessDate: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isDataless: Bool { flags & FileFlags.dataless != 0 }
    var snapshot: FileSnapshot { FileSnapshot(identity: identity, type: type) }

    init(path: String, entry: RawDirectoryEntry) {
        self.path = path
        self.type = entry.type
        self.identity = entry.identity
        self.linkCount = entry.linkCount
        self.logicalSize = entry.logicalSize
        self.allocatedSize = entry.allocatedSize
        self.exclusiveSize = entry.linkCount > 1 ? 0 : entry.exclusiveAllocatedSize
        self.flags = entry.flags
        self.modificationDate = Date(timeIntervalSince1970: entry.modificationTime)
        self.accessDate = Date(timeIntervalSince1970: entry.accessTime)
    }
}

/// High-level, cancellable filesystem queries built on `ParallelDirectoryWalker`.
struct FileSystemScanner: Sendable {
    init() {}

    /// Measures a file or folder. Hard links and APFS clones are counted once.
    /// Unreadable subfolders are skipped and counted in `unreadableDirectoryCount`.
    func measure(path: String, options: WalkOptions = WalkOptions(), progress: WalkProgress? = nil) async throws -> DiskUsage {
        try Task.checkCancellation()
        let accumulator = UsageAccumulator()
        try await measure(path: path, into: accumulator, options: options, progress: progress)
        return accumulator.current
    }

    /// Adds `path` to an existing accumulator, so several items measured together
    /// share hard-link and clone de-duplication.
    func measure(
        path: String,
        into accumulator: UsageAccumulator,
        options: WalkOptions = WalkOptions(),
        progress: WalkProgress? = nil
    ) async throws {
        guard let entry = BulkDirectoryReader.readAttributes(path: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        guard entry.type == .directory else {
            accumulator.add(entry)
            return
        }
        accumulator.addDirectory()
        let walker = ParallelDirectoryWalker<Void>(options: options, progress: progress ?? WalkProgress(), handlers: WalkHandlers(
            didRead: { _, entries in accumulator.add(entries.filter { $0.type != .directory }) },
            descend: { _, _ in accumulator.addDirectory(); return () },
            didFail: { _, _ in accumulator.addUnreadableDirectory() }
        ))
        _ = try await walker.walk(rootPath: path, rootContext: ())
        try Task.checkCancellation()
    }

    /// Measures several items independently, a few at a time. Items that no longer
    /// exist are omitted from the result.
    func measure(paths: [String], options: WalkOptions = WalkOptions(), concurrency: Int = 4) async -> [String: DiskUsage] {
        var results: [String: DiskUsage] = [:]
        var adjusted = options
        adjusted.maxConcurrency = max(2, options.maxConcurrency / max(1, concurrency))
        let perItem = adjusted
        await withTaskGroup(of: (String, DiskUsage?).self) { group in
            var iterator = paths.makeIterator()
            func addNext() -> Bool {
                guard let path = iterator.next() else { return false }
                group.addTask {
                    (path, try? await measure(path: path, options: perItem))
                }
                return true
            }
            for _ in 0..<max(1, concurrency) where !addNext() { break }
            while let (path, usage) = await group.next() {
                if let usage { results[path] = usage }
                if Task.isCancelled { group.cancelAll(); continue }
                _ = addNext()
            }
        }
        return results
    }

    /// Finds regular files below `roots` that match `predicate`.
    ///
    /// - Parameters:
    ///   - keepLargest: When set, only the largest N matches are kept (memory-bounded).
    ///   - predicate: Runs on walker threads for every regular file; keep it cheap.
    func findFiles(
        in roots: [String],
        options: WalkOptions = WalkOptions(),
        keepLargest: Int? = nil,
        progress: WalkProgress? = nil,
        where predicate: @escaping @Sendable (_ path: String, _ entry: RawDirectoryEntry) -> Bool
    ) async throws -> [FileRecord] {
        let collector = FileCollector(limit: keepLargest)
        for root in PathUtilities.removingNestedPaths(roots.map(PathUtilities.normalize)) {
            try Task.checkCancellation()
            guard let rootEntry = BulkDirectoryReader.readAttributes(path: root) else { continue }
            if rootEntry.type == .regular {
                if predicate(root, rootEntry) { collector.add(FileRecord(path: root, entry: rootEntry)) }
                continue
            }
            guard rootEntry.type == .directory else { continue }
            let walker = ParallelDirectoryWalker<Void>(options: options, progress: progress ?? WalkProgress(), handlers: WalkHandlers(
                didRead: { directory, entries in
                    var matches: [FileRecord] = []
                    for entry in entries where entry.type == .regular {
                        let path = PathUtilities.join(directory.path, entry.name)
                        if predicate(path, entry) { matches.append(FileRecord(path: path, entry: entry)) }
                    }
                    if !matches.isEmpty { collector.add(contentsOf: matches) }
                },
                descend: { _, _ in () }
            ))
            _ = try await walker.walk(rootPath: root, rootContext: ())
        }
        try Task.checkCancellation()
        return collector.results
    }

    /// Size and activity of one child of a folder, from `measureChildren(of:)`.
    struct ChildMeasurement: Sendable {
        var usage: DiskUsage
        /// Most recent modification of anything inside.
        var newestModification: Date
        /// Most recent access time of the item itself (approximate on APFS).
        var lastAccess: Date
    }

    /// Measures every child of `directory` in one parallel walk. Much faster than
    /// measuring children one by one when there are many of them or a few huge ones.
    ///
    /// - Parameter include: Child names to measure; others are skipped entirely.
    func measureChildren(
        of directory: String,
        options: WalkOptions = WalkOptions(),
        progress: WalkProgress? = nil,
        include: @escaping @Sendable (String) -> Bool = { _ in true }
    ) async throws -> [String: ChildMeasurement] {
        let children = try children(of: directory).filter { include($0.name) }
        guard !children.isEmpty else { return [:] }

        let accumulators = children.map { _ in UsageAccumulator() }
        let newest = children.map { NewestDateBox(initial: $0.modificationDate) }
        var indexByName: [String: Int] = [:]
        for (index, child) in children.enumerated() { indexByName[child.name] = index }
        let lookup = indexByName

        // Files directly in the folder are measured from their own attributes.
        for (index, child) in children.enumerated() where child.type != .directory {
            if let entry = BulkDirectoryReader.readAttributes(path: child.path) { accumulators[index].add(entry) }
        }

        let walker = ParallelDirectoryWalker<Int>(options: options, progress: progress ?? WalkProgress(), handlers: WalkHandlers(
            didRead: { job, entries in
                guard job.context >= 0 else { return }
                accumulators[job.context].add(entries.filter { $0.type != .directory })
                if let latest = entries.map(\.modificationTime).max() {
                    newest[job.context].update(Date(timeIntervalSince1970: latest))
                }
            },
            descend: { entry, parent in
                if parent.context >= 0 {
                    accumulators[parent.context].addDirectory()
                    return parent.context
                }
                guard let index = lookup[entry.name] else { return nil }
                accumulators[index].addDirectory()
                return index
            },
            didFail: { job, _ in
                if job.context >= 0 { accumulators[job.context].addUnreadableDirectory() }
            }
        ))
        _ = try await walker.walk(rootPath: directory, rootContext: -1)
        try Task.checkCancellation()

        var result: [String: ChildMeasurement] = [:]
        for (index, child) in children.enumerated() {
            result[child.path] = ChildMeasurement(
                usage: accumulators[index].current,
                newestModification: newest[index].value,
                lastAccess: child.accessDate
            )
        }
        return result
    }

    /// Lists the immediate children of a directory with their own metadata (no recursion).
    func children(of directory: String, includeHidden: Bool = true) throws -> [FileRecord] {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WalkError.cannotOpen(directory, errno) }
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BulkDirectoryReader.recommendedBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var records: [FileRecord] = []
        try BulkDirectoryReader.forEachEntry(directoryFD: fd, device: info.st_dev, buffer: buffer) { entry in
            if !includeHidden && (entry.name.hasPrefix(".") || entry.isHiddenFlagSet) { return }
            records.append(FileRecord(path: PathUtilities.join(directory, entry.name), entry: entry))
        }
        return records
    }
}

/// Thread-safe collector that optionally keeps only the largest N files.
final class FileCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int?
    private var items: [FileRecord] = []
    private var smallestKept: Int64 = 0

    init(limit: Int?) {
        self.limit = limit
    }

    func add(_ record: FileRecord) {
        add(contentsOf: [record])
    }

    func add(contentsOf records: [FileRecord]) {
        lock.withLock {
            guard let limit else {
                items.append(contentsOf: records)
                return
            }
            for record in records where items.count < limit || record.allocatedSize > smallestKept {
                items.append(record)
            }
            // Trim in batches to keep insertion cheap.
            if items.count > limit * 2 {
                items.sort { $0.allocatedSize > $1.allocatedSize }
                items.removeLast(items.count - limit)
                smallestKept = items.last?.allocatedSize ?? 0
            }
        }
    }

    var results: [FileRecord] {
        lock.withLock {
            var sorted = items.sorted { $0.allocatedSize > $1.allocatedSize }
            if let limit, sorted.count > limit { sorted.removeLast(sorted.count - limit) }
            return sorted
        }
    }
}

/// Thread-safe "latest date seen" tracker.
final class NewestDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(initial: Date) {
        date = initial
    }

    func update(_ candidate: Date) {
        lock.withLock { if candidate > date { date = candidate } }
    }

    var value: Date { lock.withLock { date } }
}
