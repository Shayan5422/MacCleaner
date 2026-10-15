import Foundation
import UniformTypeIdentifiers

// MARK: - File kinds

/// Broad kind of a file, used to filter scans and to choose icons.
enum DuplicateFileKind: String, Sendable, Codable, CaseIterable, Hashable {
    case image, video, audio, document, archive, other

    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .archive: return "Archive"
        case .other: return "File"
        }
    }

    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }

    static func classify(path: String) -> DuplicateFileKind {
        classify(extension: (path as NSString).pathExtension)
    }

    /// Classifies by file name extension. Common extensions come from a table; others are
    /// looked up once in the type system and cached, so this is cheap enough for walker threads.
    static func classify(extension rawExtension: String) -> DuplicateFileKind {
        guard !rawExtension.isEmpty else { return .other }
        let ext = rawExtension.lowercased()
        if let known = knownExtensions[ext] { return known }
        return DuplicateKindCache.shared.kind(for: ext)
    }

    fileprivate static let knownExtensions: [String: DuplicateFileKind] = {
        var table: [String: DuplicateFileKind] = [:]
        let images = [
            "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "hif", "tif", "tiff", "gif", "webp", "bmp", "avif",
            "jxl", "jp2", "j2k", "psd", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2",
            "raf", "srw", "pef", "3fr", "erf", "kdc", "mos", "mrw", "x3f", "iiq", "rwl", "raw", "tga", "exr", "hdr",
            "ico", "icns", "svg",
        ]
        let videos = [
            "mov", "mp4", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "m2ts", "mts", "m2v", "3gp",
            "3g2", "vob", "ogv", "mxf", "braw", "r3d", "insv", "lrv", "dv", "hevc",
        ]
        let audio = [
            "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "alac", "ogg", "oga", "opus", "wma", "caf",
            "m4b", "m4p", "mid", "midi", "amr", "ape", "dsf", "dff", "wv",
        ]
        let documents = [
            "pdf", "doc", "docx", "dot", "dotx", "docm", "rtf", "txt", "text", "md", "markdown", "pages", "key", "numbers",
            "xls", "xlsx", "xlsm", "xlsb", "csv", "tsv", "ppt", "pptx", "pps", "ppsx", "pptm", "odt", "ods", "odp",
            "odg", "epub", "mobi", "azw", "azw3", "djvu", "xps", "oxps", "tex", "html", "htm", "webarchive", "vcf",
            "ics", "eml", "msg", "ai", "eps", "indd", "sketch", "fig",
        ]
        let archives = [
            "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma", "zst", "z",
            "cab", "iso", "dmg", "sparseimage", "img", "pkg", "xip", "jar", "apk", "ipa", "cpio", "sit", "sitx", "arj",
        ]
        for ext in images { table[ext] = .image }
        for ext in videos { table[ext] = .video }
        for ext in audio { table[ext] = .audio }
        for ext in documents { table[ext] = .document }
        for ext in archives { table[ext] = .archive }
        return table
    }()

    fileprivate static func classifyUsingTypeSystem(_ ext: String) -> DuplicateFileKind {
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .rtf) || type.conforms(to: .epub) || type.conforms(to: .compositeContent) {
            return .document
        }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        return .other
    }
}

/// Remembers type-system lookups per extension (`UTType` lookups are too slow to repeat per file).
private final class DuplicateKindCache: @unchecked Sendable {
    static let shared = DuplicateKindCache()
    private let lock = NSLock()
    private var kinds: [String: DuplicateFileKind] = [:]

    func kind(for ext: String) -> DuplicateFileKind {
        if let cached = lock.withLock({ kinds[ext] }) { return cached }
        let kind = DuplicateFileKind.classifyUsingTypeSystem(ext)
        lock.withLock { kinds[ext] = kind }
        return kind
    }
}

/// Which kinds of files a scan compares.
enum DuplicateKindFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, images, videos, audio, documents, archives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Files"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .archives: return "Archives"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "doc.on.doc"
        case .images: return DuplicateFileKind.image.symbolName
        case .videos: return DuplicateFileKind.video.symbolName
        case .audio: return DuplicateFileKind.audio.symbolName
        case .documents: return DuplicateFileKind.document.symbolName
        case .archives: return DuplicateFileKind.archive.symbolName
        }
    }

    func includes(_ kind: DuplicateFileKind) -> Bool {
        switch self {
        case .all: return true
        case .images: return kind == .image
        case .videos: return kind == .video
        case .audio: return kind == .audio
        case .documents: return kind == .document
        case .archives: return kind == .archive
        }
    }
}

