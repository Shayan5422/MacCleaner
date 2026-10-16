import AppKit
import Foundation
import Observation

extension AntivirusViewModel {
    // MARK: - Real-time protection

    func setRealTimeProtection(_ enabled: Bool) {
        settings.realTimeProtectionChoice = enabled
        services.logger.info("Antivirus: real-time protection turned \(enabled ? "on" : "off")", category: AVLog.category)
        refreshShields()
        if enabled { requestNotificationPermission() }
    }

    /// Detections are announced with notifications; macOS asks once.
    func requestNotificationPermission() {
        let notifications = services.notifications
        Task { _ = await notifications.requestAuthorization() }
    }

    func setDownloadShield(_ enabled: Bool) {
        settings.downloadShield = enabled
        refreshShields()
    }

    /// Starts, reconfigures or stops the File Shield to match the settings.
    func refreshShields() {
        guard environment.startsShields else { return }
        guard isRealTimeProtectionOn else {
            shield?.stop()
            shield = nil
            setShieldStatistics(AVFileShield.Statistics())
            return
        }
        let configuration = shieldConfiguration()
        if let shield {
            shield.reconfigure(configuration)
        } else {
            let engine = environment.engine
            let intel = environment.intel
            let created = AVFileShield(source: environment.makeEventSource(), scanner: { engine.activeScanner }, intel: { intel.index },
                                       configuration: configuration) { [weak self] notice in
                Task { @MainActor [weak self] in self?.handle(notice) }
            }
            if created.start() {
                shield = created
                services.logger.info("Antivirus: File Shield started for \(configuration.folders.count) folders", category: AVLog.category)
            } else {
                services.logger.error("Antivirus: the File Shield couldn't start watching folders", category: AVLog.category)
            }
        }
        setShieldStatistics(shield?.statistics ?? AVFileShield.Statistics())
    }

    func shieldConfiguration() -> AVFileShield.Configuration {
        let snapshot = settings.snapshot
        var exclusions = services.settings.exclusions
        for path in snapshot.exclusions.paths { exclusions.add(path) }
        var configuration = AVFileShield.Configuration(folders: AVFileShield.Configuration.standardFolders(home: environment.home),
                                                       downloadsFolder: environment.home + "/Downloads")
        configuration.checksDownloads = snapshot.downloadShield
        configuration.options = snapshot.scanOptions
        configuration.exclusions = exclusions
        configuration.skippedRoots = Array(Set([environment.paths.root.path, environment.paths.rootPath]))
        configuration.allowedHashes = snapshot.allowedHashSet
        return configuration
    }

    /// The shield runs off the main thread; its reports arrive here.
    func handle(_ notice: AVShieldNotice) {
        switch notice {
        case .activity:
            if let shield { setShieldStatistics(shield.statistics) }
        case .accessDenied(let folder):
            if let shield { setShieldStatistics(shield.statistics) }
            services.logger.warning("Antivirus: the File Shield can't read a protected folder (\(PathUtilities.abbreviate(folder)))", category: AVLog.category)
        case .detection(let threat, let kind):
            if let shield { setShieldStatistics(shield.statistics) }
            respond(to: threat, from: kind)
        }
    }

    private func respond(to threat: AVThreat, from kind: AVShieldKind) {
        let snapshot = settings.snapshot
        services.logger.info("Antivirus: \(kind.title) detected \(threat.category.badgeTitle)", category: AVLog.category)
        guard AVAutoQuarantine.applies(to: threat, settings: snapshot) else {
            mergeThreats([threat])
            persistOpenThreats()
            report(threat, kind: kind, action: .notified, detail: nil)
            return
        }
        Task {
            do {
                let item = try await chest.quarantine(AVQuarantineRequest(threat: threat))
                await reloadChest()
                report(threat, kind: kind, action: .quarantined, detail: item.name)
            } catch {
                mergeThreats([threat])
                persistOpenThreats()
                report(threat, kind: kind, action: .quarantineFailed, detail: error.localizedDescription)
            }
        }
    }

    /// Notification, in-app alert, activity feed and the Shields tab log.
    private func report(_ threat: AVThreat, kind: AVShieldKind, action: AVShieldRecord.Action, detail: String?) {
        let quarantined = action == .quarantined
        addShieldRecord(AVShieldRecord(id: threat.id + "|" + String(Int(threat.detectedAt.timeIntervalSince1970)), date: threat.detectedAt,
                                       shield: kind, path: threat.path, name: threat.name, category: threat.category, action: action, detail: detail))
        let title: String
        var message: String
        if threat.category == .maliciousDownload {
            title = "Download from a known malware site"
            message = "“\(threat.fileName)” came from \(threat.origin?.listedURL.flatMap { URL(string: $0)?.host } ?? "an address") listed by \(threat.origin?.intelMatch?.source ?? "abuse.ch")."
            eventLog.post(ProtectionEvent(kind: .downloadFlagged, severity: .suspicious, title: "“\(threat.fileName)” came from a known malware site",
                                                           detail: threat.origin?.intelMatch?.malware ?? threat.origin?.listedURL, path: threat.path, section: .antivirus))
        } else {
            title = quarantined ? "Threat blocked" : "Threat found"
            message = "“\(threat.fileName)” is \(threat.category == .testFile ? "the antivirus test file" : threat.category == .pua ? "potentially unwanted software" : "malware") (\(threat.name))."
            eventLog.post(ProtectionEvent(
                kind: quarantined ? .threatQuarantined : .threatFound,
                severity: quarantined ? .info : (threat.category == .malware ? .threat : .suspicious),
                title: Self.foundTitle(threat),
                detail: "\(threat.name) · \(quarantined ? "moved to the Virus Chest" : "waiting for your decision")",
                path: threat.path, section: .antivirus))
        }
        switch action {
        case .quarantined: message += " It was moved to the Virus Chest."
        case .notified: message += " Review it on the Antivirus page."
        case .quarantineFailed: message += " It couldn't be moved to the Virus Chest: \(detail ?? "unknown error")"
        }
        shieldAlert = AVShieldAlert(title: title, message: message, path: threat.path, wasQuarantined: quarantined)
        Task { await services.notifications.post(title: title, body: message, identifier: "antivirus.shield.\(threat.id)", section: .antivirus) }
    }

