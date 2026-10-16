import Foundation

/// Runs scans with the shared engine and the person's settings. Used by the Antivirus page,
/// Smart Scan and the background agent; saves each scan to the history.
struct AVScanService: Sendable {
    var paths: AVPaths
    var engine: AVEngineHolder = .shared
    var intel: AVIntelHolder = .shared
    var toolkit: any AVDatabaseToolkit = AVLiveToolkit()
    var settings: AVSettingsSnapshot
    /// The app-wide exclusions (Settings › Exclusions).
    var globalExclusions: ExclusionList
    var home: String = FileManager.default.homeDirectoryForCurrentUser.path

    /// Loads the installed engine and saved threat feeds if that hasn't happened yet.
    func prepare() async {
        let engine = self.engine
        let intel = self.intel
        let paths = self.paths
        let toolkit = self.toolkit
        let sources = settings.sources
        await BackgroundWork.run(qos: .userInitiated) {
            engine.loadInstalled(paths: paths, toolkit: toolkit)
            if intel.index == nil { intel.loadSaved(paths: paths, sources: sources) }
        }
    }

    func configuration(qos: QualityOfService) -> AVScanConfiguration {
        var exclusions = globalExclusions
        for path in settings.exclusions.paths { exclusions.add(path) }
        let index = intel.index
        var configuration = AVScanConfiguration(scanner: engine.activeScanner)
        configuration.options = settings.scanOptions
        configuration.exclusions = exclusions
        configuration.skippedRoots = Array(Set([paths.root.path, paths.rootPath]))
        configuration.allowedHashes = settings.allowedHashSet
        configuration.qualityOfService = qos
        configuration.downloadRoots = index == nil ? [] : [home + "/Downloads"]
        configuration.intel = index
        configuration.usedDefinitions = engine.hasDefinitions
        configuration.definitionsDescription = Self.describe(engine.summary)
        if qos == .utility { configuration.workerCount = max(1, configuration.workerCount / 2) }
        return configuration
    }

    func run(_ plan: AVScanPlan, qos: QualityOfService = .userInitiated, progress: @escaping @Sendable (AVScanProgress) -> Void = { _ in }) async -> AVScanReport {
        await prepare()
        let report = await AVScanCoordinator.run(plan: plan, configuration: configuration(qos: qos), progress: progress)
        record(report)
        return report
    }

    func record(_ report: AVScanReport) {
        AVScanHistoryStore(url: paths.historyFile).append(report.summary)
        AVOpenThreats(kind: report.kind, date: report.finishedAt, threats: report.threats).save(to: paths.lastThreatsFile)
    }

    /// "ClamAV main 63 · daily 28155".
    static func describe(_ summary: AVDatabaseSummary?) -> String? {
        guard let summary else { return nil }
        let versions = summary.clamavVersions.sorted { $0.key > $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        return versions.isEmpty ? nil : "ClamAV " + versions
    }
}

/// Which detections are moved to the Virus Chest without asking.
enum AVAutoQuarantine {
    /// Only signature detections, never apps or anything inside an app bundle (moving those can
    /// break software, so the person decides), and only as the settings allow.
    static func applies(to threat: AVThreat, settings: AVSettingsSnapshot) -> Bool {
        guard !threat.detections.isEmpty, threat.enclosingApp == nil, !threat.isAppBundle else { return false }
        // Only detections backed by signed definitions (ClamAV's RSA-signed databases, or the built-in
        // EICAR test) act on their own. abuse.ch's hash lists aren't signed, so a tampered list must not
        // be able to move legitimate files: their matches wait for the person.
        guard threat.detections.contains(where: { $0.source == .clamav || $0.source == .builtIn }) else { return false }
        switch threat.category {
        case .malware, .testFile: return settings.autoQuarantineMalware
        case .pua: return settings.puaAction == .quarantine
        case .maliciousDownload: return false
        }
    }
}

extension AVQuarantineRequest {
    init(threat: AVThreat, path: String? = nil) {
        let target = path ?? threat.path
        self.init(path: target, expected: target == threat.path ? threat.snapshot : FileSnapshot.capture(path: target),
                  signatureName: threat.name, category: threat.category, sha256: threat.sha256, source: threat.foundBy,
                  detectedFile: target == threat.path ? nil : threat.path, downloadURL: threat.origin?.downloadURL)
    }
}