/// Smallest file a scan compares. Empty files are never compared.
enum DuplicateMinimumSize: Int64, CaseIterable, Identifiable, Codable, Sendable {
    case anySize = 1
    case kilobytes10 = 10_000
    case kilobytes100 = 100_000
    case megabyte1 = 1_000_000
    case megabytes10 = 10_000_000
    case megabytes100 = 100_000_000

    var id: Int64 { rawValue }

    var title: String {
        self == .anySize ? "Any size" : "\(ByteFormatting.string(rawValue)) or larger"
    }
}

// MARK: - Scan options and progress

/// Everything a duplicate or similar-photo scan needs, captured as a value.
struct DuplicateScanOptions: Sendable, Hashable {
    var roots: [String]
    var minimumSize: Int64 = DuplicateMinimumSize.kilobytes100.rawValue
    var kinds: DuplicateKindFilter = .all
    var includeHiddenFiles = false
    var exclusions = ExclusionList()
    /// Skip dependency and version-control folders such as `node_modules` and `.git`,
    /// whose files belong to projects and break them when removed.
    var skipDeveloperFolders = true
}

/// Stages of the exact-duplicate pipeline, in order.
enum DuplicateScanStage: Int, CaseIterable, Sendable, Comparable, Identifiable {
    case scanning, groupingBySize, partialHash, fullHash, results

    static func < (lhs: DuplicateScanStage, rhs: DuplicateScanStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .scanning: return "Scanning"
        case .groupingBySize: return "Grouping by size"
        case .partialHash: return "Partial hash"
        case .fullHash: return "Full hash"
        case .results: return "Results"
        }
    }

    var activeTitle: String {
        switch self {
        case .scanning: return "Scanning folders…"
        case .groupingBySize: return "Grouping files by size…"
        case .partialHash: return "Comparing beginnings and ends…"
        case .fullHash: return "Verifying full contents…"
        case .results: return "Preparing results…"
        }
    }

    var detail: String {
        switch self {
        case .scanning: return "Listing files in the chosen locations."
        case .groupingBySize: return "Only files of exactly the same size can be identical."
        case .partialHash: return "SHA-256 of the first and last 64 KB of each same-size file."
        case .fullHash: return "SHA-256 of the entire file confirms that copies are byte-for-byte identical."
        case .results: return "Grouping identical files."
        }
    }
}

struct DuplicateScanProgress: Sendable, Equatable {
    var stage: DuplicateScanStage
    /// Progress within the stage (0...1); nil while the amount of work is unknown.
    var fraction: Double?
    var message: String

    /// Approximate progress of the whole scan (for Smart Scan).
    var overallFraction: Double {
        let within = max(0, min(1, fraction ?? 0))
        switch stage {
        case .scanning: return 0.02
        case .groupingBySize: return 0.2
        case .partialHash: return 0.2 + 0.25 * within
        case .fullHash: return 0.45 + 0.5 * within
        case .results: return 0.97
        }
    }
}

// MARK: - Files and groups

/// One file (one inode) found during a scan, with the metadata needed to compare,
/// display and safely remove it.
struct DuplicateFile: Identifiable, Sendable, Hashable {
    var path: String
    var identity: FileIdentity
    var linkCount: UInt32
    /// Logical size of all forks, as reported by the file system.
    var logicalSize: Int64
    var allocatedSize: Int64
    /// Bytes not shared with an APFS clone, when the file system reports it.
    var privateSize: Int64?
    var cloneID: UInt64?
    var cloneReferenceCount: UInt32
    var mayShareBlocks: Bool
    var flags: UInt32
    var modificationDate: Date
    var creationDate: Date?
    /// Other names of this same file (hard links) inside the scanned locations.
    var hardLinkPaths: [String] = []
    /// Why Mac Cleaner never removes this copy; nil when it can be moved to the Trash.
    var protectionReason: String?
    /// Name of the app that manages the library containing this copy (Music, TV).
    /// Such copies are never selected automatically.
    var managedLibraryName: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var folderPath: String { (path as NSString).deletingLastPathComponent }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var kind: DuplicateFileKind { DuplicateFileKind.classify(extension: fileExtension) }
    var snapshot: FileSnapshot { FileSnapshot(identity: identity, type: .regular) }
    var isProtected: Bool { protectionReason != nil }
    /// The file has other names (hard links), so removing this name alone frees no space.
    var isHardLinked: Bool { linkCount > 1 }

