import AppKit
import Foundation
import Observation

/// Time span shown by the history charts.
enum PerformanceChartRange: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .oneMinute: return "1 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        }
    }
}

/// Which processes the table lists.
enum PerformanceProcessScope: String, CaseIterable, Identifiable, Sendable {
    case apps, mine, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .mine: return "My Processes"
        case .all: return "All Processes"
        }
    }
}

/// One row of the process table, with sort keys that are never optional.
struct PerformanceProcessRow: Identifiable, Hashable, Sendable {
    var process: PerformanceProcess
    var role: PerformanceProcessRole
    /// Share of one core, or -1 when unknown.
    var cpuSortKey: Double
    /// Share of all cores, or -1 when unknown.
    var cpuTotalSortKey: Double
    /// Footprint in bytes, or -1 when unknown.
    var memorySortKey: Int64
    var name: String
    var userName: String
    var pid: Int32
    var kindTitle: String
    var iconPath: String?
    /// More than 1 when the row combines an app with its helper processes.
    var processCount: Int

    var id: pid_t { process.pid }
}

/// A question shown before acting on an app or process.
struct PerformanceConfirmation: Identifiable, Sendable {
    enum Kind: Sendable { case quit, stopProcess }

    let id = UUID()
    var kind: Kind
    var target: PerformanceActionTarget
}

/// Outcome of the last action, shown as a banner.
struct PerformanceActionStatus: Identifiable, Sendable {
    let id = UUID()
    var message: String
    var style: InfoCallout.Style
    /// Offered when an app didn't quit after a normal request.
    var forceQuitCandidate: PerformanceActionTarget?
}

