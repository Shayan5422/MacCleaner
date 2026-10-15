import Foundation

/// An item before its size is known.
struct DeveloperItemDraft: Sendable {
    enum Size: Sendable {
        /// Reported by the tool itself (simctl, Docker, Homebrew).
        case known(Int64)
        /// Remove these files or folders; the size is their measured total.
        case paths([String])
        /// Remove every child of this folder (the folder itself stays).
        case children(of: String)
        /// A command item whose size is that of a folder it cleans.
        case folder(String)
    }

    var item: DeveloperItem
    var size: Size
    /// Show the item even when its size is zero (counts of stopped containers...).
    var keepWhenEmpty = false
}

/// What one tool's collector found.
struct DeveloperToolDraft: Sendable {
    var tool: DeveloperToolKind
    var isDetected = false
    var location: String?
    var drafts: [DeveloperItemDraft] = []
    var notes: [DeveloperNote] = []
}

/// Detects developer tools and measures what each can give back. Only
/// read-only queries run during a scan (`--dry-run`, `config get`, `df`,
/// `list`); cleanup commands run only after confirmation, elsewhere.
struct DeveloperToolsScanner: Sendable {
    enum Mode: Sendable, Equatable {
        /// Everything, including slower estimates (Homebrew dry run, dangling images).
        case full
        /// Fast pass for Smart Scan: caches and tool-reported sizes only.
        case smartScan
    }

    var home: String
    var fileScanner: FileSystemScanner
    var exclusions: ExclusionList
    var policy: SafetyPolicy
    var mode: Mode

    init(
        home: String = DeveloperToolsScanner.currentHome,
        fileScanner: FileSystemScanner = FileSystemScanner(),
        exclusions: ExclusionList = ExclusionList(),
        policy: SafetyPolicy = .current,
        mode: Mode = .full
    ) {
        self.home = home
        self.fileScanner = fileScanner
        self.exclusions = exclusions
        self.policy = policy
        self.mode = mode
    }