    /// Space freed by removing only this name: zero for hard links, only the
    /// private blocks for APFS clones.
    var exclusiveSize: Int64 {
        if linkCount > 1 { return 0 }
        if mayShareBlocks, let privateSize { return min(privateSize, allocatedSize) }
        return allocatedSize
    }

    /// Bytes this file shares with APFS clones.
    var sharedCloneBytes: Int64 {
        guard linkCount <= 1, mayShareBlocks, let privateSize else { return 0 }
        return max(0, allocatedSize - min(privateSize, allocatedSize))
    }

    /// An APFS clone whose removal frees little space.
    var isMostlySharedClone: Bool { sharedCloneBytes > 0 && sharedCloneBytes * 2 >= allocatedSize }

    var isOnExternalVolume: Bool { path.hasPrefix("/Volumes/") }

    /// Name of the external volume holding the file, if any.
    var volumeName: String? {
        guard isOnExternalVolume else { return nil }
        let parts = path.split(separator: "/", maxSplits: 3)
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// The same metadata in the form `UsageAccumulator` understands.
    var rawEntry: RawDirectoryEntry {
        RawDirectoryEntry(
            name: name, type: .regular, device: identity.device, inode: identity.inode, linkCount: linkCount,
            logicalSize: logicalSize, allocatedSize: allocatedSize, privateSize: privateSize, cloneID: cloneID,
            cloneReferenceCount: cloneReferenceCount, mayShareBlocks: mayShareBlocks, flags: flags,
            modificationTime: modificationDate.timeIntervalSince1970, accessTime: 0, error: 0
        )
    }
}

extension DuplicateFile {
    init(
        path: String,
        entry: RawDirectoryEntry,
        creationDate: Date?,
        hardLinkPaths: [String] = [],
        protectionReason: String? = nil,
        managedLibraryName: String? = nil
    ) {
        self.init(
            path: path,
            identity: entry.identity,
            linkCount: entry.linkCount,
            logicalSize: entry.logicalSize,
            allocatedSize: entry.allocatedSize,
            privateSize: entry.privateSize,
            cloneID: entry.cloneID,
            cloneReferenceCount: entry.cloneReferenceCount,
            mayShareBlocks: entry.mayShareBlocks,
            flags: entry.flags,
            modificationDate: Date(timeIntervalSince1970: entry.modificationTime),
            creationDate: creationDate,
            hardLinkPaths: hardLinkPaths,
            protectionReason: protectionReason,
            managedLibraryName: managedLibraryName
        )
    }
}

/// Files with identical contents (same size and SHA-256), one entry per inode.
struct DuplicateGroup: Identifiable, Sendable, Hashable {
    /// Hex SHA-256 of the contents; identical for every file in the group.
    var digest: String
    /// Size of one copy (data fork), in bytes.
    var contentSize: Int64
    /// At least two distinct files, sorted by path.
    var files: [DuplicateFile]

    var id: String { "\(contentSize)-\(digest)" }

    var kind: DuplicateFileKind { files.first?.kind ?? .other }

    /// The most common file name in the group; on a tie, the shortest one (copies tend to
    /// gain suffixes such as " copy" or " (1)"), then alphabetical.
    var displayName: String {
        var counts: [String: Int] = [:]
        for file in files { counts[file.name, default: 0] += 1 }
        let best = counts.min { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            if lhs.key.count != rhs.key.count { return lhs.key.count < rhs.key.count }
            return lhs.key < rhs.key
        }
        return best?.key ?? "Duplicate"
    }

    /// Space one copy occupies on disk.
    var allocatedSizePerCopy: Int64 { files.map(\.allocatedSize).max() ?? 0 }

    var containsHardLinks: Bool { files.contains { $0.isHardLinked || !$0.hardLinkPaths.isEmpty } }
    var containsClones: Bool { files.contains { $0.sharedCloneBytes > 0 } }

