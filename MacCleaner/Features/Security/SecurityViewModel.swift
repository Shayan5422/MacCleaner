import AppKit
import Foundation
import Observation

/// Result of an on-demand full signature check of one app or package.
struct SecurityDeepVerification: Sendable, Hashable {
    var evaluation: SecurityCodeEvaluation
    var gatekeeper: SecurityGatekeeperAssessment?
    var date: Date
}

/// `spctl --assess` verdict (Gatekeeper's own assessment).
struct SecurityGatekeeperAssessment: Sendable, Hashable {
    var accepted: Bool
    /// "Notarized Developer ID", "Apple System", "Unnotarized Developer ID"...
    var source: String?
    var origin: String?
    var output: String

    static func parse(_ output: String, exitCode: Int32) -> SecurityGatekeeperAssessment {
        var source: String?
        var origin: String?
        var rejected = false
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("source=") { source = String(line.dropFirst("source=".count)) }
            if line.hasPrefix("origin=") { origin = String(line.dropFirst("origin=".count)) }
            if line.hasSuffix(": rejected") || line.contains(": rejected ") { rejected = true }
        }
        return SecurityGatekeeperAssessment(accepted: exitCode == 0 && !rejected, source: source, origin: origin, output: output)
    }

    var summary: String {
        let verdict = accepted ? "Accepted by Gatekeeper" : "Rejected by Gatekeeper"
        return source.map { "\(verdict) (\($0))" } ?? verdict
    }
}

/// A change that needs confirmation before it runs.
enum SecurityPendingAction: Identifiable, Sendable {
    case disableAgent(label: String, name: String)
    case removeLoginItem(name: String, path: String?)

    var id: String {
        switch self {
        case .disableAgent(let label, _): return "disable|" + label
        case .removeLoginItem(let name, let path): return "login|" + name + "|" + (path ?? "")
        }
    }

    var title: String {
        switch self {
        case .disableAgent(_, let name): return "Turn off “\(name)”?"
        case .removeLoginItem(let name, _): return "Remove “\(name)” from login items?"
        }
    }

    var message: String {
        switch self {
        case .disableAgent:
            return "It stops now and won't start at login. Its files stay where they are, so you can turn it back on from Startup Items. Anything it does in the background stops."
        case .removeLoginItem:
            return "The app won't open automatically when you log in. The app itself isn't removed."
        }
    }

    var confirmTitle: String {
        switch self {
        case .disableAgent: return "Turn Off"
        case .removeLoginItem: return "Remove"
        }
    }
}

