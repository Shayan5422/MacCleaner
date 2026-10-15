import CoreServices
import Darwin
import Foundation

/// A file (or package) in a cloud folder.
struct CloudFileItem: Identifiable, Sendable, Hashable {
    var path: String
    var name: String
    var locationID: String
    /// Full size of the item, wherever its data is.
    var logicalSize: Int64
    /// Space its downloaded data uses on this Mac.
    var localBytes: Int64
    var modificationDate: Date
    /// The later of the access time and Spotlight's "last opened" date. Approximate.
    var lastOpenedDate: Date?
    var isPackage: Bool
    var identity: FileIdentity

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var isStoredLocally: Bool { localBytes > 0 }
    var lastUsedDate: Date { max(modificationDate, lastOpenedDate ?? .distantPast) }
}

/// Space used by one top-level folder of a cloud location.
struct CloudFolderUsage: Identifiable, Sendable, Hashable {
    var name: String
    var path: String
    var logicalBytes: Int64 = 0
    var localBytes: Int64 = 0
    var cloudOnlyBytes: Int64 = 0
    var fileCount = 0

    var id: String { path }
}

/// What a scan found in one cloud location.
struct CloudLocationSummary: Identifiable, Sendable {
    var location: CloudLocation
    /// Everything in the location, including cloud-only items (hard links and clones counted once).
    var logicalBytes: Int64 = 0
    /// Downloaded data stored on this Mac.
    var localBytes: Int64 = 0
    var fileCount = 0
    var cloudOnlyCount = 0
    var cloudOnlyBytes: Int64 = 0
    /// Folders whose contents haven't been downloaded; they aren't listed, so nothing is downloaded.
    var notDownloadedFolders = 0
    var unreadableFolders = 0
    /// Set when the location itself couldn't be read.
    var errorMessage: String?
    var topFolders: [CloudFolderUsage] = []
    /// Largest items stored on this Mac.
    var largestLocal: [CloudFileItem] = []
    /// Items stored on this Mac that weren't opened or modified for the configured number of days.
    var notOpened: [CloudFileItem] = []

    var id: String { location.id }
    var localFileCount: Int { max(0, fileCount - cloudOnlyCount) }
}

/// A set of identical, locally stored files.
struct CloudDuplicateGroup: Identifiable, Sendable, Hashable {
    var digest: String
    var size: Int64
    var items: [CloudFileItem]

    var id: String { digest }
    /// Local space used by all copies but one.
    var redundantLocalBytes: Int64 {
        let sorted = items.map(\.localBytes).sorted(by: >)
        return sorted.dropFirst().reduce(0, +)
    }
}

struct CloudScanResult: Sendable {
    var summaries: [CloudLocationSummary]
    /// Locally stored files that may be compared for identical contents. Found from metadata
    /// only; nothing has been read yet (see `CloudDuplicateFinder`).
    var duplicateCandidates: [CloudFileItem]
    var scanDate: Date
    var notOpenedDays: Int

    var totalLogicalBytes: Int64 { summaries.reduce(0) { $0 + $1.logicalBytes } }
    var totalLocalBytes: Int64 { summaries.reduce(0) { $0 + $1.localBytes } }
    var totalCloudOnlyBytes: Int64 { summaries.reduce(0) { $0 + $1.cloudOnlyBytes } }
    var totalCloudOnlyCount: Int { summaries.reduce(0) { $0 + $1.cloudOnlyCount } }
}

