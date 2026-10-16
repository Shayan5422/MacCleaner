import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Antivirus download origins")
struct AVDownloadOriginTests {
    /// Writes `kMDItemWhereFroms` the way browsers do (a binary property list array).
    static func setWhereFroms(_ urls: [String], on path: String, format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: urls, format: format, options: 0)
        let result = data.withUnsafeBytes { setxattr(path, AVDownloadOriginReader.whereFromsAttribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        #expect(result == 0)
    }

    static func setQuarantine(_ value: String, on path: String) {
        let data = Data(value.utf8)
        _ = data.withUnsafeBytes { setxattr(path, "com.apple.quarantine", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
    }

    @Test func parsesWhereFromsInEveryForm() throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: ["https://a.example/file.zip", "https://a.example/"], format: .binary, options: 0)
        #expect(AVDownloadOriginReader.parseWhereFroms(binary) == ["https://a.example/file.zip", "https://a.example/"])
        let xml = try PropertyListSerialization.data(fromPropertyList: ["https://b.example/x"], format: .xml, options: 0)
        #expect(AVDownloadOriginReader.parseWhereFroms(xml) == ["https://b.example/x"])
        let single = try PropertyListSerialization.data(fromPropertyList: "https://c.example/", format: .binary, options: 0)
        #expect(AVDownloadOriginReader.parseWhereFroms(single) == ["https://c.example/"])
        #expect(AVDownloadOriginReader.parseWhereFroms(Data("garbage".utf8)).isEmpty)
        let mixed = try PropertyListSerialization.data(fromPropertyList: ["  https://d.example/ ", 42, ""] as [Any], format: .binary, options: 0)
        #expect(AVDownloadOriginReader.parseWhereFroms(mixed) == ["https://d.example/"])
    }

    @Test func readsTheExtendedAttributesOfADownload() throws {
        let directory = try AVTestFolder()
        let file = try directory.makeFile("Downloads/setup.pkg")
        try Self.setWhereFroms(["https://evil-c2.example/setup.pkg", "https://news.example/article"], on: file)
        Self.setQuarantine("0083;6a2c78e7;Safari;DE8ED0CD-4FA0-4D8F-A740-1C18A5F09AB9", on: file)
        let origin = try #require(AVDownloadOriginReader.read(path: file, intel: nil))
        #expect(origin.urls.count == 2)
        #expect(origin.agent == "Safari")
        #expect(origin.downloadedAt == Date(timeIntervalSince1970: 0x6A2C78E7))
        #expect(origin.intelMatch == nil)
        #expect(AVDownloadOriginReader.read(path: try directory.makeFile("plain.txt"), intel: nil) == nil)
    }

    @Test func matchesListedURLsAndHosts() throws {
        let directory = try AVTestFolder()
        let now = Date()
        var database = AVIntelDatabase()
        database.merge([
            AVIndicator(kind: .host, value: "evil-c2.example", source: .urlhaus, threatType: "malware_download", firstSeen: now, lastSeen: now),
            AVIndicator(kind: .url, value: "https://cdn.example/attachments/1/payload.zip", source: .urlhaus, threatType: "malware_download", firstSeen: now, lastSeen: now),
        ])
        let index = database.index()
        let byHost = try directory.makeFile("a.pkg")
        try Self.setWhereFroms(["https://downloads.evil-c2.example/a.pkg"], on: byHost)
        #expect(AVDownloadOriginReader.read(path: byHost, intel: index)?.intelMatch?.indicator == "evil-c2.example")
        let byURL = try directory.makeFile("payload.zip")
        try Self.setWhereFroms(["https://CDN.example/attachments/1/payload.zip"], on: byURL)
        let origin = try #require(AVDownloadOriginReader.read(path: byURL, intel: index))
        #expect(origin.isKnownMalwareSite)
        #expect(origin.listedURL == "https://CDN.example/attachments/1/payload.zip")
        let clean = try directory.makeFile("clean.zip")
        try Self.setWhereFroms(["https://cdn.example/attachments/2/other.zip"], on: clean)
        #expect(AVDownloadOriginReader.read(path: clean, intel: index)?.isKnownMalwareSite == false)
    }
}