    /// The copy `rule` keeps.
    func keeper(rule: DuplicateKeepRule, context: DuplicateKeepContext) -> DuplicateFile? {
        rule.keeper(in: files, context: context)
    }

    /// Copies "Select Duplicates" marks for removal: every copy except the one the
    /// rule keeps, never protected copies and never copies inside app-managed libraries.
    func ruleMarkedIDs(rule: DuplicateKeepRule, context: DuplicateKeepContext) -> Set<String> {
        guard let keeper = keeper(rule: rule, context: context) else { return [] }
        return Set(files.lazy
            .filter { $0.id != keeper.id && $0.protectionReason == nil && $0.managedLibraryName == nil }
            .map(\.id))
    }

    /// Space freed if every copy the rule marks is removed (hard links excluded,
    /// APFS clones counted by their private blocks).
    func reclaimableBytes(rule: DuplicateKeepRule, context: DuplicateKeepContext) -> Int64 {
        let marked = ruleMarkedIDs(rule: rule, context: context)
        return DuplicateSpaceEstimator.reclaimableBytes(files.filter { marked.contains($0.id) })
    }
}

/// Several names of one file (hard links) found in the scanned locations. They
/// share one copy of the data, so they are not duplicates.
struct DuplicateHardLinkSet: Identifiable, Sendable, Hashable {
    var identity: FileIdentity
    var paths: [String]
    var logicalSize: Int64
    var allocatedSize: Int64
    /// Total number of names on disk, including names outside the scanned locations.
    var linkCount: UInt32

    var id: String { "\(identity.device):\(identity.inode)" }
    var name: String { ((paths.first ?? "") as NSString).lastPathComponent }
}

/// Outcome of an exact-duplicate scan.
struct DuplicateScanResult: Sendable {
    var groups: [DuplicateGroup] = []
    var hardLinkSets: [DuplicateHardLinkSet] = []
    var roots: [String] = []
    /// Locations that don't exist or couldn't be opened, with the reason.
    var unavailableRoots: [DuplicateUnavailableRoot] = []
    /// Regular files that matched the size and kind filters.
    var filesExamined = 0
    /// Files that shared their size with another file and were hashed.
    var filesCompared = 0
    var bytesRead: Int64 = 0
    /// Files whose contents are only in iCloud or another cloud provider. They are never
    /// read, because reading would download them.
    var cloudOnlySkipped = 0
    var unreadableFiles = 0
    /// Files that changed while being compared; left out to be safe.
    var changedFiles = 0
    var unreadableFolders = 0
    var startedAt = Date()
    var duration: TimeInterval = 0

    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.files.count - 1 } }
    var totalFilesInGroups: Int { groups.reduce(0) { $0 + $1.files.count } }
}

/// A location that couldn't be scanned.
struct DuplicateUnavailableRoot: Sendable, Hashable, Identifiable {
    var path: String
    var reason: String
    var id: String { path }
}

// MARK: - Keep rules

/// Paths a keep rule compares against.
struct DuplicateKeepContext: Sendable, Hashable {
    var downloadsFolder: String
    var preferredFolder: String?

    init(downloadsFolder: String, preferredFolder: String? = nil) {
        self.downloadsFolder = downloadsFolder
        self.preferredFolder = preferredFolder
    }

    /// The person's Downloads folder (symlinks resolved, like scanned paths).
    static func standard(preferredFolder: String? = nil) -> DuplicateKeepContext {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let downloads = PathUtilities.resolvedPath(home + "/Downloads") ?? PathUtilities.normalize(home + "/Downloads")
        let preferred = preferredFolder.map { PathUtilities.resolvedPath($0) ?? PathUtilities.normalize($0) }
        return DuplicateKeepContext(downloadsFolder: downloads, preferredFolder: preferred)
    }
}

