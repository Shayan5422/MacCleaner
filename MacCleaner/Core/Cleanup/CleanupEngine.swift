import Darwin
import Foundation

/// How items are removed.
enum CleanupMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Recoverable: items go to the Trash and can be restored from History or Finder.
    case moveToTrash
    /// Frees space immediately; items cannot be recovered.
    case deletePermanently

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveToTrash: return "Move to Trash"
        case .deletePermanently: return "Delete Immediately"
        }
    }
}

/// One thing to remove, as found by a scan.
struct CleanupItem: Sendable, Hashable, Identifiable, Codable {
    var path: String
    var purpose: DeletionPurpose
    /// Identity captured at scan time. If the item changes, it is skipped.
    var snapshot: FileSnapshot?
    /// Estimated space freed (from the scan's reclaimable size).
    var estimatedBytes: Int64
    /// Human-readable category, used in reports and history ("Application caches").
    var category: String

    var id: String { path }

    init(path: String, purpose: DeletionPurpose, snapshot: FileSnapshot?, estimatedBytes: Int64, category: String) {
        self.path = PathUtilities.normalize(path)
        self.purpose = purpose
        self.snapshot = snapshot
        self.estimatedBytes = estimatedBytes
        self.category = category
    }
}

struct CleanupOptions: Sendable {
    var method: CleanupMethod = .moveToTrash
    /// Skip items that a running process has open.
    var skipItemsInUse = true
    /// Only report what would be removed.
    var dryRun = false
    var title: String
    var source: CleanupHistoryEntry.Source = .manual
    var recordHistory = true

    init(title: String, method: CleanupMethod = .moveToTrash, source: CleanupHistoryEntry.Source = .manual, dryRun: Bool = false) {
        self.title = title
        self.method = method
        self.source = source
        self.dryRun = dryRun
    }
}

struct CleanupProgress: Sendable {
    var completed: Int
    var total: Int
    var currentPath: String
    var bytesProcessed: Int64

    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// What a cleanup did, item by item.
struct CleanupReport: Sendable {
    struct Removed: Sendable, Hashable {
        var path: String
        var bytes: Int64
        var trashedPath: String?
        var category: String
        var method: CleanupMethod = .moveToTrash
    }

    struct Skipped: Sendable, Hashable {
        var path: String
        var reason: String
    }

    struct Failed: Sendable, Hashable {
        var path: String
        var message: String
        var suggestion: String?
    }

    var method: CleanupMethod
    var dryRun: Bool
    var removed: [Removed] = []
    var skipped: [Skipped] = []
    var failed: [Failed] = []
    var wasCancelled = false
    var historyEntryID: UUID?

    var bytesRemoved: Int64 { removed.reduce(0) { $0 + $1.bytes } }
    var hasProblems: Bool { !skipped.isEmpty || !failed.isEmpty }

