import AppKit
import Foundation

extension AntivirusViewModel {
    // MARK: - Starting scans

    func startQuickScan() {
        startScan(kind: .quick) {
            await AVScanPlanner.quickScan(sources: .live(includesPrivacyProtectedFolders: true, readsLoginItems: true))
        }
    }

    func startFullScan() {
        let home = environment.home
        let includeExternal = settings.includeExternalVolumesInFullScan
        startScan(kind: .full) {
            let volumes = includeExternal ? VolumeService.mountedVolumes().filter { !$0.isRootFileSystem && $0.isLocal } : []
            return AVScanPlanner.fullScan(home: home, externalVolumes: volumes)
        }
    }

    /// Scans files and folders chosen in an open panel or dropped on the page.
    func scan(paths: [String]) {
        let paths = paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        startScan(kind: .custom) { AVScanPlanner.custom(paths: paths) }
    }

    func chooseAndScan() {
        let urls = services.permissions.chooseItems(message: "Choose files or folders to scan for malware.")
        scan(paths: urls.map(\.path))
    }

    func scan(volume: VolumeInfo) {
        startScan(kind: .volume) { AVScanPlanner.volume(volume) }
    }

    /// Download Shield on demand: scans Downloads and checks where each file came from.
    func checkDownloads() {
        let home = environment.home
        startScan(kind: .downloads) { AVScanPlanner.downloads(home: home) }
    }