/// Decides which copy of a group is kept when duplicates are selected automatically.
enum DuplicateKeepRule: String, CaseIterable, Identifiable, Codable, Sendable {
    case oldest, newest, shortestPath, outsideDownloads, preferredFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldest: return "Keep the oldest copy"
        case .newest: return "Keep the newest copy"
        case .shortestPath: return "Keep the copy with the shortest path"
        case .outsideDownloads: return "Keep the copy outside Downloads"
        case .preferredFolder: return "Keep the copy in a preferred folder"
        }
    }

    var shortTitle: String {
        switch self {
        case .oldest: return "Oldest"
        case .newest: return "Newest"
        case .shortestPath: return "Shortest path"
        case .outsideDownloads: return "Outside Downloads"
        case .preferredFolder: return "Preferred folder"
        }
    }

    /// The kept copy, for sentences such as "Selected 3 duplicates, keeping the oldest copy".
    var keptCopyPhrase: String {
        switch self {
        case .oldest: return "the oldest copy"
        case .newest: return "the newest copy"
        case .shortestPath: return "the copy with the shortest path"
        case .outsideDownloads: return "the copy outside Downloads"
        case .preferredFolder: return "the copy in your preferred folder"
        }
    }

    var explanation: String {
        switch self {
        case .oldest: return "Keeps the copy created first, which is usually the original."
        case .newest: return "Keeps the most recently created copy."
        case .shortestPath: return "Keeps the copy closest to the top of its folder hierarchy."
        case .outsideDownloads: return "Keeps a copy that isn't in Downloads, where duplicates usually come from."
        case .preferredFolder: return "Keeps the copy inside the folder you choose; otherwise one outside Downloads."
        }
    }

    /// The copy to keep. Ties are broken by the oldest copy, then the shortest path,
    /// then alphabetically, so the choice is always deterministic.
    func keeper(in files: [DuplicateFile], context: DuplicateKeepContext) -> DuplicateFile? {
        files.min { sortKey($0, context) < sortKey($1, context) }
    }

    func sortKey(_ file: DuplicateFile, _ context: DuplicateKeepContext) -> DuplicateKeepKey {
        let age = (file.creationDate ?? file.modificationDate).timeIntervalSince1970
        let length = Double(file.path.utf8.count)
        let depth = Double(file.path.utf8.lazy.filter { $0 == UInt8(ascii: "/") }.count)
        let inDownloads: Double = PathUtilities.isDescendant(file.path, of: context.downloadsFolder) ? 1 : 0
        switch self {
        case .oldest:
            return DuplicateKeepKey(numbers: [age, length, depth], path: file.path)
        case .newest:
            return DuplicateKeepKey(numbers: [-age, length, depth], path: file.path)
        case .shortestPath:
            return DuplicateKeepKey(numbers: [length, depth, age], path: file.path)
        case .outsideDownloads:
            return DuplicateKeepKey(numbers: [inDownloads, age, length, depth], path: file.path)
        case .preferredFolder:
            let inPreferred: Double
            if let preferred = context.preferredFolder, PathUtilities.isDescendant(file.path, of: preferred) {
                inPreferred = 0
            } else {
                inPreferred = 1
            }
            return DuplicateKeepKey(numbers: [inPreferred, inDownloads, age, length, depth], path: file.path)
        }
    }
}

/// Lexicographic sort key for keep rules (smaller is kept).
struct DuplicateKeepKey: Comparable {
    var numbers: [Double]
    var path: String

    static func < (lhs: DuplicateKeepKey, rhs: DuplicateKeepKey) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right {
            return left < right
        }
        return lhs.path < rhs.path
    }
}

// MARK: - Selection

/// Something that can be marked for removal inside a group.
protocol DuplicateSelectable: Identifiable where ID == String {
    /// Non-nil when the item must never be removed.
    var protectionReason: String? { get }
}

extension DuplicateFile: DuplicateSelectable {}