@MainActor
@Observable
final class SecurityViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case findings, persistence, applications, downloads

        var id: String { rawValue }

        var title: String {
            switch self {
            case .findings: return "Findings"
            case .persistence: return "Startup & Persistence"
            case .applications: return "App Signatures"
            case .downloads: return "Downloads"
            }
        }
    }

    enum AppFilter: String, CaseIterable, Identifiable {
        case all, unsigned, notNotarized, invalid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .unsigned: return "Unsigned"
            case .notNotarized: return "Not Notarized"
            case .invalid: return "Invalid"
            }
        }

        func includes(_ category: SecurityTrustCategory) -> Bool {
            switch self {
            case .all: return true
            case .unsigned: return category.lacksIdentity
            case .notNotarized: return category.isNotarizationUnconfirmed
            case .invalid: return category.isSignatureProblem
            }
        }
    }

    let services: AppServices
    let cleanupFlow = CleanupFlow()

    private(set) var posture: SecurityPosture?
    private(set) var isCheckingPosture = false
    private(set) var report: SecurityReport?
    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var progressMessage = ""
    private(set) var lastScan: SecurityScanSummary?
    private(set) var deepVerifications: [String: SecurityDeepVerification] = [:]
    private(set) var verifyingPaths: Set<String> = []
    private(set) var ignoredIDs: Set<String>
    private(set) var isPerformingAction = false

    var tab: Tab = .findings
    var searchText = ""
    var appFilter: AppFilter = .all
    var includesArchives = false
    var showsIgnored = false
    var selectedFinding: SecurityFinding?
    var pendingAction: SecurityPendingAction?
    var alertMessage: String?
    var statusMessage: String?
    private var scanTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        lastScan = SecurityStore.lastScanSummary()
        ignoredIDs = SecurityStore.ignoredFindingIDs()
    }

    // MARK: - Posture and scanning

    func onAppear() async {
        if posture == nil && !isCheckingPosture { await refreshPosture() }
    }

    func refreshPosture() async {
        isCheckingPosture = true
        posture = await SecurityPostureChecker.check()
        isCheckingPosture = false
    }

    func startScan() {
        guard !isScanning else { return }
        scanTask = Task { await runScan() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func runScan() async {
        isScanning = true
        progress = 0
        progressMessage = "Starting…"
        defer { isScanning = false }

        // Login items are read here on the main actor, only when access was already granted.
        var source = SecurityScanner.LoginItemsSource.skip
        if await StartupLoginItemsService.automationAccess(promptIfNeeded: false) == .granted,
           let records = try? StartupLoginItemsService.readLoginItems() {
            source = .provided(records)
        }

        let result = await SecurityScanner(loginItems: source).scan { [weak self] fraction, message in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.progress = max(self.progress, fraction)
                self.progressMessage = message
            }
        }
        report = result
        posture = result.posture
        if !result.wasCancelled { lastScan = result.scanSummary }
        services.logger.info(
            "Security scan \(result.wasCancelled ? "stopped" : "finished"): \(result.threatCount) threats, \(result.suspiciousCount) suspicious, \(result.recommendationCount) recommendations, \(result.informationCount) informational; \(result.posture.summary)",
            category: .security
        )
    }

    // MARK: - Derived state

    var activeFindings: [SecurityFinding] {
        guard let report else { return [] }
        return report.findings.filter { !ignoredIDs.contains($0.id) && matchesSearch($0) }
    }

    var ignoredFindings: [SecurityFinding] {
        guard let report else { return [] }
        return report.findings.filter { ignoredIDs.contains($0.id) && matchesSearch($0) }
    }

    func findings(_ severity: FindingSeverity) -> [SecurityFinding] {
        activeFindings.filter { $0.severity == severity }
    }

    func count(_ severity: FindingSeverity) -> Int {
        report?.findings.filter { $0.severity == severity && !ignoredIDs.contains($0.id) }.count ?? 0
    }

    var persistenceItems: [SecurityPersistenceItem] {
        guard let report else { return [] }
        let query = trimmedQuery
        return report.persistenceItems.filter { item in
            query.isEmpty || [item.name, item.location, item.developer, item.kind.title, item.detail]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var applications: [SecurityAppRecord] {
        guard let report else { return [] }
        let query = trimmedQuery
        return report.applications.filter { app in
            appFilter.includes(app.evaluation.category)
                && (query.isEmpty || [app.name, app.bundleIdentifier, app.evaluation.developer].compactMap { $0 }
                    .joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }

    func applicationCount(_ filter: AppFilter) -> Int {
        report?.applications.filter { filter.includes($0.evaluation.category) }.count ?? 0
    }

    var downloads: [SecurityQuarantinedFile] {
        guard let report else { return [] }
        let query = trimmedQuery
        return report.quarantinedFiles.filter { file in
            (includesArchives || file.kind.canRunCode)
                && (query.isEmpty || file.name.localizedCaseInsensitiveContains(query)
                    || (file.quarantine.agent ?? "").localizedCaseInsensitiveContains(query))
        }
    }

    var archiveCount: Int { report?.quarantinedFiles.filter { $0.kind == .archive }.count ?? 0 }

    func finding(id: String) -> SecurityFinding? { report?.findings.first { $0.id == id } }

    func isIgnored(_ finding: SecurityFinding) -> Bool { ignoredIDs.contains(finding.id) }

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    private func matchesSearch(_ finding: SecurityFinding) -> Bool {
        let query = trimmedQuery
        guard !query.isEmpty else { return true }
        return [finding.title, finding.summary, finding.path ?? "", finding.category.title]
            .joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    // MARK: - Ignore

    func setIgnored(_ finding: SecurityFinding, ignored: Bool) {
        SecurityStore.setIgnored(ignored, findingID: finding.id)
        if ignored { ignoredIDs.insert(finding.id) } else { ignoredIDs.remove(finding.id) }
        if let report {
            lastScan = SecurityScanSummary(
                date: report.finishedAt,
                threats: count(.threat), suspicious: count(.suspicious),
                recommendations: count(.recommendation), information: count(.info),
                protectionsOn: report.posture.enabledCount, protectionsTotal: report.posture.totalCount,
                summary: SecurityReport.summaryLine(threats: count(.threat), suspicious: count(.suspicious), recommendations: count(.recommendation))
            )
            if let summary = lastScan, !report.wasCancelled { SecurityStore.saveLastScanSummary(summary) }
        }
        services.logger.info(ignored ? "Security finding ignored" : "Security finding restored", category: .security)
    }

    // MARK: - Deep verification

    func deepVerify(_ path: String) {
        guard !verifyingPaths.contains(path) else { return }
        verifyingPaths.insert(path)
        Task { @MainActor in
            let evaluation = await BackgroundWork.run(qos: .userInitiated) { SecurityCodeTrust.evaluate(path: path, deep: true) }
            let type = path.hasSuffix(".pkg") || path.hasSuffix(".mpkg") ? "install" : "execute"
            var gatekeeper: SecurityGatekeeperAssessment?
            if let result = try? await ProcessRunner.run("/usr/sbin/spctl", arguments: ["--assess", "--verbose=2", "--type", type, path], timeout: 180),
               !result.timedOut {
                gatekeeper = SecurityGatekeeperAssessment.parse(result.combinedOutput, exitCode: result.exitCode)
            }
            deepVerifications[path] = SecurityDeepVerification(evaluation: evaluation, gatekeeper: gatekeeper, date: Date())
            verifyingPaths.remove(path)
            services.logger.info("Deep signature verification finished: \(evaluation.category.rawValue)", category: .security)
        }
    }

    // MARK: - Remediation

    /// Finds a startup item's label for a plist (used to stop an agent after its plist is trashed).
    private func label(forPlist plist: String) -> String? {
        try? LaunchdPlistParser.parse(contentsOf: plist).label
    }

    func requestDisableAgent(label: String, name: String) {
        guard LaunchctlClient.isValidLabel(label), !LaunchctlClient.isProtectedLabel(label) else {
            alertMessage = LaunchctlError.protectedLabel(label).localizedDescription
            return
        }
        pendingAction = .disableAgent(label: label, name: name)
    }

    func requestRemoveLoginItem(name: String, path: String?) {
        pendingAction = .removeLoginItem(name: name, path: path)
    }

    func perform(_ action: SecurityPendingAction) async {
        if pendingAction?.id == action.id { pendingAction = nil }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            switch action {
            case .disableAgent(let label, let name):
                try await LaunchctlClient().disableUserAgent(label: label)
                statusMessage = "“\(name)” is turned off. Scan again to update the results."
                services.logger.info("Turned off a user launch agent from Security", category: .security)
            case .removeLoginItem(let name, let path):
                try StartupLoginItemsService.deleteLoginItem(named: name, expectedPath: path)
                statusMessage = "“\(name)” no longer opens at login."
                services.logger.info("Removed a login item from Security", category: .security)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Moves files to the Trash through the shared cleanup flow (with its confirmation and undo).
    func requestTrash(paths: [String], purpose: DeletionPurpose, title: String, warning: String?, stopsAgentLabel: String? = nil) {
        let items = paths.map { path -> CleanupItem in
            let size = report?.quarantinedFiles.first { $0.path == path }?.sizeBytes
                ?? ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            return CleanupItem(path: path, purpose: purpose, snapshot: FileSnapshot.capture(path: path), estimatedBytes: size,
                               category: purpose == .userFile ? "Quarantined downloads" : "Launch agents and adware files")
        }
        guard !items.isEmpty else { return }
        let start: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.cleanupFlow.requestCleanup(title: title, items: items, services: self.services, regenerableData: false, warning: warning) { [weak self] report in
                guard let self else { return }
                self.removeTrashed(report: report)
                if let label = stopsAgentLabel, !report.removed.isEmpty {
                    Task { @MainActor in
                        try? await LaunchctlClient().bootoutUserAgent(label: label)
                    }
                }
                self.services.logger.info("Moved \(report.removed.count) security item(s) to the Trash", category: .security)
            }
        }
        if selectedFinding != nil {
            selectedFinding = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                start()
            }
        } else {
            start()
        }
    }

    func requestTrashLaunchAgent(plistPath: String, label: String?, name: String) {
        let resolvedLabel = label ?? self.label(forPlist: plistPath)
        let stoppable = resolvedLabel.flatMap { LaunchctlClient.isValidLabel($0) && !LaunchctlClient.isProtectedLabel($0) ? $0 : nil }
        requestTrash(
            paths: [plistPath],
            purpose: .applicationData,
            title: "Remove “\(name)”",
            warning: "The launch agent's property list moves to the Trash and the agent stops. The program it ran stays on disk; remove the app that installed it to get rid of it completely.",
            stopsAgentLabel: stoppable
        )
    }

    /// Removes trashed items from the current report so the lists stay accurate.
    private func removeTrashed(report cleanup: CleanupReport) {
        let removed = Set(cleanup.removed.map(\.path))
        guard !removed.isEmpty, var current = report else { return }
        current.quarantinedFiles.removeAll { removed.contains(PathUtilities.normalize($0.path)) }
        current.findings.removeAll { finding in
            if let path = finding.path, removed.contains(PathUtilities.normalize(path)) { return true }
            if case .quarantinedFiles(let paths) = finding.remediation, paths.allSatisfy({ removed.contains(PathUtilities.normalize($0)) }) { return true }
            return false
        }
        current.persistenceItems.removeAll { item in item.location.map { removed.contains(PathUtilities.normalize($0)) } ?? false }
        report = current
    }

    // MARK: - Shortcuts

    func open(_ pane: SystemSettingsPane) { services.permissions.open(pane) }

    func openDeviceManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInTextEdit(_ path: String) {
        Task { @MainActor in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            do {
                _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: textEdit, configuration: configuration)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func showUnidentifiedApps() {
        selectedFinding = nil
        tab = .applications
        appFilter = .unsigned
    }
}
