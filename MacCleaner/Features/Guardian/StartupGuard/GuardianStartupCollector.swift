import Foundation
import ServiceManagement

/// Reads everything that starts automatically, cheaply enough to repeat every few minutes.
///
/// It reuses the Startup Items building blocks (property-list parsing and program analysis,
/// `launchctl`, System Events login items, the Security cron reader) but skips the expensive parts
/// of a full Startup Items scan: launchd is asked once per domain, and code signatures are cached
/// by file identity, so an unchanged Mac costs a few milliseconds of work per check.
struct GuardianStartupCollector: Sendable {
    struct Paths: Sendable {
        var home: String
        var userAgents: String
        var systemAgents: String
        var systemDaemons: String
        var byHost: String
        var userLoginwindowPreferences: String
        var allUsersLoginwindowPreferences: String
        var legacyStartupItems: String
        var periodicRoots: [String]
        var periodicLocalFiles: [String]
        var launchdConf: String
        var pluginFolders: [GuardianExtraSources.PluginFolder]
        var backgroundTaskAgentFolder: String

        static var live: Paths {
            let home = LaunchdLocations.home
            return Paths(
                home: home,
                userAgents: LaunchdLocations.userAgentsFolder,
                systemAgents: LaunchdLocations.systemAgentsFolder,
                systemDaemons: LaunchdLocations.systemDaemonsFolder,
                byHost: GuardianReopenReader.liveByHostFolder,
                userLoginwindowPreferences: GuardianReopenReader.liveUserPreferencesFile,
                allUsersLoginwindowPreferences: "/Library/Preferences/com.apple.loginwindow.plist",
                legacyStartupItems: "/Library/StartupItems",
                periodicRoots: ["/etc/periodic", "/usr/local/etc/periodic"],
                periodicLocalFiles: ["/etc/daily.local", "/etc/weekly.local", "/etc/monthly.local"],
                launchdConf: "/etc/launchd.conf",
                pluginFolders: GuardianExtraSources.pluginFolders(home: home),
                backgroundTaskAgentFolder: home + "/Library/Application Support/com.apple.backgroundtaskmanagementagent"
            )
        }

        /// Folders watched with FSEvents for immediate re-checks.
        var watchedFolders: [String] {
            [userAgents, systemAgents, systemDaemons, byHost, backgroundTaskAgentFolder]
        }
    }

    struct Request: Sendable {
        /// "Open at Login" items read through System Events; nil when they weren't read this time.
        var loginItems: [StartupLoginItemRecord]?
        /// Why login items are missing, when they are.
        var loginItemsState: GuardianSourceStatus.State = .notChecked
        var includeExtensions = true
    }

    var paths: Paths = .live
    var signatures: GuardianSignatureCache
    var hardwareUUID: String?

    init(paths: Paths = .live, signatures: GuardianSignatureCache, hardwareUUID: String? = GuardianReopenReader.hardwareUUID()) {
        self.paths = paths
        self.signatures = signatures
        self.hardwareUUID = hardwareUUID
    }

    // MARK: - Collection