    /// One-line summary for banners and notifications.
    var summary: String {
        let size = ByteFormatting.string(bytesRemoved)
        if dryRun {
            return "Dry run: \(removed.count) item\(removed.count == 1 ? "" : "s") (\(size)) would be removed."
        }
        let trashed = removed.filter { $0.method == .moveToTrash }
        let deleted = removed.filter { $0.method == .deletePermanently }
        var text: String
        if deleted.isEmpty {
            text = "Moved \(removed.count) item\(removed.count == 1 ? "" : "s") (\(size)) to the Trash."
        } else if trashed.isEmpty {
            text = "Removed \(removed.count) item\(removed.count == 1 ? "" : "s"), freeing \(size)."
        } else {
            let deletedSize = ByteFormatting.string(deleted.reduce(0) { $0 + $1.bytes })
            let trashedSize = ByteFormatting.string(trashed.reduce(0) { $0 + $1.bytes })
            text = "Deleted \(deleted.count) item\(deleted.count == 1 ? "" : "s") (\(deletedSize)) and moved \(trashed.count) to the Trash (\(trashedSize))."
        }
        if !skipped.isEmpty { text += " \(skipped.count) skipped." }
        if !failed.isEmpty { text += " \(failed.count) couldn't be removed." }
        if wasCancelled { text += " Cancelled before finishing." }
        return text
    }
}

/// Removes items safely. Every item is re-identified and checked against the
/// `SafetyPolicy` immediately before removal; items that are open in a running
/// app are skipped; everything is recorded in the history so trashed items can
/// be restored.
actor CleanupEngine {
    private let policy: SafetyPolicy
    private let history: HistoryStore
    private let logger: ActivityLogger

    init(policy: SafetyPolicy = .current, history: HistoryStore, logger: ActivityLogger = .shared) {
        self.policy = policy
        self.history = history
        self.logger = logger
    }

    func clean(
        _ items: [CleanupItem],
        options: CleanupOptions,
        progress: (@Sendable (CleanupProgress) -> Void)? = nil
    ) async -> CleanupReport {
        var report = CleanupReport(method: options.method, dryRun: options.dryRun)
        let started = Date()

        // Drop duplicates and items nested inside other selected items.
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let topLevel = PathUtilities.removingNestedPaths(Array(byPath.keys)).compactMap { byPath[$0] }

        let openFiles = options.skipItemsInUse && !options.dryRun
            ? await BackgroundWork.run(qos: .userInitiated) { ProcessInspector.openFiles() }
            : OpenFileIndex()
        let runningExecutables = options.skipItemsInUse
            ? await BackgroundWork.run(qos: .userInitiated) {
                ProcessInspector.allProcesses().filter(\.isOwnedByCurrentUser).compactMap { process in
                    process.executablePath.map { (path: $0, name: process.name) }
                }
            }
            : []

        var processedBytes: Int64 = 0
        for (index, item) in topLevel.enumerated() {
            if Task.isCancelled {
                report.wasCancelled = true
                break
            }
            progress?(CleanupProgress(completed: index, total: topLevel.count, currentPath: item.path, bytesProcessed: processedBytes))

            let verdict = policy.evaluate(path: item.path, purpose: item.purpose)
            if case .denied(let reason) = verdict {
                report.skipped.append(.init(path: item.path, reason: reason))
                continue
            }
            if let expected = item.snapshot {
                guard let current = FileSnapshot.capture(path: item.path) else {
                    report.skipped.append(.init(path: item.path, reason: "The item no longer exists."))
                    continue
                }
                if current != expected {
                    report.skipped.append(.init(path: item.path, reason: "The item changed after the scan, so it was left untouched. Scan again to review it."))
                    continue
                }
            }
            if options.skipItemsInUse {
                let holders = openFiles.holders(of: item.path)
                let running = runningExecutables.filter { PathUtilities.isSameOrDescendant($0.path, of: item.path) }
                if !holders.isEmpty || !running.isEmpty {
                    let names = Array(Set(holders.map(\.process) + running.map(\.name))).sorted().prefix(3).joined(separator: ", ")
                    report.skipped.append(.init(path: item.path, reason: "In use by \(names). Quit the app and try again."))
                    continue
                }
            }

            if options.dryRun {
                report.removed.append(.init(path: item.path, bytes: item.estimatedBytes, trashedPath: nil, category: item.category))
                processedBytes += item.estimatedBytes
                continue
            }

            do {
                // Personal files, apps and app settings always go to the Trash.
                let method = item.purpose.allowsPermanentDeletion ? options.method : .moveToTrash
                let removed = try await remove(item, method: method)
                report.removed.append(removed)
                processedBytes += removed.bytes
            } catch {
                let (message, suggestion) = CleanupErrorAdvisor.describe(error, item: item)
                report.failed.append(.init(path: item.path, message: message, suggestion: suggestion))
            }
        }
        progress?(CleanupProgress(completed: topLevel.count, total: topLevel.count, currentPath: "", bytesProcessed: processedBytes))

        if options.recordHistory && (!report.removed.isEmpty || !report.failed.isEmpty) {
            let entry = CleanupHistoryEntry(
                title: options.title,
                source: options.source,
                method: options.method,
                dryRun: options.dryRun,
                bytes: report.bytesRemoved,
                itemCount: report.removed.count,
                skippedCount: report.skipped.count,
                failedCount: report.failed.count,
                items: report.removed.map {
                    CleanupHistoryEntry.Item(originalPath: $0.path, trashedPath: $0.trashedPath, bytes: $0.bytes, category: $0.category)
                }
            )
            report.historyEntryID = entry.id
            await history.append(entry)
        }

        let duration = String(format: "%.1f", Date().timeIntervalSince(started))
        logger.info(
            "\(options.title): \(options.dryRun ? "dry run, " : "")\(report.removed.count) removed (\(ByteFormatting.string(report.bytesRemoved))), \(report.skipped.count) skipped, \(report.failed.count) failed, method \(options.method.rawValue), \(duration)s",
            category: .cleanup
        )
        return report
    }

    private func remove(_ item: CleanupItem, method: CleanupMethod) async throws -> CleanupReport.Removed {
        switch method {
        case .moveToTrash:
            let trashed: String? = try await BackgroundWork.run {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)
                return resulting?.path
            }
            return .init(path: item.path, bytes: item.estimatedBytes, trashedPath: trashed, category: item.category, method: .moveToTrash)
        case .deletePermanently:
            let snapshot = item.snapshot
            let result = try await BackgroundWork.run(qos: .userInitiated) {
                try SafeRemover.remove(path: item.path, expected: snapshot)
            }
            return .init(path: item.path, bytes: max(result.bytesFreed, 0), trashedPath: nil, category: item.category, method: .deletePermanently)
        }
    }
}

/// Turns filesystem errors into explanations with a next step.
enum CleanupErrorAdvisor {
    static func describe(_ error: Error, item: CleanupItem) -> (message: String, suggestion: String?) {
        if let removal = error as? SafeRemover.RemovalError {
            switch removal {
            case .partial(let result):
                let permission = result.failures.contains { $0.code == EPERM || $0.code == EACCES }
                return (removal.localizedDescription, permission ? permissionSuggestion(for: item) : "Quit apps that may be using these files and try again.")
            case .changed:
                return (removal.localizedDescription, "Scan again to review the current contents.")
            default:
                return (removal.localizedDescription, nil)
            }
        }
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        let isPermission = nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError
            || posix == EPERM || posix == EACCES
        if isPermission {
            return ("Permission denied.", permissionSuggestion(for: item))
        }
        if nsError.code == NSFileNoSuchFileError || posix == ENOENT {
            return ("The item no longer exists.", nil)
        }
        return (nsError.localizedDescription, nil)
    }

    private static func permissionSuggestion(for item: CleanupItem) -> String {
        switch item.purpose {
        case .application:
            return "macOS blocked changes to this app. Allow Mac Cleaner in System Settings › Privacy & Security › App Management, or drag the app to the Trash in Finder."
        case .applicationData where item.path.hasPrefix("/Library/"):
            return "This system-wide file belongs to an administrator. Reveal it in Finder and move it to the Trash there (Finder asks for your password)."
        default:
            return "Grant Full Disk Access to Mac Cleaner in System Settings › Privacy & Security, or remove the item in Finder."
        }
    }
}
