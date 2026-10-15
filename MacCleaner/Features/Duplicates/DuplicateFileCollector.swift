import Darwin
import Foundation

/// A regular file found by the collector, with the metadata read in bulk.
struct DuplicateScannedFile: Sendable {
    var path: String
    var entry: RawDirectoryEntry
}

/// Everything the collector found.
struct DuplicateCollection: Sendable {
    var files: [DuplicateScannedFile] = []
    /// Roots actually scanned (symlinks resolved, nested roots removed).
    var roots: [String] = []
    var unavailableRoots: [DuplicateUnavailableRoot] = []
    var cloudOnlySkipped = 0
    var unreadableFolders = 0
}

/// Walks the chosen locations with `ParallelDirectoryWalker` and collects regular
/// files that match a filter.
///
/// * Packages (apps, Photos and Music libraries, bundles) are opaque and never entered.
/// * Folders managed by macOS or by apps (Trash, Time Machine, Photo Booth) are skipped.
/// * Dependency and version-control folders are skipped when requested.
/// * Cloud-only (dataless) files are counted but never collected, so nothing downloads.
enum DuplicateFileCollector {
    /// Folders never entered: system bookkeeping, backups and libraries managed by apps
    /// that don't use a package extension.
    static let alwaysSkippedFolderNames: Set<String> = [
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        ".MobileBackups", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
        "Backups.backupdb", "Photo Booth Library", "iPhoto Library", "Aperture Library",
        "iMovie Events.localized", "iMovie Projects.localized", "Final Cut Events", "Final Cut Projects",
    ]

