import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file, package or folder a scan found.
struct FileScanItem: Sendable, Identifiable, Hashable {
    enum Kind: Sendable, Hashable {
        case file
        /// A bundle such as a Pages document, treated as one item.
        case package
        case folder
    }

    var url: URL
    var kind: Kind
    /// The picked folder it was found in.
    var rootID: UUID
    /// The path from the picked folder, starting with its name: "Downloads/Videos/Trip.mov".
    var displayPath: String
    /// Bytes on disk, which is what deleting frees; the content size when the system reports no allocation.
    var size: Int64
    /// The size of the content, compared when looking for duplicates.
    var contentSize: Int64
    var modificationDate: Date?
    var creationDate: Date?
    var typeIdentifier: String?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// The folder it's in, from the picked folder: "Downloads › Videos".
    var location: String { displayPath.split(separator: "/").dropLast().joined(separator: " › ") }
    var contentType: UTType? { typeIdentifier.flatMap { UTType($0) } }
}

/// Files with identical content.
struct FileDuplicateGroup: Sendable, Identifiable, Hashable {
    /// The copy to keep first (the oldest, then the one with the shortest path), then the others.
    var files: [FileScanItem]
    /// The content size and SHA-256.
    var id: String

    var keeper: FileScanItem { files[0] }
    var extras: ArraySlice<FileScanItem> { files.dropFirst() }
    /// What deleting every copy but one frees.
    var reclaimableBytes: Int64 { extras.reduce(0) { $0 + $1.size } }
}

/// What a scan of the picked folders found.
struct FileScanResult: Sendable, Equatable {
    var largeFiles: [FileScanItem] = []
    var oldFiles: [FileScanItem] = []
    var duplicateGroups: [FileDuplicateGroup] = []
    var emptyFolders: [FileScanItem] = []
    /// Files and packages looked at.
    var itemCount = 0
    /// Files that are only in iCloud or another cloud service; they're skipped so nothing is downloaded.
    var cloudOnlyCount = 0
    /// Folders that couldn't be read.
    var unreadableCount = 0
    var date = Date()

    func items(in category: FileCategory) -> [FileScanItem] {
        switch category {
        case .large: return largeFiles
        case .old: return oldFiles
        case .duplicates: return duplicateGroups.flatMap(\.files)
        case .emptyFolders: return emptyFolders
        }
    }

    /// The files deleting could remove: large and old files, and every copy of a duplicate but one.
    private var reclaimableItems: [URL: FileScanItem] {
        var items: [URL: FileScanItem] = [:]
        for item in largeFiles + oldFiles + duplicateGroups.flatMap(\.extras) {
            items[item.url] = item
        }
        return items
    }

    /// Each file counted once, even when it's both large and old.
    var reclaimableBytes: Int64 { reclaimableItems.values.reduce(0) { $0 + $1.size } }
    var reclaimableFileCount: Int { reclaimableItems.count }

    /// Bytes and count for a category's summary row; duplicates count the copies beyond one.
    func total(of category: FileCategory) -> (count: Int, bytes: Int64) {
        switch category {
        case .duplicates:
            return (duplicateGroups.reduce(0) { $0 + $1.extras.count }, duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes })
        default:
            let items = items(in: category)
            return (items.count, items.reduce(0) { $0 + $1.size })
        }
    }

    /// The result without the given items, after they were deleted. Duplicate groups left with one file are dropped.
    func removing(_ urls: Set<URL>) -> FileScanResult {
        var result = self
        result.largeFiles.removeAll { urls.contains($0.url) }
        result.oldFiles.removeAll { urls.contains($0.url) }
        result.emptyFolders.removeAll { urls.contains($0.url) }
        result.duplicateGroups = duplicateGroups.compactMap { group in
            var group = group
            group.files.removeAll { urls.contains($0.url) }
            return group.files.count > 1 ? group : nil
        }
        return result
    }

    /// The result without anything from a folder the person removed from the list.
    func removingRoot(_ rootID: UUID) -> FileScanResult {
        removing(Set(FileCategory.allCases.flatMap { items(in: $0) }.filter { $0.rootID == rootID }.map(\.url)))
    }
}

/// The kinds of results, each with its own list.
enum FileCategory: String, CaseIterable, Identifiable, Sendable {
    case large, old, duplicates, emptyFolders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .large: return "Large Files"
        case .old: return "Old Files"
        case .duplicates: return "Duplicates"
        case .emptyFolders: return "Empty Folders"
        }
    }

    var subtitle: String {
        switch self {
        case .large: return "50 MB or more"
        case .old: return "Not changed in over a year"
        case .duplicates: return "Identical copies"
        case .emptyFolders: return "Nothing inside"
        }
    }

    var symbol: String {
        switch self {
        case .large: return "arrow.up.doc.fill"
        case .old: return "clock.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .emptyFolders: return "folder"
        }
    }

    var tint: Color {
        switch self {
        case .large: return .purple
        case .old: return .orange
        case .duplicates: return .teal
        case .emptyFolders: return Color(.systemGray)
        }
    }

    /// The noun for the items in its list.
    var noun: String { self == .emptyFolders ? "folder" : "file" }
}

/// How far a scan got.
struct FileScanProgress: Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case listing
        case comparing
    }

    var stage: Stage = .listing
    var itemsFound = 0
    /// Files of the same size whose content is compared.
    var toCompare = 0
    var compared = 0

    var fraction: Double? {
        stage == .comparing && toCompare > 0 ? Double(compared) / Double(toCompare) : nil
    }

    var message: String {
        switch stage {
        case .listing:
            return itemsFound == 0 ? "Looking through your folders…" : "\(NumberFormatting.count(itemsFound, "item")) checked"
        case .comparing:
            return "Comparing \(NumberFormatting.count(toCompare, "possible duplicate"))…"
        }
    }
}
