import Foundation
import Testing
@testable import MacCleaner

/// Leftover matching against a fake Library folder in a temporary directory.
struct UninstallerLeftoverTests {
    private static let notelyPath = "/Applications/Notely.app"

    private func notely(groups: [String] = [], team: String? = "ABCDE12345", helpers: [String] = [], jobLabels: [String] = []) -> UninstallerAppIdentity {
        UninstallerTestFixtures.identity(
            path: Self.notelyPath,
            bundleID: "com.example.Notely",
            names: ["Notely"],
            executable: "Notely",
            team: team,
            groups: groups,
            helpers: helpers,
            jobLabels: jobLabels
        )
    }

    private func locator(_ sandbox: UninstallerTestSandbox, system: Bool = false, receipts: Bool = false) -> UninstallerLeftoverLocator {
        UninstallerLeftoverLocator(
            homeLibrary: sandbox.root.appendingPathComponent("Library"),
            systemLibrary: system ? sandbox.root.appendingPathComponent("SystemLibrary") : nil,
            receiptsDirectory: receipts ? sandbox.root.appendingPathComponent("Receipts") : nil
        )
    }

    private func safety(_ result: UninstallerLocateResult) -> [String: CleanupSafety] {
        Dictionary(uniqueKeysWithValues: result.leftovers.map { ($0.path, $0.safety) })
    }

    @Test func exactAndPrefixedIdentifierMatchesAreSafe() throws {
        let sandbox = try UninstallerTestSandbox()
        let expectedSafe = [
            try sandbox.makeDirectory("Library/Application Support/com.example.Notely"),
            try sandbox.makeDirectory("Library/Caches/com.example.Notely"),
            try sandbox.makeDirectory("Library/Caches/com.example.Notely.ShipIt"),
            try sandbox.makeFile("Library/Preferences/com.example.Notely.plist"),
            try sandbox.makeFile("Library/Preferences/com.example.Notely.sync.plist"),
            try sandbox.makeFile("Library/Preferences/ByHost/com.example.Notely.1DE357A1-5E44-5B02-873C-A229AA4347E1.plist"),
            try sandbox.makeDirectory("Library/Containers/com.example.Notely"),
            try sandbox.makeDirectory("Library/Saved Application State/com.example.Notely.savedState"),
            try sandbox.makeDirectory("Library/HTTPStorages/com.example.Notely"),
            try sandbox.makeFile("Library/HTTPStorages/com.example.Notely.binarycookies"),
            try sandbox.makeDirectory("Library/WebKit/com.example.Notely"),
            try sandbox.makeDirectory("Library/Logs/com.example.Notely"),
            try sandbox.makeFile("Library/Cookies/com.example.Notely.binarycookies"),
            try sandbox.makeDirectory("Library/Application Scripts/com.example.Notely"),
        ]
        // Similar names that aren't the identifier or "<identifier>.…".
        let unrelated = [
            try sandbox.makeDirectory("Library/Caches/com.example.NotelyPro"),
            try sandbox.makeDirectory("Library/Caches/com.example.Notely-ide"),
            try sandbox.makeFile("Library/Preferences/com.example.plist"),
        ]

        let result = locator(sandbox).locate(for: notely(), otherApps: [])
        let found = safety(result)
        for path in expectedSafe {
            #expect(found[path] == .safe, "Expected \(path) to be found as safe")
        }
        for path in unrelated {
            #expect(found[path] == nil, "\(path) must not match")
        }
        let container = result.leftovers.first { $0.kind == .containers }
        #expect(container?.isProtectedAppData == true)
        #expect(result.leftovers.allSatisfy { !$0.isSystemWide })
    }