/// Live state of a cloud scan, safe to poll from the main actor.
final class CloudScanProgress: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case reading, readingDates, comparing
    }

    struct Snapshot: Sendable {
        var phase: Phase = .reading
        var locationTitle = ""
        var locationIndex = 0
        var locationCount = 0
        var filesSeen = 0
        var bytesToCompare: Int64 = 0
        var bytesCompared: Int64 = 0

        var fraction: Double? {
            switch phase {
            case .reading, .readingDates:
                guard locationCount > 0 else { return nil }
                return min(0.95, Double(locationIndex) / Double(locationCount))
            case .comparing:
                guard bytesToCompare > 0 else { return nil }
                return min(1, Double(bytesCompared) / Double(bytesToCompare))
            }
        }
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var cancelled = false

    var snapshot: Snapshot { lock.withLock { state } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
    func update(_ change: (inout Snapshot) -> Void) { lock.withLock { change(&state) } }
}

/// Measures cloud folders without ever downloading anything: only metadata is read,
/// and folders that haven't been downloaded (dataless directories) are not listed.
struct CloudStorageScanner: Sendable {
    var notOpenedDays = 180
    /// Items smaller than this aren't listed individually or compared for duplicates.
    var minimumItemBytes: Int64 = 1_000_000
    var largestLimit = 50
    var notOpenedLimit = 200
    var includeHiddenItemsInLists = false
    var exclusions = ExclusionList()

    func scan(locations: [CloudLocation], progress: CloudScanProgress) async throws -> CloudScanResult {
        progress.update { $0.locationCount = locations.count }
        var summaries: [CloudLocationSummary] = []
        var duplicateCandidates: [CloudFileItem] = []
        for (index, location) in locations.enumerated() {
            try Task.checkCancellation()
            progress.update {
                $0.phase = .reading
                $0.locationIndex = index
                $0.locationTitle = location.title
            }
            let (summary, candidates) = try await scanLocation(location, progress: progress)
            summaries.append(summary)
            duplicateCandidates += candidates
        }

        progress.update {
            $0.phase = .readingDates
            $0.locationIndex = locations.count
        }
        summaries = await applyLastOpenedDates(to: summaries)
        try Task.checkCancellation()
        // Comparing contents means reading files, which macOS records as an access. That only
        // happens when the person asks for it (`CloudDuplicateFinder`), never during analysis.
        return CloudScanResult(summaries: summaries, duplicateCandidates: duplicateCandidates, scanDate: Date(), notOpenedDays: notOpenedDays)
    }

    // MARK: - One location

    private func scanLocation(_ location: CloudLocation, progress: CloudScanProgress) async throws -> (CloudLocationSummary, [CloudFileItem]) {
        var summary = CloudLocationSummary(location: location)
        guard CloudProviderDetector.isDirectory(location.path) else {
            summary.errorMessage = "This folder no longer exists."
            return (summary, [])
        }
        let collector = CloudLocationCollector(
            location: location, minimumItemBytes: minimumItemBytes, largestLimit: largestLimit,
            notOpenedLimit: notOpenedLimit, includeHidden: includeHiddenItemsInLists,
            notOpenedCutoff: Date().timeIntervalSince1970 - Double(notOpenedDays) * 86_400
        )

        var options = WalkOptions()
        options.includesHiddenItems = true
        options.descendsIntoPackages = true
        options.crossesVolumes = false
        options.exclusions = exclusions
        let isAppData = location.role == .appData

        let walker = ParallelDirectoryWalker<CloudWalkContext>(options: options, handlers: WalkHandlers(
            didRead: { job, entries in
                collector.read(job: job, entries: entries)
                progress.update { $0.filesSeen += entries.count }
            },
            descend: { entry, parent in
                if isAppData, parent.depth == 0, entry.name == CloudProviderDetector.iCloudDriveContainer {
                    return nil // iCloud Drive itself is its own location.
                }
                return collector.descend(into: entry, parent: parent)
            },
            didFail: { job, code in collector.didFail(job: job, code: code) }
        ))
        do {
            let walk = try await walker.walk(rootPath: location.path, rootContext: .folder(topLevel: nil))
            if walk.wasCancelled { throw CancellationError() }
        } catch let error as WalkError {
            summary.errorMessage = error.localizedDescription
            return (summary, [])
        }
        try Task.checkCancellation()
        return collector.finish(into: summary)
    }

    // MARK: - Last opened dates

    /// Reads Spotlight's "last opened" date for listed items (metadata only, no file access).
    private func applyLastOpenedDates(to summaries: [CloudLocationSummary]) async -> [CloudLocationSummary] {
        let cutoff = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(notOpenedDays) * 86_400)
        let limit = notOpenedLimit
        return await BackgroundWork.run(qos: .utility) {
            summaries.map { summary in
                var updated = summary
                func refresh(_ item: CloudFileItem) -> CloudFileItem {
                    guard let date = CloudSpotlight.lastUsedDate(path: item.path) else { return item }
                    var copy = item
                    copy.lastOpenedDate = max(copy.lastOpenedDate ?? .distantPast, date)
                    return copy
                }
                updated.largestLocal = summary.largestLocal.map(refresh)
                updated.notOpened = Array(summary.notOpened.map(refresh)
                    .filter { $0.lastUsedDate < cutoff }
                    .sorted { $0.localBytes > $1.localBytes }
                    .prefix(limit))
                return updated
            }
        }
    }
}

/// Spotlight's "last opened" date. Reads the metadata index only.
enum CloudSpotlight {
    static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}

// MARK: - Walk state

enum CloudWalkContext: Sendable {
    /// A regular folder; `topLevel` is the index of the location's top-level folder containing it.
    case folder(topLevel: Int?)
    /// A folder inside a package, which is listed as one item.
    case package(CloudPackageAccumulator, topLevel: Int?)
}

