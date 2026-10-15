import Foundation
import Observation

/// State of the "what will be removed" sheet for one or several apps.
@MainActor
@Observable
final class UninstallerPreviewModel: Identifiable {
    enum Mode: Sendable {
        /// Remove the app and the selected related files.
        case uninstall
        /// Keep the app; remove the selected caches, preferences and data.
        case reset
    }

    enum Phase: Equatable {
        case preparing(message: String, fraction: Double)
        case ready
    }

    struct Section: Identifiable {
        var app: UninstallerApp
        var leftovers: [UninstallerLeftover]
        var excluded: [UninstallerExcludedItem]
        var receipts: [String]

        var id: String { app.path }
    }

    let id = UUID()
    let mode: Mode
    let apps: [UninstallerApp]
    private(set) var phase: Phase = .preparing(message: "Looking for related files…", fraction: 0)
    private(set) var sections: [Section] = []
    var selectedPaths: Set<String> = []
    private(set) var runningProcesses: [UninstallerRunningProcess] = []
    private(set) var isQuitting = false
    /// Apps didn't quit after a polite request; offer Force Quit.
    private(set) var quitTimedOut = false
    var isConfirmingForceQuit = false

    @ObservationIgnored private var task: Task<Void, Never>?

    init(mode: Mode, apps: [UninstallerApp]) {
        self.mode = mode
        self.apps = apps
    }

    var title: String {
        switch mode {
        case .uninstall: return apps.count == 1 ? "Uninstall \(apps[0].name)" : "Uninstall \(apps.count) Apps"
        case .reset: return "Reset \(apps.first?.name ?? "App")"
        }
    }

    var isReady: Bool { phase == .ready }

    var allLeftovers: [UninstallerLeftover] { sections.flatMap(\.leftovers) }

    var selectedLeftovers: [UninstallerLeftover] {
        allLeftovers.filter { selectedPaths.contains($0.path) }
    }

    var appBytes: Int64 {
        mode == .uninstall ? apps.reduce(0) { $0 + ($1.usage?.reclaimableBytes ?? 0) } : 0
    }

    /// Space freed by the selection (nested selections counted once).
    var selectedBytes: Int64 {
        let chosen = selectedLeftovers
        let topLevel = Set(PathUtilities.removingNestedPaths(chosen.map(\.path)))
        return appBytes + chosen.filter { topLevel.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var hasUnmeasuredSelection: Bool {
        selectedLeftovers.contains(where: \.isSizeIncomplete) || (mode == .uninstall && apps.contains { $0.usage == nil })
    }

    var selectedSystemWideCount: Int { selectedLeftovers.filter(\.isSystemWide).count }

    var canConfirm: Bool {
        guard isReady, runningProcesses.isEmpty, !isQuitting else { return false }
        return mode == .uninstall ? !apps.isEmpty : !selectedPaths.isEmpty
    }

    func isSelected(_ leftover: UninstallerLeftover) -> Bool {
        selectedPaths.contains(leftover.path)
    }

    func toggle(_ leftover: UninstallerLeftover) {
        if selectedPaths.contains(leftover.path) { selectedPaths.remove(leftover.path) } else { selectedPaths.insert(leftover.path) }
    }

    /// Tri-state for a group checkbox: true, false, or nil when mixed.
    func selectionState(of leftovers: [UninstallerLeftover]) -> Bool? {
        let count = leftovers.filter { selectedPaths.contains($0.path) }.count
        if count == 0 { return false }
        return count == leftovers.count ? true : nil
    }

    func setSelected(_ leftovers: [UninstallerLeftover], _ selected: Bool) {
        for leftover in leftovers {
            if selected { selectedPaths.insert(leftover.path) } else { selectedPaths.remove(leftover.path) }
        }
    }

    /// The items handed to the cleanup engine: app bundles (uninstall only) and selected leftovers.
    func cleanupItems() -> [CleanupItem] {
        var items: [CleanupItem] = []
        if mode == .uninstall {
            for app in apps {
                items.append(CleanupItem(
                    path: app.path,
                    purpose: .application,
                    snapshot: FileSnapshot.capture(path: app.path),
                    estimatedBytes: app.usage?.reclaimableBytes ?? 0,
                    category: "Applications"
                ))
            }
        }
        items += selectedLeftovers.map { $0.cleanupItem() }
        return items
    }

    /// launchd labels to stop before quitting: agents found for the apps and jobs inside the bundles.
    var jobLabels: [String] {
        let fromLeftovers = allLeftovers.filter { $0.kind == .launchAgents }.compactMap(\.launchLabel)
        return Array(Set(fromLeftovers + apps.flatMap(\.identity.embeddedJobLabels)))
    }

    // MARK: Preparation (driven by the view model)

    func setProgress(_ fraction: Double, message: String) {
        if case .preparing = phase { phase = .preparing(message: message, fraction: fraction) }
    }

    func finishPreparing(results: [UninstallerLocateResult]) {
        var seen = Set<String>()
        sections = zip(apps, results).map { app, result in
            var leftovers = result.leftovers.filter { seen.insert($0.path).inserted }
            if mode == .reset { leftovers = leftovers.filter(\.kind.isOfferedForReset) }
            return Section(app: app, leftovers: leftovers, excluded: result.excluded, receipts: result.receipts)
        }
        selectedPaths = Set(allLeftovers.filter { leftover in
            guard leftover.safety == .safe else { return false }
            return mode == .uninstall || leftover.kind.isResetDefault
        }.map(\.path))
        phase = .ready
    }

    // MARK: Running apps

    func refreshRunningProcesses() {
        let paths = apps.map(\.path)
        Task {
            let running = await BackgroundWork.run { UninstallerProcessControl.runningProcesses(inside: paths) }
            runningProcesses = running
            if running.isEmpty { quitTimedOut = false }
        }
    }

    func setRunningProcesses(_ processes: [UninstallerRunningProcess]) {
        runningProcesses = processes
    }

    /// Asks the apps (and their background helpers) to quit, then waits up to ten seconds.
    func quitRunningApps(logger: ActivityLogger) {
        guard !isQuitting, !runningProcesses.isEmpty else { return }
        isQuitting = true
        quitTimedOut = false
        let processes = runningProcesses
        let labels = jobLabels
        let paths = apps.map(\.path)
        task = Task {
            await UninstallerProcessControl.requestQuit(processes, jobLabels: labels)
            let remaining = await UninstallerProcessControl.waitUntilQuit(bundlePaths: paths, timeout: 10)
            runningProcesses = remaining
            quitTimedOut = !remaining.isEmpty
            isQuitting = false
            logger.info("Asked \(processes.count) process(es) to quit before uninstalling; \(remaining.count) still running", category: .uninstall)
        }
    }

    /// Force quits after the person confirmed that unsaved changes may be lost.
    func forceQuitRunningApps(logger: ActivityLogger) {
        guard !isQuitting, !runningProcesses.isEmpty else { return }
        isQuitting = true
        let processes = runningProcesses
        let paths = apps.map(\.path)
        task = Task {
            UninstallerProcessControl.forceQuit(processes)
            let remaining = await UninstallerProcessControl.waitUntilQuit(bundlePaths: paths, timeout: 3)
            runningProcesses = remaining
            quitTimedOut = !remaining.isEmpty
            isQuitting = false
            logger.info("Force quit \(processes.count) process(es) before uninstalling; \(remaining.count) still running", category: .uninstall)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func attach(_ task: Task<Void, Never>) {
        self.task?.cancel()
        self.task = task
    }
}
