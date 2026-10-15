import Foundation
import Observation

/// A cleanup command that is running or has finished.
struct DeveloperCommandRun: Identifiable {
    enum State {
        case running
        case finished(CommandResult)
        case failed(String)
        case stopped
    }

    let id = UUID()
    var item: DeveloperItem
    var command: DeveloperCommand
    var state: State = .running
    var startedAt = Date()
    var finishedAt: Date?
    /// Space the item still used after the command, measured again.
    var bytesAfter: Int64?
    var isMeasuring = false

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var succeeded: Bool {
        if case .finished(let result) = state { return result.succeeded }
        return false
    }

    /// About how much space the command gave back.
    var freedBytes: Int64? {
        guard let bytesAfter, succeeded else { return nil }
        return max(0, item.bytes - bytesAfter)
    }
}

@MainActor
@Observable
final class DeveloperToolsViewModel {
    enum Phase: Equatable {
        case idle, scanning, ready
    }

    let services: AppServices
    let cleanupFlow = CleanupFlow()

    private(set) var phase: Phase = .idle
    private(set) var progressFraction: Double = 0
    private(set) var progressMessage = ""
    private(set) var reports: [DeveloperToolReport] = []
    private(set) var missingTools: [DeveloperToolKind] = []
    private(set) var isXcodeRunning = false
    private(set) var lastScanDate: Date?
    private(set) var refreshingTools: Set<DeveloperToolKind> = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var excludedPaths: Set<String> = []

    var searchText = ""
    var collapsedTools: Set<DeveloperToolKind> = []
    /// Groups the person opened or closed; others use a default based on their size.
    var groupExpansion: [String: Bool] = [:]
    /// Command waiting for confirmation.
    var pendingCommand: DeveloperItem?
    /// Command running or finished (shows its output).
    var commandRun: DeveloperCommandRun?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private let home = DeveloperToolsScanner.currentHome

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Derived state

    var hasScanned: Bool { lastScanDate != nil }
    var isBusy: Bool { phase == .scanning || cleanupFlow.isCleaning || commandRun?.isRunning == true }