    /// The home folder with symbolic links resolved, matching `SafetyPolicy`.
    static var currentHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PathUtilities.resolvedPath(home) ?? home
    }

    /// Tools covered by Smart Scan.
    static let smartScanTools: Set<DeveloperToolKind> = [
        .xcode, .simulators, .swiftPM, .cocoaPods, .carthage, .homebrew, .npm, .pnpm, .yarn, .pip, .uv, .docker,
    ]

    func scan(
        tools: Set<DeveloperToolKind> = Set(DeveloperToolKind.allCases),
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async -> DeveloperScanResult {
        progress?(0.02, "Looking for developer tools…")
        let environment = await DeveloperEnvironment.detect(home: home)
        let xcodeRunning = DeveloperEnvironment.isXcodeRunning()
        let requested = DeveloperToolKind.allCases.filter { tools.contains($0) }

        // Collect in parallel, a few tools at a time (each may start a command-line tool).
        let limiter = AsyncLimiter(limit: 4)
        let counter = DeveloperProgressCounter(total: requested.count)
        var drafts: [DeveloperToolDraft] = []
        await withTaskGroup(of: DeveloperToolDraft.self) { group in
            for tool in requested {
                group.addTask {
                    await limiter.run {
                        await collect(tool, environment: environment, xcodeRunning: xcodeRunning)
                    }
                }
            }
            for await draft in group {
                drafts.append(draft)
                let done = counter.increment()
                progress?(0.05 + 0.45 * Double(done) / Double(max(1, requested.count)), "Checked \(draft.tool.title)")
            }
        }
        if Task.isCancelled { return DeveloperScanResult() }

        progress?(0.5, "Measuring caches…")
        let measured = await measure(drafts, progress: progress)
        if Task.isCancelled { return DeveloperScanResult() }

        progress?(0.97, "Preparing results…")
        let collected = drafts
        let result = await BackgroundWork.run(qos: .userInitiated) { [self] in
            assemble(collected, measured: measured, xcodeRunning: xcodeRunning, requested: requested)
        }
        progress?(1, "Done")
        return result
    }

    // MARK: - Measuring

    private struct Measurements: Sendable {
        var paths: [String: DiskUsage] = [:]
        var children: [String: [String: DiskUsage]] = [:]
    }

    private func measure(_ drafts: [DeveloperToolDraft], progress: (@Sendable (Double, String) -> Void)?) async -> Measurements {
        var paths = Set<String>()
        var folders = Set<String>()
        for draft in drafts {
            for item in draft.drafts {
                switch item.size {
                case .known: break
                case .paths(let list): paths.formUnion(list)
                case .folder(let path): paths.insert(path)
                case .children(let folder): folders.insert(folder)
                }
            }
        }
        var result = Measurements()
        // Measure in small batches (each batch in parallel) so progress keeps moving.
        let sortedPaths = paths.sorted()
        let batchSize = 8
        var start = 0
        while start < sortedPaths.count, !Task.isCancelled {
            let batch = Array(sortedPaths[start..<min(start + batchSize, sortedPaths.count)])
            progress?(0.5 + 0.3 * Double(start) / Double(max(1, sortedPaths.count)), "Measuring \(PathUtilities.abbreviate(batch[0]))…")
            let measured = await fileScanner.measure(paths: batch, concurrency: 4)
            result.paths.merge(measured) { first, _ in first }
            start += batchSize
        }
        let sortedFolders = folders.sorted()
        for (index, folder) in sortedFolders.enumerated() {
            if Task.isCancelled { break }
            progress?(0.8 + 0.15 * Double(index) / Double(max(1, sortedFolders.count)), "Measuring \(PathUtilities.abbreviate(folder))…")
            result.children[folder] = (try? await DeveloperFolderMeasurer.measureChildren(of: folder)) ?? [:]
        }
        return result
    }

    // MARK: - Assembly

    private func assemble(
        _ drafts: [DeveloperToolDraft],
        measured: Measurements,
        xcodeRunning: Bool,
        requested: [DeveloperToolKind]
    ) -> DeveloperScanResult {
        var result = DeveloperScanResult(isXcodeRunning: xcodeRunning)
        for draft in drafts {
            guard draft.isDetected else {
                if draft.tool != .temporaryFiles { result.missingTools.append(draft.tool) }
                continue
            }
            var items: [DeveloperItem] = []
            for itemDraft in draft.drafts {
                if let item = finish(itemDraft, measured: measured) { items.append(item) }
            }
            // Keep each group together, largest items first.
            let groupOrder = draft.drafts.map(\.item.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            items.sort { lhs, rhs in
                let left = groupOrder.firstIndex(of: lhs.group) ?? 0
                let right = groupOrder.firstIndex(of: rhs.group) ?? 0
                if left != right { return left < right }
                // Archives: oldest first, the ones people most likely no longer need.
                if lhs.trashOnly, rhs.trashOnly, let leftDate = lhs.date, let rightDate = rhs.date, leftDate != rightDate {
                    return leftDate < rightDate
                }
                return lhs.bytes > rhs.bytes
            }
            if draft.tool == .temporaryFiles && items.isEmpty { continue }
            result.reports.append(DeveloperToolReport(tool: draft.tool, location: draft.location, items: items, notes: draft.notes))
        }
        result.reports.sort { lhs, rhs in
            if lhs.recoverableBytes != rhs.recoverableBytes { return lhs.recoverableBytes > rhs.recoverableBytes }
            return (requested.firstIndex(of: lhs.tool) ?? 0) < (requested.firstIndex(of: rhs.tool) ?? 0)
        }
        result.missingTools.sort { (requested.firstIndex(of: $0) ?? 0) < (requested.firstIndex(of: $1) ?? 0) }
        result.date = Date()
        return result
    }

    private func finish(_ draft: DeveloperItemDraft, measured: Measurements) -> DeveloperItem? {
        var item = draft.item
        switch draft.size {
        case .known(let bytes):
            item.bytes = bytes
            return bytes > 0 || draft.keepWhenEmpty ? item : nil
        case .folder(let path):
            item.bytes = measured.paths[path]?.reclaimableBytes ?? 0
            return item.bytes > 0 || draft.keepWhenEmpty ? item : nil
        case .paths(let paths):
            let targets = paths.compactMap { path -> DeveloperFileTarget? in
                guard let usage = measured.paths[path] else { return nil }
                return target(path, usage: usage)
            }
            return fileItem(item, targets: targets)
        case .children(let folder):
            let usages = measured.children[folder] ?? [:]
            let targets = usages.keys.sorted().compactMap { path in target(path, usage: usages[path] ?? .zero) }
            if item.path == nil { item.path = folder }
            return fileItem(item, targets: targets)
        }
    }

    private func fileItem(_ base: DeveloperItem, targets: [DeveloperFileTarget]) -> DeveloperItem? {
        let usage = targets.reduce(DiskUsage.zero) { $0 + $1.usage }
        // Items that free no space aren't worth a row on a page about space.
        guard !targets.isEmpty, usage.allocatedBytes > 0 else { return nil }
        var item = base
        item.action = .delete(targets)
        item.bytes = usage.reclaimableBytes
        if item.path == nil { item.path = targets.count == 1 ? targets[0].path : (targets[0].path as NSString).deletingLastPathComponent }
        return item
    }

    /// A removable target, if exclusions and the safety policy allow it.
    private func target(_ path: String, usage: DiskUsage) -> DeveloperFileTarget? {
        guard !exclusions.isExcluded(path), policy.evaluate(path: path, purpose: .developerData).isAllowed else { return nil }
        return DeveloperFileTarget(path: path, snapshot: FileSnapshot.capture(path: path), usage: usage)
    }
}

/// Thread-safe counter for progress reporting.
final class DeveloperProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    let total: Int

    init(total: Int) {
        self.total = total
    }

    func increment() -> Int {
        lock.withLock {
            done += 1
            return done
        }
    }
}
