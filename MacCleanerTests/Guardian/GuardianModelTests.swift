import Foundation
import Testing
@testable import MacCleaner

/// Services whose settings, history and log stay in temporary locations.
@MainActor
enum GuardianTestServices {
    static func make(_ directory: GuardianTestDirectory) throws -> AppServices {
        let defaults = try #require(UserDefaults(suiteName: "GuardianTests-\(UUID().uuidString)"))
        return AppServices(
            settings: SettingsManager(defaults: defaults),
            permissions: PermissionManager(),
            history: HistoryStore(directory: directory.url.appendingPathComponent("History", isDirectory: true)),
            logger: ActivityLogger(directory: directory.url.appendingPathComponent("Logs", isDirectory: true))
        )
    }

    static func settings() throws -> GuardianSettings {
        GuardianSettings(defaults: try #require(UserDefaults(suiteName: "GuardianSettings-\(UUID().uuidString)")))
    }
}

@MainActor
struct GuardianSettingsTests {
    @Test func defaultsAndPersistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "GuardianSettings-\(UUID().uuidString)"))
        let settings = GuardianSettings(defaults: defaults)
        #expect(settings.watchStartupItems)
        #expect(settings.notifyNewStartupItems)
        #expect(!settings.notifyOtherStartupChanges)
        #expect(settings.scanNewStartupItems)
        #expect(settings.analyzeLogin)
        #expect(settings.webShieldEnabled)
        #expect(settings.webShieldNotifications)
        #expect(settings.isBrowserWatched("chrome"))

        var changed: [GuardianSettings.Key] = []
        settings.onChange = { changed.append($0) }
        settings.webShieldEnabled = false
        settings.setBrowser("safari", watched: false)
        settings.notifyOtherStartupChanges = true
        #expect(changed == [.webShieldEnabled, .webShieldDisabledBrowsers, .notifyOtherStartupChanges])

        let reloaded = GuardianSettings(defaults: defaults)
        #expect(!reloaded.webShieldEnabled)
        #expect(!reloaded.isBrowserWatched("safari"))
        #expect(reloaded.isBrowserWatched("firefox"))
        #expect(reloaded.notifyOtherStartupChanges)
        reloaded.setBrowser("safari", watched: true)
        #expect(GuardianSettings(defaults: defaults).isBrowserWatched("safari"))
    }

    @Test func everyKeyIsPrefixed() {
        #expect(GuardianSettings.Key.allCases.allSatisfy { $0.rawValue.hasPrefix("guardian.") })
        #expect(Set(GuardianSettings.Key.allCases.map(\.rawValue)).count == GuardianSettings.Key.allCases.count)
    }
}

@MainActor
struct StartupGuardModelTests {
    @Test func notificationTextNamesTheSigner() {
        var record = GuardianRecordFactory.agent("com.example.updater")
        record.name = "Example Updater"
        #expect(StartupGuardModel.notificationBody(for: record) == "“Example Updater” will start automatically — signed by Example Inc.")
        record.signature = GuardianSignatureSummary(category: .unsigned)
        #expect(StartupGuardModel.notificationBody(for: record) == "“Example Updater” will start automatically — unsigned.")
    }

    @Test func onlyNewOrRiskyChangesWithAProgramAreScanned() throws {
        let directory = try GuardianTestDirectory()
        let program = try directory.write("#!/bin/sh\n", to: "bin/tool")
        let record = GuardianRecordFactory.agent("com.example.tool", program: program, category: .script, team: nil)
        #expect(StartupGuardModel.wantsScan(GuardianStartupChange(date: Date(), kind: .added, record: record)))
        #expect(!StartupGuardModel.wantsScan(GuardianStartupChange(date: Date(), kind: .removed, record: record)))
        #expect(!StartupGuardModel.wantsScan(GuardianStartupChange(date: Date(), kind: .changed, fields: [.enabled], record: record)))
        #expect(StartupGuardModel.wantsScan(GuardianStartupChange(date: Date(), kind: .changed, fields: [.program], record: record)))
        let missing = GuardianRecordFactory.agent("com.example.gone", program: directory.path("bin/gone"))
        #expect(!StartupGuardModel.wantsScan(GuardianStartupChange(date: Date(), kind: .added, record: missing)))
    }

