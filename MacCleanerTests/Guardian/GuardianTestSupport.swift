import Foundation
import SQLite3
@testable import MacCleaner

/// A temporary folder for one Guardian test, removed afterwards. Paths are resolved
/// (`/private/var/...`) because SQLite refuses paths that go through symbolic links.
final class GuardianTestDirectory {
    let root: String

    init(_ name: String = "GuardianTests") throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathUtilities.resolvedPath(base.path) ?? base.path
    }

    deinit {
        // Restore permissions a test may have removed, then delete everything.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                chmod(root + "/" + relative, 0o755)
            }
        }
        chmod(root, 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }

    var url: URL { URL(fileURLWithPath: root, isDirectory: true) }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func write(_ text: String, to relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        return full
    }

    @discardableResult
    func writePlist(_ object: Any, to relative: String, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
        try data.write(to: URL(fileURLWithPath: full))
        return full
    }

    func setModified(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}

/// A small SQLite connection for building browser-history fixtures.
final class GuardianTestDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw PrivacySQLiteError.failed(code: SQLITE_CANTOPEN, message: "Couldn't create the test database")
        }
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw PrivacySQLiteError.failed(code: SQLITE_ERROR, message: message)
        }
    }

    func integer(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PrivacySQLiteError.failed(code: SQLITE_ERROR, message: "prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }
}

/// History databases shaped like the browsers' own (only the tables and columns the Web Shield reads, plus a few real ones).
enum GuardianHistoryFixtures {
    static let chromiumSchema = """
    CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
    CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
                      typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
    CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL,
                        segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL);
    """

    static let firefoxSchema = """
    CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR, visit_count INTEGER DEFAULT 0,
                            hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, frecency INTEGER DEFAULT -1 NOT NULL,
                            last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL);
    CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER, session INTEGER);
    """

    static let safariSchema = """
    CREATE TABLE history_items(id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT NULL, visit_count INTEGER NOT NULL);
    CREATE TABLE history_visits(id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
                                visit_time REAL NOT NULL, title TEXT NULL, load_successful BOOLEAN NOT NULL DEFAULT 1);
    """

    /// Chromium time: microseconds since 1601-01-01.
    static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    static func addChromiumVisit(_ database: GuardianTestDatabase, id: Int, url: String, date: Date) throws {
        let escaped = url.replacingOccurrences(of: "'", with: "''")
        try database.execute("INSERT OR IGNORE INTO urls(url, title, last_visit_time) VALUES ('\(escaped)', 'Page', \(chromiumTime(date)));")
        try database.execute("INSERT INTO visits(id, url, visit_time) VALUES (\(id), (SELECT id FROM urls WHERE url = '\(escaped)'), \(chromiumTime(date)));")
    }

    static func addFirefoxVisit(_ database: GuardianTestDatabase, id: Int, url: String, date: Date) throws {
        let escaped = url.replacingOccurrences(of: "'", with: "''")
        try database.execute("INSERT INTO moz_places(url, title, last_visit_date) SELECT '\(escaped)', 'Page', 0 WHERE NOT EXISTS (SELECT 1 FROM moz_places WHERE url = '\(escaped)');")
        try database.execute("INSERT INTO moz_historyvisits(id, place_id, visit_date, visit_type) VALUES (\(id), (SELECT id FROM moz_places WHERE url = '\(escaped)'), \(Int64(date.timeIntervalSince1970 * 1_000_000)), 1);")
    }

    static func addSafariVisit(_ database: GuardianTestDatabase, id: Int, url: String, date: Date) throws {
        let escaped = url.replacingOccurrences(of: "'", with: "''")
        try database.execute("INSERT OR IGNORE INTO history_items(url, visit_count) VALUES ('\(escaped)', 1);")
        try database.execute("INSERT INTO history_visits(id, history_item, visit_time) VALUES (\(id), (SELECT id FROM history_items WHERE url = '\(escaped)'), \(date.timeIntervalSinceReferenceDate));")
    }
}

/// Threat feeds with a few known-bad entries.
struct GuardianFakeLookup: ThreatIntelLookup {
    var urls: [String: ThreatIntelMatch] = [:]
    var hosts: [String: ThreatIntelMatch] = [:]
    var ips: [String: ThreatIntelMatch] = [:]

    func match(ip: String, port: UInt16?) -> ThreatIntelMatch? { ips[ip] }

    func match(host: String) -> ThreatIntelMatch? {
        // Exact host or a listed parent domain, like the real feeds.
        var candidate = host
        while true {
            if let match = hosts[candidate] { return match }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
    }

    func match(url: String) -> ThreatIntelMatch? { urls[url] }

    static func entry(_ indicator: String, type: String = "malware_download", malware: String? = nil) -> ThreatIntelMatch {
        ThreatIntelMatch(indicator: indicator, threatType: type, malware: malware, confidence: 100, source: "URLhaus (abuse.ch)",
                         firstSeen: nil, reference: URL(string: "https://urlhaus.abuse.ch/"))
    }
}

/// Records the commands it's asked to run and answers with canned results. Nothing is executed.
final class GuardianFakeRunner: @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> CommandResult

    init(respond: @escaping @Sendable (Call) -> CommandResult = { _ in CommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false) }) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { recorded } }

    var runner: GuardianCommandRunner {
        { [self] executable, arguments in
            let call = Call(executable: executable, arguments: arguments)
            lock.withLock { recorded.append(call) }
            return respond(call)
        }
    }

    static func result(_ output: String = "", error: String = "", exitCode: Int32 = 0) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: output, standardError: error, timedOut: false)
    }
}

/// Builds startup records for diff tests.
enum GuardianRecordFactory {
    static func agent(
        _ label: String,
        program: String = "/Applications/Example.app/Contents/MacOS/Helper",
        arguments: [String] = [],
        enabled: Bool? = true,
        category: SecurityTrustCategory = .developerIDNotarized,
        team: String? = "ABCDE12345",
        source: GuardianStartupSource = .userLaunchAgents,
        date: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> GuardianStartupRecord {
        var record = GuardianStartupRecord(source: source, key: "/Users/test/Library/LaunchAgents/\(label).plist", kind: .userAgent, name: label,
                                           identifier: label, programPath: program, arguments: arguments,
                                           configPath: "/Users/test/Library/LaunchAgents/\(label).plist", date: date)
        record.isEnabled = enabled
        record.signature = GuardianSignatureSummary(category: category, developer: "Example Inc", teamIdentifier: team)
        return record
    }

    static func collection(_ records: [GuardianStartupRecord], covered: [GuardianStartupSource], date: Date) -> GuardianStartupCollection {
        GuardianStartupCollection(date: date, records: records, statuses: covered.map { GuardianSourceStatus(source: $0, state: .read) })
    }
}
