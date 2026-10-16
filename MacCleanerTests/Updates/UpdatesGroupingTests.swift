import Foundation
import Testing
@testable import MacCleaner

/// Rows and a view model with temporary settings, so nothing touches the real app list.
@MainActor
enum UpdatesTestRows {
    static func app(_ name: String, short: String = "1.0", build: String? = "100", size: Int64? = nil, lastUsed: Date? = nil, appStore: Bool = false) -> UninstallerApp {
        let path = "/Applications/\(name).app"
        let info = AppBundleInfo(
            path: path, name: name, bundleIdentifier: "com.example.\(name.replacingOccurrences(of: " ", with: ""))",
            shortVersion: short, buildVersion: build, executableName: name, minimumSystemVersion: nil, sparkleFeedURL: nil,
            isAppStoreApp: appStore, isSystemApp: false, isAppleApp: false, installedDate: nil, modificationDate: nil
        )
        var app = UninstallerApp(info: info, identity: UninstallerAppIdentity(path: path, bundleIdentifier: info.bundleIdentifier, names: [name]))
        app.lastUsed = lastUsed
        if let size { app.usage = DiskUsage(logicalBytes: size, allocatedBytes: size, reclaimableBytes: size, fileCount: 1, directoryCount: 0, unreadableDirectoryCount: 0) }
        return app
    }

    static func row(
        _ name: String,
        status: UpdatesStatus?,
        source: UpdatesSource = .sparkle,
        mechanism: UpdatesMechanism = .sparkleFeed(URL(string: "https://example.com/appcast.xml")!),
        latest: String? = nil,
        critical: Bool = false,
        size: Int64? = nil,
        lastUsed: Date? = nil,
        storeURL: URL? = nil
    ) -> UpdatesAppRow {
        var row = UpdatesAppRow(app: app(name, size: size, lastUsed: lastUsed), mechanism: mechanism)
        if let status {
            var result = UpdatesCheckResult(status: status, source: source, latestVersion: latest, detail: "", checkedAt: Date(), installedVersionAtCheck: "1.0 (100)")
            result.isCritical = critical
            result.storeURL = storeURL
            row.result = result
        }
        return row
    }

    static func model(rows: [UpdatesAppRow], controller: AppUpdateController? = nil) throws -> UpdatesViewModel {
        let defaults = try #require(UserDefaults(suiteName: "UpdatesGroupingTests-\(UUID().uuidString)"))
        let services = AppServices(settings: SettingsManager(defaults: defaults))
        let updates = controller ?? AppUpdateController(currentVersion: "1.0.0", currentBuild: "1", transport: AppUpdateTestTransport.failing(AppUpdateError.network("offline")), store: AppUpdateMemoryStore())
        let model = UpdatesViewModel(services: services, appUpdates: updates, includesMacCleaner: controller != nil)
        model.replaceRows(rows, checkedAt: Date())
        return model
    }
}

@MainActor
struct UpdatesGroupingTests {
    @Test func sameUpdatesArentPostedTwice() throws {
        let rows = [
            UpdatesTestRows.row("Writer", status: .updateAvailable, latest: "2.0"),
            UpdatesTestRows.row("Viewer", status: .updateAvailable, latest: "3.0"),
        ]
        let model = try UpdatesTestRows.model(rows: rows)
        let log = ProtectionEventLog(directory: nil)
        model.eventLog = log
        model.postUpdatesEvent(rows)
        model.postUpdatesEvent(rows)
        #expect(log.events.count == 1)
        #expect(log.events.first?.title == "2 app updates available")
        #expect(log.events.first?.detail == "Viewer, Writer")

        // A different set is news again.
        model.postUpdatesEvent(Array(rows.prefix(1)))
        #expect(log.events.count == 2)
        #expect(log.events.first?.title == "1 app update available")
    }

