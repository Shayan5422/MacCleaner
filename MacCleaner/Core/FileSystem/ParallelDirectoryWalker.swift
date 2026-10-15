import Darwin
import Foundation

/// Options that control a directory traversal.
struct WalkOptions: Sendable {
    /// Descend into other mounted volumes. Off by default so a scan of one volume
    /// never wanders into external drives, network shares or snapshots.
    var crossesVolumes = false
    /// Include dot-files and items with the `UF_HIDDEN` flag.
    var includesHiddenItems = true
    /// Descend into bundles such as `.app` or `.photoslibrary`.
    var descendsIntoPackages = true
    var exclusions = ExclusionList()
    /// Maximum depth below the root (the root's children are depth 1).
    var maxDepth = Int.max
    /// Number of threads reading directories at the same time.
    var maxConcurrency = WalkOptions.defaultConcurrency
    /// Enter folders whose listing lives only in the cloud (iCloud Drive / File Provider
    /// placeholders). Off by default: listing them would make the provider download them.
    var entersDatalessFolders = false

    static let defaultConcurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
}

/// A directory waiting to be read. `context` carries caller data such as a tree node.
struct DirectoryJob<Context: Sendable>: Sendable {
    let path: String
    let depth: Int
    let context: Context
}

/// Callbacks invoked by `ParallelDirectoryWalker`. They run concurrently on worker
/// threads, but never concurrently for the same directory.
struct WalkHandlers<Context: Sendable>: Sendable {
    /// Receives the (filtered) entries of a directory.
    var didRead: @Sendable (_ directory: DirectoryJob<Context>, _ entries: [RawDirectoryEntry]) -> Void
    /// Returns the context for a subdirectory to descend into, or nil to skip it.
    var descend: @Sendable (_ subdirectory: RawDirectoryEntry, _ parent: DirectoryJob<Context>) -> Context?
    /// Called when a directory cannot be opened or read (`errno` value).
    var didFail: @Sendable (_ directory: DirectoryJob<Context>, _ error: Int32) -> Void = { _, _ in }
}

/// Live counters of a running walk, safe to poll from any thread.
final class WalkProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var directoriesRead = 0
        var entriesSeen = 0
        var unreadableDirectories = 0
        var currentPath = ""
    }

    private let lock = NSLock()
    private var state = Snapshot()

    init() {}

    var snapshot: Snapshot { lock.withLock { state } }

    func record(directory path: String, entries: Int) {
        lock.withLock {
            state.directoriesRead += 1
            state.entriesSeen += entries
            state.currentPath = path
        }
    }

    func recordUnreadable() {
        lock.withLock { state.unreadableDirectories += 1 }
    }
}

/// Paths that could not be read during a walk (capped, for display).
struct WalkSummary: Sendable {
    var directoriesRead = 0
    var entriesSeen = 0
    var unreadablePaths: [String] = []
    var unreadableCount = 0
    var wasCancelled = false
}

enum WalkError: LocalizedError {
    case notADirectory(String)
    case cannotOpen(String, Int32)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let path):
            return "\(PathUtilities.abbreviate(path)) is not a folder."
        case .cannotOpen(let path, let code):
            if code == EPERM || code == EACCES {
                return "Mac Cleaner doesn't have permission to read \(PathUtilities.abbreviate(path)). Grant Full Disk Access in System Settings › Privacy & Security."
            }
            return "Couldn't open \(PathUtilities.abbreviate(path)): \(String(cString: strerror(code)))."
        }
    }
}

/// Multi-threaded directory traversal built on `getattrlistbulk(2)`.
///
/// * Never follows symbolic links (directories are opened with `O_NOFOLLOW`).
/// * Stays on the root's volume unless `crossesVolumes` is set. On the startup
///   disk, scan `/System/Volumes/Data` rather than `/`: the system volume is a
///   separate sealed volume and firmlinks such as `/Users` point into the data volume.
/// * Runs on dedicated threads instead of the Swift concurrency pool, because
///   directory reads are blocking system calls.
final class ParallelDirectoryWalker<Context: Sendable>: @unchecked Sendable {
    let options: WalkOptions
    let progress: WalkProgress

    private let handlers: WalkHandlers<Context>
    private let condition = NSCondition()
    private var pending: [DirectoryJob<Context>] = []
    private var busyWorkers = 0
    private var cancelled = false
    private var summary = WalkSummary()
    private var rootDevice: Int32 = 0

