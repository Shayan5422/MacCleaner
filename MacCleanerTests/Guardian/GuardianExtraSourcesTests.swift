import Foundation
import Testing
@testable import MacCleaner

struct GuardianPluginKitTests {
    /// `pluginkit -m -v` output: election mark, identifier(version), UUID, registration time and path, tab-separated.
    static let sample = """
         com.apple.share.System.add-to-photos(1.0)\t3F2504E0-4F89-11D3-9A0C-0305E82C3301\t2026-09-17 18:14:08 +0000\t/System/Library/PrivateFrameworks/ShareKit.framework/PlugIns/AddToPhotos.appex
    +    com.example.sync.finder(4.2)\t1225956C-47AF-4DF6-BDC5-E021BEB49756\t2026-10-16 14:38:14 +0000\t/Applications/Example Sync.app/Contents/PlugIns/FinderSync.appex
    -    com.example.other.finder(1.0)\t6A894073-844D-4AEB-ACF5-A059E19DA447\t2026-09-17 18:14:08 +0000\t/Applications/Other.app/Contents/PlugIns/OtherFinder.appex
         com.example.sync.fileprovider(4.2)\t02FA0EB1-0949-4429-8B0D-B788D95CBE22\t2026-10-01 09:00:00 +0000\t/Applications/Example Sync.app/Contents/PlugIns/FileProvider.appex
         com.example.widget(2.5)\t2E0B8C11-8E10-4518-91F4-CED11730D437\t2026-09-17 18:14:09 +0000\t/Applications/Example.app/Contents/PlugIns/Widget.appex
    =    com.example.widget(2.4)\t2E0B8C11-8E10-4518-91F4-CED11730D438\t2026-09-01 18:14:09 +0000\t/Applications/Example 2.app/Contents/PlugIns/Widget.appex
     (6 plug-ins)
    """

    @Test func parsesElectionIdentifierVersionAndPath() {
        let entries = GuardianPluginKitParser.parse(Self.sample)
        #expect(entries.count == 6)
        let finder = entries[1]
        #expect(finder.election == "+")
        #expect(finder.identifier == "com.example.sync.finder")
        #expect(finder.version == "4.2")
        #expect(finder.uuid == "1225956C-47AF-4DF6-BDC5-E021BEB49756")
        #expect(finder.path == "/Applications/Example Sync.app/Contents/PlugIns/FinderSync.appex")
        #expect(finder.registered == ISO8601DateFormatter().date(from: "2026-10-16T14:38:14Z"))
        #expect(entries[0].election == nil)
        #expect(entries[2].election == "-")
        #expect(entries[5].election == "=")
    }

    @Test func ignoresFooterAndNoMatches() {
        #expect(GuardianPluginKitParser.parse("  (no matches)\n").isEmpty)
        #expect(GuardianPluginKitParser.parse(" (518 plug-ins)").isEmpty)
    }

    @Test func onlyThirdPartyExtensionsThatRunByThemselvesAreRecords() {
        let points: [String: String] = [
            "/Applications/Example Sync.app/Contents/PlugIns/FinderSync.appex": "com.apple.FinderSync",
            "/Applications/Other.app/Contents/PlugIns/OtherFinder.appex": "com.apple.FinderSync",
            "/Applications/Example Sync.app/Contents/PlugIns/FileProvider.appex": "com.apple.fileprovider-nonui",
            "/Applications/Example.app/Contents/PlugIns/Widget.appex": "com.apple.widgetkit-extension",
        ]
        let result = GuardianExtensionPoints.records(from: GuardianPluginKitParser.parse(Self.sample), extensionPoint: { points[$0] }, now: Date())
        #expect(result.records.map(\.identifier) == ["com.example.sync.finder", "com.example.other.finder", "com.example.sync.fileprovider"])
        #expect(result.records[0].kind == .finderSyncExtension)
        #expect(result.records[0].isEnabled == true)
        // Finder Sync extensions run only when switched on.
        #expect(result.records[1].isEnabled == false)
        #expect(result.records[2].kind == .backgroundExtension)
        #expect(result.records[2].isEnabled == true)
        #expect(result.records[0].ownerName == "Example Sync")
        // The widget runs only when shown; the superseded duplicate isn't counted twice.
        #expect(result.onDemand == 1)
    }
}

struct GuardianCronTests {
    @Test func cronLinesBecomeRecordsWithReadableSchedules() {
        let jobs = SecuritySystemInventoryParser.cronJobs("""
        # m h dom mon dow command
        SHELL=/bin/zsh
        */5 * * * * /Users/test/bin/sync.sh --quiet
        @reboot /usr/local/bin/tunnel start
        30 4 * * * cd /tmp && make clean
        */5 * * * * /Users/test/bin/sync.sh --quiet
        """)
        let records = GuardianExtraSources.cronRecords(jobs, now: Date())
        #expect(records.count == 4)
        #expect(records[0].name == "sync.sh")
        #expect(records[0].programPath == "/Users/test/bin/sync.sh")
        #expect(records[0].arguments == ["--quiet"])
        #expect(records[0].trigger == "Every 5 minutes")
        #expect(records[1].trigger == "At startup")
        #expect(records[2].programPath == nil)
        #expect(records[2].note == "Runs: cd /tmp && make clean")
        #expect(records[2].trigger == "Every day at 04:30")
        // The same line twice keeps two distinct identities.
        #expect(records[0].id != records[3].id)
        #expect(records.allSatisfy { $0.source == .cronJobs && $0.kind == .cronJob })
    }

