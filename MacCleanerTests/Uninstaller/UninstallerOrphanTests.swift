import Foundation
import Testing
@testable import MacCleaner

/// Detection of leftovers from apps that are no longer installed, on a fake Library.
struct UninstallerOrphanTests {
    private func scanner(_ sandbox: UninstallerTestSandbox, system: Bool = false, canRead: Bool = false) -> UninstallerOrphanScanner {
        UninstallerOrphanScanner(
            homeLibrary: sandbox.root.appendingPathComponent("Library"),
            systemLibrary: system ? sandbox.root.appendingPathComponent("SystemLibrary") : nil,
            canReadProtectedAppData: canRead
        )
    }

    private func installed(_ identities: [UninstallerAppIdentity], running: [String] = []) -> UninstallerInstalledSet {
        UninstallerInstalledSet(apps: identities, additionalIdentifiers: running)
    }

    private let installedApp = UninstallerTestFixtures.identity(
        path: "/Applications/Installed.app", bundleID: "com.installed.App", names: ["Installed"],
        groups: ["TEAM123456.com.installed.shared"], helpers: ["com.installed.App.helper"]
    )

    @Test func findsItemsOfRemovedAppsAndGroupsThem() throws {
        let sandbox = try UninstallerTestSandbox()
        let paths = [
            try sandbox.makeDirectory("Library/Application Support/com.gone.App"),
            try sandbox.makeFile("Library/Preferences/com.gone.App.plist"),
            try sandbox.makeDirectory("Library/Caches/com.gone.App"),
            try sandbox.makeDirectory("Library/Containers/com.gone.App"),
            try sandbox.makeDirectory("Library/Saved Application State/com.gone.App.savedState"),
            try sandbox.makeFile("Library/HTTPStorages/com.gone.App.binarycookies"),
        ]
        try sandbox.ageEverything(days: 30)

        let items = scanner(sandbox).scan(installed: installed([installedApp])) { _ in false }
        #expect(Set(items.map(\.path)) == Set(paths))
        #expect(items.allSatisfy { $0.identifier == "com.gone.App" })
        #expect(items.first { $0.kind == .containers }?.isProtectedAppData == true)
        #expect(items.filter { $0.kind != .containers }.allSatisfy { !$0.isProtectedAppData })

        let groups = UninstallerOrphanScanner.group(items)
        #expect(groups.count == 1)
        #expect(groups.first?.displayName == "Gone")
        #expect(groups.first?.items.count == paths.count)

        // Leftovers of removed apps always need review and are never preselected.
        let candidate = try #require(items.first).cleanupCandidate(identifier: "com.gone.App")
        #expect(candidate.safety == .review)
        #expect(!candidate.isSelectedByDefault)
        #expect(candidate.purpose == .applicationData)
    }

    @Test func skipsInstalledRegisteredAppleAndSharedItems() throws {
        let sandbox = try UninstallerTestSandbox()
        try sandbox.makeDirectory("Library/Application Support/com.apple.Something")
        try sandbox.makeDirectory("Library/Caches/com.installed.App.ShipIt")
        try sandbox.makeFile("Library/Preferences/com.installed.App.helper.plist")
        try sandbox.makeDirectory("Library/Caches/com.installed")
        try sandbox.makeDirectory("Library/Caches/com.plausiblelabs.crashreporter.data")
        try sandbox.makeDirectory("Library/Caches/com.registered.App")
        try sandbox.makeDirectory("Library/Caches/is.workflow.shortcuts")
        try sandbox.makeDirectory("Library/Caches/Some Folder")
        try sandbox.makeDirectory("Library/Caches/org.swift.swiftpm")
        try sandbox.makeDirectory("Library/Application Support/com.running.Agent")
        // An ancestor of an installed identifier: "com.vendor.suite" while "com.vendor.suite.pro" is installed.
        try sandbox.makeDirectory("Library/Application Support/com.vendor.suite")
        let removed = try sandbox.makeDirectory("Library/Caches/com.removed.Tool")
        try sandbox.ageEverything(days: 30)

        let suitePro = UninstallerTestFixtures.identity(path: "/Applications/Suite Pro.app", bundleID: "com.vendor.suite.pro", names: ["Suite Pro"])
        let items = scanner(sandbox).scan(installed: installed([installedApp, suitePro], running: ["com.running.Agent"])) { identifier in
            identifier.lowercased() == "com.registered.app"
        }
        #expect(items.map(\.path) == [removed])
    }