/// Totals of one package (`.pages`, `.app`, `.photoslibrary`…), listed as a single item.
final class CloudPackageAccumulator: @unchecked Sendable {
    let path: String
    let name: String
    let identity: FileIdentity
    let modificationTime: Double
    let accessTime: Double
    private let lock = NSLock()
    private(set) var logical: Int64 = 0
    private(set) var local: Int64 = 0

    init(path: String, entry: RawDirectoryEntry) {
        self.path = path
        self.name = entry.name
        self.identity = entry.identity
        self.modificationTime = entry.modificationTime
        self.accessTime = entry.accessTime
    }

    func add(logical: Int64, local: Int64) {
        lock.withLock {
            self.logical += logical
            self.local += local
        }
    }

    var totals: (logical: Int64, local: Int64) { lock.withLock { (logical, local) } }
}

/// Thread-safe results for one location while its walk runs.
final class CloudLocationCollector: @unchecked Sendable {
    private let location: CloudLocation
    private let minimumItemBytes: Int64
    private let largestLimit: Int
    private let notOpenedLimit: Int
    private let includeHidden: Bool
    private let notOpenedCutoff: Double

    private let usage = UsageAccumulator()
    private let lock = NSLock()
    private var cloudOnlyCount = 0
    private var notDownloadedFolders = 0
    private var unreadable = 0
    private var rootError: Int32?
    private var topFolderNames: [String] = []
    private var topFolders: [Int: CloudFolderUsage] = [:]
    private var rootFiles = CloudFolderUsage(name: "", path: "")
    private var items: [CloudFileItem] = []
    private var oldItems: [CloudFileItem] = []
    private var duplicateCandidates: [CloudFileItem] = []
    private var packages: [(CloudPackageAccumulator, Int?)] = []

    init(location: CloudLocation, minimumItemBytes: Int64, largestLimit: Int, notOpenedLimit: Int, includeHidden: Bool, notOpenedCutoff: Double) {
        self.location = location
        self.minimumItemBytes = minimumItemBytes
        self.largestLimit = largestLimit
        self.notOpenedLimit = notOpenedLimit
        self.includeHidden = includeHidden
        self.notOpenedCutoff = notOpenedCutoff
    }

    func descend(into entry: RawDirectoryEntry, parent: DirectoryJob<CloudWalkContext>) -> CloudWalkContext? {
        let topLevel: Int?
        let package: CloudPackageAccumulator?
        switch parent.context {
        case .package(let accumulator, let index):
            topLevel = index
            package = accumulator
        case .folder(let index):
            if parent.depth == 0 {
                topLevel = lock.withLock {
                    topFolderNames.append(entry.name)
                    return topFolderNames.count - 1
                }
            } else {
                topLevel = index
            }
            package = nil
        }
        if entry.isDataless {
            // Listing a placeholder folder would make the provider download its contents.
            lock.withLock { notDownloadedFolders += 1 }
            return nil
        }
        if let package { return .package(package, topLevel: topLevel) }
        if StoragePackages.isPackage(name: entry.name) {
            let accumulator = CloudPackageAccumulator(path: PathUtilities.join(parent.path, entry.name), entry: entry)
            lock.withLock { packages.append((accumulator, topLevel)) }
            return .package(accumulator, topLevel: topLevel)
        }
        return .folder(topLevel: topLevel)
    }

    func read(job: DirectoryJob<CloudWalkContext>, entries: [RawDirectoryEntry]) {
        let files = entries.filter { $0.type != .directory }
        usage.add(files)
        var logical: Int64 = 0
        var local: Int64 = 0
        var cloudOnlyBytes: Int64 = 0
        var cloudOnly = 0
        var fileCount = 0
        var newItems: [CloudFileItem] = []
        let topLevel: Int?
        var package: CloudPackageAccumulator?
        switch job.context {
        case .folder(let index): topLevel = index
        case .package(let accumulator, let index):
            topLevel = index
            package = accumulator
        }

        for entry in files where entry.type == .regular {
            fileCount += 1
            logical += entry.logicalSize
            if entry.isDataless {
                cloudOnly += 1
                cloudOnlyBytes += entry.logicalSize
                continue
            }
            local += entry.allocatedSize
            guard package == nil, entry.allocatedSize >= minimumItemBytes || entry.logicalSize >= minimumItemBytes else { continue }
            if !includeHidden, entry.name.hasPrefix(".") || entry.isHiddenFlagSet { continue }
            newItems.append(CloudFileItem(
                path: PathUtilities.join(job.path, entry.name),
                name: entry.name,
                locationID: location.id,
                logicalSize: entry.logicalSize,
                localBytes: entry.allocatedSize,
                modificationDate: Date(timeIntervalSince1970: entry.modificationTime),
                lastOpenedDate: entry.accessTime > 0 ? Date(timeIntervalSince1970: entry.accessTime) : nil,
                isPackage: false,
                identity: entry.identity
            ))
        }
        package?.add(logical: logical, local: local)

        lock.withLock {
            cloudOnlyCount += cloudOnly
            if let topLevel {
                var folder = topFolders[topLevel] ?? CloudFolderUsage(name: topFolderNames[topLevel], path: PathUtilities.join(location.path, topFolderNames[topLevel]))
                folder.logicalBytes += logical
                folder.localBytes += local
                folder.cloudOnlyBytes += cloudOnlyBytes
                folder.fileCount += fileCount
                topFolders[topLevel] = folder
            } else {
                rootFiles.logicalBytes += logical
                rootFiles.localBytes += local
                rootFiles.cloudOnlyBytes += cloudOnlyBytes
                rootFiles.fileCount += fileCount
            }
            for item in newItems { record(item, isRegularFile: true) }
        }
    }

