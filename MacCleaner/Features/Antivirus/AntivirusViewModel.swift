import AppKit
import Foundation
import Observation

/// Dependencies of the Antivirus page, injectable for tests and previews.
struct AntivirusEnvironment: Sendable {
    var paths: AVPaths
    var engine: AVEngineHolder
    var intel: AVIntelHolder
    var updater: AVDefinitionsUpdater.Environment
    var makeEventSource: @Sendable () -> any AVFileEventSource
    var home: String
    /// How often automatic updates ask the updater (it only goes online when a check is due).
    var autoUpdateInterval: TimeInterval = 3600
    /// Delay before the first automatic check after launch, so launching stays light.
    var firstAutoUpdateDelay: TimeInterval = 45
    var startsShields = true

    static func standard() -> AntivirusEnvironment {
        let paths = AVPaths.standard
        return AntivirusEnvironment(paths: paths, engine: .shared, intel: .shared, updater: .live(paths: paths),
                                    makeEventSource: { AVFSEventSource() }, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

/// A detection the shields reported, kept for the Shields tab.
struct AVShieldRecord: Codable, Sendable, Identifiable, Hashable {
    enum Action: String, Codable, Sendable { case quarantined, notified, quarantineFailed }

    var id: String
    var date: Date
    var shield: AVShieldKind
    var path: String
    var name: String
    var category: AVThreatCategory
    var action: Action
    var detail: String?
}

/// An in-app alert about a real-time detection.
struct AVShieldAlert: Identifiable, Sendable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var path: String
    var wasQuarantined: Bool
}

/// The result of "Test Protection".
struct AVProtectionTestResult: Sendable, Equatable {
    var detected: Bool
    var signatureName: String?
    var usedDefinitions: Bool
    var removedTestFile: Bool
    /// Another antivirus removed or blocked the test file before Mac Cleaner could scan it.
    var blockedByOtherSoftware = false
    var date: Date
}

/// State of the Antivirus page, the shields and the menu bar section.
@MainActor
@Observable
final class AntivirusViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case scan, shields, chest, definitions, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .scan: return "Scan"
            case .shields: return "Shields"
            case .chest: return "Virus Chest"
            case .definitions: return "Definitions"
            case .history: return "History"
            }
        }
    }

    /// Overall protection, for the page, the Dashboard and the menu bar.
    enum ProtectionState: String, Sendable, Equatable {
        case protected, attention, threats, notSetUp

        var title: String {
            switch self {
            case .protected: return "Protected"
            case .attention: return "Attention needed"
            case .threats: return "Threats found"
            case .notSetUp: return "Not set up"
            }
        }

        var symbolName: String {
            switch self {
            case .protected: return "checkmark.shield.fill"
            case .attention: return "exclamationmark.shield.fill"
            case .threats: return "xmark.shield.fill"
            case .notSetUp: return "shield.slash"
            }
        }
    }

    let services: AppServices
    /// Opens another section (set by `AppEnvironment.connectNavigation`).
    var navigate: ((AppSection) -> Void)?
    let settings: AntivirusSettings
    @ObservationIgnored let environment: AntivirusEnvironment
    @ObservationIgnored let updater: AVDefinitionsUpdater
    @ObservationIgnored let chest: AVVirusChest
    /// The shared protection activity feed (menu bar and Dashboard).
    @ObservationIgnored let eventLog: ProtectionEventLog

    // Definitions
    private(set) var definitionsState: AVDefinitionsState
    private(set) var isUpdatingDefinitions = false
    private(set) var updateProgress: AVUpdateProgress?
    private(set) var updateProblem: String?
    private(set) var updateMessage: String?
    private(set) var hasDefinitions = false
    private(set) var engineSummary: AVDatabaseSummary?
    private(set) var engineProblem: String?
    private(set) var intelIndicatorCount = 0
    private(set) var freshclam: AVFreshclamTool?
    private(set) var brewPath: String?
    private(set) var toolsChecked = false
    var homebrewInstall: AVHomebrewInstallRun?
    var confirmsHomebrewInstall = false

    // Scanning
    private(set) var isScanning = false
    private(set) var scanProgress: AVScanProgress?
    private(set) var lastReport: AVScanReport?
    /// Threats waiting for a decision (last scan and real-time detections).
    private(set) var threats: [AVThreat] = []
    private(set) var history: [AVScanSummary] = []
    private(set) var busyThreatIDs: Set<String> = []
    private(set) var isTestingProtection = false
    private(set) var testResult: AVProtectionTestResult?
    var selectedThreat: AVThreat?
    var threatToAllow: AVThreat?

    // Virus Chest
    private(set) var chestItems: [AVChestItem] = []
    private(set) var busyChestIDs: Set<String> = []
    var chestItemToDelete: AVChestItem?
    /// Restoring needs a different folder (something exists at the original place).
    var restoreNeedingFolder: AVChestItem?

    // Shields
    private(set) var shieldStatistics = AVFileShield.Statistics()
    private(set) var shieldRecords: [AVShieldRecord] = []
    var shieldAlert: AVShieldAlert?
    private(set) var openAtLoginStatus: AVLoginItemController.Status = .notRegistered
    /// Views that can show `shieldAlert`; only the first one does, so it never appears twice.
    private(set) var alertPresenters: [UUID] = []

    // Page
    var tab: Tab = .scan
    var statusMessage: String?
    var errorMessage: String?
    /// Shown with "Reveal in Finder" when macOS or ownership prevented an action.
    var errorPath: String?

    @ObservationIgnored private(set) var started = false
    @ObservationIgnored var shield: AVFileShield?
    @ObservationIgnored var scanTask: Task<Void, Never>?
    @ObservationIgnored private var autoUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(services: AppServices, environment: AntivirusEnvironment = .standard(), defaults: UserDefaults = .standard,
         eventLog: ProtectionEventLog = .shared) {
        self.services = services
        self.environment = environment
        self.eventLog = eventLog
        settings = AntivirusSettings(defaults: defaults)
        updater = AVDefinitionsUpdater(environment: environment.updater)
        chest = AVVirusChest(paths: environment.paths, logger: services.logger)
        // A small JSON file; everything heavy happens in `start()`.
        definitionsState = AVStateFile(url: environment.paths.stateFile).load()
        hasDefinitions = environment.engine.hasDefinitions
        engineSummary = environment.engine.summary
    }

    // MARK: - Start

    /// Starts the engine load, real-time shields and automatic updates. Cheap on the main thread
    /// and safe to call more than once; works without any window (menu bar only).
    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(forName: AVEngineHolder.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineChanged() }
        })
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let environment = self.environment
        let sources = settings.sources
        let loaded = await BackgroundWork.run(qos: .utility) { () -> (AVDefinitionsState, [AVScanSummary], AVOpenThreats?, String?, [AVShieldRecord]) in
            try? environment.paths.prepare()
            environment.paths.cleanTemporary()
            let error = environment.engine.loadInstalled(paths: environment.paths, toolkit: environment.updater.toolkit)
            if environment.intel.index == nil { environment.intel.loadSaved(paths: environment.paths, sources: sources) }
            return (AVStateFile(url: environment.paths.stateFile).load(),
                    AVScanHistoryStore(url: environment.paths.historyFile).load(),
                    AVOpenThreats.load(from: environment.paths.lastThreatsFile),
                    error.map { AVDefinitionsUpdater.describeCompileFailure($0, hadPrevious: false) },
                    AVJSONFile.load([AVShieldRecord].self, from: environment.paths.shieldLogFile) ?? [])
        }
        definitionsState = loaded.0
        history = loaded.1
        if let open = loaded.2 { mergeThreats(open.threats) }
        engineProblem = loaded.3
        shieldRecords = loaded.4
        engineChanged()
        if let installed = definitionsState.installed, loaded.3 != nil || installed.compiledByBuild != AVAppBuild.current {
            // Compiled by another version of Mac Cleaner, or unreadable: compile the downloaded files again.
            updateDefinitions(trigger: .rebuild)
        }
        await reloadChest()
        refreshShields()
        scheduleAutomaticUpdates()
        refreshOpenAtLoginStatus()
        await refreshTools()
    }

    /// The engine was installed or removed (here, by an update, or by another part of the app).
    private func engineChanged() {
        hasDefinitions = environment.engine.hasDefinitions
        engineSummary = environment.engine.summary
        intelIndicatorCount = environment.intel.index?.indicatorCount ?? 0
        if hasDefinitions { engineProblem = nil }
    }

    // MARK: - Protection state

    var activeThreatCount: Int { threats.count }

    var definitionsInstalled: Bool { hasDefinitions || definitionsState.installed != nil }

    var isRealTimeProtectionOn: Bool { settings.isRealTimeProtectionOn(definitionsInstalled: definitionsInstalled) }

    var protectionState: ProtectionState {
        if activeThreatCount > 0 { return .threats }
        if !definitionsInstalled { return .notSetUp }
        return attentionReasons.isEmpty ? .protected : .attention
    }

    /// Why the state is "Attention needed", most important first.
    var attentionReasons: [String] {
        var reasons: [String] = []
        if let engineProblem, !hasDefinitions { reasons.append(engineProblem) }
        if !isRealTimeProtectionOn { reasons.append("Real-time protection is off.") }
        if let age = definitionsAgeDays, age >= 7 { reasons.append("Virus definitions are \(age) days old.") }
        if !shieldStatistics.deniedFolders.isEmpty, isRealTimeProtectionOn {
            let names = shieldStatistics.deniedFolders.map { PathUtilities.abbreviate($0) }.joined(separator: ", ")
            reasons.append("Mac Cleaner isn't allowed to read \(names).")
        }
        return reasons
    }

    /// One line under the status title.
    var statusExplanation: String {
        switch protectionState {
        case .protected:
            return "Real-time protection is on and virus definitions are up to date."
        case .attention:
            return attentionReasons.first ?? "Some protection settings need a look."
        case .threats:
            return activeThreatCount == 1 ? "1 threat is waiting for your decision." : "\(activeThreatCount) threats are waiting for your decision."
        case .notSetUp:
            return "Download the free virus definitions to scan for malware. Until then, scans use only built-in test signatures and Mac Cleaner's adware rules."
        }
    }

    /// When the definitions last changed.
    var definitionsUpdatedAt: Date? { definitionsState.lastUpdated ?? definitionsState.installed?.compiledAt }

    var definitionsAgeDays: Int? {
        guard let date = definitionsState.lastSuccessfulCheck ?? definitionsUpdatedAt else { return nil }
        return Int(Date().timeIntervalSince(date) / 86_400)
    }

    /// "Definitions updated 2 h ago" or "Definitions not installed".
    var definitionsAgeText: String {
        guard definitionsInstalled else { return "Definitions not installed" }
        guard let date = definitionsUpdatedAt else { return "Definitions installed" }
        return "Definitions updated \(AVFormat.age(date))"
    }

    var signatureCount: Int? { engineSummary?.signatureCount ?? definitionsState.installed?.summary.signatureCount }

    var lastScan: AVScanSummary? { history.first }

    var chestCount: Int { chestItems.count }

    // MARK: - Definitions

    /// The explicit first download.
    func installDefinitions() {
        updateDefinitions(trigger: .firstInstall)
    }

    /// "Update Now" (or an automatic check).
    func updateDefinitions(trigger: AVDefinitionsUpdater.Trigger = .manual) {
        guard !isUpdatingDefinitions else { return }
        isUpdatingDefinitions = true
        if trigger != .automatic {
            updateProblem = nil
            updateMessage = nil
        }
        updateProgress = trigger == .rebuild
            ? AVUpdateProgress(phase: .compiling, message: "Preparing the virus definitions for scanning…")
            : AVUpdateProgress(phase: .checking, message: "Checking for new virus definitions…")
        let snapshot = settings.snapshot
        Task {
            let outcome = await updater.update(trigger: trigger, settings: snapshot) { progress in
                Task { @MainActor in
                    guard self.isUpdatingDefinitions else { return }
                    self.updateProgress = progress
                }
            }
            apply(outcome, trigger: trigger)
        }
    }

    private func apply(_ outcome: AVDefinitionsUpdater.Outcome, trigger: AVDefinitionsUpdater.Trigger) {
        let firstInstall = !definitionsInstalled && outcome.state.installed != nil
        isUpdatingDefinitions = false
        updateProgress = nil
        definitionsState = outcome.state
        if let engine = outcome.engine {
            environment.engine.install(engine, compiledAt: outcome.state.installed?.compiledAt)
            if trigger == .rebuild {
                services.logger.info("Antivirus: compiled the virus definitions again for this version (\(engine.summary.signatureCount) signatures)", category: AVLog.category)
            } else {
                let versions = AVScanService.describe(engine.summary) ?? "New definitions"
                eventLog.post(ProtectionEvent(kind: .definitionsUpdated, severity: .info, title: "Virus definitions updated",
                                              detail: "\(versions) · \(NumberFormatting.count(engine.summary.signatureCount)) signatures",
                                              section: .antivirus))
                services.logger.info("Antivirus: installed new virus definitions (\(engine.summary.signatureCount) signatures)", category: AVLog.category)
            }
        }
        if outcome.intelChanged { environment.intel.install(outcome.intel) }
        engineChanged()
        if trigger == .rebuild {
            if let problem = outcome.problem { updateProblem = problem }
        } else if trigger != .automatic || !definitionsInstalled {
            updateProblem = outcome.problem ?? (trigger == .automatic ? nil : outcome.skippedReason)
            updateMessage = outcome.installedNewDatabase ? "The virus definitions were updated." : (outcome.problem == nil && outcome.skippedReason == nil ? "The virus definitions are up to date." : nil)
        }
        if let problem = outcome.problem { services.logger.warning("Antivirus: definitions update problem: \(problem)", category: AVLog.category) }
        if firstInstall && isRealTimeProtectionOn { requestNotificationPermission() }
        refreshShields()
        scheduleAutomaticUpdates(afterUpdate: true)
    }

    /// Automatic updates while the app runs (only after the first install, never in Low Power Mode).
    /// The first check comes shortly after launch; after any update, successful or not, the next one
    /// waits a full interval (a failure used to be retried within a minute, again and again).
    func scheduleAutomaticUpdates(afterUpdate: Bool = false) {
        autoUpdateTask?.cancel()
        autoUpdateTask = nil
        guard settings.automaticUpdates, definitionsState.firstInstallRequested else { return }
        let interval = environment.autoUpdateInterval
        let delay = afterUpdate ? interval : environment.firstAutoUpdateDelay
        autoUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled {
                if !ProcessInfo.processInfo.isLowPowerModeEnabled { await self?.automaticUpdateTick() }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func automaticUpdateTick() async {
        // The background agent may have installed new definitions meanwhile.
        let paths = environment.paths
        let state = await BackgroundWork.run(qos: .utility) { AVStateFile(url: paths.stateFile).load() }
        let loaded = environment.engine.loadedDatabaseDate
        let installed = state.installed?.compiledAt
        if (installed == nil) != (loaded == nil) || abs((installed ?? .distantPast).timeIntervalSince(loaded ?? .distantPast)) >= 1 {
            let environment = self.environment
            await BackgroundWork.run(qos: .utility) { _ = environment.engine.loadInstalled(paths: environment.paths, toolkit: environment.updater.toolkit) }
            definitionsState = state
            engineChanged()
        }
        updateDefinitions(trigger: .automatic)
    }

    /// Looks for freshclam and Homebrew (local checks only).
    func refreshTools() async {
        brewPath = AVFreshclamLocator.homebrewPath()
        if let path = await AVFreshclamLocator.locate(brew: brewPath) {
            freshclam = AVFreshclamTool(path: path, version: await AVFreshclamLocator.version(of: path))
        } else {
            freshclam = nil
        }
        toolsChecked = true
    }

    /// The updater the next update will use.
    var activeUpdater: AVUpdaterKind { settings.useFreshclam && freshclam != nil ? .freshclam : .builtIn }

    func setSource(_ keyPath: WritableKeyPath<AVSourceSelection, Bool>, enabled: Bool) {
        settings.sources[keyPath: keyPath] = enabled
        if !enabled, keyPath == \AVSourceSelection.urlhaus || keyPath == \AVSourceSelection.threatFox {
            let paths = environment.paths
            let intel = environment.intel
            let sources = settings.sources
            Task {
                _ = await BackgroundWork.run(qos: .utility) { intel.loadSaved(paths: paths, sources: sources) }
                engineChanged()
            }
        }
    }

    // MARK: - For other features

    /// Scans one file with the loaded engine. Returns nil when definitions aren't loaded.
    func scanFile(at path: String) async -> AVFileScanResult? {
        await environment.engine.scanFile(at: path, options: settings.snapshot.scanOptions)
    }

    /// Moves `path` into the Virus Chest (for other features, such as startup monitoring).
    /// Throws `AVChestError` when the item can't be moved; `suggestsFinder` errors mean an
    /// administrator is needed.
    @discardableResult
    func moveToVirusChest(path: String, reason: String) async throws -> AVChestItem {
        let request = AVQuarantineRequest(path: path, expected: FileSnapshot.capture(path: path), signatureName: reason,
                                          category: .malware, sha256: AVFileHasher.sha256(path: path), source: .scan)
        let item = try await chest.quarantine(request)
        await reloadChest()
        eventLog.post(ProtectionEvent(kind: .threatQuarantined, severity: .info,
                                                       title: "“\(item.name)” moved to the Virus Chest", detail: reason, path: path, section: .antivirus))
        return item
    }

    func reloadChest() async {
        chestItems = await chest.items()
    }

    /// Adds threats without duplicates, newest knowledge first.
    func mergeThreats(_ incoming: [AVThreat]) {
        var byID = Dictionary(threats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for threat in incoming where FileManager.default.fileExists(atPath: threat.path) || threat.ruleMatch != nil {
            byID[threat.id] = threat
        }
        threats = byID.values.sorted { lhs, rhs in
            lhs.category != rhs.category ? lhs.category > rhs.category : lhs.detectedAt > rhs.detectedAt
        }
    }

    func removeThreats(where predicate: (AVThreat) -> Bool) {
        threats.removeAll(where: predicate)
        persistOpenThreats()
    }

    func persistOpenThreats() {
        let open = AVOpenThreats(kind: lastReport?.kind ?? .quick, date: Date(), threats: threats)
        let url = environment.paths.lastThreatsFile
        Task.detached(priority: .utility) { open.save(to: url) }
    }

    func setBusy(_ id: String, _ busy: Bool) {
        if busy { busyThreatIDs.insert(id) } else { busyThreatIDs.remove(id) }
    }

    func setChestBusy(_ id: String, _ busy: Bool) {
        if busy { busyChestIDs.insert(id) } else { busyChestIDs.remove(id) }
    }

    func setReport(_ report: AVScanReport?) { lastReport = report }
    func setHistory(_ summaries: [AVScanSummary]) { history = summaries }
    func setScanning(_ scanning: Bool, progress: AVScanProgress?) {
        isScanning = scanning
        scanProgress = progress
    }
    func setScanProgress(_ progress: AVScanProgress) { if isScanning { scanProgress = progress } }
    func setTesting(_ testing: Bool, result: AVProtectionTestResult?) {
        isTestingProtection = testing
        if let result { testResult = result }
    }
    func setShieldStatistics(_ statistics: AVFileShield.Statistics) { shieldStatistics = statistics }
    func addShieldRecord(_ record: AVShieldRecord) {
        shieldRecords.insert(record, at: 0)
        if shieldRecords.count > 50 { shieldRecords.removeLast(shieldRecords.count - 50) }
        let records = shieldRecords
        let url = environment.paths.shieldLogFile
        Task.detached(priority: .utility) { try? AVJSONFile.save(records, to: url) }
    }
    func setOpenAtLoginStatus(_ status: AVLoginItemController.Status) { openAtLoginStatus = status }

    var primaryAlertPresenter: UUID? { alertPresenters.first }

    func registerAlertPresenter(_ id: UUID) {
        if !alertPresenters.contains(id) { alertPresenters.append(id) }
    }

    func unregisterAlertPresenter(_ id: UUID) {
        alertPresenters.removeAll { $0 == id }
    }

    /// Number of folders the File Shield watches.
    var watchedFolderCount: Int { AVFileShield.Configuration.standardFolders(home: environment.home).count }

    func showError(_ error: Error, path: String? = nil) {
        errorMessage = error.localizedDescription
        errorPath = (error as? AVChestError)?.suggestsFinder == true ? path : nil
    }
}
