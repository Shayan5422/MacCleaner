import Darwin
import Foundation

struct PrivacyFirefoxHistoryCounts: Sendable, Hashable {
    var visits: Int
    var downloads: Int
}

/// What clearing one Firefox profile's history did.
struct PrivacyFirefoxHistoryClearResult: Sendable, Hashable {
    var visitsRemoved = 0
    /// Pages that were only in history (no bookmark or keyword) and were removed.
    var pagesRemoved = 0
    /// Bookmarked pages that were kept; their visit dates and counts were reset.
    var pagesKept = 0
    var inputHistoryRemoved = 0
    var annotationsRemoved = 0
    var metadataRemoved = 0
    var originsRemoved = 0
    /// Verified copy of the database taken before any change.
    var backupPath = ""
    /// `false` if Firefox's write-ahead log couldn't be folded into the database yet.
    var logCheckpointed = true
}

enum PrivacyFirefoxHistoryError: LocalizedError {
    case databaseMissing
    case profileInUse
    case unexpectedSchema(String)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return "This Firefox profile has no history database."
        case .profileInUse:
            return "Firefox is using this profile. Quit Firefox and try again."
        case .unexpectedSchema(let table):
            return "The history database doesn’t look like Firefox’s (missing “\(table)”), so it was left untouched."
        case .backupFailed(let reason):
            return "Couldn’t make a backup copy of the history database, so nothing was changed. \(reason)"
        }
    }
}

/// Clears Firefox browsing history inside `places.sqlite`.
///
/// Firefox stores bookmarks in the same database as history, so the file is
/// never deleted. Instead, with Firefox closed and after a verified backup copy:
/// visits, typed-address history and history metadata are deleted; pages that
/// no bookmark or keyword uses are deleted; bookmarked pages are kept with their
/// visit statistics reset; download annotations and orphaned site entries are
/// removed; then the write-ahead log is truncated so removed rows don't linger.
enum PrivacyFirefoxHistory {
    static let downloadAnnotationPattern = "downloads/%"

    /// Where backups are kept: ~/Library/Application Support/Mac Cleaner/Backups.
    static func backupRoot(home: String) -> String {
        home + "/Library/Application Support/Mac Cleaner/Backups"
    }