    @Test func loadsStoredStateAndFiltersChanges() async throws {
        let directory = try GuardianTestDirectory()
        let store = GuardianStartupStore(directory: directory.url)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let base = GuardianStartupDiff.merge(previous: nil, collection: GuardianRecordFactory.collection([GuardianRecordFactory.agent("com.example.a")],
                                                                                                          covered: [.userLaunchAgents], date: date))
        await store.save(snapshot: base.snapshot)
        let record = base.snapshot.records[0]
        await store.save(changes: [
            GuardianStartupChange(date: date.addingTimeInterval(60), kind: .added, record: record),
            GuardianStartupChange(date: date.addingTimeInterval(30), kind: .removed, record: record),
            GuardianStartupChange(date: date.addingTimeInterval(10), kind: .changed, fields: [.enabled], record: record),
        ])

        let model = StartupGuardModel(services: try GuardianTestServices.make(directory), settings: try GuardianTestServices.settings(),
                                      eventLog: ProtectionEventLog(directory: nil), storageDirectory: directory.url)
        model.loadStoredState()
        #expect(model.snapshot?.records.count == 1)
        #expect(model.watchingSince == date)
        #expect(model.changes.count == 3)
        model.changeFilter = .removed
        #expect(model.filteredChanges.map(\.kind) == [.removed])
        #expect(model.count(of: .added) == 1)
        #expect(model.currentRecord(for: model.changes[0])?.id == record.id)
    }

    @Test func actionsFitTheCause() throws {
        let directory = try GuardianTestDirectory()
        let model = StartupGuardModel(services: try GuardianTestServices.make(directory), settings: try GuardianTestServices.settings(),
                                      eventLog: ProtectionEventLog(directory: nil), storageDirectory: nil)
        func item(_ cause: GuardianLoginCause) -> GuardianOpenedAtLoginItem {
            GuardianOpenedAtLoginItem(name: "App", bundleIdentifier: "com.example.app", path: "/Applications/App.app", isApp: true, pid: 1, started: Date(), cause: cause)
        }
        #expect(model.actions(for: item(.loginItem)) == [.removeLoginItem, .reveal])
        #expect(model.actions(for: item(.appLoginItem)) == [.openLoginItemsSettings, .openApp(path: "/Applications/App.app"), .reveal])
        #expect(model.actions(for: item(.reopened)) == [.stopReopening, .reveal])
        #expect(model.actions(for: item(.launchAgent(label: "com.example.agent", plistPath: "/x.plist", isUserAgent: true))) == [.turnOffAgent, .reveal])
        #expect(model.actions(for: item(.launchAgent(label: "com.example.agent", plistPath: "/x.plist", isUserAgent: false))) == [.openLoginItemsSettings, .reveal])
        #expect(model.actions(for: item(.launchAgent(label: "com.apple.something", plistPath: "/x.plist", isUserAgent: true))) == [.openLoginItemsSettings, .reveal])
        #expect(model.actions(for: item(.unknown)) == [.openLoginItemsSettings, .reveal])
    }

    @Test func turnOffOnlyForYourOwnAgents() throws {
        let directory = try GuardianTestDirectory()
        let model = StartupGuardModel(services: try GuardianTestServices.make(directory), settings: try GuardianTestServices.settings(),
                                      eventLog: ProtectionEventLog(directory: nil), storageDirectory: nil)
        #expect(model.canTurnOff(GuardianRecordFactory.agent("com.example.a")))
        #expect(!model.canTurnOff(GuardianRecordFactory.agent("com.apple.a")))
        #expect(!model.canTurnOff(GuardianRecordFactory.agent("com.example.a", enabled: false)))
        var daemon = GuardianRecordFactory.agent("com.example.d", source: .systemLaunchDaemons)
        daemon.kind = .systemDaemon
        #expect(!model.canTurnOff(daemon))
        // Move to Trash needs the property list to exist.
        #expect(!model.canMoveToTrash(GuardianRecordFactory.agent("com.example.a")))
    }

    @Test func onlyTheCardThatAskedShowsTheConfirmation() throws {
        let directory = try GuardianTestDirectory()
        let model = StartupGuardModel(services: try GuardianTestServices.make(directory), settings: try GuardianTestServices.settings(),
                                      eventLog: ProtectionEventLog(directory: nil), storageDirectory: nil)
        model.requestReopenChange(turnOn: false, from: .reopen)
        #expect(model.presenter == .reopen)
        #expect(model.pendingAction?.id == "reopen|off")
        // Each card has its own Move to Trash flow.
        #expect(model.cleanupFlow(for: .changes) !== model.cleanupFlow(for: .moreItems))
        model.requestTurnOff(GuardianRecordFactory.agent("com.apple.protected"), from: .changes)
        #expect(model.presenter == .changes)
        #expect(model.alertMessage != nil)
    }

