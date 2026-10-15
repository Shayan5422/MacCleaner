import Foundation
import Testing
@testable import MacCleaner

@Suite("Privacy – macOS download history")
struct PrivacyQuarantineEventsTests {
    static let secretURL = "https://downloads.example.com/very-private-installer.dmg"

    /// Same table layout as ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2.
    static let schema = """
    CREATE TABLE LSQuarantineEvent (
        LSQuarantineEventIdentifier TEXT PRIMARY KEY NOT NULL,
        LSQuarantineTimeStamp REAL,
        LSQuarantineAgentBundleIdentifier TEXT,
        LSQuarantineAgentName TEXT,
        LSQuarantineDataURLString TEXT,
        LSQuarantineSenderName TEXT,
        LSQuarantineSenderAddress TEXT,
        LSQuarantineTypeNumber INTEGER,
        LSQuarantineOriginTitle TEXT,
        LSQuarantineOriginURLString TEXT,
        LSQuarantineOriginAlias BLOB
    );
    CREATE INDEX LSQuarantineEventIndex ON LSQuarantineEvent (LSQuarantineEventIdentifier);
    INSERT INTO LSQuarantineEvent VALUES ('A1', 780000000, 'com.apple.Safari', 'Safari', '\(secretURL)', NULL, NULL, 0, NULL, 'https://example.com/downloads', NULL);
    INSERT INTO LSQuarantineEvent VALUES ('B2', 780000100, 'com.google.Chrome', 'Chrome', 'https://example.org/report.pdf', NULL, NULL, 0, NULL, NULL, NULL);
    INSERT INTO LSQuarantineEvent VALUES ('C3', 780000200, 'com.apple.mail', 'Mail', 'https://example.net/attachment.zip', NULL, NULL, 0, NULL, NULL, NULL);
    """

    @Test func countsAndClearsDownloadEvents() throws {
        let sandbox = try PrivacyTestSandbox()
        let path = PrivacyQuarantineEvents.databasePath(home: sandbox.home)
        try sandbox.makeDatabase(at: path, sql: Self.schema)

        #expect(try PrivacyQuarantineEvents.eventCount(at: path) == 3)
        let status = try #require(PrivacyQuarantineEvents.status(home: sandbox.home))
        #expect(status.eventCount == 3)
        #expect(!status.isBlocked)

        let removed = try PrivacyQuarantineEvents.clearAll(at: path)

        #expect(removed == 3)
        #expect(try PrivacyQuarantineEvents.eventCount(at: path) == 0)
        // The database and its table stay, so Launch Services keeps working.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try sandbox.integer("SELECT COUNT(*) FROM sqlite_master WHERE name = 'LSQuarantineEvent'", in: path) == 1)
        // Removed rows are overwritten, not just unlinked inside the file.
        let contents = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(contents.range(of: Data(Self.secretURL.utf8)) == nil)
    }

    @Test func missingDatabaseIsNotAnError() throws {
        let sandbox = try PrivacyTestSandbox()
        #expect(PrivacyQuarantineEvents.status(home: sandbox.home) == nil)
        #expect(try PrivacyQuarantineEvents.clearAll(at: PrivacyQuarantineEvents.databasePath(home: sandbox.home)) == 0)
    }

    @Test func emptyDatabaseWithoutTheTableReportsZero() throws {
        let sandbox = try PrivacyTestSandbox()
        let path = PrivacyQuarantineEvents.databasePath(home: sandbox.home)
        try sandbox.makeDatabase(at: path, sql: "CREATE TABLE other (id INTEGER);")
        #expect(try PrivacyQuarantineEvents.eventCount(at: path) == 0)
        #expect(try PrivacyQuarantineEvents.clearAll(at: path) == 0)
    }
}
