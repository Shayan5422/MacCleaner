import Foundation

/// The system-wide download history macOS keeps in Launch Services'
/// QuarantineEventsV2 database: one row per file downloaded by a browser, mail
/// app or messaging app (source URL, date and app).
///
/// Clearing it doesn't weaken Gatekeeper: Gatekeeper checks the quarantine
/// attribute stored on each downloaded file, not this list.
enum PrivacyQuarantineEvents {
    static let tableName = "LSQuarantineEvent"

    static func databasePath(home: String) -> String {
        home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
    }

    /// Reads the number of recorded downloads without changing anything.
    static func status(home: String) -> PrivacyQuarantineStatus? {
        let path = databasePath(home: home)
        switch PrivacyFileAccess.probe(path) {
        case .missing, .directory, .symlink, .special:
            return nil
        case .blocked:
            return PrivacyQuarantineStatus(path: path, eventCount: nil, isBlocked: true, problem: "macOS protects this list. Grant Full Disk Access to include it.")
        case .file:
            do {
                return PrivacyQuarantineStatus(path: path, eventCount: try eventCount(at: path), isBlocked: false, problem: nil)
            } catch let error as PrivacySQLiteError {
                if case .permissionDenied = error {
                    return PrivacyQuarantineStatus(path: path, eventCount: nil, isBlocked: true, problem: "macOS protects this list. Grant Full Disk Access to include it.")
                }
                return PrivacyQuarantineStatus(path: path, eventCount: nil, isBlocked: false, problem: error.localizedDescription)
            } catch {
                return PrivacyQuarantineStatus(path: path, eventCount: nil, isBlocked: false, problem: error.localizedDescription)
            }
        }
    }

    static func eventCount(at path: String) throws -> Int {
        let database = try PrivacySQLiteDatabase(path: path, readOnly: true, busyTimeoutMilliseconds: 1_000)
        defer { database.close() }
        guard try database.tableExists(tableName) else { return 0 }
        return Int(try database.integer("SELECT COUNT(*) FROM " + tableName) ?? 0)
    }

    /// Deletes every recorded download event and returns how many were removed.
    /// Freed database pages are overwritten (`secure_delete`), so removed URLs
    /// don't stay readable inside the file.
    static func clearAll(at path: String) throws -> Int {
        guard PrivacyFileAccess.probe(path) == .file else { return 0 }
        let database = try PrivacySQLiteDatabase(path: path, readOnly: false, busyTimeoutMilliseconds: 3_000)
        defer { database.close() }
        guard try database.tableExists(tableName) else { return 0 }
        try database.execute("PRAGMA secure_delete = ON")
        try database.execute("BEGIN IMMEDIATE")
        let removed: Int
        do {
            removed = try database.execute("DELETE FROM " + tableName)
            try database.execute("COMMIT")
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
        _ = try? database.integer("PRAGMA wal_checkpoint(TRUNCATE)")
        return removed
    }
}