    @Test func appNameMatchesNeedReviewAndAreConservative() throws {
        let sandbox = try UninstallerTestSandbox()
        let support = try sandbox.makeDirectory("Library/Application Support/Notely")
        let caches = try sandbox.makeDirectory("Library/Caches/notely")
        let shortName = try sandbox.makeDirectory("Library/Application Support/Zed")
        let generic = try sandbox.makeDirectory("Library/Application Support/Helper")

        let notelyResult = locator(sandbox).locate(for: notely(), otherApps: [])
        #expect(safety(notelyResult)[support] == .review)
        #expect(safety(notelyResult)[caches] == .review)
        #expect(notelyResult.leftovers.first { $0.path == support }?.reason.isNameBased == true)

        // Names shorter than four characters are never matched.
        let zed = UninstallerTestFixtures.identity(path: "/Applications/Zed.app", bundleID: "dev.zed.Zed", names: ["Zed"])
        #expect(safety(locator(sandbox).locate(for: zed, otherApps: []))[shortName] == nil)

        // Generic words are never matched.
        let helper = UninstallerTestFixtures.identity(path: "/Applications/Helper.app", bundleID: "com.example.helperapp", names: ["Helper"])
        #expect(safety(locator(sandbox).locate(for: helper, otherApps: []))[generic] == nil)
    }

    @Test func sameNameAsAnotherInstalledAppIsExcluded() throws {
        let sandbox = try UninstallerTestSandbox()
        let support = try sandbox.makeDirectory("Library/Application Support/Notely")
        let other = UninstallerTestFixtures.identity(path: "/Applications/Other/Notely.app", bundleID: "org.other.notely", names: ["Notely"])

        let result = locator(sandbox).locate(for: notely(), otherApps: [other])
        #expect(safety(result)[support] == nil)
        #expect(result.excluded.contains { $0.path == support })
    }

    @Test func sharedVendorFoldersAreExcluded() throws {
        let sandbox = try UninstallerTestSandbox()
        let vendorFolder = try sandbox.makeDirectory("Library/Application Support/Google")
        let chromeData = try sandbox.makeDirectory("Library/Application Support/Google/Chrome")
        let driveData = try sandbox.makeDirectory("Library/Application Support/Google/DriveFS")
        let chromeCache = try sandbox.makeDirectory("Library/Caches/Google/Chrome")
        let chromeIdentifier = try sandbox.makeDirectory("Library/Application Support/com.google.Chrome")

        let chrome = UninstallerTestFixtures.identity(
            path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome", names: ["Google Chrome", "Chrome"],
            vendorWords: ["google", "google llc"]
        )
        let drive = UninstallerTestFixtures.identity(
            path: "/Applications/Google Drive.app", bundleID: "com.google.drivefs", names: ["Google Drive"],
            vendorWords: ["google", "google llc"]
        )

        let result = locator(sandbox).locate(for: chrome, otherApps: [drive])
        let found = safety(result)
        #expect(found[vendorFolder] == nil, "The shared vendor folder itself is never removed")
        #expect(found[chromeData] == .review)
        #expect(found[chromeCache] == .review)
        #expect(found[driveData] == nil)
        #expect(found[chromeIdentifier] == .safe)

        // An app named like its vendor: the folder is shared while another app of the vendor stays.
        let avastFolder = try sandbox.makeDirectory("Library/Application Support/Avast")
        let avast = UninstallerTestFixtures.identity(path: "/Applications/Avast.app", bundleID: "com.avast.AAFM", names: ["Avast"])
        let avastTool = UninstallerTestFixtures.identity(path: "/Applications/Avast Tool.app", bundleID: "com.avast.tool", names: ["Avast Tool"])
        let avastResult = locator(sandbox).locate(for: avast, otherApps: [avastTool])
        #expect(safety(avastResult)[avastFolder] == nil)
        #expect(avastResult.excluded.contains { $0.path == avastFolder })
        // Without the other app, the same folder is offered for review.
        #expect(safety(locator(sandbox).locate(for: avast, otherApps: []))[avastFolder] == .review)
    }

