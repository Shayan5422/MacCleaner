import Foundation
import SQLite3

/// Errors from the small SQLite wrapper used by the Privacy cleaner.
enum PrivacySQLiteError: LocalizedError, Equatable {
    /// Another process holds the database (the owning app is probably running).
    case busy(String)
    /// macOS privacy protection or file permissions blocked access.
    case permissionDenied(String)
    case notADatabase(String)
    case failed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "The database is in use by another app. Quit the app that owns it and try again."
        case .permissionDenied:
            return "macOS didn’t allow Mac Cleaner to open the database. Grant Full Disk Access in System Settings › Privacy & Security and try again."
        case .notADatabase:
            return "The file isn’t a readable database, so it was left untouched."
        case .failed(let code, let message):
            return "The database reported an error (\(code)): \(message)"
        }
    }

    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    static func from(code: Int32, message: String, systemErrno: Int32 = 0) -> PrivacySQLiteError {
        switch code & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .busy(message)
        case SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY:
            return .permissionDenied(message)
        case SQLITE_CANTOPEN, SQLITE_IOERR:
            // Privacy protection makes the underlying open() fail with EPERM.
            return systemErrno == EPERM || systemErrno == EACCES ? .permissionDenied(message) : .failed(code: code, message: message)
        case SQLITE_NOTADB, SQLITE_CORRUPT:
            return .notADatabase(message)
        default:
            return .failed(code: code, message: message)
        }
    }
}

/// A value bound to a statement parameter.
enum PrivacySQLiteValue: Sendable, Hashable {
    case text(String)
    case integer(Int64)
    case null
}

/// Minimal synchronous wrapper around the system SQLite library. Not thread-safe:
/// create, use and close it within one blocking job.
final class PrivacySQLiteDatabase {
    let path: String
    private var handle: OpaquePointer?

    /// Opens an existing database. Never creates one and never follows symbolic links.
    init(path: String, readOnly: Bool, busyTimeoutMilliseconds: Int32 = 3_000) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
            let systemErrno = db.map { sqlite3_system_errno($0) } ?? 0
            sqlite3_close_v2(db)
            throw PrivacySQLiteError.from(code: code, message: message, systemErrno: systemErrno)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    /// Changes made by the most recent INSERT, UPDATE or DELETE.
    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a statement to completion and returns the number of changed rows.
    @discardableResult
    func execute(_ sql: String, _ bindings: [PrivacySQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            if code == SQLITE_ROW { continue }
            throw lastError(code)
        }
        return changes
    }

    /// First column of the first row as an integer (nil for no row or NULL).
    func integer(_ sql: String, _ bindings: [PrivacySQLiteValue] = []) throws -> Int64? {
        try rows(sql, bindings) { statement in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        }.first ?? nil
    }

    /// First column of every row as text.
    func strings(_ sql: String, _ bindings: [PrivacySQLiteValue] = []) throws -> [String] {
        try rows(sql, bindings) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }.compactMap { $0 }
    }

    func tableExists(_ table: String) throws -> Bool {
        try integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) ?? 0 > 0
    }

    func columns(of table: String) throws -> Set<String> {
        Set(try strings("SELECT name FROM pragma_table_info(?)", [.text(table)]))
    }

    /// Copies the whole database (including committed write-ahead-log content)
    /// into a new single-file database at `destination`, then verifies the copy.
    func backup(to destination: String) throws {
        guard let handle else { throw PrivacySQLiteError.failed(code: SQLITE_MISUSE, message: "The database is closed.") }
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw PrivacySQLiteError.failed(code: SQLITE_CANTOPEN, message: "A backup already exists at this location.")
        }
        var target: OpaquePointer?
        let openCode = sqlite3_open_v2(destination, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil)
        defer { sqlite3_close_v2(target) }
        guard openCode == SQLITE_OK, let target else {
            throw PrivacySQLiteError.failed(code: openCode, message: String(cString: sqlite3_errstr(openCode)))
        }
        guard let backup = sqlite3_backup_init(target, "main", handle, "main") else {
            throw PrivacySQLiteError.from(code: sqlite3_errcode(target), message: String(cString: sqlite3_errmsg(target)))
        }
        var stepCode: Int32 = SQLITE_OK
        var attempts = 0
        repeat {
            stepCode = sqlite3_backup_step(backup, -1)
            if stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED {
                attempts += 1
                sqlite3_sleep(100)
            }
        } while (stepCode == SQLITE_OK || stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED) && attempts < 50
        let finishCode = sqlite3_backup_finish(backup)
        guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw PrivacySQLiteError.from(code: stepCode == SQLITE_DONE ? finishCode : stepCode, message: String(cString: sqlite3_errmsg(target)))
        }
        // A standalone copy: no write-ahead log next to it.
        sqlite3_exec(target, "PRAGMA journal_mode = DELETE", nil, nil, nil)
        var check: OpaquePointer?
        defer { sqlite3_finalize(check) }
        guard sqlite3_prepare_v2(target, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
              sqlite3_step(check) == SQLITE_ROW,
              let text = sqlite3_column_text(check, 0), String(cString: text) == "ok" else {
            throw PrivacySQLiteError.notADatabase("The backup copy failed verification.")
        }
    }

    // MARK: - Private

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func prepare(_ sql: String, _ bindings: [PrivacySQLiteValue]) throws -> OpaquePointer {
        guard let handle else { throw PrivacySQLiteError.failed(code: SQLITE_MISUSE, message: "The database is closed.") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw lastError(code)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindCode: Int32
            switch value {
            case .text(let text): bindCode = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .integer(let number): bindCode = sqlite3_bind_int64(statement, index, number)
            case .null: bindCode = sqlite3_bind_null(statement, index)
            }
            if bindCode != SQLITE_OK {
                sqlite3_finalize(statement)
                throw lastError(bindCode)
            }
        }
        return statement
    }

    private func rows<T>(_ sql: String, _ bindings: [PrivacySQLiteValue], _ read: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError(code) }
            results.append(read(statement))
        }
        return results
    }

    private func lastError(_ code: Int32) -> PrivacySQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
        let systemErrno = handle.map { sqlite3_system_errno($0) } ?? 0
        return PrivacySQLiteError.from(code: code, message: message, systemErrno: systemErrno)
    }
}
