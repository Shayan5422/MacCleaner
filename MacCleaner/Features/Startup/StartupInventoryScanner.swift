import Foundation
import ServiceManagement

/// Collects startup items from every supported source and enriches them with
/// launchd status, code signatures, running processes and heuristics.
/// Headless: usable from the UI, Smart Scan, the Security scanner and automation.
struct StartupInventoryScanner: Sendable {
    var includesAppBackgroundItems: Bool
    var includesSystemItems: Bool
    var environment: LaunchdProgramAnalyzer.Environment

    init(includesAppBackgroundItems: Bool = true, includesSystemItems: Bool = true, environment: LaunchdProgramAnalyzer.Environment = .live) {
        self.includesAppBackgroundItems = includesAppBackgroundItems
        self.includesSystemItems = includesSystemItems
        self.environment = environment
    }

    /// Scans all sources.
    ///
    /// - Parameter loginItems: "Open at Login" items read through System Events, or nil when
    ///   they couldn't be read (they're then omitted and a note explains why).
    func scan(
        loginItems: [StartupLoginItemRecord]?,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async -> StartupInventory {
        let now = Date()
        progress(0.02, "Reading launch agents and login items…")
        let includeApps = includesAppBackgroundItems
        let includeSystem = includesSystemItems
        let environment = environment
        let collected = await BackgroundWork.run(qos: .userInitiated) {
            Self.collect(loginItems: loginItems, includeApps: includeApps, includeSystem: includeSystem, environment: environment)
        }
        var notes = collected.notes
        guard !Task.isCancelled else {
            return StartupInventory(items: collected.items, includesLoginItems: loginItems != nil, scannedAt: now, notes: notes)
        }

        progress(0.2, "Asking launchd for status…")
        let launchd = await Self.launchdSnapshot(for: collected.items, includeSystem: includeSystem)
        if launchd.guiServices == nil { notes.append("launchd didn't report which services are loaded, so some statuses are unknown.") }

        progress(0.35, "Checking code signatures…")
        let targets = Array(Set(collected.items.compactMap(\.targetPath))).sorted()
        let counter = StartupProgressCounter(total: targets.count)
        let evaluations = await StartupParallel.map(targets, limit: 6) { path in
            let evaluation = await BackgroundWork.run(qos: .userInitiated) { SecurityCodeTrust.evaluate(path: path) }
            progress(0.35 + 0.45 * counter.advance(), "Checking code signatures…")
            return evaluation
        }
        let evaluationsByPath = Dictionary(evaluations.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        progress(0.82, "Measuring resource use…")
        let plistPaths = collected.items.filter { $0.kind != .loginItem }.compactMap(\.plistPath)
        let ownerPaths = Array(Set(collected.items.compactMap(\.owner?.path)))
        let extras = await BackgroundWork.run(qos: .userInitiated) { () -> StartupExtras in
            let processes = ProcessInspector.allProcesses()
            var approvals: [String: StartupBackgroundApproval] = [:]
            for path in plistPaths {
                approvals[path] = StartupBackgroundApproval(SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: path)))
            }
            var lastUsed: [String: Date] = [:]
            for path in ownerPaths {
                if let date = ApplicationCatalog.lastUsedDate(path: path) { lastUsed[path] = date }
            }
            return StartupExtras(processes: processes, approvals: approvals, lastUsed: lastUsed)
        }

        let processIndex = StartupProcessIndex(processes: extras.processes)
        let assembled = collected.items.map {
            Self.assemble($0, launchd: launchd, evaluations: evaluationsByPath, extras: extras, processIndex: processIndex, now: now)
        }
        progress(0.95, "Looking for unnecessary items…")
        let items = StartupHeuristics.applyConcerns(to: assembled, installedVendorPrefixes: collected.vendorPrefixes, now: now)
            .sorted(by: Self.displayOrder)
        progress(1, "Done")
        return StartupInventory(items: items, includesLoginItems: loginItems != nil, scannedAt: now, notes: notes)
    }