    @Test func moreSpecificIdentifiersOfOtherAppsWin() throws {
        let sandbox = try UninstallerTestSandbox()
        let own = try sandbox.makeDirectory("Library/Application Support/com.foo.app")
        let proData = try sandbox.makeDirectory("Library/Application Support/com.foo.app.pro")
        let ambiguous = try sandbox.makeDirectory("Library/Caches/com.foo.app.shared")
        let duplicate = try sandbox.makeDirectory("Library/Caches/com.bar.tool")

        let target = UninstallerTestFixtures.identity(path: "/Applications/Foo.app", bundleID: "com.foo.app", names: ["Foo Basic"])
        let pro = UninstallerTestFixtures.identity(path: "/Applications/Foo Pro.app", bundleID: "com.foo.app.pro", names: ["Foo Pro"])
        let result = locator(sandbox).locate(for: target, otherApps: [pro])
        let found = safety(result)
        #expect(found[own] == .safe)
        #expect(found[proData] == nil)
        #expect(result.excluded.contains { $0.path == proData })
        #expect(found[ambiguous] == .review, "Items under a namespace another app shares need review")

        // Two copies of the same app: their data is shared.
        let copyA = UninstallerTestFixtures.identity(path: "/Applications/Tool.app", bundleID: "com.bar.tool", names: ["Bar Tool"])
        let copyB = UninstallerTestFixtures.identity(path: "/Users/someone/Applications/Tool.app", bundleID: "com.bar.tool", names: ["Bar Tool"])
        #expect(safety(locator(sandbox).locate(for: copyA, otherApps: [copyB]))[duplicate] == nil)
    }

    @Test func helperIdentifiersBelongToTheApp() throws {
        let sandbox = try UninstallerTestSandbox()
        let helperContainer = try sandbox.makeDirectory("Library/Containers/com.example.notelyhelper")
        let extensionContainer = try sandbox.makeDirectory("Library/Containers/com.example.Notely.ShareExtension")

        let result = locator(sandbox).locate(for: notely(helpers: ["com.example.notelyhelper"]), otherApps: [])
        #expect(safety(result)[helperContainer] == .safe)
        #expect(safety(result)[extensionContainer] == .safe)
        #expect(result.leftovers.first { $0.path == helperContainer }?.reason == .helperIdentifier("com.example.notelyhelper"))
    }

    @Test func groupContainersRequireOwnershipEvidence() throws {
        let sandbox = try UninstallerTestSandbox()
        let named = try sandbox.makeDirectory("Library/Group Containers/ABCDE12345.com.example.Notely")
        let groupPrefixed = try sandbox.makeDirectory("Library/Group Containers/group.com.example.Notely.widgets")
        let sharedWithTasks = try sandbox.makeDirectory("Library/Group Containers/ABCDE12345.shared")
        let declaredOnly = try sandbox.makeDirectory("Library/Group Containers/ABCDE12345.NotelySync")
        let unrelated = try sandbox.makeDirectory("Library/Group Containers/ZZZZZ99999.com.unrelated.app")
        let apple = try sandbox.makeDirectory("Library/Group Containers/group.com.apple.notes")

        let target = notely(groups: ["ABCDE12345.com.example.Notely", "ABCDE12345.shared", "ABCDE12345.NotelySync"])
        let tasks = UninstallerTestFixtures.identity(
            path: "/Applications/Tasks.app", bundleID: "com.example.Tasks", names: ["Tasks Pro"], team: "ABCDE12345",
            groups: ["ABCDE12345.shared"]
        )
        let result = locator(sandbox).locate(for: target, otherApps: [tasks])
        let found = safety(result)
        #expect(found[named] == .safe)
        #expect(found[groupPrefixed] == .safe)
        #expect(found[sharedWithTasks] == nil)
        #expect(result.excluded.contains { $0.path == sharedWithTasks })
        #expect(found[declaredOnly] == .review, "Declared but not named after the app: review")
        #expect(found[unrelated] == nil)
        #expect(found[apple] == nil)
        #expect(result.leftovers.filter { $0.kind == .groupContainers }.allSatisfy { $0.isProtectedAppData })

        // A team-mate app whose entitlements are unknown might share a group named after the target.
        let unknownTeammate = UninstallerTestFixtures.identity(
            path: "/Applications/Mystery.app", bundleID: "com.example.Mystery", names: ["Mystery"], team: "ABCDE12345", entitlementsKnown: false
        )
        #expect(safety(locator(sandbox).locate(for: target, otherApps: [unknownTeammate]))[named] == .review)
    }