/// The items marked for removal, with the invariant that every group keeps at
/// least one unmarked item and protected items are never marked.
struct DuplicateMarkSet: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case marked, unmarked, unchanged
        /// The item is protected (see `protectionReason`).
        case refusedProtected
        /// Marking it would leave the group without a copy to keep.
        case refusedLastCopy
    }

    private(set) var ids: Set<String> = []

    init() {}

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Marks or unmarks one item of a group, refusing to mark protected items or the last kept one.
    @discardableResult
    mutating func setMarked<Member: DuplicateSelectable>(_ shouldMark: Bool, member: Member, in members: [Member]) -> Outcome {
        guard shouldMark else {
            return ids.remove(member.id) == nil ? .unchanged : .unmarked
        }
        if ids.contains(member.id) { return .unchanged }
        if member.protectionReason != nil { return .refusedProtected }
        let keptAfterwards = members.filter { $0.id != member.id && !ids.contains($0.id) }.count
        guard keptAfterwards >= 1 else { return .refusedLastCopy }
        ids.insert(member.id)
        return .marked
    }

    /// Replaces the marks of one group. Protected items are dropped from `chosen`, and if
    /// `chosen` would mark every item, the first item is kept.
    mutating func replaceMarks<Member: DuplicateSelectable>(in members: [Member], with chosen: Set<String>) {
        var allowed = Set(members.lazy.filter { chosen.contains($0.id) && $0.protectionReason == nil }.map(\.id))
        if !members.isEmpty, allowed.count >= members.count, let first = members.first {
            allowed.remove(first.id)
        }
        for member in members {
            if allowed.contains(member.id) { ids.insert(member.id) } else { ids.remove(member.id) }
        }
    }

    /// Keeps only `keeper` in its group: every other unprotected item is marked.
    mutating func keepOnly<Member: DuplicateSelectable>(_ keeper: Member, in members: [Member]) {
        replaceMarks(in: members, with: Set(members.lazy.filter { $0.id != keeper.id }.map(\.id)))
    }

    mutating func unmarkAll<Member: DuplicateSelectable>(in members: [Member]) {
        for member in members { ids.remove(member.id) }
    }

    mutating func removeAll() {
        ids.removeAll()
    }

    /// Drops marks for items that no longer exist in the results.
    mutating func prune(keeping validIDs: Set<String>) {
        ids.formIntersection(validIDs)
    }

    /// Restores the invariant after groups were rearranged: a group whose items are
    /// all marked gets its first item unmarked. Returns the number of groups repaired.
    @discardableResult
    mutating func repair<Member: DuplicateSelectable>(groups: [[Member]]) -> Int {
        var repaired = 0
        for members in groups where !members.isEmpty && members.allSatisfy({ ids.contains($0.id) }) {
            if let first = members.first { ids.remove(first.id) }
            repaired += 1
        }
        return repaired
    }

    func markedCount<Member: DuplicateSelectable>(in members: [Member]) -> Int {
        members.reduce(0) { $0 + (ids.contains($1.id) ? 1 : 0) }
    }

    /// `true` when at least one item of `members` stays unmarked.
    func keepsAtLeastOne<Member: DuplicateSelectable>(of members: [Member]) -> Bool {
        members.contains { !ids.contains($0.id) }
    }
}

// MARK: - Space accounting

/// Estimates the space freed by removing a set of files, reusing the app's
/// `UsageAccumulator` so hard links and APFS clone families are counted exactly
/// as everywhere else in the app.
enum DuplicateSpaceEstimator {
    static func reclaimableBytes(_ files: some Sequence<DuplicateFile>) -> Int64 {
        let accumulator = UsageAccumulator()
        for file in files { accumulator.add(file.rawEntry) }
        return accumulator.current.reclaimableBytes
    }

    /// Per-file estimates that add up to `reclaimableBytes(files)`. Shared clone blocks
    /// freed only when a whole clone family is removed are attributed to the last member.
    static func perFileEstimates(_ files: [DuplicateFile]) -> [String: Int64] {
        let accumulator = UsageAccumulator()
        var estimates: [String: Int64] = [:]
        var previous: Int64 = 0
        for file in files {
            accumulator.add(file.rawEntry)
            let total = accumulator.current.reclaimableBytes
            estimates[file.id, default: 0] += total - previous
            previous = total
        }
        return estimates
    }
}

// MARK: - Concurrency helpers

/// A lock-protected value shared between walker threads and hashing workers.
final class DuplicateLockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// Cancellation flag readable from GCD threads, where `Task.isCancelled` isn't available.
final class DuplicateCancellation: Sendable {
    private let flag = DuplicateLockedBox(false)

    init() {}

    var isCancelled: Bool { flag.current }

    func cancel() {
        flag.withLock { $0 = true }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Lets progress callbacks through at most every `interval` seconds.
final class DuplicateProgressThrottle: Sendable {
    private let last = DuplicateLockedBox<UInt64>(0)
    private let intervalNanoseconds: UInt64

    init(interval: TimeInterval = 0.1) {
        intervalNanoseconds = UInt64(interval * 1_000_000_000)
    }

    func shouldReport(force: Bool = false) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return last.withLock { previous in
            guard force || now &- previous >= intervalNanoseconds else { return false }
            previous = now
            return true
        }
    }
}
