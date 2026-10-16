import AppKit
import Foundation
import Observation

/// Where the update state is kept. `UserDefaults` conforms; tests and simulated
/// versions use `AppUpdateMemoryStore`, so they never write preference files.
protocol AppUpdateStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: AppUpdateStore {}

final class AppUpdateMemoryStore: AppUpdateStore {
    private var values: [String: Any] = [:]

    init() {}

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Mac Cleaner's own updates: the daily check, "Check for Updates…", "Skip This
/// Version" and "Download & Install".
///
/// Automatic checks run at most once a day (the first a little after launch), only
/// while "Check for Mac Cleaner updates automatically" is on, and stay silent unless
/// they find an update. Manual checks always report their result. Nothing is
/// downloaded or installed until the person chooses to.
@MainActor
@Observable
final class AppUpdateController {
    static let shared = AppUpdateController.makeShared()

    /// What the last manual check said (automatic checks don't change it).
    enum Phase: Equatable {
        case idle
        case checking
        case finished(AppUpdateCheckResult)
    }

    /// Progress of "Download & Install".
    enum InstallPhase: Equatable {
        case idle
        case working(AppUpdateInstaller.Stage)
        /// Installed; Mac Cleaner is about to restart.
        case relaunching(version: String)
        case failed(String)
        /// The verified disk image was saved and opened for the person to install it.
        case savedDiskImage(URL, reason: String)
    }

    enum Keys {
        static let lastCheckDate = "appUpdate.lastCheckDate"
        /// The newest release seen (JSON), kept while it's newer than this build.
        static let latestRelease = "appUpdate.latestRelease"
        static let skippedVersion = "appUpdate.skippedVersion"
        static let automaticChecks = "appUpdate.automaticChecks"
        static let all = [lastCheckDate, latestRelease, skippedVersion, automaticChecks]
    }

    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The first automatic check waits a little so it never competes with launch work.
    nonisolated static let firstCheckDelay: TimeInterval = 20
    /// How often the automatic loop re-evaluates whether a check is due.
    nonisolated static let pollInterval: TimeInterval = 60 * 60

    let currentVersion: String
    let currentBuild: String
    /// True for a simulated version (debug builds' `--pretend-version`): installing is off.
    let isSimulated: Bool

    /// The newest release that's newer than this build, even if it was skipped.
    private(set) var latestRelease: AppRelease?
    private(set) var skippedVersion: String?
    private(set) var phase: Phase = .idle
    /// Any check (manual or automatic) in flight.
    private(set) var isChecking = false
    private(set) var lastCheckDate: Date?
    private(set) var installPhase: InstallPhase = .idle
    /// The last automatic or manual check failed (shown quietly in Settings and About).
    private(set) var lastFailure: String?

    var automaticChecksEnabled: Bool {
        didSet { store.set(automaticChecksEnabled, forKey: Keys.automaticChecks) }
    }

    @ObservationIgnored private let transport: AppUpdateTransport
    @ObservationIgnored private let store: AppUpdateStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// "Check for Updates…" was chosen while an automatic check was running: report that one.
    @ObservationIgnored private var reportRunningCheck = false
    /// The bundle that "Download & Install" replaces.
    @ObservationIgnored var bundleURL: URL = Bundle.main.bundleURL
    /// Where "Download Disk Image" saves the verified image.
    @ObservationIgnored var downloadsFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    /// Ends the app after a successful install (the relauncher then reopens it).
    @ObservationIgnored var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    /// Receives an "update available" event for each new version found (the menu bar's Activity feed).
    @ObservationIgnored var eventLog: ProtectionEventLog?

    init(
        currentVersion: String = AppInfo.version,
        currentBuild: String = AppInfo.build,
        transport: AppUpdateTransport = .live,
        store: AppUpdateStore = UserDefaults.standard,
        isSimulated: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.transport = transport
        self.store = store
        self.isSimulated = isSimulated
        self.now = now
        automaticChecksEnabled = store.object(forKey: Keys.automaticChecks) as? Bool ?? true
        restore()
    }

    private static func makeShared() -> AppUpdateController {
        #if DEBUG
        // `--pretend-version 0.9.0` simulates an older build (screenshots, manual testing).
        // It never touches the saved state and can't install anything.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--pretend-version"), index + 1 < arguments.count,
           let version = AppVersion.normalized(arguments[index + 1]) {
            return AppUpdateController(currentVersion: version, currentBuild: "", store: AppUpdateMemoryStore(), isSimulated: true)
        }
        #endif
        let controller = AppUpdateController()
        controller.eventLog = .shared
        return controller
    }