    @Test func launchAgentsMatchByLabelProgramOrAssociatedIdentifier() throws {
        let sandbox = try UninstallerTestSandbox()
        let byLabel = try sandbox.makePlist("Library/LaunchAgents/com.example.Notely.helper.plist", [
            "Label": "com.example.Notely.helper", "ProgramArguments": ["/usr/bin/true"],
        ])
        let byProgram = try sandbox.makePlist("Library/LaunchAgents/com.vendor.launcher.plist", [
            "Label": "com.vendor.launcher", "ProgramArguments": ["/usr/bin/open", "-a", "/Applications/Notely.app", "--args", "--background"],
        ])
        let byAssociation = try sandbox.makePlist("Library/LaunchAgents/notely-sync.plist", [
            "Label": "Notely Sync", "AssociatedBundleIdentifiers": "com.example.Notely", "ProgramArguments": ["/usr/local/bin/notely-sync"],
        ])
        let otherApp = try sandbox.makePlist("Library/LaunchAgents/com.other.agent.plist", [
            "Label": "com.other.agent", "ProgramArguments": ["/Applications/Other.app/Contents/MacOS/Agent"],
        ])
        let shared = try sandbox.makePlist("Library/LaunchAgents/com.suite.updater.plist", [
            "Label": "com.suite.updater",
            "ProgramArguments": ["/Applications/Notely.app/Contents/Helpers/Updater", "--also", "/Applications/Other.app"],
        ])

        let other = UninstallerTestFixtures.identity(path: "/Applications/Other.app", bundleID: "com.other.app", names: ["Other App"])
        let result = locator(sandbox).locate(for: notely(), otherApps: [other])
        let found = safety(result)
        #expect(found[byLabel] == .safe)
        #expect(found[byProgram] == .safe)
        #expect(found[byAssociation] == .safe)
        #expect(found[otherApp] == nil)
        #expect(found[shared] == nil)
        #expect(result.excluded.contains { $0.path == shared })
        #expect(result.leftovers.first { $0.path == byLabel }?.launchLabel == "com.example.Notely.helper")
    }

    @Test func systemWideItemsNeedAnAdministrator() throws {
        let sandbox = try UninstallerTestSandbox()
        let support = try sandbox.makeDirectory("SystemLibrary/Application Support/com.example.Notely")
        let daemon = try sandbox.makePlist("SystemLibrary/LaunchDaemons/com.example.Notely.daemon.plist", [
            "Label": "com.example.Notely.daemon", "Program": "/Library/PrivilegedHelperTools/com.example.Notely.daemon",
        ])
        let helperTool = try sandbox.makeFile("SystemLibrary/PrivilegedHelperTools/com.example.Notely.daemon")
        let systemPrefs = try sandbox.makeFile("SystemLibrary/Preferences/com.example.Notely.plist")
        let unrelatedDaemon = try sandbox.makePlist("SystemLibrary/LaunchDaemons/com.vendor.service.plist", [
            "Label": "com.vendor.service", "Program": "/Library/PrivilegedHelperTools/com.vendor.service",
        ])

        let result = locator(sandbox, system: true).locate(for: notely(), otherApps: [])
        let found = safety(result)
        for path in [support, daemon, helperTool, systemPrefs] {
            #expect(found[path] == .safe, "Expected \(path)")
            #expect(result.leftovers.first { $0.path == path }?.isSystemWide == true)
        }
        #expect(found[unrelatedDaemon] == nil)
        #expect(result.leftovers.first { $0.path == daemon }?.kind == .launchDaemons)
        #expect(result.leftovers.first { $0.path == helperTool }?.kind == .privilegedHelpers)
    }

