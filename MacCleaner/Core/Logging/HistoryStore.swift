import Foundation

/// A completed (or simulated) cleanup, kept so people can review what happened
/// and restore items that were moved to the Trash.
struct CleanupHistoryEntry: Codable, Sendable, Identifiable, Hashable {
    enum Source: String, Codable, Sendable {
        case manual, smartScan, automation, uninstaller

        var title: String {
            switch self {
            case .manual: return "Manual"
            case .smartScan: return "Smart Scan"
            case .automation: return "Automatic"
            case .uninstaller: return "Uninstaller"
            }
        }
    }

    struct Item: Codable, Sendable, Hashable, Identifiable {
        var originalPath: String
        var trashedPath: String?
        var bytes: Int64
        var category: String
        var restored = false

        var id: String { originalPath }
        var canRestore: Bool { trashedPath != nil && !restored }
    }

    var id = UUID()
    var date = Date()
    var title: String
    var source: Source
    var method: CleanupMethod
    var dryRun: Bool
    var bytes: Int64
    var itemCount: Int
    var skippedCount: Int
    var failedCount: Int
    /// Removed items (capped). Paths stay on this Mac and are only used for restoring.
    var items: [Item]
    var note: String?

    var restorableCount: Int { items.filter(\.canRestore).count }
}

/// Persists cleanup history as JSON in Application Support.
actor HistoryStore {
    static let maximumEntries = 300
    static let maximumItemsPerEntry = 5_000

    private let fileURL: URL
    private var entries: [CleanupHistoryEntry]?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Cleaner", isDirectory: true)
        fileURL = base.appendingPathComponent("History.json")
    }

    func allEntries() -> [CleanupHistoryEntry] {
        loadIfNeeded()
    }

    func append(_ entry: CleanupHistoryEntry) {
        var current = loadIfNeeded()
        var stored = entry
        if stored.items.count > Self.maximumItemsPerEntry {
            stored.items = Array(stored.items.prefix(Self.maximumItemsPerEntry))
        }
        current.insert(stored, at: 0)
        if current.count > Self.maximumEntries { current.removeLast(current.count - Self.maximumEntries) }
        entries = current
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Total bytes removed by real (not simulated) cleanups.
    func totalBytesCleaned() -> Int64 {
        loadIfNeeded().filter { !$0.dryRun }.reduce(0) { $0 + $1.bytes }
    }

    struct RestoreResult: Sendable {
        var restored: [String] = []
        var failed: [(path: String, reason: String)] = []
    }

    /// Moves trashed items back to their original location. Never overwrites an existing item.
    func restore(entryID: UUID, paths: Set<String>? = nil) -> RestoreResult {
        var current = loadIfNeeded()
        guard let entryIndex = current.firstIndex(where: { $0.id == entryID }) else { return RestoreResult() }
        var result = RestoreResult()
        let manager = FileManager.default
        for index in current[entryIndex].items.indices {
            let item = current[entryIndex].items[index]
            guard item.canRestore, let trashed = item.trashedPath else { continue }
            if let paths, !paths.contains(item.originalPath) { continue }
            if manager.fileExists(atPath: item.originalPath) {
                result.failed.append((item.originalPath, "An item with the same name already exists at the original location."))
                continue
            }
            guard manager.fileExists(atPath: trashed) else {
                result.failed.append((item.originalPath, "The item is no longer in the Trash."))
                continue
            }
            let parent = (item.originalPath as NSString).deletingLastPathComponent
            guard manager.fileExists(atPath: parent) else {
                result.failed.append((item.originalPath, "The original folder no longer exists."))
                continue
            }
            do {
                try manager.moveItem(atPath: trashed, toPath: item.originalPath)
                current[entryIndex].items[index].restored = true
                result.restored.append(item.originalPath)
            } catch {
                result.failed.append((item.originalPath, error.localizedDescription))
            }
        }
        entries = current
        save()
        return result
    }

    // MARK: - Persistence

    private func loadIfNeeded() -> [CleanupHistoryEntry] {
        if let entries { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([CleanupHistoryEntry].self, from: $0) } ?? []
        entries = loaded
        return loaded
    }

    private func save() {
        guard let entries else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: [.atomic])
        } catch {
            ActivityLogger.shared.error("Couldn't save cleanup history: \(error.localizedDescription)", category: .cleanup)
        }
    }
}