    /// Fresh launchd details for one item (used by the detail view).
    static func refreshedServiceInfo(for item: StartupItem) async -> LaunchctlServiceInfo? {
        guard let label = item.label else { return nil }
        let domain: LaunchdDomain = item.kind == .systemDaemon || item.plistPath?.contains("/Contents/Library/LaunchDaemons/") == true
            ? .system : .currentUser
        return await LaunchctlClient().serviceInfo(label: label, domain: domain)
    }

    // MARK: - Collection (blocking)

    private struct Collected: Sendable {
        var items: [StartupItem]
        var vendorPrefixes: Set<String>
        var notes: [String]
    }

    private struct StartupExtras: Sendable {
        var processes: [ProcessSnapshot]
        var approvals: [String: StartupBackgroundApproval]
        var lastUsed: [String: Date]
    }

    private struct LaunchdSnapshot: Sendable {
        var guiServices: [String: LaunchctlListedService]?
        var systemServices: [String: LaunchctlListedService]?
        var guiOverrides: [String: Bool]
        var systemOverrides: [String: Bool]
        var userInfos: [String: LaunchctlServiceInfo]
    }

    private static func collect(
        loginItems: [StartupLoginItemRecord]?,
        includeApps: Bool,
        includeSystem: Bool,
        environment: LaunchdProgramAnalyzer.Environment
    ) -> Collected {
        var items: [StartupItem] = []
        var notes: [String] = []
        let apps = ApplicationCatalog.installedApplications(includeSystemApps: false)
        let index = StartupAppIndex(apps: apps)

        if let loginItems {
            for record in loginItems {
                var item = StartupItem(id: "loginItem|\(record.name)|\(record.path ?? "")", kind: .loginItem, name: record.name)
                item.targetPath = record.path
                item.opensHidden = record.hidden
                items.append(item)
            }
        } else {
            notes.append("Login items weren't read because Mac Cleaner doesn't have Automation access to System Events.")
        }

        func addFolder(_ folder: String, kind: StartupItemKind) {
            guard let files = LaunchdLocations.plistFiles(in: folder) else {
                if FileManager.default.fileExists(atPath: folder) {
                    notes.append("\(PathUtilities.abbreviate(folder)) couldn't be read.")
                }
                return
            }
            for file in files {
                items.append(makeLaunchdItem(path: file.path, linkDestination: file.linkDestination, kind: kind, bundlePath: nil, environment: environment))
            }
        }
        addFolder(LaunchdLocations.userAgentsFolder, kind: .userAgent)
        if includeSystem {
            addFolder(LaunchdLocations.systemAgentsFolder, kind: .systemAgent)
            addFolder(LaunchdLocations.systemDaemonsFolder, kind: .systemDaemon)
        }

        if includeApps {
            for app in apps where !app.isAppleApp {
                let embedded = LaunchdLocations.embeddedItems(inApp: app.path)
                guard !embedded.isEmpty else { continue }
                for helper in embedded.loginItemApps {
                    let info = ApplicationCatalog.read(path: helper)
                    var item = StartupItem(id: "appBackgroundItem|" + helper, kind: .appBackgroundItem,
                                           name: info?.name ?? ((helper as NSString).lastPathComponent as NSString).deletingPathExtension)
                    item.label = info?.bundleIdentifier
                    item.targetPath = helper
                    item.containingAppPath = app.path
                    items.append(item)
                }
                for plist in embedded.agentPlists + embedded.daemonPlists {
                    var item = makeLaunchdItem(path: plist, linkDestination: nil, kind: .appBackgroundItem, bundlePath: app.path, environment: environment)
                    item.containingAppPath = app.path
                    items.append(item)
                }
            }
        }

        for position in items.indices {
            if let app = owner(for: items[position], index: index) {
                items[position].owner = StartupOwnerApp(name: app.name, path: app.path, bundleIdentifier: app.bundleIdentifier, lastUsedDate: nil)
            }
        }
        return Collected(items: items, vendorPrefixes: index.vendorPrefixes, notes: notes)
    }