    @Test func resultsNeverLeaveTheLibraryFolders() throws {
        let sandbox = try UninstallerTestSandbox()
        try sandbox.makeDirectory("Library/Application Support/com.example.Notely")
        try sandbox.makeDirectory("Library/Application Support/Notely")
        try sandbox.makeDirectory("Library/Caches/com.example.Notely")
        // Look-alikes outside Library must never be returned.
        try sandbox.makeDirectory("Documents/Notely")
        try sandbox.makeDirectory("Documents/com.example.Notely")
        try sandbox.makeDirectory("SystemLibrary/Caches/com.example.Notely")

        let locator = locator(sandbox, system: true)
        let result = locator.locate(for: notely(), otherApps: [])
        #expect(!result.leftovers.isEmpty)
        let roots = [locator.homeLibrary, locator.systemLibrary].compactMap { $0 }
        for leftover in result.leftovers {
            #expect(roots.contains { PathUtilities.isDescendant(leftover.path, of: $0) }, "\(leftover.path) is outside the Library folders")
            #expect(!roots.contains(leftover.path))
        }
        #expect(!result.leftovers.contains { $0.path.contains("/Documents/") })
    }

    @Test func crashReportsMatchTheExecutableName() throws {
        let sandbox = try UninstallerTestSandbox()
        let report = try sandbox.makeFile("Library/Logs/DiagnosticReports/Notely-2026-01-02-101010.ips")
        let otherReport = try sandbox.makeFile("Library/Logs/DiagnosticReports/NotelyPro-2026-01-02-101010.ips")
        let notAReport = try sandbox.makeFile("Library/Logs/DiagnosticReports/Notely-notes.txt")

        let found = safety(locator(sandbox).locate(for: notely(), otherApps: []))
        #expect(found[report] == .safe)
        #expect(found[otherReport] == nil)
        #expect(found[notAReport] == nil)
    }

    @Test func receiptsAreInformationOnly() throws {
        let sandbox = try UninstallerTestSandbox()
        try sandbox.makeFile("Receipts/com.example.Notely.pkg.plist")
        try sandbox.makeFile("Receipts/com.example.Notely.pkg.bom")
        try sandbox.makeFile("Receipts/com.unrelated.pkg.plist")

        let result = locator(sandbox, receipts: true).locate(for: notely(), otherApps: [])
        #expect(result.receipts == ["com.example.Notely.pkg"])
        #expect(!result.leftovers.contains { $0.path.contains("/Receipts/") })
    }

    @Test func unreadableFoldersHaveAnUnknownSize() {
        var unreadable = DiskUsage()
        unreadable.directoryCount = 1
        unreadable.unreadableDirectoryCount = 1
        #expect(UninstallerLeftoverService.knownUsage(unreadable) == nil, "Zero bytes would be a guess")
        var partial = unreadable
        partial.fileCount = 3
        partial.reclaimableBytes = 4_096
        #expect(UninstallerLeftoverService.knownUsage(partial) == partial)
        #expect(UninstallerLeftoverService.knownUsage(.zero) == .zero)
    }

    @Test func batchLocateListsFoldersOncePerTarget() throws {
        let sandbox = try UninstallerTestSandbox()
        let first = try sandbox.makeDirectory("Library/Caches/com.example.Notely")
        let second = try sandbox.makeDirectory("Library/Caches/com.other.Writer")
        let writer = UninstallerTestFixtures.identity(path: "/Applications/Writer.app", bundleID: "com.other.Writer", names: ["Writer Plus"])

        let results = locator(sandbox).locate(for: [notely(), writer], otherApps: [])
        #expect(results.count == 2)
        #expect(results[0].leftovers.map(\.path) == [first])
        #expect(results[1].leftovers.map(\.path) == [second])
    }
}

