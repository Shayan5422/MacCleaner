import Foundation

/// Fingerprints and sizes from earlier scans, kept in Application Support so a rescan only looks at
/// photos that are new or changed. An entry holds for the modification date it was made with:
/// editing a photo (or anything else that changes its modification date) makes it stale.
struct PhotoScanCache: Sendable, Equatable {
    /// Bumped when fingerprints change meaning, so entries from an older format are dropped.
    static let formatVersion = 2

    struct Entry: Codable, Sendable, Equatable {
        /// The asset's modification date when the entry was made, in seconds since 1970.
        var modified: Double?
        var hash: UInt64?
        var luma: UInt8?
        /// The detail hash's bits, then its clear-cut bits: eight words.
        var detail: [UInt64]?
        /// Only sizes Photos reported; estimates aren't kept.
        var bytes: Int64?

        enum CodingKeys: String, CodingKey {
            case modified = "m", hash = "h", luma = "l", detail = "d", bytes = "b"
        }
    }

    private(set) var entries: [String: Entry] = [:]

    var count: Int { entries.count }

    func fingerprint(for id: String, modified: Date?) -> ImageFingerprint? {
        guard let entry = validEntry(id, modified), let hash = entry.hash, let luma = entry.luma else { return nil }
        let detail = entry.detail.flatMap { words in
            words.count == 8 ? DetailHash(bits: Array(words[0..<4]), strong: Array(words[4..<8])) : nil
        }
        return ImageFingerprint(hash: hash, luma: luma, detail: detail)
    }

    func size(for id: String, modified: Date?) -> MediaSize? {
        guard let bytes = validEntry(id, modified)?.bytes else { return nil }
        return MediaSize(bytes: bytes, isEstimated: false)
    }

    mutating func store(_ fingerprint: ImageFingerprint, for id: String, modified: Date?) {
        var entry = currentEntry(id, modified)
        entry.hash = fingerprint.hash
        entry.luma = fingerprint.luma
        entry.detail = fingerprint.detail.map { $0.bits + $0.strong }
        entries[id] = entry
    }

    mutating func store(_ size: MediaSize, for id: String, modified: Date?) {
        guard !size.isEstimated else { return }
        var entry = currentEntry(id, modified)
        entry.bytes = size.bytes
        entries[id] = entry
    }

    /// Forgets assets that aren't in the library anymore.
    mutating func prune(keeping ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    private func validEntry(_ id: String, _ modified: Date?) -> Entry? {
        guard let entry = entries[id], entry.modified == modified?.timeIntervalSince1970 else { return nil }
        return entry
    }

    /// The entry to add to: the existing one while it's valid, otherwise a fresh one for this date.
    private func currentEntry(_ id: String, _ modified: Date?) -> Entry {
        validEntry(id, modified) ?? Entry(modified: modified?.timeIntervalSince1970)
    }

    // MARK: Storage

    private struct File: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// Application Support/Photos/scan-cache.json in the app's container.
    static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Photos", isDirectory: true).appendingPathComponent("scan-cache.json")
    }

    /// The cache saved at `url`, or an empty one when there's none or it's from another format.
    static func load(from url: URL) -> PhotoScanCache {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == formatVersion else { return PhotoScanCache() }
        var cache = PhotoScanCache()
        cache.entries = file.entries
        return cache
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(File(version: Self.formatVersion, entries: entries))
        try data.write(to: url, options: .atomic)
        // It can always be rebuilt, so it stays out of iCloud and computer backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = url
        try? file.setResourceValues(values)
    }
}