    static func makeLaunchdItem(
        path: String,
        linkDestination: String?,
        kind: StartupItemKind,
        bundlePath: String?,
        environment: LaunchdProgramAnalyzer.Environment = .live
    ) -> StartupItem {
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var item = StartupItem(id: kind.rawValue + "|" + path, kind: kind, name: fileName)
        item.plistPath = path
        item.plistLinkDestination = linkDestination
        do {
            let definition = try LaunchdPlistParser.parse(contentsOf: path)
            item.definition = definition
            if let label = definition.label, !label.isEmpty {
                item.label = label
                item.name = label
            }
            let analysis = LaunchdProgramAnalyzer.analyze(definition, plistPath: linkDestination ?? path, bundlePath: bundlePath, environment: environment)
            item.analysis = analysis
            item.targetPath = analysis.targetPath
        } catch {
            item.parseError = error.localizedDescription
        }
        return item
    }

    /// The app an item belongs to, only when that's reliable (bundle, association or label).
    private static func owner(for item: StartupItem, index: StartupAppIndex) -> AppBundleInfo? {
        switch item.kind {
        case .appBackgroundItem:
            return item.containingAppPath.flatMap { index.app(path: $0) ?? ApplicationCatalog.read(path: $0) }
        case .loginItem:
            guard let path = item.targetPath, path.hasSuffix(".app") else { return nil }
            return index.app(path: path) ?? (FileManager.default.fileExists(atPath: path) ? ApplicationCatalog.read(path: path) : nil)
        case .userAgent, .systemAgent, .systemDaemon:
            break
        }
        if let definition = item.definition {
            for identifier in definition.associatedBundleIdentifiers {
                if let app = index.app(bundleIdentifier: identifier) { return app }
            }
        }
        if let enclosing = item.analysis?.enclosingAppPath, StartupAppIndex.isInApplicationsFolder(enclosing) {
            if let app = index.app(path: enclosing) { return app }
            if FileManager.default.fileExists(atPath: enclosing), let app = ApplicationCatalog.read(path: enclosing) { return app }
        }
        if let label = item.label, !LaunchctlClient.isProtectedLabel(label), let app = index.app(matchingLabel: label) {
            return app
        }
        return nil
    }

    // MARK: - launchd

    private static func launchdSnapshot(for items: [StartupItem], includeSystem: Bool) async -> LaunchdSnapshot {
        let client = LaunchctlClient()
        async let guiServices = client.loadedServices(domain: .currentUser)
        async let guiOverrides = client.disabledOverrides(domain: .currentUser)
        async let systemServices = loadedServicesIfNeeded(client: client, domain: .system, enabled: includeSystem || items.contains { $0.kind == .appBackgroundItem })
        async let systemOverrides = overridesIfNeeded(client: client, domain: .system, enabled: includeSystem)

        let userLabels = Array(Set(items.filter { $0.kind == .userAgent }.compactMap(\.label))).sorted()
        let infos = await StartupParallel.map(userLabels, limit: 6) { label in
            (label, await client.serviceInfo(label: label, domain: .currentUser))
        }
        var userInfos: [String: LaunchctlServiceInfo] = [:]
        for (label, info) in infos { if let info { userInfos[label] = info } }

        return LaunchdSnapshot(
            guiServices: await guiServices,
            systemServices: await systemServices,
            guiOverrides: await guiOverrides,
            systemOverrides: await systemOverrides,
            userInfos: userInfos
        )
    }

    private static func loadedServicesIfNeeded(client: LaunchctlClient, domain: LaunchdDomain, enabled: Bool) async -> [String: LaunchctlListedService]? {
        enabled ? await client.loadedServices(domain: domain) : nil
    }

    private static func overridesIfNeeded(client: LaunchctlClient, domain: LaunchdDomain, enabled: Bool) async -> [String: Bool] {
        enabled ? await client.disabledOverrides(domain: domain) : [:]
    }

    // MARK: - Assembly