    init(options: WalkOptions = WalkOptions(), progress: WalkProgress = WalkProgress(), handlers: WalkHandlers<Context>) {
        self.options = options
        self.progress = progress
        self.handlers = handlers
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Walks the tree below `rootPath`, blocking the calling thread until done.
    func run(rootPath: String, rootContext: Context) throws -> WalkSummary {
        // The root the person chose may itself be a symlink (e.g. /tmp); scan its target.
        // Symlinks below the root are never followed.
        let normalized = PathUtilities.normalize(rootPath)
        let root = PathUtilities.resolvedPath(normalized).map(PathUtilities.normalize) ?? normalized
        var info = stat()
        guard lstat(root, &info) == 0 else {
            throw WalkError.cannotOpen(root, errno)
        }
        guard FileObjectType(mode: info.st_mode) == .directory else {
            throw WalkError.notADirectory(root)
        }
        rootDevice = info.st_dev

        condition.lock()
        pending = [DirectoryJob(path: root, depth: 0, context: rootContext)]
        busyWorkers = 0
        summary = WalkSummary()
        condition.unlock()

        let workerCount = max(1, options.maxConcurrency)
        let group = DispatchGroup()
        for _ in 1..<workerCount {
            group.enter()
            let thread = Thread { [self] in
                workerLoop()
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
        workerLoop()
        group.wait()

        condition.lock()
        defer { condition.unlock() }
        summary.wasCancelled = cancelled
        return summary
    }

    /// Async wrapper: walks on background threads and supports task cancellation.
    func walk(rootPath: String, rootContext: Context) async throws -> WalkSummary {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WalkSummary, Error>) in
                let thread = Thread { [self] in
                    do {
                        continuation.resume(returning: try run(rootPath: rootPath, rootContext: rootContext))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.qualityOfService = .userInitiated
                thread.stackSize = 1 << 20
                thread.start()
            }
        } onCancel: {
            cancel()
        }
    }

    // MARK: - Workers

    private func workerLoop() {
        // Never let a scan trigger iCloud or File Provider downloads: with this policy
        // a dataless item fails to open instead of being fetched from the cloud.
        if !options.entersDatalessFolders {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: BulkDirectoryReader.recommendedBufferSize, alignment: 16
        )
        defer { buffer.deallocate() }

        while let job = nextJob() {
            let children = process(job, buffer: buffer)
            finish(adding: children)
        }
    }

    private func nextJob() -> DirectoryJob<Context>? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { return nil }
            if let job = pending.popLast() {
                busyWorkers += 1
                return job
            }
            if busyWorkers == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    private func finish(adding children: [DirectoryJob<Context>]) {
        condition.lock()
        pending.append(contentsOf: children)
        busyWorkers -= 1
        condition.broadcast()
        condition.unlock()
    }

    private func recordFailure(_ job: DirectoryJob<Context>, code: Int32) {
        progress.recordUnreadable()
        condition.lock()
        summary.unreadableCount += 1
        if summary.unreadablePaths.count < 500 { summary.unreadablePaths.append(job.path) }
        condition.unlock()
        handlers.didFail(job, code)
    }

    private func process(_ job: DirectoryJob<Context>, buffer: UnsafeMutableRawBufferPointer) -> [DirectoryJob<Context>] {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            recordFailure(job, code: errno)
            return []
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            recordFailure(job, code: errno)
            return []
        }
        // A mount point below the root: skip unless crossing volumes was requested.
        if info.st_dev != rootDevice && !options.crossesVolumes {
            return []
        }

        var entries: [RawDirectoryEntry] = []
        entries.reserveCapacity(32)
        do {
            try BulkDirectoryReader.forEachEntry(directoryFD: fd, device: info.st_dev, buffer: buffer) {
                entries.append($0)
            }
        } catch let error as POSIXError {
            recordFailure(job, code: error.code.rawValue)
        } catch {
            recordFailure(job, code: EIO)
        }

        if !options.includesHiddenItems {
            entries.removeAll { $0.name.hasPrefix(".") || $0.isHiddenFlagSet }
        }
        if options.exclusions.hasExclusions(inside: job.path) {
            entries.removeAll { options.exclusions.isExcluded(PathUtilities.join(job.path, $0.name)) }
        }

        progress.record(directory: job.path, entries: entries.count)
        condition.lock()
        summary.directoriesRead += 1
        summary.entriesSeen += entries.count
        condition.unlock()

        handlers.didRead(job, entries)

        guard job.depth < options.maxDepth else { return [] }
        var children: [DirectoryJob<Context>] = []
        for entry in entries where entry.type == .directory {
            if !options.crossesVolumes && entry.device != 0 && entry.device != rootDevice { continue }
            if entry.isDataless && !options.entersDatalessFolders { continue }
            if !options.descendsIntoPackages && PackageDetector.isPackage(name: entry.name) { continue }
            guard let context = handlers.descend(entry, job) else { continue }
            children.append(DirectoryJob(path: PathUtilities.join(job.path, entry.name), depth: job.depth + 1, context: context))
        }
        return children
    }
}

/// Recognizes bundle directories that Finder shows as a single file.
enum PackageDetector {
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "qlgenerator", "mdimporter",
        "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary", "migratedphotolibrary",
        "fcpbundle", "imovielibrary", "theater", "logicx", "band", "pages", "numbers", "key",
        "rtfd", "xcodeproj", "xcworkspace", "playground", "xcarchive", "xcassets", "dSYM",
        "pkg", "mpkg", "sparsebundle", "dmgpart", "lpdf", "scptd", "wdgt", "saver", "prefPane",
        "docarchive", "doccarchive", "nib", "storyboardc", "icon", "workflow", "action", "component",
        "vst", "vst3", "aaxplugin", "mlmodelc", "car", "lproj_bundle", "backupdb", "sketch"
    ]

    private static let lowercasedExtensions = Set(packageExtensions.map { $0.lowercased() })

    static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return lowercasedExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