    @Test func reopenConfirmationExplainsTheSetting() {
        #expect(GuardianStartupAction.turnOffReopen.message.contains("Reopen windows when logging back in"))
        #expect(GuardianStartupAction.turnOffReopen.confirmTitle == "Don't Reopen")
        #expect(!GuardianStartupAction.turnOffReopen.isDestructive)
    }
}

@MainActor
struct GuardianControllerTests {
    @Test func startIsANoOpInTheTestHostAndWiringWorks() throws {
        let directory = try GuardianTestDirectory()
        let controller = GuardianController(services: try GuardianTestServices.make(directory), eventLog: ProtectionEventLog(directory: nil),
                                            settings: try GuardianTestServices.settings(), storageDirectory: nil,
                                            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        // Only call start() when the guard recognizes the test host, so a failure can't start real monitoring.
        try #require(GuardianRuntime.isTestHost)
        controller.start()
        controller.start()
        #expect(!controller.isRunning)
        controller.stop()

        var opened: [AppSection] = []
        controller.navigate = { opened.append($0) }
        controller.startupGuard.openStartupItems()
        controller.webShield.checkMyDownloads()
        #expect(opened == [.startup, .antivirus])

        controller.startupScanHook = { _ in GuardianScanVerdict(detections: []) }
        #expect(controller.startupGuard.scanHook != nil)
        controller.startupScanHook = nil
        #expect(controller.startupGuard.scanHook == nil)
    }

    @Test func settingChangesReachTheWebShield() throws {
        let directory = try GuardianTestDirectory()
        let settings = try GuardianTestServices.settings()
        let controller = GuardianController(services: try GuardianTestServices.make(directory), eventLog: ProtectionEventLog(directory: nil),
                                            settings: settings, storageDirectory: nil, scratchDirectory: directory.url.appendingPathComponent("scratch"))
        settings.setBrowser("chrome", watched: false)
        #expect(controller.webShield.browsers.first { $0.id == "chrome" }?.isWatched == false)
        settings.webShieldEnabled = false
        #expect(controller.webShield.status == .off)
    }
}

struct GuardianSignatureCacheTests {
    @Test func unchangedFilesAreNotCheckedAgain() throws {
        let directory = try GuardianTestDirectory()
        let file = try directory.write("one", to: "tool")
        let counter = GuardianCallCounter()
        let cache = GuardianSignatureCache { _ in
            counter.increment()
            return GuardianSignatureSummary(category: .unsigned)
        }
        _ = cache.summary(for: file)
        _ = cache.summary(for: file)
        #expect(counter.value == 1)
        try "two, longer".write(toFile: file, atomically: false, encoding: .utf8)
        _ = cache.summary(for: file)
        #expect(counter.value == 2)
    }

    @Test func bundleIdentityIncludesItsSignatureFiles() throws {
        let directory = try GuardianTestDirectory()
        try directory.write("<plist/>", to: "Example.app/Contents/Info.plist")
        let before = GuardianSignatureCache.identity(of: directory.path("Example.app"))
        try directory.write("resources", to: "Example.app/Contents/_CodeSignature/CodeResources")
        #expect(GuardianSignatureCache.identity(of: directory.path("Example.app")) != before)
    }
}

final class GuardianCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

struct GuardianDayGroupingTests {
    @Test func groupsByDayNewestFirst() {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let older = calendar.date(byAdding: .day, value: -5, to: now)!
        let groups = GuardianDayGrouping.groups([now, yesterday, now.addingTimeInterval(-1), older], date: { $0 }, now: now)
        #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(groups.count == 3)
        #expect(groups.first?.items.count == (calendar.isDate(now.addingTimeInterval(-1), inSameDayAs: now) ? 2 : 1))
    }
}

struct GuardianFileWatcherTests {
    @Test func reportsChangesInAWatchedFolderAndStopsCleanly() async throws {
        let directory = try GuardianTestDirectory()
        let folder = try directory.makeDirectory("LaunchAgents")
        let seen = GuardianSeenPaths()
        let watcher = GuardianFileWatcher(paths: [folder, directory.path("missing")], latency: 0.1) { paths in seen.add(paths) }
        let watched = watcher.start()
        #expect(watched == [folder])
        #expect(watcher.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        try directory.write("<plist/>", to: "LaunchAgents/com.example.new.plist")
        let deadline = Date().addingTimeInterval(10)
        while !seen.paths.contains(where: { $0.hasSuffix("com.example.new.plist") }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen.paths.contains { $0.hasSuffix("com.example.new.plist") })
        watcher.stop()
        #expect(!watcher.isRunning)
        watcher.stop() // idempotent
    }
}

final class GuardianSeenPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ paths: [String]) { lock.withLock { stored += paths } }
    var paths: [String] { lock.withLock { stored } }
}