    /// External and removable drives that can be scanned.
    var scannableVolumes: [VolumeInfo] {
        VolumeService.mountedVolumes().filter { !$0.isRootFileSystem }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func makeScanService() -> AVScanService {
        AVScanService(paths: environment.paths, engine: environment.engine, intel: environment.intel, toolkit: environment.updater.toolkit,
                      settings: settings.snapshot, globalExclusions: services.settings.exclusions, home: environment.home)
    }

    private func startScan(kind: AVScanKind, plan makePlan: @escaping @Sendable () async -> AVScanPlan) {
        guard !isScanning else { return }
        setScanning(true, progress: AVScanProgress(kind: kind))
        tab = .scan
        statusMessage = nil
        let service = makeScanService()
        scanTask = Task {
            let plan = await makePlan()
            let report = await service.run(plan) { progress in
                Task { @MainActor in self.setScanProgress(progress) }
            }
            finishScan(report)
        }
    }

    private func finishScan(_ report: AVScanReport) {
        setScanning(false, progress: nil)
        setReport(report)
        removeThreats { $0.foundBy == .scan && FileManager.default.fileExists(atPath: $0.path) == false }
        mergeThreats(report.threats)
        persistOpenThreats()
        setHistory(AVScanHistoryStore(url: environment.paths.historyFile).load())
        engineChangedAfterScan()

        let summary = report.summary
        services.logger.info("Antivirus: \(report.kind.title) \(report.wasCancelled ? "stopped" : "finished"): \(report.filesScanned) files, \(report.threats.count) threats, \(report.skippedCount) skipped", category: AVLog.category)
        for threat in report.threats.prefix(10) {
            eventLog.post(ProtectionEvent(
                kind: .threatFound, severity: threat.category.severity == .threat ? .threat : .suspicious,
                title: Self.foundTitle(threat), detail: "\(threat.name) · waiting for your decision", path: threat.path, section: .antivirus))
        }
        eventLog.post(ProtectionEvent(
            kind: .scanCompleted, severity: report.threats.isEmpty ? .info : .threat,
            title: "\(report.kind.title) \(report.wasCancelled ? "stopped" : "finished")", detail: summary.resultLine, section: .antivirus))
        if !report.threats.isEmpty && !NSApplication.shared.isActive {
            let count = report.threats.count
            Task {
                await services.notifications.post(title: count == 1 ? "The virus scan found a threat" : "The virus scan found \(count) threats",
                                                  body: "Open Mac Cleaner to review \(count == 1 ? "it" : "them").",
                                                  identifier: "antivirus.scan", section: .antivirus)
            }
        }
    }

    private func engineChangedAfterScan() {
        // Scans load the engine on demand; keep the page's view of it current.
        if hasDefinitions != environment.engine.hasDefinitions {
            NotificationCenter.default.post(name: AVEngineHolder.didChangeNotification, object: nil)
        }
    }

    static func foundTitle(_ threat: AVThreat) -> String {
        switch threat.category {
        case .malware: return "Virus found in “\(threat.fileName)”"
        case .pua: return "Unwanted software in “\(threat.fileName)”"
        case .testFile: return "Test file detected: “\(threat.fileName)”"
        case .maliciousDownload: return "“\(threat.fileName)” came from a known malware site"
        }
    }

    // MARK: - Results

    /// Moves a threat (or the app that contains it) into the Virus Chest.
    func moveToChest(_ threat: AVThreat, wholeApp: Bool = false) {
        let target = wholeApp ? (threat.enclosingApp ?? threat.path) : threat.path
        guard !busyThreatIDs.contains(threat.id) else { return }
        setBusy(threat.id, true)
        selectedThreat = nil
        Task {
            defer { setBusy(threat.id, false) }
            do {
                let item = try await chest.quarantine(AVQuarantineRequest(threat: threat, path: target))
                removeThreats { $0.id == threat.id || (wholeApp && PathUtilities.isSameOrDescendant($0.path, of: target)) }
                await reloadChest()
                markQuarantinedInHistory(1)
                statusMessage = "“\(item.name)” was moved to the Virus Chest. It can't run there, and you can restore it if needed."
                eventLog.post(ProtectionEvent(kind: .threatQuarantined, severity: .info,
                                                               title: "“\(item.name)” moved to the Virus Chest", detail: threat.name,
                                                               path: threat.path, section: .antivirus))
            } catch {
                showError(error, path: target)
            }
        }
    }

    /// Moves every threat that doesn't need a separate decision (items inside apps do).
    func moveAllToChest() {
        let candidates = threats.filter { $0.enclosingApp == nil && !busyThreatIDs.contains($0.id) }
        let skipped = threats.count - candidates.count
        guard !candidates.isEmpty else { return }
        for threat in candidates { setBusy(threat.id, true) }
        Task {
            var moved = 0
            var failures: [String] = []
            for threat in candidates {
                do {
                    _ = try await chest.quarantine(AVQuarantineRequest(threat: threat))
                    moved += 1
                    removeThreats { $0.id == threat.id }
                    eventLog.post(ProtectionEvent(kind: .threatQuarantined, severity: .info,
                                                                   title: "“\(threat.fileName)” moved to the Virus Chest", detail: threat.name,
                                                                   path: threat.path, section: .antivirus))
                } catch {
                    failures.append("\(threat.fileName): \(error.localizedDescription)")
                }
                setBusy(threat.id, false)
            }
            await reloadChest()
            markQuarantinedInHistory(moved)
            var message = moved == 1 ? "1 threat was moved to the Virus Chest." : "\(moved) threats were moved to the Virus Chest."
            if skipped > 0 { message += " \(skipped) inside apps need your decision: choose “Move App to Virus Chest” for each." }
            statusMessage = moved > 0 || skipped > 0 ? message : nil
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    /// Hides a threat from the results this time only.
    func ignoreOnce(_ threat: AVThreat) {
        removeThreats { $0.id == threat.id }
        services.logger.info("Antivirus: a detection was ignored once", category: AVLog.category)
    }

    /// Adds the file's SHA-256 to the allow list (after confirmation in the view).
    func alwaysAllow(_ threat: AVThreat) {
        threatToAllow = nil
        Task {
            var hash = threat.sha256
            if hash == nil {
                let path = threat.path
                hash = await BackgroundWork.run(qos: .userInitiated) { AVFileHasher.sha256(path: path) }
            }
            guard let hash, settings.allow(sha256: hash, name: threat.fileName, path: threat.path, signatureName: threat.name) else {
                errorMessage = "The file couldn't be read, so it can't be added to the allow list."
                return
            }
            removeThreats { $0.sha256?.lowercased() == hash.lowercased() || $0.id == threat.id }
            statusMessage = "“\(threat.fileName)” will no longer be reported. You can remove it from the allow list in Settings › Antivirus."
            services.logger.info("Antivirus: a file was added to the allow list", category: AVLog.category)
        }
    }

    private func markQuarantinedInHistory(_ count: Int) {
        guard count > 0, var summary = lastReport?.summary else { return }
        let store = AVScanHistoryStore(url: environment.paths.historyFile)
        if let stored = store.load().first(where: { $0.id == summary.id }) { summary = stored }
        summary.quarantinedCount += count
        store.update(summary)
        setHistory(store.load())
    }

    func clearHistory() {
        AVScanHistoryStore(url: environment.paths.historyFile).clear()
        setHistory([])
    }

    // MARK: - Test protection

    /// Writes the EICAR test file into a new temporary folder (never Downloads), scans it,
    /// shows the result and deletes it.
    func testProtection() {
        guard !isTestingProtection else { return }
        setTesting(true, result: nil)
        let engine = environment.engine
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { () -> AVProtectionTestResult in
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Mac Cleaner Protection Test \(UUID().uuidString)", isDirectory: true)
                let file = folder.appendingPathComponent("eicar-test-file.txt")
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try AVEICAR.data.write(to: file, options: .withoutOverwriting)
                } catch {
                    // Writing the test file can be refused by another antivirus.
                    return AVProtectionTestResult(detected: false, signatureName: nil, usedDefinitions: engine.hasDefinitions, removedTestFile: true,
                                                  blockedByOtherSoftware: true, date: Date())
                }
                let scan = engine.activeScanner.scanFile(atPath: file.path, options: AVScanOptions())
                let vanished = !scan.isInfected && !FileManager.default.fileExists(atPath: file.path)
                try? FileManager.default.removeItem(at: folder)
                return AVProtectionTestResult(detected: scan.isInfected, signatureName: scan.detections.first?.signatureName,
                                              usedDefinitions: engine.hasDefinitions, removedTestFile: !FileManager.default.fileExists(atPath: file.path),
                                              blockedByOtherSoftware: vanished, date: Date())
            }
            setTesting(false, result: result)
            services.logger.info("Antivirus: protection test \(result.detected ? "detected" : "did not detect") the EICAR test file", category: AVLog.category)
        }
    }

    // MARK: - VirusTotal

    /// Opens the VirusTotal report page for a hash in the browser. Nothing is uploaded.
    func openVirusTotal(sha256: String) {
        guard AVAllowedHash.isValidSHA256(sha256), let url = URL(string: "https://www.virustotal.com/gui/file/\(sha256.lowercased())") else { return }
        NSWorkspace.shared.open(url)
    }
}