    /// Reports and items that match the search, without excluded items.
    var visibleReports: [DeveloperToolReport] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return reports.compactMap { report in
            var filtered = report
            filtered.items = report.items.filter { item in
                if let path = item.path, excludedPaths.contains(path) { return false }
                guard !query.isEmpty else { return true }
                return [item.title, item.detail ?? "", item.group, report.tool.title, item.path ?? "", item.command?.commandLine ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            if !query.isEmpty && filtered.items.isEmpty && !report.tool.title.localizedCaseInsensitiveContains(query) { return nil }
            return filtered
        }
    }

    var fileItems: [DeveloperItem] {
        reports.flatMap(\.items).filter { $0.isFileItem && !excludedPaths.contains($0.path ?? "") }
    }

    var selectedItems: [DeveloperItem] {
        fileItems.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    var totalRecoverable: Int64 {
        reports.reduce(0) { $0 + $1.recoverableBytes }
    }

    var safeRecoverable: Int64 {
        reports.flatMap(\.items).filter { $0.safety == .safe && $0.countsTowardTotal && !$0.sizeIsUpperBound }.reduce(0) { $0 + $1.bytes }
    }

    func isSelected(_ item: DeveloperItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    func toggle(_ item: DeveloperItem) {
        guard item.isFileItem else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    /// Tri-state for a tool's checkbox: true, false, or nil when mixed.
    func selectionState(of report: DeveloperToolReport) -> Bool? {
        let items = report.items.filter(\.isFileItem)
        let count = items.filter { selectedIDs.contains($0.id) }.count
        if count == 0 { return false }
        return count == items.count ? true : nil
    }

    func setSelection(of report: DeveloperToolReport, selected: Bool) {
        for item in report.items where item.isFileItem {
            if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
        }
    }

    func toggleCollapsed(_ tool: DeveloperToolKind) {
        if collapsedTools.contains(tool) { collapsedTools.remove(tool) } else { collapsedTools.insert(tool) }
    }

    /// Large groups (dozens of archives) start collapsed; searching opens everything.
    func isGroupExpanded(_ group: String, in report: DeveloperToolReport) -> Bool {
        if !searchText.isEmpty { return true }
        if let value = groupExpansion[report.tool.rawValue + "|" + group] { return value }
        return report.items.filter { $0.group == group }.count <= 12
    }

    func toggleGroup(_ group: String, in report: DeveloperToolReport) {
        groupExpansion[report.tool.rawValue + "|" + group] = !isGroupExpanded(group, in: report)
    }

    func selectionState(of items: [DeveloperItem]) -> Bool? {
        let files = items.filter(\.isFileItem)
        let count = files.filter { selectedIDs.contains($0.id) }.count
        if count == 0 { return false }
        return count == files.count ? true : nil
    }

    func setSelection(of items: [DeveloperItem], selected: Bool) {
        for item in items where item.isFileItem {
            if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
        }
    }

    // MARK: - Scanning

    func scan() {
        scanTask?.cancel()
        phase = .scanning
        progressFraction = 0
        progressMessage = "Looking for developer tools…"
        let scanner = makeScanner()
        let started = Date()
        scanTask = Task { [weak self] in
            let result = await scanner.scan { [weak self] fraction, message in
                Task { @MainActor in self?.updateProgress(fraction, message) }
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(result, duration: Date().timeIntervalSince(started))
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = hasScanned ? .ready : .idle
    }

    private func makeScanner() -> DeveloperToolsScanner {
        DeveloperToolsScanner(home: home, fileScanner: services.scanner, exclusions: services.settings.scanPreferences.exclusions, policy: services.policy)
    }

    private func updateProgress(_ fraction: Double, _ message: String) {
        guard phase == .scanning else { return }
        progressFraction = fraction
        progressMessage = message
    }

    private func apply(_ result: DeveloperScanResult, duration: TimeInterval) {
        reports = result.reports
        missingTools = result.missingTools
        isXcodeRunning = result.isXcodeRunning
        lastScanDate = result.date
        excludedPaths = []
        selectedIDs = Set(result.reports.flatMap(\.items).filter { $0.isFileItem && $0.safety == .safe }.map(\.id))
        phase = .ready
        let itemCount = result.reports.reduce(0) { $0 + $1.items.count }
        services.logger.info(
            "Developer scan: \(result.reports.count) tools, \(itemCount) items, \(ByteFormatting.string(result.recoverableBytes)) recoverable, \(String(format: "%.1f", duration))s",
            category: .developer
        )
    }

    /// Scans a few tools again and replaces their cards.
    func refresh(_ tools: Set<DeveloperToolKind>) async {
        guard !tools.isEmpty else { return }
        refreshingTools.formUnion(tools)
        let scanner = makeScanner()
        let result = await scanner.scan(tools: tools)
        refreshingTools.subtract(tools)
        let previousSelection = selectedIDs
        // Replace cards in place so the page doesn't jump around.
        var updated: [DeveloperToolReport] = []
        for report in reports {
            if tools.contains(report.tool) {
                if let fresh = result.reports.first(where: { $0.tool == report.tool }) { updated.append(fresh) }
            } else {
                updated.append(report)
            }
        }
        for fresh in result.reports where !updated.contains(where: { $0.tool == fresh.tool }) {
            updated.append(fresh)
        }
        reports = updated
        missingTools = (missingTools.filter { !tools.contains($0) } + result.missingTools)
            .sorted { (DeveloperToolKind.allCases.firstIndex(of: $0) ?? 0) < (DeveloperToolKind.allCases.firstIndex(of: $1) ?? 0) }
        isXcodeRunning = DeveloperEnvironment.isXcodeRunning()
        // Keep selections that still exist; new safe items start selected.
        let validIDs = Set(reports.flatMap(\.items).filter(\.isFileItem).map(\.id))
        let newSafe = result.reports.flatMap(\.items).filter { $0.isFileItem && $0.safety == .safe }.map(\.id)
        selectedIDs = previousSelection.intersection(validIDs).union(newSafe)
    }

    // MARK: - Cleaning files

    func cleanSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        // Archives and items that need care always go to the Trash so they can be restored.
        let trashOnly = items.contains { $0.trashOnly || $0.safety == .caution }
        var warnings: [String] = []
        if isXcodeRunning, items.contains(where: { $0.tool == .xcode }) {
            warnings.append("Xcode is open, so folders it’s using will be skipped.")
        }
        for warning in items.compactMap(\.warning) where !warnings.contains(warning) {
            warnings.append(warning)
        }
        let tools = Set(items.map(\.tool))
        cleanupFlow.requestCleanup(
            title: "Developer Cleanup",
            items: items.flatMap(\.cleanupItems),
            services: services,
            regenerableData: !trashOnly,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        ) { [weak self] report in
            self?.didClean(report, tools: tools)
        }
    }

    private func didClean(_ report: CleanupReport, tools: Set<DeveloperToolKind>) {
        services.logger.info(
            "Developer cleanup: \(report.removed.count) removed, \(ByteFormatting.string(report.bytesRemoved)), \(report.skipped.count) skipped, \(report.failed.count) failed",
            category: .developer
        )
        Task { await refresh(tools) }
    }

    func exclude(_ item: DeveloperItem) {
        guard let path = item.path else { return }
        services.settings.addExclusion(path)
        excludedPaths.insert(path)
        selectedIDs.remove(item.id)
    }

    // MARK: - Commands

    func requestCommand(_ item: DeveloperItem) {
        guard item.command != nil, !isBusy else { return }
        pendingCommand = item
    }

    func runCommand(_ item: DeveloperItem) {
        pendingCommand = nil
        guard let command = item.command, commandRun?.isRunning != true else { return }
        commandRun = DeveloperCommandRun(item: item, command: command)
        let runID = commandRun?.id
        let home = home
        let label = ([command.displayName] + command.arguments.prefix(2)).joined(separator: " ")
        services.logger.info("Running \(label)", category: .developer)
        commandTask = Task { [weak self] in
            var state: DeveloperCommandRun.State
            do {
                let result = try await ProcessRunner.run(
                    command.executable,
                    arguments: command.arguments,
                    environment: DeveloperCLI.environment(adding: command.environment),
                    currentDirectory: home,
                    timeout: command.timeout,
                    maxOutputBytes: 2 * 1024 * 1024
                )
                state = Task.isCancelled ? .stopped : .finished(result)
            } catch {
                state = Task.isCancelled ? .stopped : .failed(error.localizedDescription)
            }
            guard let self, self.commandRun?.id == runID else { return }
            self.commandRun?.state = state
            self.commandRun?.finishedAt = Date()
            self.commandRun?.isMeasuring = true
            self.logCommand(label: label, state: state)
            await self.refresh([item.tool])
            guard self.commandRun?.id == runID else { return }
            let after = self.reports.first { $0.tool == item.tool }?.items.first { $0.id == item.id }?.bytes ?? 0
            self.commandRun?.bytesAfter = after
            self.commandRun?.isMeasuring = false
        }
    }

    func stopCommand() {
        commandTask?.cancel()
    }

    func dismissCommandRun() {
        guard commandRun?.isRunning != true else { return }
        commandRun = nil
    }

    private func logCommand(label: String, state: DeveloperCommandRun.State) {
        switch state {
        case .finished(let result):
            if result.succeeded {
                services.logger.info("\(label) finished", category: .developer)
            } else {
                services.logger.warning("\(label) failed: exit code \(result.exitCode)\(result.timedOut ? ", timed out" : "")", category: .developer)
            }
        case .failed:
            services.logger.error("\(label) couldn’t run", category: .developer)
        case .stopped:
            services.logger.warning("\(label) was stopped", category: .developer)
        case .running:
            break
        }
    }
}