    // MARK: - Derived state

    /// A newer release the person hasn't skipped.
    var availableUpdate: AppRelease? {
        guard let latestRelease, latestRelease.version != skippedVersion else { return nil }
        return latestRelease
    }

    func isSkipped(_ release: AppRelease) -> Bool {
        skippedVersion == release.version
    }

    var isInstalling: Bool {
        switch installPhase {
        case .working, .relaunching: return true
        default: return false
        }
    }

    /// The last manual check failed.
    var lastCheckFailed: Bool {
        if case .finished(.failed) = phase { return true }
        return false
    }

    // MARK: - Checking

    /// True when no check finished in the last `interval` (or the clock went backwards).
    nonisolated static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// Starts the background loop: the first check shortly after launch, then whenever a
    /// day has passed. `automaticChecksEnabled` is read before each check. Idempotent.
    func startAutomaticChecks() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstCheckDelay))
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkIfDue()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    func stopAutomaticChecks() {
        loopTask?.cancel()
        loopTask = nil
    }

    func checkIfDue() async {
        guard automaticChecksEnabled, Self.isDue(lastCheck: lastCheckDate, now: now()) else { return }
        await performCheck(manual: false)
    }

    /// "Check for Updates…": always reports up to date, an update, or what went wrong.
    func checkNow() {
        Task { await performCheck(manual: true) }
    }

    func performCheck(manual: Bool) async {
        if manual { phase = .checking }
        guard !isChecking else {
            if manual { reportRunningCheck = true }
            return
        }
        isChecking = true
        let checker = AppUpdateChecker(currentVersion: currentVersion, transport: transport)
        let result = await checker.check()
        isChecking = false
        let report = manual || reportRunningCheck
        reportRunningCheck = false
        apply(result, manual: report)
    }

    /// Records a result. A manual check also un-skips the version it finds.
    func apply(_ result: AppUpdateCheckResult, manual: Bool) {
        if result.isConclusive {
            let date = now()
            lastCheckDate = date
            store.set(date, forKey: Keys.lastCheckDate)
            lastFailure = nil
        }
        switch result {
        case .updateAvailable(let release):
            if let data = try? JSONEncoder().encode(release) { store.set(data, forKey: Keys.latestRelease) }
            if manual, skippedVersion == release.version {
                skippedVersion = nil
                store.removeObject(forKey: Keys.skippedVersion)
            }
            let isNew = latestRelease?.version != release.version
            latestRelease = release
            if isNew, !isSkipped(release) {
                eventLog?.post(ProtectionEvent(
                    kind: .appUpdateAvailable,
                    severity: .recommendation,
                    title: "Mac Cleaner \(release.version) is available",
                    detail: "You have \(currentVersion). Open Updates to install it.",
                    section: .updates
                ))
            }
        case .upToDate, .noReleases:
            store.removeObject(forKey: Keys.latestRelease)
            latestRelease = nil
        case .failed(let reason):
            lastFailure = reason
        }
        if manual {
            phase = .finished(result)
        } else if result.isConclusive, phase != .checking {
            phase = .idle
        }
    }

    // MARK: - Actions

    /// "Skip This Version": hides the notice until a newer version appears.
    func skip(_ release: AppRelease) {
        skippedVersion = release.version
        store.set(release.version, forKey: Keys.skippedVersion)
        if case .finished(.updateAvailable) = phase { phase = .idle }
    }

    func openReleasePage(_ release: AppRelease) {
        AppInfo.open(release.pageURL)
    }

    /// Downloads and verifies the release, replaces this copy of Mac Cleaner and restarts
    /// it. Where Mac Cleaner can't replace itself, the verified disk image is saved and
    /// opened instead.
    func downloadAndInstall(_ release: AppRelease) {
        guard installTask == nil else { return }
        guard !isSimulated else {
            installPhase = .failed(AppUpdateError.simulatedVersion.localizedDescription)
            return
        }
        let target: URL
        do {
            target = try AppUpdateInstaller.replaceableLocation(of: bundleURL)
        } catch {
            downloadDiskImage(release, reason: error.localizedDescription)
            return
        }
        let installer = AppUpdateInstaller(currentVersion: currentVersion, transport: transport)
        installPhase = .working(.downloading(received: 0, expected: release.diskImage?.size))
        let progress = progressHandler()
        installTask = Task { [weak self] in
            do {
                let app = try await installer.install(release, replacing: target, progress: progress)
                guard let self else { return }
                self.installTask = nil
                self.installPhase = .relaunching(version: app.version)
                ActivityLogger.shared.info("Mac Cleaner updated to \(app.version); restarting", category: .updates)
                do {
                    try AppUpdateInstaller.relaunch(target)
                } catch {
                    self.installPhase = .failed("Mac Cleaner \(app.version) is installed. Quit and open it again to finish. (\(error.localizedDescription))")
                    return
                }
                try? await Task.sleep(for: .milliseconds(800))
                self.terminate()
            } catch {
                self?.finishWithError(error)
            }
        }
    }

    /// Downloads and verifies the disk image, saves it to Downloads and opens it, for
    /// people who install updates themselves (or when the app's folder isn't writable).
    func downloadDiskImage(_ release: AppRelease, reason: String? = nil) {
        guard installTask == nil else { return }
        let installer = AppUpdateInstaller(currentVersion: currentVersion, transport: transport)
        let folder = downloadsFolder
        installPhase = .working(.downloading(received: 0, expected: release.diskImage?.size))
        let progress = progressHandler()
        installTask = Task { [weak self] in
            do {
                let image = try await installer.downloadVerifiedDiskImage(release, to: folder, progress: progress)
                guard let self else { return }
                self.installTask = nil
                NSWorkspace.shared.open(image)
                self.installPhase = .savedDiskImage(image, reason: reason ?? "")
                ActivityLogger.shared.info("Mac Cleaner \(release.version) disk image verified and saved", category: .updates)
            } catch {
                self?.finishWithError(error)
            }
        }
    }

    func cancelInstall() {
        guard case .working(let stage) = installPhase, stage != .installing else { return }
        installTask?.cancel()
    }

    /// Clears a finished or failed install so the window shows the release again.
    func resetInstall() {
        guard !isInstalling else { return }
        installPhase = .idle
    }

    /// Forwards the installer's progress to `installPhase` on the main actor.
    private func progressHandler() -> @Sendable (AppUpdateInstaller.Stage) -> Void {
        { [weak self] stage in
            Task { @MainActor in self?.report(stage) }
        }
    }

    private func report(_ stage: AppUpdateInstaller.Stage) {
        guard installTask != nil, case .working = installPhase else { return }
        installPhase = .working(stage)
    }

    private func finishWithError(_ error: Error) {
        installTask = nil
        if error is CancellationError || (error as? AppUpdateError) == .cancelled {
            installPhase = .idle
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        installPhase = .failed(message)
        ActivityLogger.shared.error("Mac Cleaner update failed: \(message)", category: .updates)
    }

    // MARK: - Text

    /// One line for About, Settings and the menu bar.
    var statusTitle: String {
        if let release = availableUpdate { return "Mac Cleaner \(release.version) is available" }
        switch phase {
        case .checking: return "Checking for updates…"
        case .finished(.failed): return "Couldn't check for updates"
        default: return "Mac Cleaner \(currentVersion)"
        }
    }

    var statusDetail: String {
        if availableUpdate != nil { return "You have \(currentVersion)." }
        switch phase {
        case .checking:
            return "Asking GitHub for the newest release…"
        case .finished(.failed(let reason)):
            return reason
        case .finished, .idle:
            if let date = lastCheckDate {
                return "You're up to date · checked \(DateFormatting.relative(date, to: now()))."
            }
            return automaticChecksEnabled ? "Updates are checked once a day." : "Automatic checks are off."
        }
    }

    // MARK: - Persistence

    /// Brings back an update found earlier, unless this build is already that new.
    private func restore() {
        lastCheckDate = store.object(forKey: Keys.lastCheckDate) as? Date
        skippedVersion = store.object(forKey: Keys.skippedVersion) as? String
        guard let data = store.object(forKey: Keys.latestRelease) as? Data,
              let release = try? JSONDecoder().decode(AppRelease.self, from: data) else { return }
        guard AppVersion.isNewer(release.version, than: currentVersion) else {
            store.removeObject(forKey: Keys.latestRelease)
            return
        }
        latestRelease = release
    }

    #if DEBUG
    /// Shows `release` as available without saving anything (previews and screenshots).
    func showForPreview(_ release: AppRelease?) {
        latestRelease = release
    }
    #endif
}
