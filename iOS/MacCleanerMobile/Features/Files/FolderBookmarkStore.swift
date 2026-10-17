import Foundation

/// A folder the person picked, kept as a bookmark so the app can open it again after a relaunch.
struct SavedFolder: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var addedAt = Date()
}

/// Saves the picked folders' bookmarks in Application Support, and turns them back into URLs.
struct FolderBookmarkStore: Sendable {
    var fileURL: URL

    static var standard: FolderBookmarkStore {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return FolderBookmarkStore(fileURL: support.appendingPathComponent("CleanupFolders.json"))
    }

    func load() -> [SavedFolder] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedFolder].self, from: data)) ?? []
    }

    func save(_ folders: [SavedFolder]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(folders).write(to: fileURL, options: .atomic)
    }

    /// A bookmark for a folder from the document picker, made while its security scope is open.
    static func makeBookmark(for url: URL) throws -> Data {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    enum Resolution: Sendable {
        /// The folder's URL, and a new bookmark when the saved one was stale.
        case resolved(URL, refreshedBookmark: Data?)
        /// The folder can't be opened anymore; the person has to pick it again.
        case unavailable
    }

    /// Resolves a saved bookmark. A stale bookmark is made again from the resolved URL; a folder that was deleted
    /// or can't be found means asking the person again.
    static func resolve(_ folder: SavedFolder) -> Resolution {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale),
              !url.path.contains("/.Trash") else {
            return .unavailable
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable
        }
        let refreshed = isStale ? try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return .resolved(url, refreshedBookmark: refreshed)
    }

    /// Where a folder is, in the words of the Files app: "iCloud Drive", "On My iPhone".
    static func locationName(for url: URL, deviceWord: String) -> String {
        let path = url.path
        if path.contains("/Mobile Documents/") { return "iCloud Drive" }
        if path.contains("/File Provider Storage") { return "On My \(deviceWord)" }
        if path.hasPrefix(FileScanner.canonicalPath(URL(fileURLWithPath: NSHomeDirectory()))) || path.hasPrefix(NSHomeDirectory()) {
            return "Mac Cleaner"
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty || parent == "/" ? "Files" : parent
    }
}

/// Security-scoped access to the picked folders, kept open while their results are on screen so files can be
/// previewed and deleted.
@MainActor
final class FolderAccessSession {
    private var urls: [URL] = []

    func open(_ newURLs: [URL]) {
        for url in newURLs where !urls.contains(url) {
            if url.startAccessingSecurityScopedResource() { urls.append(url) }
        }
    }

    func close(_ url: URL) {
        guard let index = urls.firstIndex(of: url) else { return }
        urls.remove(at: index).stopAccessingSecurityScopedResource()
    }

    func closeAll() {
        for url in urls { url.stopAccessingSecurityScopedResource() }
        urls.removeAll()
    }
}