    /// Creates `<root>/<date and time>/<label>` and returns its path.
    static func makeBackupDirectory(root: String, label: String, date: Date = Date()) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeLabel = label.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        let base = root + "/" + formatter.string(from: date) + "/" + String(safeLabel)
        var directory = base
        var attempt = 2
        while FileManager.default.fileExists(atPath: directory) {
            directory = base + " \(attempt)"
            attempt += 1
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Number of visits and downloads recorded in history (read-only).
    static func counts(placesPath: String) throws -> PrivacyFirefoxHistoryCounts {
        let database = try PrivacySQLiteDatabase(path: placesPath, readOnly: true, busyTimeoutMilliseconds: 500)
        defer { database.close() }
        var counts = PrivacyFirefoxHistoryCounts(visits: 0, downloads: 0)
        if try database.tableExists("moz_historyvisits") {
            counts.visits = Int(try database.integer("SELECT COUNT(*) FROM moz_historyvisits") ?? 0)
        }
        if try database.tableExists("moz_annos"), try database.tableExists("moz_anno_attributes") {
            counts.downloads = Int(try database.integer(
                "SELECT COUNT(DISTINCT a.place_id) FROM moz_annos a JOIN moz_anno_attributes n ON n.id = a.anno_attribute_id WHERE n.name = ?",
                [.text("downloads/destinationFileURI")]
            ) ?? 0)
        }
        return counts
    }

    /// `true` while a Firefox process holds the profile lock.
    static func isProfileLocked(profileDirectory: String) -> Bool {
        let fd = open(profileDirectory + "/.parentlock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }

    /// Clears the history of the profile that owns `placesPath`. Firefox must be closed.
    static func clearHistory(placesPath: String, backupDirectory: String) throws -> PrivacyFirefoxHistoryClearResult {
        guard PrivacyFileAccess.probe(placesPath) == .file else { throw PrivacyFirefoxHistoryError.databaseMissing }
        let profileDirectory = (placesPath as NSString).deletingLastPathComponent
        if isProfileLocked(profileDirectory: profileDirectory) { throw PrivacyFirefoxHistoryError.profileInUse }

        let database = try PrivacySQLiteDatabase(path: placesPath, readOnly: false, busyTimeoutMilliseconds: 2_000)
        defer { database.close() }

        for table in ["moz_places", "moz_historyvisits", "moz_bookmarks"] {
            guard try database.tableExists(table) else { throw PrivacyFirefoxHistoryError.unexpectedSchema(table) }
        }
        let placeColumns = try database.columns(of: "moz_places")
        guard placeColumns.isSuperset(of: ["id", "visit_count", "last_visit_date"]) else {
            throw PrivacyFirefoxHistoryError.unexpectedSchema("moz_places")
        }

        // 1. A verified copy before anything changes.
        let backupPath = backupDirectory + "/places.sqlite"
        do {
            try FileManager.default.createDirectory(atPath: backupDirectory, withIntermediateDirectories: true)
            try database.backup(to: backupPath)
        } catch let error as PrivacySQLiteError where error.isBusy {
            throw PrivacyFirefoxHistoryError.profileInUse
        } catch {
            throw PrivacyFirefoxHistoryError.backupFailed(error.localizedDescription)
        }

        var result = PrivacyFirefoxHistoryClearResult(backupPath: backupPath)

        // 2. One transaction: either all of history goes, or nothing changes.
        try database.execute("PRAGMA secure_delete = ON")
        do {
            try database.execute("BEGIN IMMEDIATE")
        } catch let error as PrivacySQLiteError where error.isBusy {
            throw PrivacyFirefoxHistoryError.profileInUse
        }
        do {
            result.visitsRemoved = try database.execute("DELETE FROM moz_historyvisits")
            if try database.tableExists("moz_historyvisits_extra") {
                try database.execute("DELETE FROM moz_historyvisits_extra")
            }
            if try database.tableExists("moz_inputhistory") {
                result.inputHistoryRemoved = try database.execute("DELETE FROM moz_inputhistory")
            }
            for table in ["moz_places_metadata", "moz_places_metadata_search_queries"] {
                if try database.tableExists(table) {
                    result.metadataRemoved += try database.execute("DELETE FROM " + table)
                }
            }

            // Pages used by a bookmark or keyword stay, so bookmarks keep working.
            var keep = ["id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)"]
            if try database.tableExists("moz_keywords"), try database.columns(of: "moz_keywords").contains("place_id") {
                keep.append("id NOT IN (SELECT place_id FROM moz_keywords WHERE place_id IS NOT NULL)")
            }
            if placeColumns.contains("foreign_count") {
                keep.append("foreign_count = 0")
            }
            result.pagesRemoved = try database.execute("DELETE FROM moz_places WHERE " + keep.joined(separator: " AND "))

            if try database.tableExists("moz_annos") {
                result.annotationsRemoved += try database.execute("DELETE FROM moz_annos WHERE place_id NOT IN (SELECT id FROM moz_places)")
                if try database.tableExists("moz_anno_attributes") {
                    // Download history of pages that are kept because they're bookmarked.
                    result.annotationsRemoved += try database.execute(
                        "DELETE FROM moz_annos WHERE anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name LIKE ?)",
                        [.text(downloadAnnotationPattern)]
                    )
                }
            }
            if try database.tableExists("moz_places_extra") {
                try database.execute("DELETE FROM moz_places_extra WHERE place_id NOT IN (SELECT id FROM moz_places)")
            }

            // Kept pages forget when and how often they were visited.
            var resets = ["visit_count = 0", "last_visit_date = NULL"]
            if placeColumns.contains("typed") { resets.append("typed = 0") }
            if placeColumns.contains("recalc_frecency") { resets.append("recalc_frecency = 1") }
            if placeColumns.contains("recalc_alt_frecency") { resets.append("recalc_alt_frecency = 1") }
            result.pagesKept = try database.execute("UPDATE moz_places SET " + resets.joined(separator: ", "))

            if placeColumns.contains("origin_id"), try database.tableExists("moz_origins") {
                result.originsRemoved = try database.execute(
                    "DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places WHERE origin_id IS NOT NULL)"
                )
            }
            try database.execute("COMMIT")
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }

        // 3. Fold the write-ahead log into the database and truncate it.
        result.logCheckpointed = (try? database.integer("PRAGMA wal_checkpoint(TRUNCATE)")) == 0
        return result
    }
}