    @Test func rowsLandInTheRightSection() {
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: .updateAvailable)) == .updates)
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: .incompatible)) == .updates)
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: .upToDate)) == .upToDate)
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: .unknown)) == .other)
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: .failed)) == .other)
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: nil)) == .notChecked)
        #expect(UpdatesViewModel.group(of: UpdatesTestRows.row("A", status: .notChecked)) == .notChecked)

        // A row being checked again stays where its last result put it.
        var checking = UpdatesTestRows.row("A", status: .upToDate)
        checking.isChecking = true
        #expect(checking.status == .checking)
        #expect(UpdatesViewModel.group(of: checking) == .upToDate)
    }

    @Test func sectionsComeInOrderAndOmitEmptyGroups() {
        let rows = [
            UpdatesTestRows.row("Zed", status: .unknown),
            UpdatesTestRows.row("Mail Helper", status: .upToDate),
            UpdatesTestRows.row("Beta", status: .updateAvailable, latest: "2.0"),
            UpdatesTestRows.row("Alpha", status: .updateAvailable, latest: "2.0"),
        ]
        let sections = UpdatesViewModel.sections(for: rows, sortedBy: .name)
        #expect(sections.map(\.group) == [.updates, .upToDate, .other])
        #expect(sections[0].rows.map(\.name) == ["Alpha", "Beta"])
    }

    @Test func updatesSortMacCleanerAndImportantUpdatesFirst() {
        let macCleaner = UpdatesAppRow(app: UpdatesTestRows.app("Mac Cleaner"), mechanism: .github,
                                       result: UpdatesCheckResult(status: .updateAvailable, source: .github, latestVersion: "1.1.0", detail: "", checkedAt: Date(), installedVersionAtCheck: "1.0"))
        let rows = [
            UpdatesTestRows.row("Alpha", status: .updateAvailable, latest: "2.0"),
            UpdatesTestRows.row("Old Mac Only", status: .incompatible, latest: "9.0"),
            UpdatesTestRows.row("Zulu", status: .updateAvailable, latest: "2.0", critical: true),
            macCleaner,
            UpdatesTestRows.row("beta", status: .updateAvailable, latest: "2.0"),
        ]
        let sorted = UpdatesViewModel.sorted(rows, by: .name).map(\.name)
        #expect(sorted == ["Mac Cleaner", "Zulu", "Alpha", "beta", "Old Mac Only"])
    }

    @Test func sortsBySizeAndLastUse() {
        let now = Date()
        let rows = [
            UpdatesTestRows.row("Small", status: .upToDate, size: 10, lastUsed: now.addingTimeInterval(-86_400)),
            UpdatesTestRows.row("Large", status: .upToDate, size: 1_000, lastUsed: now.addingTimeInterval(-30 * 86_400)),
            UpdatesTestRows.row("Unmeasured", status: .upToDate, size: nil, lastUsed: nil),
            UpdatesTestRows.row("Medium", status: .upToDate, size: 500, lastUsed: now),
        ]
        #expect(UpdatesViewModel.sorted(rows, by: .size).map(\.name) == ["Large", "Medium", "Small", "Unmeasured"])
        #expect(UpdatesViewModel.sorted(rows, by: .lastUsed).map(\.name) == ["Medium", "Small", "Large", "Unmeasured"])
        #expect(UpdatesViewModel.sorted(rows, by: .name).map(\.name) == ["Large", "Medium", "Small", "Unmeasured"])
    }

    @Test func filtersSearchAndCountsWorkOnTheGroups() throws {
        let store = URL(string: "macappstore://apps.apple.com/app/id1")!
        let rows = [
            UpdatesTestRows.row("Dropover", status: .updateAvailable, source: .appStore, mechanism: .appStore, latest: "5.3.1", storeURL: store),
            UpdatesTestRows.row("BetterDisplay", status: .updateAvailable, latest: "5.1.1"),
            UpdatesTestRows.row("Slack", status: .unknown, source: .none, mechanism: .squirrel),
            UpdatesTestRows.row("Notes Pro", status: .upToDate, latest: "1.0"),
        ]
        let model = try UpdatesTestRows.model(rows: rows)
        #expect(model.allRows.count == 4)
        #expect(model.availableUpdateCount == 2)
        #expect(model.upToDateCount == 1)
        #expect(model.otherCount == 1)
        #expect(model.sections.map(\.group) == [.updates, .upToDate, .other])

        model.filter = .updates
        #expect(model.sections.map(\.group) == [.updates])
        #expect(model.isExpanded(.updates))
        model.filter = .appStore
        #expect(model.visibleRows.map(\.name) == ["Dropover"])
        model.filter = .unknown
        #expect(model.visibleRows.map(\.name) == ["Slack"])
        #expect(model.count(for: .unknown) == 1)
        model.filter = .all
        model.searchText = "better"
        #expect(model.visibleRows.map(\.name) == ["BetterDisplay"])
        // Searching shows matches even in collapsed groups.
        #expect(model.isExpanded(.other))
        model.searchText = ""
        #expect(model.isExpanded(.updates))
        #expect(!model.isExpanded(.upToDate))
        #expect(!model.isExpanded(.other))
        model.toggle(.other)
        #expect(model.isExpanded(.other))
    }

    @Test func eachUpdateNamesHowItsInstalled() throws {
        let store = URL(string: "macappstore://apps.apple.com/app/id1")!
        let rows = [
            UpdatesTestRows.row("Dropover", status: .updateAvailable, source: .appStore, mechanism: .appStore, latest: "5.3.1", storeURL: store),
            UpdatesTestRows.row("BetterDisplay", status: .updateAvailable, latest: "5.1.1"),
            UpdatesTestRows.row("Notes Pro", status: .upToDate, latest: "1.0"),
        ]
        let model = try UpdatesTestRows.model(rows: rows)
        #expect(model.updateAction(for: rows[0]) == .appStore(store))
        #expect(model.updateAction(for: rows[1]) == .openApp)
        #expect(model.updateAction(for: rows[2]) == .none)

        let plan = model.updateAllPlan
        #expect(plan.appStore.map(\.name) == ["Dropover"])
        #expect(plan.selfUpdating.map(\.name) == ["BetterDisplay"])
        #expect(plan.homebrew.isEmpty)
        #expect(plan.macCleaner == nil)
        #expect(plan.canRun)
    }

    @Test func macCleanerIsARowWithItsGitHubRelease() async throws {
        let transport = ScriptedTransport()
        let controller = AppUpdateController(currentVersion: "0.9.0", currentBuild: "1", transport: transport.transport, store: AppUpdateMemoryStore())
        let model = try UpdatesTestRows.model(rows: [UpdatesTestRows.row("Alpha", status: .upToDate)], controller: controller)
        let before = try #require(model.macCleanerRow)
        #expect(before.isMacCleaner)
        #expect(before.status == .notChecked)
        #expect(UpdatesViewModel.group(of: before) == .notChecked)

        await controller.performCheck(manual: true)
        let row = try #require(model.macCleanerRow)
        #expect(row.status == .updateAvailable)
        #expect(row.displaySource == .github)
        #expect(row.shortLatestVersion == "1.0.0")
        #expect(model.updateAction(for: row) == .macCleaner)
        #expect(model.availableUpdateCount == 1)
        #expect(model.sections.first?.rows.first?.isMacCleaner == true)
        #expect(model.hasReleaseNotes(row))
        model.toggleReleaseNotes(row)
        guard case .loaded(let document)? = model.notes[row.id] else {
            Issue.record("Mac Cleaner's notes come from the release")
            return
        }
        #expect(document.blocks.contains(.heading("Highlights", level: 2)))

        // A skipped version stays visible but no longer counts as an update to install.
        controller.skip(try #require(controller.latestRelease))
        #expect(model.availableUpdateCount == 0)
        #expect(model.macCleanerRow?.isSkipped == true)
        #expect(model.updateAllPlan.macCleaner == nil)
    }

    @Test func versionsAreShownWithoutBuildNumbers() {
        var row = UpdatesTestRows.row("Spark", status: .updateAvailable, latest: "3.31.6")
        row.app.info.shortVersion = "3.31.5"
        row.app.info.buildVersion = "3.31.5.141152"
        #expect(row.installedVersion == "3.31.5 (3.31.5.141152)")
        #expect(row.shortInstalledVersion == "3.31.5")
        #expect(row.versionHelp == "Installed: version 3.31.5 (build 3.31.5.141152) · Latest: 3.31.6")

        row.result?.latestVersion = "4.2.1,1234"
        #expect(row.shortLatestVersion == "4.2.1")
        row.result?.latestVersion = "2.3 (1234)"
        #expect(row.shortLatestVersion == "2.3")
        row.app.info.shortVersion = nil
        #expect(row.shortInstalledVersion == "3.31.5.141152")
    }
}