@MainActor
@Observable
final class PerformanceViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case monitor = "Monitor"
        case optimize = "Optimize"

        var id: String { rawValue }
    }

    let services: AppServices
    let monitor: PerformanceMonitor
    /// Set by the app shell to navigate to another section (for example Startup Items).
    var openSection: ((AppSection) -> Void)?

    var tab: Tab = .monitor
    var chartRange: PerformanceChartRange = .fiveMinutes
    var processSearch = ""
    var processScope: PerformanceProcessScope = .mine {
        didSet { monitor.includesOtherUsersProcesses = isVisible && processScope == .all }
    }
    var processSortOrder: [KeyPathComparator<PerformanceProcessRow>] = [KeyPathComparator(\.cpuSortKey, order: .reverse)]
    var processSelection: Set<pid_t> = []

    var confirmation: PerformanceConfirmation?
    /// Drives the two-step Force Quit sheet.
    var forceQuitTarget: PerformanceActionTarget?
    var actionStatus: PerformanceActionStatus?

    private(set) var startupSummary: PerformanceStartupSummary?
    private(set) var bootDate: Date?
    /// nil while unknown.
    private(set) var notificationsAuthorized: Bool?

    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var followUpTask: Task<Void, Never>?

    init(services: AppServices, monitor: PerformanceMonitor) {
        self.services = services
        self.monitor = monitor
    }

    var settings: SettingsManager { services.settings }

    // MARK: - Lifecycle

    /// Starts monitoring; call from the page's `onAppear`.
    func pageAppeared() {
        guard !isVisible else { return }
        isVisible = true
        monitor.includesOtherUsersProcesses = processScope == .all
        monitor.acquire(includingProcesses: true)
        bootDate = Self.readBootDate()
        refreshStartupSummary()
        refreshNotificationStatus()
    }

    /// Stops monitoring (unless another client still needs it); call from `onDisappear`.
    func pageDisappeared() {
        guard isVisible else { return }
        isVisible = false
        monitor.includesOtherUsersProcesses = false
        monitor.release(includingProcesses: true)
    }

    func refreshStartupSummary() {
        Task {
            let summary = await BackgroundWork.run(qos: .utility) { PerformanceStartupSummary.read() }
            startupSummary = summary
        }
    }

    func refreshNotificationStatus() {
        Task {
            notificationsAuthorized = await services.notifications.isAuthorized()
        }
    }

    /// Turns performance alerts on or off; turning them on asks for notification permission.
    func setAlertsEnabled(_ enabled: Bool) {
        settings.performanceAlertsEnabled = enabled
        services.logger.info("Performance alerts \(enabled ? "enabled" : "disabled")", category: .monitor)
        guard enabled else { return }
        Task {
            _ = await services.notifications.requestAuthorization()
            notificationsAuthorized = await services.notifications.isAuthorized()
        }
    }

    var refreshInterval: TimeInterval {
        get {
            let current = monitor.refreshInterval
            return PerformanceMonitor.supportedIntervals.min { abs($0 - current) < abs($1 - current) } ?? current
        }
        set { monitor.refreshInterval = newValue }
    }

    // MARK: - Processes

    var processRows: [PerformanceProcessRow] {
        let apps = PerformanceAppDirectory.current()
        let cores = Double(max(1, monitor.topology.logicalCoreCount))
        var rows = processScope == .apps ? appRows(apps: apps, cores: cores) : individualRows(apps: apps, cores: cores)
        let query = processSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rows = rows.filter { row in
                row.name.localizedCaseInsensitiveContains(query)
                    || String(row.pid) == query
                    || (row.process.executablePath?.localizedCaseInsensitiveContains(query) ?? false)
                    || row.userName.localizedCaseInsensitiveContains(query)
            }
        }
        return rows.sorted(using: processSortOrder)
    }

    private func individualRows(apps: PerformanceAppDirectory, cores: Double) -> [PerformanceProcessRow] {
        var rows: [PerformanceProcessRow] = []
        rows.reserveCapacity(monitor.processes.count)
        for process in monitor.processes where processScope == .all || process.isCurrentUser {
            let role = PerformanceProcessPolicy.role(of: process, apps: apps)
            var name = process.name
            if case .app(let app) = role { name = app.name }
            rows.append(row(for: process, role: role, name: name, processCount: 1, cores: cores))
        }
        return rows
    }

    /// One row per user-facing app, with its helper processes' CPU and memory added in.
    /// Apps Mac Cleaner never acts on (Finder, Mac Cleaner itself…) are listed without actions.
    private func appRows(apps: PerformanceAppDirectory, cores: Double) -> [PerformanceProcessRow] {
        struct Group {
            var app: PerformanceRunningApp
            var main: PerformanceProcess?
            var cpu: Double?
            var memory: UInt64 = 0
            var count = 0
        }
        var groups: [pid_t: Group] = [:]
        for process in monitor.processes where process.hasUsageInfo {
            let owner: PerformanceRunningApp?
            if let app = apps.byPID[process.pid], app.isUserFacing {
                owner = app
            } else if let bundle = process.appBundlePath {
                owner = apps.userFacingByBundlePath[bundle]
            } else {
                owner = nil
            }
            guard let owner else { continue }
            var group = groups[owner.pid] ?? Group(app: owner)
            if process.pid == owner.pid { group.main = process }
            if let cpu = process.cpu { group.cpu = (group.cpu ?? 0) + cpu }
            group.memory += process.memoryFootprint ?? 0
            group.count += 1
            groups[owner.pid] = group
        }
        return groups.values.compactMap { group in
            guard var process = group.main else { return nil }
            let role = PerformanceProcessPolicy.role(of: process, apps: apps)
            process.cpu = group.cpu
            process.memoryFootprint = group.memory
            return row(for: process, role: role, name: group.app.name, processCount: group.count, cores: cores)
        }
    }

    private func row(for process: PerformanceProcess, role: PerformanceProcessRole, name: String, processCount: Int, cores: Double) -> PerformanceProcessRow {
        PerformanceProcessRow(
            process: process,
            role: role,
            cpuSortKey: process.cpu ?? -1,
            cpuTotalSortKey: process.cpu.map { $0 / cores } ?? -1,
            memorySortKey: process.memoryFootprint.map { Int64(clamping: $0) } ?? -1,
            name: name,
            userName: process.userName,
            pid: process.pid,
            kindTitle: processCount > 1 ? "\(role.title) · \(processCount)" : role.title,
            iconPath: role.actionableApp?.bundlePath ?? process.appBundlePath ?? process.executablePath,
            processCount: processCount
        )
    }

    /// The busiest processes for compact lists (menu bar, summaries).
    static func topProcesses(_ processes: [PerformanceProcess], limit: Int) -> [PerformanceProcess] {
        Array(processes.filter { ($0.cpu ?? 0) > 0 }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(limit))
    }

    // MARK: - Optimize

    var recommendations: [PerformanceRecommendation] {
        PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(
            sample: monitor.latest,
            processes: monitor.processes.filter(\.hasUsageInfo),
            apps: .current(),
            logicalCoreCount: monitor.topology.logicalCoreCount,
            startup: startupSummary,
            bootDate: bootDate
        ))
    }

    /// Apps using the most memory (with their helpers), largest first.
    var memoryHeavyApps: [PerformanceMemoryHeavyApp] {
        PerformanceAdvisor.memoryHeavyApps(
            processes: monitor.processes,
            apps: .current(),
            totalMemory: monitor.latest?.memoryTotal ?? ProcessInfo.processInfo.physicalMemory
        )
    }

    /// Seconds of process monitoring so far (sustained-CPU findings need about 30).
    var processObservationSeconds: TimeInterval {
        guard let started = monitor.processTrackingStarted else { return 0 }
        return max(0, Date().timeIntervalSince(started))
    }

    // MARK: - Actions

    /// Actions available for a table row.
    func actions(for row: PerformanceProcessRow) -> [PerformanceAction] {
        if row.role.actionableApp != nil { return [.quit, .forceQuit] }
        if row.role.canStopProcess { return [.stopProcess] }
        return []
    }

    func target(for row: PerformanceProcessRow) -> PerformanceActionTarget? {
        if let app = row.role.actionableApp { return .app(app) }
        if row.role.canStopProcess { return .process(row.process) }
        return nil
    }

    /// Starts an action; every action asks for confirmation first.
    func perform(_ action: PerformanceAction, target: PerformanceActionTarget?) {
        switch action {
        case .openStartupItems:
            openSection?(.startup)
        case .quit:
            guard let target else { return }
            confirmation = PerformanceConfirmation(kind: .quit, target: target)
        case .stopProcess:
            guard let target else { return }
            confirmation = PerformanceConfirmation(kind: .stopProcess, target: target)
        case .forceQuit:
            guard let target else { return }
            forceQuitTarget = target
        }
    }

    /// Called when the person confirmed `confirmation`.
    func confirm(_ confirmation: PerformanceConfirmation) {
        self.confirmation = nil
        let target = confirmation.target
        switch confirmation.kind {
        case .quit:
            if report(PerformanceProcessActions.quit(target), action: "Asked app to quit", target: target) {
                watchForQuit(target)
            }
        case .stopProcess:
            report(PerformanceProcessActions.stopProcess(target), action: "Sent stop request to process", target: target)
        }
    }

    /// Called after the second Force Quit confirmation.
    func confirmForceQuit(_ target: PerformanceActionTarget) {
        forceQuitTarget = nil
        followUpTask?.cancel()
        report(PerformanceProcessActions.forceQuit(target), action: "Force quit app", target: target)
    }

    @discardableResult
    private func report(_ result: Result<String, PerformanceActionError>, action: String, target: PerformanceActionTarget) -> Bool {
        switch result {
        case .success(let message):
            services.logger.info("\(action): \(target.name)", category: .monitor)
            actionStatus = PerformanceActionStatus(message: message, style: .success)
            return true
        case .failure(let error):
            services.logger.warning("\(action) failed for \(target.name): \(error.localizedDescription)", category: .monitor)
            actionStatus = PerformanceActionStatus(message: error.localizedDescription, style: .warning)
            return false
        }
    }

    /// If an app hasn't quit after a few seconds, explain why and offer Force Quit.
    private func watchForQuit(_ target: PerformanceActionTarget) {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            guard PerformanceProcessActions.isStillRunning(target) else {
                if self.actionStatus?.style == .success { self.actionStatus = PerformanceActionStatus(message: "\(target.name) quit.", style: .success) }
                return
            }
            self.actionStatus = PerformanceActionStatus(
                message: "\(target.name) is still open. It may be waiting for you to save changes — switch to it to answer. If it isn't responding, you can force quit it.",
                style: .info,
                forceQuitCandidate: target
            )
        }
    }

    // MARK: - Helpers

    private static func readBootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}
