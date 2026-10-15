import Foundation
import Testing
@testable import MacCleaner

@Suite("Privacy – Firefox history clearing")
struct PrivacyFirefoxHistoryTests {
    /// A trimmed-down copy of Firefox's places.sqlite schema with history,
    /// a bookmark, a keyword, download annotations and history metadata.
    static let placesSQL = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE moz_origins (id INTEGER PRIMARY KEY, prefix TEXT NOT NULL, host TEXT NOT NULL, frecency INTEGER NOT NULL DEFAULT 0, recalc_frecency INTEGER NOT NULL DEFAULT 0, UNIQUE (prefix, host));
    CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL, url_hash INTEGER DEFAULT 0 NOT NULL, origin_id INTEGER REFERENCES moz_origins(id), recalc_frecency INTEGER NOT NULL DEFAULT 0, recalc_alt_frecency INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER, session INTEGER, source INTEGER DEFAULT 0 NOT NULL, triggeringPlaceId INTEGER);
    CREATE TABLE moz_inputhistory (place_id INTEGER NOT NULL, input LONGVARCHAR NOT NULL, use_count INTEGER, PRIMARY KEY (place_id, input));
    CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT, syncStatus INTEGER NOT NULL DEFAULT 0, syncChangeCounter INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE moz_keywords (id INTEGER PRIMARY KEY AUTOINCREMENT, keyword TEXT UNIQUE, place_id INTEGER, post_data TEXT);
    CREATE TABLE moz_anno_attributes (id INTEGER PRIMARY KEY, name VARCHAR(32) UNIQUE NOT NULL);
    CREATE TABLE moz_annos (id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL, anno_attribute_id INTEGER, content LONGVARCHAR, flags INTEGER DEFAULT 0, expiration INTEGER DEFAULT 0, type INTEGER DEFAULT 0, dateAdded INTEGER DEFAULT 0, lastModified INTEGER DEFAULT 0);
    CREATE TABLE moz_places_metadata (id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL, referrer_place_id INTEGER, created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, total_view_time INTEGER NOT NULL DEFAULT 0);

    INSERT INTO moz_origins (id, prefix, host) VALUES (1, 'https://', 'bookmarked.example'), (2, 'https://', 'visited.example'), (3, 'https://', 'search.example');
    INSERT INTO moz_places (id, url, title, visit_count, typed, frecency, last_visit_date, foreign_count, origin_id) VALUES
        (1, 'https://bookmarked.example/', 'Bookmarked', 5, 1, 900, 1700000000000000, 1, 1),
        (2, 'https://visited.example/a', 'Visited A', 3, 1, 500, 1700000000000001, 0, 2),
        (3, 'https://visited.example/b', 'Visited B', 1, 0, 100, 1700000000000002, 0, 2),
        (4, 'https://search.example/?q=%s', 'Search', 0, 0, 50, NULL, 1, 3),
        (5, 'https://bookmarked.example/file.zip', 'file.zip', 1, 0, 20, 1700000000000003, 0, 1);
    INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES
        (1, 1, 1), (1, 2, 1), (1, 3, 2), (2, 4, 1), (2, 5, 1), (3, 6, 1), (5, 7, 7);
    INSERT INTO moz_inputhistory (place_id, input, use_count) VALUES (2, 'vis', 2), (1, 'book', 1);
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
        (1, 2, NULL, 0, 0, 'root', 'root________'),
        (10, 1, 1, 1, 0, 'Bookmarked', 'bookmark0001');
    INSERT INTO moz_keywords (keyword, place_id) VALUES ('s', 4);
    INSERT INTO moz_anno_attributes (id, name) VALUES (1, 'downloads/destinationFileURI'), (2, 'downloads/metaData'), (3, 'URIProperties/characterSet');
    INSERT INTO moz_annos (place_id, anno_attribute_id, content) VALUES
        (5, 1, 'file:///Users/someone/Downloads/file.zip'), (5, 2, '{}'),
        (1, 1, 'file:///Users/someone/Downloads/page.html'), (1, 3, 'UTF-8');
    INSERT INTO moz_places_metadata (place_id, total_view_time) VALUES (2, 1234), (1, 99);
    """

    private func makeProfile(_ sandbox: PrivacyTestSandbox) throws -> String {
        let profile = sandbox.library + "/Application Support/Firefox/Profiles/test.default-release"
        let places = profile + "/places.sqlite"
        try sandbox.makeDatabase(at: places, sql: Self.placesSQL)
        return places
    }

    @Test func countsVisitsAndDownloadsReadOnly() throws {
        let sandbox = try PrivacyTestSandbox()
        let places = try makeProfile(sandbox)
        let counts = try PrivacyFirefoxHistory.counts(placesPath: places)
        #expect(counts.visits == 7)
        #expect(counts.downloads == 2)
    }

    @Test func clearsHistoryButKeepsBookmarksAndMakesABackup() throws {
        let sandbox = try PrivacyTestSandbox()
        let places = try makeProfile(sandbox)
        let backupRoot = sandbox.root + "/Backups"
        let backupDirectory = try PrivacyFirefoxHistory.makeBackupDirectory(root: backupRoot, label: "Firefox test.default-release")

        let result = try PrivacyFirefoxHistory.clearHistory(placesPath: places, backupDirectory: backupDirectory)

        // What was removed.
        #expect(result.visitsRemoved == 7)
        #expect(result.pagesRemoved == 3)
        #expect(result.pagesKept == 2)
        #expect(result.inputHistoryRemoved == 2)
        #expect(result.metadataRemoved == 2)
        #expect(result.originsRemoved == 1)
        #expect(result.annotationsRemoved == 3)

        // Visits and typed history are gone.
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_historyvisits", in: places) == 0)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_inputhistory", in: places) == 0)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_places_metadata", in: places) == 0)

        // The bookmarked page and the keyword target survive, with history statistics reset.
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_places", in: places) == 2)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_places WHERE id IN (1, 4)", in: places) == 2)
        #expect(try sandbox.integer("SELECT visit_count FROM moz_places WHERE id = 1", in: places) == 0)
        #expect(try sandbox.integer("SELECT last_visit_date FROM moz_places WHERE id = 1", in: places) == nil)
        #expect(try sandbox.integer("SELECT typed FROM moz_places WHERE id = 1", in: places) == 0)
        #expect(try sandbox.integer("SELECT recalc_frecency FROM moz_places WHERE id = 1", in: places) == 1)

        // Bookmarks and keywords are untouched and still point at existing pages.
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_bookmarks", in: places) == 2)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk", in: places) == 1)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_keywords k JOIN moz_places p ON p.id = k.place_id", in: places) == 1)

        // Download history is gone; the bookmarked page keeps its other annotations.
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_annos", in: places) == 1)
        #expect(try sandbox.integer("SELECT anno_attribute_id FROM moz_annos", in: places) == 3)

        // Sites that only appeared in history are forgotten.
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_origins", in: places) == 2)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_origins WHERE host = 'visited.example'", in: places) == 0)

        // A verified, standalone backup holds the previous history.
        #expect(result.backupPath == backupDirectory + "/places.sqlite")
        #expect(FileManager.default.fileExists(atPath: result.backupPath))
        #expect(!FileManager.default.fileExists(atPath: result.backupPath + "-wal"))
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_historyvisits", in: result.backupPath) == 7)
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_bookmarks", in: result.backupPath) == 2)

        // The write-ahead log was folded in, so removed rows don't linger next to the database.
        #expect(result.logCheckpointed)
        let walSize = (try? FileManager.default.attributesOfItem(atPath: places + "-wal"))?[.size] as? NSNumber
        #expect((walSize?.intValue ?? 0) == 0)
    }

    @Test func refusesADatabaseThatIsNotFirefoxHistory() throws {
        let sandbox = try PrivacyTestSandbox()
        let path = sandbox.library + "/Application Support/Firefox/Profiles/odd.profile/places.sqlite"
        try sandbox.makeDatabase(at: path, sql: """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER, last_visit_date INTEGER);
        CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER);
        INSERT INTO moz_places (url) VALUES ('https://example.com');
        INSERT INTO moz_historyvisits (place_id) VALUES (1);
        """)
        let backups = sandbox.root + "/Backups/refused"

        #expect(throws: PrivacyFirefoxHistoryError.self) {
            try PrivacyFirefoxHistory.clearHistory(placesPath: path, backupDirectory: backups)
        }
        // Nothing changed and no backup was needed.
        #expect(try sandbox.integer("SELECT COUNT(*) FROM moz_historyvisits", in: path) == 1)
        #expect(!FileManager.default.fileExists(atPath: backups + "/places.sqlite"))
    }

    @Test func reportsAMissingDatabase() throws {
        let sandbox = try PrivacyTestSandbox()
        #expect(throws: PrivacyFirefoxHistoryError.self) {
            try PrivacyFirefoxHistory.clearHistory(placesPath: sandbox.library + "/missing/places.sqlite", backupDirectory: sandbox.root + "/Backups")
        }
    }

    @Test func profileWithoutLockFileIsNotInUse() throws {
        let sandbox = try PrivacyTestSandbox()
        let profile = try sandbox.makeDirectory(sandbox.library + "/Application Support/Firefox/Profiles/idle.profile")
        #expect(!PrivacyFirefoxHistory.isProfileLocked(profileDirectory: profile))
        try sandbox.makeFile(profile + "/.parentlock", bytes: 0)
        #expect(!PrivacyFirefoxHistory.isProfileLocked(profileDirectory: profile))
    }

    @Test func backupFoldersAreUniqueAndDated() throws {
        let sandbox = try PrivacyTestSandbox()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try PrivacyFirefoxHistory.makeBackupDirectory(root: sandbox.root + "/Backups", label: "Firefox a/b", date: date)
        let second = try PrivacyFirefoxHistory.makeBackupDirectory(root: sandbox.root + "/Backups", label: "Firefox a/b", date: date)
        #expect(first != second)
        #expect(first.hasSuffix("/Firefox a-b"))
        #expect(FileManager.default.fileExists(atPath: first))
        #expect(FileManager.default.fileExists(atPath: second))
    }
}
