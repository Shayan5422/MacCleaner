import Foundation
import Testing
@testable import MacCleaner

@Suite("Privacy – protected data")
struct PrivacyProtectedDataTests {
    private static let profile = "/Users/someone/Library/Application Support/Google/Chrome/Default"
    private static let firefox = "/Users/someone/Library/Application Support/Firefox/Profiles/abcd.default-release"

    static let protectedPaths: [String] = {
        let chrome: [String] = [
            "Login Data", "Login Data-journal", "Login Data For Account", "Web Data", "Web Data-journal",
            "Account Web Data", "Bookmarks", "Bookmarks.bak", "Favicons", "Favicons-journal", "Preferences",
            "Secure Preferences", "Affiliation Database", "Extensions/abcdef/1.0/manifest.json",
            "Local Extension Settings/abcdef", "IndexedDB/chrome-extension_abcdef_0.indexeddb.leveldb",
        ].map { profile + "/" + $0 }
        let mozilla: [String] = [
            "logins.json", "logins-backup.json", "key4.db", "cert9.db", "places.sqlite", "places.sqlite-wal",
            "favicons.sqlite", "formhistory.sqlite", "prefs.js",
            "storage/default/moz-extension+++1234-5678^userContextId=4294967295", "storage/permanent/chrome",
        ].map { firefox + "/" + $0 }
        let other: [String] = [
            "/Users/someone/Library/Application Support/Google/Chrome/Local State",
            "/Users/someone/Library/Safari/Bookmarks.plist",
            "/Users/someone/Library/Safari/Form Values",
            "/Users/someone/Library/Keychains/login.keychain-db",
            "/Users/someone/Library/Containers/com.example/Data/Library/Keychains/data.keychain",
        ]
        return chrome + mozilla + other
    }()

    static let browsingTracePaths: [String] = {
        let chrome: [String] = [
            "History", "History-journal", "Visited Links", "Top Sites", "Shortcuts", "Network/Cookies",
            "Network/Cookies-journal", "Local Storage", "IndexedDB/https_example.com_0.indexeddb.leveldb",
            "Sessions", "GPUCache",
        ].map { profile + "/" + $0 }
        let mozilla: [String] = [
            "cookies.sqlite", "cookies.sqlite-wal", "storage/default/https+++example.com", "sessionstore.jsonlz4",
        ].map { firefox + "/" + $0 }
        let other: [String] = [
            "/Users/someone/Library/Caches/Google/Chrome/Default",
            "/Users/someone/Library/Safari/History.db",
            "/Users/someone/Library/Safari/History.db-wal",
            "/Users/someone/Library/Safari/Downloads.plist",
            "/Users/someone/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "/Users/someone/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3",
        ]
        return chrome + mozilla + other
    }()

    @Test(arguments: protectedPaths)
    func neverAllowsCredentialsBookmarksSettingsOrExtensionData(path: String) {
        #expect(PrivacyProtectedData.denyReason(for: path) != nil)
    }

    @Test(arguments: browsingTracePaths)
    func allowsBrowsingTraces(path: String) {
        #expect(PrivacyProtectedData.denyReason(for: path) == nil)
    }

    /// The scan of a fake Library must offer history and cookies but never
    /// credential, bookmark or extension files that sit right next to them.
    @Test func inventoryNeverOffersProtectedFiles() async throws {
        let sandbox = try PrivacyTestSandbox()
        let chrome = sandbox.library + "/Application Support/Google/Chrome/Default"
        for name in ["History", "History-journal", "Top Sites", "Login Data", "Login Data-journal", "Web Data", "Bookmarks", "Favicons", "Preferences", "Secure Preferences"] {
            try sandbox.makeFile(chrome + "/" + name)
        }
        try sandbox.makeFile(chrome + "/Network/Cookies")
        try sandbox.makeFile(chrome + "/Local Storage/leveldb/000003.log")
        try sandbox.makeFile(chrome + "/IndexedDB/https_example.com_0.indexeddb.leveldb/000003.log")
        try sandbox.makeFile(chrome + "/IndexedDB/chrome-extension_abcdef_0.indexeddb.leveldb/000003.log")
        try sandbox.makeFile(chrome + "/Extensions/abcdef/1.0/manifest.json")
        try sandbox.makeFile(sandbox.library + "/Application Support/Google/Chrome/Local State")
        try sandbox.makeFile(sandbox.library + "/Caches/Google/Chrome/Default/Cache/Cache_Data/data_0", bytes: 4096)

        let firefox = sandbox.library + "/Application Support/Firefox/Profiles/abcd.default-release"
        try sandbox.write("[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abcd.default-release\nDefault=1\n", to: sandbox.library + "/Application Support/Firefox/profiles.ini")
        for name in ["places.sqlite", "places.sqlite-wal", "logins.json", "key4.db", "cert9.db", "cookies.sqlite", "cookies.sqlite-wal", "formhistory.sqlite", "favicons.sqlite", "sessionstore.jsonlz4"] {
            try sandbox.makeFile(firefox + "/" + name)
        }
        try sandbox.makeFile(firefox + "/storage/default/https+++example.com/ls/data.sqlite")
        try sandbox.makeFile(firefox + "/storage/default/moz-extension+++1234/idb/store.sqlite")

        let safari = sandbox.library + "/Safari"
        for name in ["History.db", "History.db-wal", "Bookmarks.plist", "Downloads.plist", "LastSession.plist"] {
            try sandbox.makeFile(safari + "/" + name)
        }

        let scanner = PrivacyScanner(home: sandbox.home, browsers: [.chrome, .firefox, .safari], includesSystemData: false, readsFirefoxHistory: false)
        let result = await scanner.scan(applicationPaths: [:], runningBrowserIDs: [])
        let offered = result.browsers.flatMap(\.items).flatMap(\.targets).map(\.path)

        #expect(!offered.isEmpty)
        for path in offered {
            #expect(PrivacyProtectedData.denyReason(for: path) == nil, "Protected file offered: \(path)")
        }
        let names = Set(offered.map { ($0 as NSString).lastPathComponent })
        #expect(names.isDisjoint(with: ["Login Data", "Login Data-journal", "Web Data", "Bookmarks", "Favicons", "Preferences", "Secure Preferences", "Local State", "places.sqlite", "places.sqlite-wal", "logins.json", "key4.db", "cert9.db", "formhistory.sqlite", "favicons.sqlite", "Bookmarks.plist"]))
        #expect(names.isSuperset(of: ["History", "History-journal", "Top Sites", "Cookies", "cookies.sqlite", "cookies.sqlite-wal", "History.db", "History.db-wal", "Downloads.plist", "https+++example.com"]))
        #expect(!offered.contains { $0.contains("chrome-extension") || $0.contains("moz-extension") })

        let chromeReport = try #require(result.browsers.first { $0.id == PrivacyBrowser.chrome.id })
        #expect(chromeReport.bytes(in: .cache) > 0)
        #expect(chromeReport.items.contains { $0.category == .history && $0.safety == .review })
        #expect(chromeReport.items.contains { $0.category == .cookies && $0.safety == .caution })
        // Firefox history is cleared inside the database, never by deleting places.sqlite.
        let firefoxReport = try #require(result.browsers.first { $0.id == PrivacyBrowser.firefox.id })
        #expect(firefoxReport.firefoxHistory.count == 1)
        #expect(!firefoxReport.items.contains { $0.category == .history })
    }
}