    func collect(_ request: Request, now: Date = Date()) async -> GuardianStartupCollection {
        let paths = self.paths
        let hardwareUUID = self.hardwareUUID
        async let filesTask = BackgroundWork.run(qos: .utility) { Self.readFiles(paths: paths, hardwareUUID: hardwareUUID, now: now) }
        let client = LaunchctlClient()
        async let guiServices = client.loadedServices(domain: .currentUser)
        async let systemServices = client.loadedServices(domain: .system)
        async let guiOverrides = client.disabledOverrides(domain: .currentUser)
        async let systemOverrides = client.disabledOverrides(domain: .system)
        async let cronJobs = SecuritySystemInventory.cronJobs()
        async let extensions = request.includeExtensions ? Self.readExtensions(now: now) : nil

        let files = await filesTask
        let launchd = LaunchdState(gui: await guiServices, system: await systemServices,
                                   guiOverrides: await guiOverrides, systemOverrides: await systemOverrides)

        var records: [GuardianStartupRecord] = []
        var statuses = files.statuses

        // launchd folders
        let approvals = await BackgroundWork.run(qos: .utility) { () -> [String: StartupBackgroundApproval] in
            var result: [String: StartupBackgroundApproval] = [:]
            for item in files.launchdItems + files.embeddedPlistItems {
                guard let plist = item.plistPath else { continue }
                result[plist] = StartupBackgroundApproval(SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: plist)))
            }
            return result
        }
        for item in files.launchdItems {
            records.append(Self.record(launchdItem: item, launchd: launchd, approval: item.plistPath.flatMap { approvals[$0] }, index: files.appIndex, now: now))
        }

        // App background items that are active (loaded in launchd or allowed by macOS).
        if launchd.gui != nil {
            var count = 0
            for helper in files.embeddedHelpers {
                guard let label = helper.label, launchd.gui?[label] != nil else { continue }
                var record = GuardianStartupRecord(source: .appBackgroundItems, key: helper.path, kind: .appBackgroundItem, name: helper.name,
                                                   identifier: label, programPath: helper.path, date: now)
                record.ownerName = helper.appName
                record.ownerPath = helper.appPath
                record.isEnabled = true
                record.isRunning = launchd.gui?[label]?.pid != nil
                record.trigger = "Opens at login (turned on in \(helper.appName))"
                records.append(record)
                count += 1
            }
            for item in files.embeddedPlistItems {
                guard let label = item.label else { continue }
                let isDaemon = item.plistPath?.contains("/Contents/Library/LaunchDaemons/") == true
                let listed = isDaemon ? launchd.system?[label] : launchd.gui?[label]
                let approval = item.plistPath.flatMap { approvals[$0] }
                guard listed != nil || approval == .enabled || approval == .requiresApproval else { continue }
                var record = Self.record(launchdItem: item, launchd: launchd, approval: approval, index: files.appIndex, now: now)
                record.isEnabled = approval == .requiresApproval ? false : true
                record.isRunning = listed?.pid != nil
                records.append(record)
                count += 1
            }
            statuses.append(GuardianSourceStatus(source: .appBackgroundItems, state: .read, count: count))
        } else {
            statuses.append(GuardianSourceStatus(source: .appBackgroundItems, state: .failed, note: "launchd didn't report which background items are active."))
        }

        // Login items
        if let loginItems = request.loginItems {
            for item in loginItems {
                var record = GuardianStartupRecord(source: .loginItems, key: item.path ?? item.name, kind: .loginItem, name: item.name,
                                                   programPath: item.path, date: now)
                record.isEnabled = true
                record.trigger = item.hidden ? "Opens hidden at login" : "Opens at login"
                if let path = item.path, path.hasSuffix(".app") {
                    record.ownerPath = path
                    record.identifier = files.appIndex.app(path: path)?.bundleIdentifier ?? ApplicationCatalog.read(path: path)?.bundleIdentifier
                }
                records.append(record)
            }
            statuses.append(GuardianSourceStatus(source: .loginItems, state: .read, count: loginItems.count))
        } else {
            var status = GuardianSourceStatus(source: .loginItems, state: request.loginItemsState)
            if request.loginItemsState == .needsAutomation {
                status.note = "Login items are read through System Events, which needs Automation access."
            }
            statuses.append(status)
        }

        // Reopen windows at login
        if let reopen = files.reopen {
            var record = GuardianStartupRecord(source: .reopenSetting, key: GuardianReopenReader.savesStateKey, kind: .reopenSetting,
                                               name: "Reopen windows when logging back in", identifier: GuardianReopenReader.savesStateKey, date: now)
            record.isEnabled = reopen.savesState
            record.trigger = reopen.savesState ? "Reopens the apps that are open when you log out" : "Off: apps don't reopen at login"
            record.configPath = reopen.listPath
            records.append(record)
            statuses.append(GuardianSourceStatus(source: .reopenSetting, state: .read, count: reopen.apps.count))
        } else {
            statuses.append(GuardianSourceStatus(source: .reopenSetting, state: .failed, note: "The per-Mac preferences folder couldn't be read."))
        }

        // Cron
        if let jobs = await cronJobs {
            let cron = GuardianExtraSources.cronRecords(jobs, now: now)
            records += cron
            var status = GuardianSourceStatus(source: .cronJobs, state: .read, count: cron.count)
            status.note = "System-wide cron tables need an administrator to read."
            statuses.append(status)
        } else {
            statuses.append(GuardianSourceStatus(source: .cronJobs, state: .failed, note: "crontab couldn't be read."))
        }

        // App extensions
        var onDemand = 0
        if let extensions = await extensions {
            records += extensions.records
            onDemand = extensions.onDemand
            statuses.append(GuardianSourceStatus(source: .appExtensions, state: .read, count: extensions.records.count))
        } else {
            statuses.append(GuardianSourceStatus(source: .appExtensions, state: request.includeExtensions ? .failed : .notChecked))
        }
        records += files.extraRecords

        // Signatures (cached) and running state.
        records = await Self.attachSignatures(records, cache: signatures)
        records = await Self.attachRunningState(records)
        return GuardianStartupCollection(date: now, records: records, statuses: statuses, reopen: files.reopen, onDemandExtensionCount: onDemand)
    }

    // MARK: - Files (blocking)

    struct EmbeddedHelper: Sendable {
        var path: String
        var name: String
        var label: String?
        var appName: String
        var appPath: String
    }

    struct Files: Sendable {
        var launchdItems: [StartupItem] = []
        var embeddedHelpers: [EmbeddedHelper] = []
        var embeddedPlistItems: [StartupItem] = []
        var appIndex: StartupAppIndex
        var reopen: GuardianReopenState?
        var extraRecords: [GuardianStartupRecord] = []
        var statuses: [GuardianSourceStatus] = []
    }

    static func readFiles(paths: Paths, hardwareUUID: String?, now: Date) -> Files {
        let apps = ApplicationCatalog.installedApplications(includeSystemApps: false)
        var files = Files(appIndex: StartupAppIndex(apps: apps))

        func addFolder(_ folder: String, kind: StartupItemKind, source: GuardianStartupSource) {
            guard let plists = LaunchdLocations.plistFiles(in: folder) else {
                let exists = FileManager.default.fileExists(atPath: folder)
                files.statuses.append(GuardianSourceStatus(source: source, state: exists ? .needsFullDiskAccess : .notPresent))
                return
            }
            for plist in plists {
                var item = StartupInventoryScanner.makeLaunchdItem(path: plist.path, linkDestination: plist.linkDestination, kind: kind, bundlePath: nil)
                item.owner = owner(of: item, index: files.appIndex)
                files.launchdItems.append(item)
            }
            files.statuses.append(GuardianSourceStatus(source: source, state: .read, count: plists.count))
        }
        addFolder(paths.userAgents, kind: .userAgent, source: .userLaunchAgents)
        addFolder(paths.systemAgents, kind: .systemAgent, source: .systemLaunchAgents)
        addFolder(paths.systemDaemons, kind: .systemDaemon, source: .systemLaunchDaemons)

        for app in apps where !app.isAppleApp {
            let embedded = LaunchdLocations.embeddedItems(inApp: app.path)
            guard !embedded.isEmpty else { continue }
            for helper in embedded.loginItemApps {
                let info = ApplicationCatalog.read(path: helper)
                files.embeddedHelpers.append(EmbeddedHelper(
                    path: helper,
                    name: info?.name ?? ((helper as NSString).lastPathComponent as NSString).deletingPathExtension,
                    label: info?.bundleIdentifier,
                    appName: app.name,
                    appPath: app.path
                ))
            }
            for plist in embedded.agentPlists + embedded.daemonPlists {
                var item = StartupInventoryScanner.makeLaunchdItem(path: plist, linkDestination: nil, kind: .appBackgroundItem, bundlePath: app.path)
                item.containingAppPath = app.path
                item.owner = StartupOwnerApp(name: app.name, path: app.path, bundleIdentifier: app.bundleIdentifier, lastUsedDate: nil)
                files.embeddedPlistItems.append(item)
            }
        }

        files.reopen = GuardianReopenReader.read(byHostFolder: paths.byHost, userPreferencesFile: paths.userLoginwindowPreferences, hardwareUUID: hardwareUUID)

        let legacy = GuardianExtraSources.legacyStartupItems(folder: paths.legacyStartupItems, now: now)
        let periodic = GuardianExtraSources.periodicScripts(roots: paths.periodicRoots, localFiles: paths.periodicLocalFiles, now: now)
        let conf = GuardianExtraSources.launchdConf(path: paths.launchdConf, now: now)
        let hooks = GuardianExtraSources.loginHooks(preferenceFiles: [paths.userLoginwindowPreferences, paths.allUsersLoginwindowPreferences], now: now)
        let plugins = GuardianExtraSources.plugins(folders: paths.pluginFolders, quickLookGeneratorsSupported: !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)), now: now)
        for part in [legacy, periodic, conf, hooks, plugins] {
            files.extraRecords += part.records
            files.statuses.append(part.status)
        }
        return files
    }

    /// The installed app an item belongs to, when that's reliable (declared association, enclosing app or label).
    static func owner(of item: StartupItem, index: StartupAppIndex) -> StartupOwnerApp? {
        func make(_ app: AppBundleInfo) -> StartupOwnerApp {
            StartupOwnerApp(name: app.name, path: app.path, bundleIdentifier: app.bundleIdentifier, lastUsedDate: nil)
        }
        if let definition = item.definition {
            for identifier in definition.associatedBundleIdentifiers {
                if let app = index.app(bundleIdentifier: identifier) { return make(app) }
            }
        }
        if let enclosing = item.analysis?.enclosingAppPath {
            if let app = index.app(path: enclosing) { return make(app) }
            if StartupAppIndex.isInApplicationsFolder(enclosing), let app = ApplicationCatalog.read(path: enclosing) { return make(app) }
        }
        if let label = item.label, !LaunchctlClient.isProtectedLabel(label), let app = index.app(matchingLabel: label) {
            return make(app)
        }
        return nil
    }

    // MARK: - launchd

    struct LaunchdState: Sendable {
        var gui: [String: LaunchctlListedService]?
        var system: [String: LaunchctlListedService]?
        var guiOverrides: [String: Bool]
        var systemOverrides: [String: Bool]

        /// The label of the launchd job that runs `pid`, from the loaded-service lists.
        func label(forPID pid: Int32) -> String? {
            gui?.first(where: { $0.value.pid == pid })?.key ?? system?.first(where: { $0.value.pid == pid })?.key
        }
    }

    static func record(launchdItem original: StartupItem, launchd: LaunchdState, approval: StartupBackgroundApproval?,
                       index: StartupAppIndex, now: Date) -> GuardianStartupRecord {
        var item = original
        item.backgroundApproval = approval
        let source: GuardianStartupSource
        var listed: LaunchctlListedService?
        switch item.kind {
        case .userAgent:
            source = .userLaunchAgents
            if let label = item.label { listed = launchd.gui?[label]; item.disabledOverride = launchd.guiOverrides[label] }
        case .systemAgent:
            source = .systemLaunchAgents
            if let label = item.label { listed = launchd.gui?[label]; item.disabledOverride = launchd.guiOverrides[label] }
        case .systemDaemon:
            source = .systemLaunchDaemons
            if let label = item.label { listed = launchd.system?[label]; item.disabledOverride = launchd.systemOverrides[label] }
        case .appBackgroundItem, .loginItem:
            source = .appBackgroundItems
            let isDaemon = item.plistPath?.contains("/Contents/Library/LaunchDaemons/") == true
            if let label = item.label {
                listed = isDaemon ? launchd.system?[label] : launchd.gui?[label]
                item.disabledOverride = isDaemon ? launchd.systemOverrides[label] : launchd.guiOverrides[label]
            }
        }
        let program = item.targetPath ?? item.analysis?.executable
        var record = GuardianStartupRecord(
            source: source,
            key: item.plistPath ?? item.id,
            kind: GuardianStartupKind(item.kind),
            name: item.name,
            identifier: item.label,
            programPath: program,
            arguments: Array((item.analysis?.arguments ?? item.definition?.argumentVector ?? []).dropFirst()),
            configPath: item.plistPath,
            date: now
        )
        record.isEnabled = item.isEnabled
        record.startsAutomatically = item.definition?.startsAutomatically ?? false
        record.trigger = item.triggerSummary
        record.isRunning = listed?.pid != nil
        if let owner = item.owner {
            record.ownerName = owner.name
            record.ownerPath = owner.path
        }
        if item.parseError != nil {
            record.note = "The property list is damaged, so launchd ignores it."
            record.startsAutomatically = false
            record.isUnreadable = true
        } else if item.definition?.isEmpty == true {
            record.note = "The property list doesn't define a program, so launchd ignores it."
            record.startsAutomatically = false
        } else if StartupHeuristics.isBroken(item) {
            record.note = "The program it starts no longer exists."
        } else if approval == .requiresApproval {
            record.note = "Switched off under Allow in the Background in System Settings."
        }
        if item.kind == .systemAgent || item.kind == .systemDaemon {
            record.access = .administrator
        }
        return record
    }

    // MARK: - Extensions

    static func readExtensions(now: Date) async -> (records: [GuardianStartupRecord], onDemand: Int)? {
        guard let result = try? await ProcessRunner.run("/usr/bin/pluginkit", arguments: ["-m", "-v"], timeout: 20), result.succeeded else { return nil }
        let entries = GuardianPluginKitParser.parse(result.standardOutput)
        return await BackgroundWork.run(qos: .utility) { GuardianExtensionPoints.records(from: entries, now: now) }
    }

    // MARK: - Signatures and running state

    static func attachSignatures(_ records: [GuardianStartupRecord], cache: GuardianSignatureCache) async -> [GuardianStartupRecord] {
        let paths = Array(Set(records.compactMap(\.programPath).filter { LaunchdPathProbe.status($0) == .exists })).sorted()
        let summaries = await StartupParallel.map(paths, limit: 4) { path in
            (path, await BackgroundWork.run(qos: .utility) { cache.summary(for: path) })
        }
        let byPath = Dictionary(summaries, uniquingKeysWith: { first, _ in first })
        return records.map { record in
            var copy = record
            if let path = record.programPath {
                copy.signature = byPath[path] ?? (LaunchdPathProbe.status(path) == .missing ? GuardianSignatureSummary(category: .missing) : nil)
            }
            return copy
        }
    }

    /// Running state for apps and helpers (launchd jobs already have theirs).
    static func attachRunningState(_ records: [GuardianStartupRecord]) async -> [GuardianStartupRecord] {
        let needsProcesses = records.contains { $0.isRunning == nil && $0.programPath != nil }
        guard needsProcesses else { return records }
        let processes = await BackgroundWork.run(qos: .utility) { ProcessInspector.allProcesses() }
        let index = StartupProcessIndex(processes: processes)
        return records.map { record in
            guard record.isRunning == nil, let path = record.programPath else { return record }
            var copy = record
            switch record.kind {
            case .loginItem, .appBackgroundItem, .appLoginItem:
                copy.isRunning = !index.processes(insideBundle: path).isEmpty || !index.processes(executable: path).isEmpty
            case .finderSyncExtension, .backgroundExtension, .spotlightImporter:
                copy.isRunning = !index.processes(insideBundle: path).isEmpty
            default:
                break
            }
            return copy
        }
    }
}