    @Test func recentlyChangedItemsAreStillInUse() throws {
        let sandbox = try UninstallerTestSandbox()
        let old = try sandbox.makeDirectory("Library/Application Support/com.old.App")
        try sandbox.makeDirectory("Library/Application Support/com.fresh.App")
        try sandbox.age("Library/Application Support/com.old.App", days: 40)

        let items = scanner(sandbox).scan(installed: installed([])) { _ in false }
        #expect(items.map(\.path) == [old])
    }

    @Test func hostPreferencesAndGroupContainersAreParsed() throws {
        let sandbox = try UninstallerTestSandbox()
        let byHost = try sandbox.makeFile("Library/Preferences/ByHost/com.gone.App.1DE357A1-5E44-5B02-873C-A229AA4347E1.plist")
        let group = try sandbox.makeDirectory("Library/Group Containers/ABCDE12345.com.gone.App")
        try sandbox.makeDirectory("Library/Group Containers/TEAM123456.com.installed.shared")
        try sandbox.makeDirectory("Library/Group Containers/UBF8T346G9.Office")
        try sandbox.ageEverything(days: 30)

        let items = scanner(sandbox).scan(installed: installed([installedApp])) { _ in false }
        #expect(Set(items.map(\.path)) == [byHost, group])
        #expect(items.allSatisfy { $0.identifier == "com.gone.App" })
        #expect(items.first { $0.path == group }?.kind == .groupContainers)
    }

    @Test func launchJobsOfRemovedAppsAreFound() throws {
        let sandbox = try UninstallerTestSandbox()
        let presentApp = try sandbox.makeDirectory("Applications/Present.app/Contents/MacOS")
        let goneAgent = try sandbox.makePlist("Library/LaunchAgents/com.gone.agent.plist", [
            "Label": "com.gone.agent",
            "ProgramArguments": ["/Applications/Gone-\(UUID().uuidString).app/Contents/MacOS/Agent", "--background"],
        ])
        try sandbox.makePlist("Library/LaunchAgents/com.present.agent.plist", [
            "Label": "com.present.agent", "ProgramArguments": [presentApp + "/Agent"],
        ])
        try sandbox.makePlist("Library/LaunchAgents/com.tool.daemon.plist", [
            "Label": "com.tool.daemon", "ProgramArguments": ["/usr/local/bin/tool"],
        ])
        let goneDaemon = try sandbox.makePlist("SystemLibrary/LaunchDaemons/com.gone.service.plist", [
            "Label": "com.gone.service",
            "Program": "/Library/PrivilegedHelperTools/com.gone.service",
            "AssociatedBundleIdentifiers": ["com.gone.Product"],
        ])
        try sandbox.makePlist("SystemLibrary/LaunchDaemons/com.installed.App.daemon.plist", [
            "Label": "com.installed.App.daemon",
            "Program": "/Library/PrivilegedHelperTools/com.installed.App.daemon",
            "AssociatedBundleIdentifiers": ["com.installed.App"],
        ])
        try sandbox.ageEverything(days: 30)

        let items = scanner(sandbox, system: true).scan(installed: installed([installedApp])) { _ in false }
        #expect(Set(items.map(\.path)) == [goneAgent, goneDaemon])
        #expect(items.first { $0.path == goneAgent }?.kind == .launchAgents)
        #expect(items.first { $0.path == goneAgent }?.isSystemWide == false)
        #expect(items.first { $0.path == goneDaemon }?.kind == .launchDaemons)
        #expect(items.first { $0.path == goneDaemon }?.isSystemWide == true)
    }