struct UninstallerIdentifierRulesTests {
    @Test(arguments: [
        ("com.vendor.app", true), ("org.example.tool.helper", true), ("md.obsidian", false), ("Google", false),
        ("com.Adobe.Premiere Pro.22.0", false), ("Com.vendor.app", false), ("com..app", false), ("1com.vendor.app", false),
    ])
    func reverseDNSRecognition(name: String, expected: Bool) {
        #expect(UninstallerIdentifierRules.isReverseDNS(name) == expected)
    }

    @Test func groupIdentifiersAreParsed() {
        #expect(UninstallerIdentifierRules.parseGroupIdentifier("6N38VWS5BX.ru.keepcoder.Telegram") == (team: "6N38VWS5BX", identifier: "ru.keepcoder.Telegram"))
        #expect(UninstallerIdentifierRules.parseGroupIdentifier("D3Y7QS482H.group.me.damir.dropover-mac") == (team: "D3Y7QS482H", identifier: "me.damir.dropover-mac"))
        #expect(UninstallerIdentifierRules.parseGroupIdentifier("group.com.example.app") == (team: nil, identifier: "com.example.app"))
        #expect(UninstallerIdentifierRules.parseGroupIdentifier("UBF8T346G9.Office") == (team: "UBF8T346G9", identifier: "Office"))
    }

    @Test func hostSuffixesAreStripped() {
        #expect(UninstallerIdentifierRules.strippingHostSuffix("com.foo.app.1DE357A1-5E44-5B02-873C-A229AA4347E1") == "com.foo.app")
        #expect(UninstallerIdentifierRules.strippingHostSuffix("com.foo.app.001122AABBCC") == "com.foo.app")
        #expect(UninstallerIdentifierRules.strippingHostSuffix("com.foo.app") == "com.foo.app")
    }

    @Test func identifierMatchingUsesWholeComponents() {
        #expect(UninstallerIdentifierRules.matches("com.foo.app", identifier: "com.foo.app"))
        #expect(UninstallerIdentifierRules.matches("COM.FOO.APP.ShipIt", identifier: "com.foo.app"))
        #expect(!UninstallerIdentifierRules.matches("com.foo.application", identifier: "com.foo.app"))
        #expect(!UninstallerIdentifierRules.matches("com.foo.app-ide", identifier: "com.foo.app"))
    }

    @Test func appleIdentifiersAreRecognized() {
        #expect(UninstallerIdentifierRules.isAppleIdentifier("com.apple.Safari"))
        #expect(UninstallerIdentifierRules.isAppleIdentifier("group.com.apple.notes"))
        #expect(UninstallerIdentifierRules.isAppleIdentifier("243LU875E5.groups.com.apple.podcasts"))
        #expect(UninstallerIdentifierRules.isAppleIdentifier("is.workflow.shortcuts"))
        #expect(!UninstallerIdentifierRules.isAppleIdentifier("com.applesauce.app"))
    }

    @Test func vendorWordsComeFromIdentifierAndDeveloper() {
        #expect(UninstallerAppIdentity.vendorWords(bundleIdentifier: "com.google.Chrome", developer: "Google LLC") == ["google", "google llc"])
        #expect(UninstallerAppIdentity.vendorWords(bundleIdentifier: "md.obsidian", developer: "Mac App Store") == [])
        #expect(UninstallerAppIdentity.vendorWords(bundleIdentifier: "com.spotify.client", developer: "Spotify") == ["spotify"])
    }

    @Test func copyrightHolderIsExtracted() {
        #expect(UninstallerApp.copyrightHolder("Copyright © 2013–2024 Telegram Messenger Inc. All rights reserved.") == "Telegram Messenger Inc")
        #expect(UninstallerApp.copyrightHolder("© 2003-2024 Apple Inc.") == "Apple Inc")
        #expect(UninstallerApp.copyrightHolder(nil) == nil)
        #expect(UninstallerApp.copyrightHolder("2024") == nil)
    }
}