    private static func assemble(
        _ original: StartupItem,
        launchd: LaunchdSnapshot,
        evaluations: [String: SecurityCodeEvaluation],
        extras: StartupExtras,
        processIndex: StartupProcessIndex,
        now: Date
    ) -> StartupItem {
        var item = original
        if let target = item.targetPath { item.code = evaluations[target] }
        if let ownerPath = item.owner?.path { item.owner?.lastUsedDate = extras.lastUsed[ownerPath] }
        if item.kind != .loginItem, let plist = item.plistPath { item.backgroundApproval = extras.approvals[plist] }

        var listed: LaunchctlListedService?
        if let label = item.label {
            switch item.kind {
            case .userAgent:
                item.launchctl = launchd.userInfos[label]
                listed = launchd.guiServices?[label]
                item.disabledOverride = launchd.guiOverrides[label]
            case .systemAgent:
                listed = launchd.guiServices?[label]
                item.disabledOverride = launchd.guiOverrides[label]
            case .systemDaemon:
                listed = launchd.systemServices?[label]
                item.disabledOverride = launchd.systemOverrides[label]
            case .appBackgroundItem:
                let isDaemon = item.plistPath?.contains("/Contents/Library/LaunchDaemons/") == true
                listed = isDaemon ? launchd.systemServices?[label] : launchd.guiServices?[label]
                item.disabledOverride = isDaemon ? launchd.systemOverrides[label] : launchd.guiOverrides[label]
            case .loginItem:
                break
            }
        }

        // Match running processes: whole app bundles for apps, the launchd PID for jobs.
        var processes: [ProcessSnapshot] = []
        let launchdPID = item.launchctl?.pid ?? listed?.pid
        let opensApp = item.kind == .loginItem || item.analysis?.targetKind == .application
            || (item.kind == .appBackgroundItem && item.definition == nil)
        if opensApp, let target = item.targetPath {
            processes = processIndex.processes(insideBundle: target)
        } else if let launchdPID, let process = processIndex.process(pid: launchdPID) {
            processes = [process]
        } else if let analysis = item.analysis, analysis.targetKind == .program, let target = analysis.targetPath {
            processes = processIndex.processes(executable: target)
        }
        item.usage = StartupProcessIndex.usage(of: processes, now: now)

        let loaded = item.launchctl != nil || listed != nil
        let runningPID = processes.first?.pid ?? launchdPID
        item.state = state(for: item, isRunning: !processes.isEmpty || launchdPID != nil, runningPID: runningPID, isLoaded: loaded,
                           statusKnown: item.kind == .loginItem || (item.kind == .systemDaemon ? launchd.systemServices != nil : launchd.guiServices != nil))
        return item
    }

    static func state(for item: StartupItem, isRunning: Bool, runningPID: Int32?, isLoaded: Bool, statusKnown: Bool) -> StartupItemState {
        if item.parseError != nil || item.definition?.isEmpty == true { return .invalid }
        if StartupHeuristics.isBroken(item) { return .broken }
        if item.kind == .loginItem { return isRunning ? .running(pid: runningPID) : .notRunning }
        if isRunning { return .running(pid: runningPID) }
        if item.backgroundApproval == .requiresApproval { return .offInSettings }
        if item.isEnabled == false { return .disabled }
        if isLoaded { return .loaded }
        return statusKnown ? .notLoaded : .unknown
    }

    /// Items needing attention first, then by name.
    static func displayOrder(_ lhs: StartupItem, _ rhs: StartupItem) -> Bool {
        if lhs.isPotentiallyUnnecessary != rhs.isPotentiallyUnnecessary { return lhs.isPotentiallyUnnecessary }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Thread-safe progress counter for parallel work.
final class StartupProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var completed = 0

    init(total: Int) { self.total = max(1, total) }

    /// Records one finished unit and returns the completed fraction.
    func advance() -> Double {
        lock.withLock {
            completed += 1
            return Double(completed) / Double(total)
        }
    }
}
