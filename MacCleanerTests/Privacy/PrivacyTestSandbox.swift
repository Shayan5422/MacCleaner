import Foundation
import SQLite3
@testable import MacCleaner

/// A temporary fake home folder for Privacy tests. Paths are resolved with
/// `realpath` because SQLite refuses database paths that go through symbolic
/// links (`$TMPDIR` lives under the `/var` → `/private/var` link).
final class PrivacyTestSandbox {
    let root: String
    let home: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PrivacyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathUtilities.resolvedPath(base.path) ?? base.path
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home + "/Library", withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    var library: String { home + "/Library" }

    @discardableResult
    func makeFile(_ path: String, bytes: Int = 64) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    @discardableResult
    func makeDirectory(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func writeJSON(_ object: Any, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: path))
    }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Creates a SQLite database by running `sql`.
    func makeDatabase(at path: String, sql: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw PrivacySQLiteError.failed(code: SQLITE_CANTOPEN, message: "Couldn't create test database")
        }
        defer { sqlite3_close_v2(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw PrivacySQLiteError.failed(code: SQLITE_ERROR, message: message)
        }
    }

    func integer(_ sql: String, in path: String) throws -> Int64? {
        let database = try PrivacySQLiteDatabase(path: path, readOnly: true)
        defer { database.close() }
        return try database.integer(sql)
    }
}
