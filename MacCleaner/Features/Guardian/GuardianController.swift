import Foundation
import Observation

/// The assistant that watches over the Mac while Mac Cleaner runs, with or without a window:
///
/// - **Startup Guard** (`startupGuard`): everything that starts automatically, what changed
///   (checked at launch, every ~10 minutes, and right away when a launch agent folder changes),
///   and what opened by itself at the last login.
/// - **Web Shield** (`webShield`): warns when a browser opened a site listed by the threat feeds.
///
/// Create it once (for example in `AppEnvironment`), set `navigate`, and call `start()` at launch.
/// Idle cost is negligible: FSEvents with latency, a 10-minute timer, and history polling only
/// while a watched browser runs and the threat feeds are loaded.
@MainActor
@Observable
final class GuardianController {
    let services: AppServices
    let eventLog: ProtectionEventLog
    let settings: GuardianSettings
    let startupGuard: StartupGuardModel
    let webShield: WebShieldModel

    private(set) var isRunning = false

    /// Opens a section of the main window (notifications, "Check my downloads", "Open Startup Items").
    @ObservationIgnored var navigate: ((AppSection) -> Void)? {
        didSet {
            startupGuard.navigate = navigate
            webShield.navigate = navigate
        }
    }

    /// Lets the antivirus engine scan the program of every new startup item. Return nil when nothing
    /// could be scanned. The coordinator adapts its engine, for example:
    /// `guardian.startupScanHook = { path in await engine.scan(path).map { GuardianScanVerdict(detections: $0.map(\.signatureName)) } }`
    var startupScanHook: GuardianStartupScanHook? {
        get { startupGuard.scanHook }
        set { startupGuard.scanHook = newValue }
    }

    convenience init(services: AppServices, eventLog: ProtectionEventLog = .shared) {
        self.init(services: services, eventLog: eventLog, settings: GuardianSettings(), storageDirectory: GuardianStorage.defaultDirectory)
    }

    /// - Parameter storageDirectory: where Guardian keeps its state; a temporary folder in tests, nil for memory only.
    init(services: AppServices, eventLog: ProtectionEventLog, settings: GuardianSettings, storageDirectory: URL?,
         scratchDirectory: URL = GuardianStorage.defaultScratchDirectory) {
        self.services = services
        self.eventLog = eventLog
        self.settings = settings
        self.startupGuard = StartupGuardModel(services: services, settings: settings, eventLog: eventLog, storageDirectory: storageDirectory)
        self.webShield = WebShieldModel(settings: settings, notifications: services.notifications, eventLog: eventLog,
                                        storageDirectory: storageDirectory, scratchDirectory: scratchDirectory)
        settings.onChange = { [weak self] key in self?.settingChanged(key) }
    }

    /// Starts watching (idempotent). Works without any window. Never starts inside the unit-test host.
    func start() {
        guard !isRunning, !GuardianRuntime.isTestHost else { return }
        isRunning = true
        startupGuard.start()
        webShield.start()
        services.logger.info("Guardian started (Startup Guard, Web Shield)", category: .app)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        startupGuard.stop()
        webShield.stop()
    }

    private func settingChanged(_ key: GuardianSettings.Key) {
        switch key {
        case .webShieldEnabled, .webShieldDisabledBrowsers, .webShieldNotifications:
            webShield.settingsChanged(key)
        case .watchStartupItems, .notifyNewStartupItems, .notifyOtherStartupChanges, .scanNewStartupItems, .analyzeLogin:
            startupGuard.settingsChanged(key)
        }
    }
}