    func didFail(job: DirectoryJob<CloudWalkContext>, code: Int32) {
        lock.withLock {
            unreadable += 1
            if job.depth == 0 { rootError = code }
        }
    }

    /// Dependency and build folders (node_modules, .git, DerivedData…) hold many identical files
    /// that tools manage; removing their downloads frees little and can break offline builds.
    static func isInsideDeveloperFolder(_ path: String) -> Bool {
        path.split(separator: "/").contains { StorageCategory.developerFolderNames.contains(String($0)) }
    }

    /// Keeps the largest items and the not-opened ones, bounded. Call with `lock` held.
    private func record(_ item: CloudFileItem, isRegularFile: Bool) {
        items.append(item)
        if items.count > largestLimit * 4 {
            items.sort { $0.localBytes > $1.localBytes }
            items.removeLast(items.count - largestLimit)
        }
        if item.lastUsedDate.timeIntervalSince1970 < notOpenedCutoff {
            oldItems.append(item)
            if oldItems.count > notOpenedLimit * 8 {
                oldItems.sort { $0.localBytes > $1.localBytes }
                oldItems.removeLast(oldItems.count - notOpenedLimit * 2)
            }
        }
        if isRegularFile, !Self.isInsideDeveloperFolder(item.path) { duplicateCandidates.append(item) }
    }

    func finish(into summary: CloudLocationSummary) -> (CloudLocationSummary, [CloudFileItem]) {
        var result = summary
        let totals = usage.current
        // Packages become single items.
        let finishedPackages: [(CloudFileItem, Int?)] = lock.withLock { packages }.map { accumulator, topLevel in
            let (logical, local) = accumulator.totals
            let item = CloudFileItem(
                path: accumulator.path, name: accumulator.name, locationID: location.id,
                logicalSize: logical, localBytes: local,
                modificationDate: Date(timeIntervalSince1970: accumulator.modificationTime),
                lastOpenedDate: accumulator.accessTime > 0 ? Date(timeIntervalSince1970: accumulator.accessTime) : nil,
                isPackage: true, identity: accumulator.identity
            )
            return (item, topLevel)
        }
        return lock.withLock {
            for (item, _) in finishedPackages where item.localBytes >= minimumItemBytes {
                if !includeHidden, item.name.hasPrefix(".") { continue }
                record(item, isRegularFile: false)
            }
            result.logicalBytes = totals.logicalBytes
            result.localBytes = max(0, totals.allocatedBytes)
            result.fileCount = totals.fileCount
            result.cloudOnlyCount = cloudOnlyCount
            result.cloudOnlyBytes = totals.cloudOnlyBytes
            result.notDownloadedFolders = notDownloadedFolders
            result.unreadableFolders = unreadable
            if let rootError, totals.fileCount == 0 {
                result.errorMessage = WalkError.cannotOpen(location.path, rootError).localizedDescription
            }
            var folders = Array(topFolders.values)
            if rootFiles.fileCount > 0 {
                var root = rootFiles
                root.name = "Items at the top level"
                root.path = location.path
                folders.append(root)
            }
            if location.role == .appData {
                folders = folders.map { folder in
                    var renamed = folder
                    renamed.name = CloudProviderDetector.appContainerTitle(folder.name)
                    return renamed
                }
            }
            result.topFolders = folders.filter { $0.logicalBytes > 0 }.sorted { $0.logicalBytes > $1.logicalBytes }
            result.largestLocal = Array(items.sorted { $0.localBytes > $1.localBytes }.prefix(largestLimit))
            // Twice the limit: some may turn out to be recently opened once Spotlight's dates are read.
            result.notOpened = Array(oldItems.sorted { $0.localBytes > $1.localBytes }.prefix(notOpenedLimit * 2))
            return (result, duplicateCandidates)
        }
    }
}