    // MARK: - Open at login

    func setOpenAtLogin(_ enabled: Bool) {
        let controller = AVLoginItemController()
        do {
            try controller.setOpenAtLogin(enabled)
            services.logger.info("Antivirus: open at login turned \(enabled ? "on" : "off")", category: AVLog.category)
        } catch {
            errorMessage = "macOS didn't change the login item: \(error.localizedDescription). You can change it in System Settings › General › Login Items."
        }
        refreshOpenAtLoginStatus()
    }

    func refreshOpenAtLoginStatus() {
        setOpenAtLoginStatus(AVLoginItemController().status)
    }

    func openLoginItemsSettings() {
        AVLoginItemController().openLoginItemsSettings()
    }

    // MARK: - Virus Chest

    /// Restores an item. When something exists at the original place, or the folder is gone,
    /// asks for a folder.
    func restore(_ item: AVChestItem, alwaysAllow: Bool = false, chooseFolder: Bool = false) {
        guard !busyChestIDs.contains(item.id) else { return }
        var folder: String?
        if chooseFolder {
            guard let chosen = services.permissions.chooseFolder(message: "Choose where to restore “\(item.name)”.", prompt: "Restore Here") else { return }
            folder = chosen.path
        }
        setChestBusy(item.id, true)
        Task {
            defer { setChestBusy(item.id, false) }
            do {
                let path = try await chest.restore(item, toFolder: folder)
                if alwaysAllow, let hash = item.sha256 {
                    settings.allow(sha256: hash, name: item.name, path: path, signatureName: item.signatureName)
                }
                await reloadChest()
                statusMessage = "“\(item.name)” was restored to \(PathUtilities.abbreviate((path as NSString).deletingLastPathComponent))."
                    + (alwaysAllow ? " It won't be reported again." : "")
            } catch AVChestError.destinationExists, AVChestError.originalFolderMissing {
                statusMessage = nil
                errorMessage = "“\(item.name)” can't go back to \(PathUtilities.abbreviate((item.originalPath as NSString).deletingLastPathComponent)) because something is already there or the folder is gone. Choose another folder."
                restoreNeedingFolder = item
            } catch {
                showError(error)
            }
        }
    }

    func deleteFromChest(_ item: AVChestItem) {
        chestItemToDelete = nil
        setChestBusy(item.id, true)
        Task {
            defer { setChestBusy(item.id, false) }
            do {
                try await chest.delete(item)
                await reloadChest()
                statusMessage = "“\(item.name)” was deleted permanently."
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - ClamAV tools

    /// Runs `brew install clamav` after the person confirmed it, with live output.
    func installClamAVWithHomebrew() {
        confirmsHomebrewInstall = false
        guard let brewPath, homebrewInstall?.isRunning != true else { return }
        let run = AVHomebrewInstallRun(brew: brewPath)
        homebrewInstall = run
        services.logger.info("Antivirus: installing ClamAV with Homebrew", category: AVLog.category)
        run.start { [weak self] succeeded in
            guard let self else { return }
            Task {
                await self.refreshTools()
                if succeeded, self.freshclam != nil { self.statusMessage = "ClamAV is installed. Mac Cleaner now updates the definitions with freshclam." }
            }
        }
    }
}

/// `brew install clamav` with its output shown live.
@MainActor
@Observable
final class AVHomebrewInstallRun: Identifiable {
    let id = UUID()
    let command: (executable: String, arguments: [String], display: String)
    private(set) var lines: [String] = []
    private(set) var isRunning = false
    private(set) var succeeded: Bool?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(brew: String) {
        command = AVHomebrew.installCommand(brew: brew)
    }

    var displayCommand: String { command.display }

    func start(onFinish: @escaping @MainActor (Bool) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        let command = self.command
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let process = Task.detached(priority: .userInitiated) { () -> CommandResult? in
            defer { continuation.finish() }
            return try? await AVStreamingCommand.run(command.executable, arguments: command.arguments, environment: AVHomebrew.environment(),
                                                     timeout: 60 * 60) { continuation.yield($0.text) }
        }
        task = Task { [weak self] in
            await withTaskCancellationHandler {
                for await line in stream { self?.append(line) }
            } onCancel: {
                process.cancel()
            }
            let result = await process.value
            guard let self else { return }
            let ok = result?.succeeded == true
            if result == nil { self.append("Homebrew couldn't be started or was stopped.") }
            self.isRunning = false
            self.succeeded = ok
            onFinish(ok)
        }
    }

    func cancel() { task?.cancel() }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 2_000 { lines.removeFirst(lines.count - 2_000) }
    }
}