    /// Dependency, build and version-control folders: their files belong to projects,
    /// which break when files inside are removed.
    static let developerFolderNames: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", ".git", ".hg", ".svn", ".bzr", "Pods", "Carthage",
        "DerivedData", ".build", ".swiftpm", "__pycache__", "site-packages", ".venv", "venv", ".tox", ".gradle",
        ".m2", ".cargo", ".rustup", ".npm", ".yarn", ".pnpm-store", ".next", ".nuxt", ".dart_tool", ".pub-cache",
        ".terraform", ".idea",
    ]

    /// Normalizes and resolves symlinks in the roots, and drops roots nested inside others.
    static func prepareRoots(_ roots: [String]) -> (roots: [String], unavailable: [DuplicateUnavailableRoot]) {
        var resolved: [String] = []
        var unavailable: [DuplicateUnavailableRoot] = []
        for root in roots {
            let normalized = PathUtilities.normalize(root)
            guard !normalized.isEmpty else { continue }
            if let real = PathUtilities.resolvedPath(normalized) {
                resolved.append(PathUtilities.firmlinkCanonical(real))
            } else {
                unavailable.append(DuplicateUnavailableRoot(path: normalized, reason: "The folder no longer exists or isn't connected."))
            }
        }
        return (PathUtilities.removingNestedPaths(resolved), unavailable)
    }

    /// Collects regular, non-empty, locally available files of at least
    /// `options.minimumSize` bytes for which `accept` returns true.
    ///
    /// - Parameter accept: Runs on walker threads for every candidate file; keep it cheap.
    static func collect(
        options: DuplicateScanOptions,
        progress: WalkProgress,
        accept: @escaping @Sendable (_ path: String, _ entry: RawDirectoryEntry) -> Bool
    ) async throws -> DuplicateCollection {
        let prepared = prepareRoots(options.roots)
        let box = DuplicateLockedBox(DuplicateCollection(unavailableRoots: prepared.unavailable))

        var walkOptions = WalkOptions()
        walkOptions.includesHiddenItems = options.includeHiddenFiles
        walkOptions.descendsIntoPackages = false
        walkOptions.crossesVolumes = false
        walkOptions.exclusions = options.exclusions

        let skipped = options.skipDeveloperFolders ? alwaysSkippedFolderNames.union(developerFolderNames) : alwaysSkippedFolderNames
        let minimum = max(1, options.minimumSize)

        /// Applies the shared filters to one entry; returns nil when the file is skipped.
        @Sendable func consider(_ path: String, _ entry: RawDirectoryEntry) -> (file: DuplicateScannedFile?, cloudOnly: Bool) {
            guard entry.type == .regular, entry.error == 0, entry.logicalSize >= minimum else { return (nil, false) }
            guard accept(path, entry) else { return (nil, false) }
            // Reading a dataless file would download it from the cloud.
            if entry.isDataless { return (nil, true) }
            return (DuplicateScannedFile(path: path, entry: entry), false)
        }

        for root in prepared.roots {
            try Task.checkCancellation()
            if options.exclusions.isExcluded(root) { continue }

            guard let rootEntry = BulkDirectoryReader.readAttributes(path: root) else {
                box.withLock { $0.unavailableRoots.append(DuplicateUnavailableRoot(path: root, reason: "The location couldn't be read.")) }
                continue
            }
            switch rootEntry.type {
            case .regular:
                let result = consider(root, rootEntry)
                box.withLock { collection in
                    collection.roots.append(root)
                    if let file = result.file { collection.files.append(file) }
                    if result.cloudOnly { collection.cloudOnlySkipped += 1 }
                }
                continue
            case .directory:
                box.withLock { $0.roots.append(root) }
            default:
                continue
            }

            // Hidden items and exclusions are filtered by the walker itself.
            let walker = ParallelDirectoryWalker<Void>(options: walkOptions, progress: progress, handlers: WalkHandlers(
                didRead: { directory, entries in
                    var matches: [DuplicateScannedFile] = []
                    var cloudOnly = 0
                    for entry in entries where entry.type == .regular {
                        let result = consider(PathUtilities.join(directory.path, entry.name), entry)
                        if let file = result.file { matches.append(file) }
                        if result.cloudOnly { cloudOnly += 1 }
                    }
                    guard !matches.isEmpty || cloudOnly > 0 else { return }
                    box.withLock { collection in
                        collection.files.append(contentsOf: matches)
                        collection.cloudOnlySkipped += cloudOnly
                    }
                },
                descend: { subdirectory, _ in
                    skipped.contains(subdirectory.name) ? nil : ()
                },
                didFail: { _, _ in
                    box.withLock { $0.unreadableFolders += 1 }
                }
            ))
            do {
                let summary = try await walker.walk(rootPath: root, rootContext: ())
                if summary.wasCancelled { throw CancellationError() }
            } catch let error as WalkError {
                box.withLock { $0.unavailableRoots.append(DuplicateUnavailableRoot(path: root, reason: error.localizedDescription)) }
            }
        }
        try Task.checkCancellation()
        return box.current
    }
}

/// Recognizes media folders managed by Apple apps. Copies inside them are never
/// selected automatically, because removing them leaves broken entries in the app.
enum DuplicateManagedLibrary {
    static func name(for path: String, home: String) -> String? {
        let music = home + "/Music"
        let musicLibraries = [music + "/Music/Media.localized", music + "/Music/Media", music + "/iTunes/iTunes Media", music + "/iTunes/iTunes Music"]
        if musicLibraries.contains(where: { PathUtilities.isDescendant(path, of: $0) }) { return "Music" }
        let tvLibraries = [home + "/Movies/TV/Media.localized", home + "/Movies/TV/Media"]
        if tvLibraries.contains(where: { PathUtilities.isDescendant(path, of: $0) }) { return "TV" }
        return nil
    }
}

/// Reads a file's creation date (`st_birthtime`) without following symlinks.
enum DuplicateFileDates {
    static func creationDate(path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let seconds = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
}

/// Polls a `WalkProgress` while a walk runs and reports it.
enum DuplicateWalkPoller {
    static func start(_ progress: WalkProgress, interval: Duration = .milliseconds(200), report: @escaping @Sendable (WalkProgress.Snapshot) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                report(progress.snapshot)
                try? await Task.sleep(for: interval)
            }
        }
    }
}