    @Test func helpersOfARemovedAppJoinItsGroup() {
        func item(_ identifier: String, _ kind: UninstallerLeftoverKind, bytes: Int64) -> UninstallerOrphanItem {
            var usage = DiskUsage()
            usage.reclaimableBytes = bytes
            return UninstallerOrphanItem(
                path: "/tmp/\(identifier)/\(kind.rawValue)", identifier: identifier, kind: kind, modificationDate: nil,
                isProtectedAppData: false, usage: usage, snapshot: nil, sameDeveloperAs: nil
            )
        }
        let groups = UninstallerOrphanScanner.group([
            item("com.macpaw.CleanMyMac4", .preferences, bytes: 10),
            item("com.macpaw.CleanMyMac4.Updater", .webData, bytes: 20),
            item("com.macpaw.CleanMyMac4.Menu", .preferences, bytes: 5),
            item("us.zoom.xos", .preferences, bytes: 100),
            item("us.zoom.updater", .preferences, bytes: 1),
            item("us.zoom.updater.login.check", .launchAgents, bytes: 1),
        ])
        #expect(groups.map(\.identifier) == ["us.zoom.xos", "com.macpaw.CleanMyMac4", "us.zoom.updater"])
        #expect(groups[1].items.count == 3)
        #expect(groups[1].totalBytes == 35)
        #expect(groups[2].items.count == 2)
    }

    @Test(arguments: [
        ("com.isaacmarovitz.Whisky", "Whisky"), ("com.openai.atlas", "Atlas"), ("chat.atomic.app", "Atomic"),
        ("com.macpaw.CleanMyMac4.Updater", "CleanMyMac4 Updater"), ("com.todesktop.230313mzl4w4u92", "com.todesktop.230313mzl4w4u92"),
        ("Canva", "Canva"),
    ])
    func orphanGroupNames(identifier: String, expected: String) {
        #expect(UninstallerOrphanGroup.displayName(for: identifier) == expected)
    }

    @Test func installedSetOwnership() {
        let set = UninstallerInstalledSet(apps: [
            UninstallerTestFixtures.identity(path: "/Applications/A.app", bundleID: "com.vendor.App", names: ["A"]),
            UninstallerTestFixtures.identity(path: "/Applications/B.app", bundleID: "md.obsidian", names: ["Obsidian"]),
            UninstallerTestFixtures.identity(path: "/Applications/C.app", bundleID: "com.suite.app.pro", names: ["C"]),
        ])
        #expect(set.owns("com.vendor.app"))
        #expect(set.owns("com.vendor.app.shipit"))
        #expect(set.owns("md.obsidian.helper"))
        #expect(set.owns("com.suite.app"))
        #expect(!set.owns("com.vendor.application"))
        #expect(!set.owns("com.other.app"))
        #expect(set.vendorApps["com.vendor"] == "A")
    }

    @Test func enclosingAppBundleIsTheOutermostApp() {
        #expect(UninstallerOrphanScanner.enclosingAppBundle("/Applications/Foo.app/Contents/MacOS/Foo") == "/Applications/Foo.app")
        #expect(UninstallerOrphanScanner.enclosingAppBundle("/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper") == "/Applications/Foo.app")
        #expect(UninstallerOrphanScanner.enclosingAppBundle("/usr/local/bin/tool") == nil)
    }

    @Test func unusedAppsNeedSpotlightData() {
        let now = Date()
        func app(_ name: String, lastUsed: Date?) -> UninstallerApp {
            let info = AppBundleInfo(
                path: "/Applications/\(name).app", name: name, bundleIdentifier: "com.test.\(name)", shortVersion: "1.0",
                buildVersion: "1", executableName: name, minimumSystemVersion: nil, sparkleFeedURL: nil,
                isAppStoreApp: false, isSystemApp: false, isAppleApp: false, installedDate: nil, modificationDate: nil
            )
            return UninstallerApp(
                info: info,
                identity: UninstallerAppIdentity(path: info.path, bundleIdentifier: info.bundleIdentifier, names: [name]),
                lastUsed: lastUsed
            )
        }
        let apps = [
            app("Old", lastUsed: now.addingTimeInterval(-200 * 86_400)),
            app("Recent", lastUsed: now.addingTimeInterval(-2 * 86_400)),
            app("Never", lastUsed: nil),
        ]
        #expect(LeftoversSmartScanProvider.unusedApps(apps, now: now).map(\.name) == ["Old"])
        #expect(LeftoversSmartScanProvider.unusedApps([app("Never", lastUsed: nil)], now: now).isEmpty)
    }
}