    @Test func scheduleSummaries() {
        #expect(GuardianExtraSources.cronScheduleSummary("* * * * *") == "Every minute")
        #expect(GuardianExtraSources.cronScheduleSummary("15 * * * *") == "Every hour at :15")
        #expect(GuardianExtraSources.cronScheduleSummary("@hourly") == "Every hour")
        #expect(GuardianExtraSources.cronScheduleSummary("0 9 * * 1-5") == "Schedule 0 9 * * 1-5")
    }
}

struct GuardianLegacySourceTests {
    @Test func legacyStartupItemsAreListedAsNotRun() throws {
        let directory = try GuardianTestDirectory()
        try directory.write("#!/bin/sh\n", to: "StartupItems/OldThing/OldThing")
        try directory.write("", to: "StartupItems/.DS_Store")
        let result = GuardianExtraSources.legacyStartupItems(folder: directory.path("StartupItems"), now: Date())
        #expect(result.records.map(\.name) == ["OldThing"])
        #expect(result.records.first?.isEnabled == false)
        #expect(result.status.state == .read)
        #expect(GuardianExtraSources.legacyStartupItems(folder: directory.path("missing"), now: Date()).status.state == .notPresent)
    }

    @Test func periodicReportsOnlyCustomScripts() throws {
        let directory = try GuardianTestDirectory()
        try directory.write("#!/bin/sh\n", to: "etc/periodic/daily/110.clean-tmps")
        let custom = try directory.write("#!/bin/sh\n", to: "etc/periodic/daily/500.backup-to-server")
        chmod(custom, 0o755)
        try directory.write("#!/bin/sh\n", to: "local/periodic/weekly/cleanup")
        try directory.write("echo hi\n", to: "etc/daily.local")
        let result = GuardianExtraSources.periodicScripts(
            roots: [directory.path("etc/periodic"), directory.path("local/periodic")],
            appleRoot: directory.path("etc/periodic"),
            localFiles: [directory.path("etc/daily.local"), directory.path("etc/weekly.local")],
            now: Date()
        )
        let names = result.records.map(\.name).sorted()
        #expect(!names.contains("110.clean-tmps"))
        #expect(names.contains("500.backup-to-server"))
        #expect(names.contains("cleanup"))
        #expect(names.contains("daily.local"))
        #expect(result.records.first { $0.name == "500.backup-to-server" }?.isEnabled == true)
        #expect(result.records.first { $0.name == "cleanup" }?.trigger == "Runs weekly (periodic)")
        #expect(result.status.state == .read)

        let none = GuardianExtraSources.periodicScripts(roots: [directory.path("nothing")], localFiles: [], now: Date())
        #expect(none.status.state == .notPresent)
        #expect(none.status.note != nil)
    }

    @Test func appleScriptNamesAreSkippedInTheSystemFolder() {
        #expect(GuardianExtraSources.applePeriodicScripts.contains("110.clean-tmps"))
        #expect(!GuardianExtraSources.applePeriodicScripts.contains("500.backup-to-server"))
    }

    @Test func launchdConfPresenceIsReported() throws {
        let directory = try GuardianTestDirectory()
        #expect(GuardianExtraSources.launchdConf(path: directory.path("launchd.conf"), now: Date()).records.isEmpty)
        try directory.write("setenv DYLD_INSERT_LIBRARIES /tmp/x.dylib\n", to: "launchd.conf")
        let result = GuardianExtraSources.launchdConf(path: directory.path("launchd.conf"), now: Date())
        #expect(result.records.count == 1)
        #expect(result.records.first?.note?.contains("ignores") == true)
    }

    @Test func loginAndLogoutHooksAreRead() throws {
        let directory = try GuardianTestDirectory()
        try directory.writePlist(["LoginHook": "/usr/local/bin/at-login.sh", "TALLogoutSavesState": false], to: "user.plist")
        try directory.writePlist(["LogoutHook": "/Library/Scripts/at-logout.sh", "LoginHook": "/usr/local/bin/at-login.sh"], to: "all.plist")
        let result = GuardianExtraSources.loginHooks(preferenceFiles: [directory.path("user.plist"), directory.path("all.plist"), directory.path("missing.plist")], now: Date())
        #expect(result.records.map(\.kind) == [.loginHook, .logoutHook])
        #expect(result.records.first?.programPath == "/usr/local/bin/at-login.sh")
        #expect(result.status.state == .read)
        #expect(result.status.note?.contains("root") == true)
    }

    @Test func pluginsAreFoundAndQuickLookGeneratorsMarkedUnsupported() throws {
        let directory = try GuardianTestDirectory()
        try directory.writePlist(["CFBundleIdentifier": "com.example.importer"], to: "Spotlight/Example.mdimporter/Contents/Info.plist")
        try directory.makeDirectory("QuickLook/Old.qlgenerator/Contents")
        try directory.write("", to: "QuickLook/readme.txt")
        let folders = [
            GuardianExtraSources.PluginFolder(path: directory.path("Spotlight"), kind: .spotlightImporter, suffix: ".mdimporter"),
            GuardianExtraSources.PluginFolder(path: directory.path("QuickLook"), kind: .quickLookPlugin, suffix: ".qlgenerator"),
            GuardianExtraSources.PluginFolder(path: directory.path("Missing"), kind: .quickLookPlugin, suffix: ".qlgenerator"),
        ]
        let result = GuardianExtraSources.plugins(folders: folders, quickLookGeneratorsSupported: false, now: Date())
        #expect(result.records.map(\.name) == ["Example", "Old"])
        #expect(result.records[0].identifier == "com.example.importer")
        #expect(result.records[0].isEnabled == true)
        #expect(result.records[1].isEnabled == false)
        #expect(result.records[1].note?.contains("macOS 15") == true)
    }
}
