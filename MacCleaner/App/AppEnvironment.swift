import Foundation
import Observation

/// Creates the shared services and every feature's view model once, and wires
/// navigation between features.
@MainActor
@Observable
final class AppEnvironment {
    let services: AppServices
    let navigation = NavigationModel()
    let monitor: PerformanceMonitor

    let dashboard: DashboardViewModel
    let smartScan: SmartScanViewModel
    let systemJunk: SystemJunkViewModel
    let privacy: PrivacyViewModel
    let developer: DeveloperToolsViewModel
    let storage: StorageAnalyzerViewModel
    let duplicates: DuplicatesViewModel
    let cloud: CloudStorageViewModel
    let uninstaller: UninstallerViewModel
    let updates: UpdatesViewModel
    let startup: StartupViewModel
    let performance: PerformanceViewModel
    let security: SecurityViewModel
    let antivirus: AntivirusViewModel
    let network: NetworkViewModel
    let guardian: GuardianController
    let automation: AutomationViewModel
    let history: HistoryViewModel

    init(services: AppServices = AppServices()) {
        self.services = services
        let monitor = PerformanceMonitor(settings: services.settings)
        self.monitor = monitor
        dashboard = DashboardViewModel(services: services, monitor: monitor)
        smartScan = SmartScanViewModel(services: services, providers: Self.smartScanProviders())
        systemJunk = SystemJunkViewModel(services: services, extraProviders: [LeftoversSmartScanProvider()])
        privacy = PrivacyViewModel(services: services)
        developer = DeveloperToolsViewModel(services: services)
        storage = StorageAnalyzerViewModel(services: services)
        duplicates = DuplicatesViewModel(services: services)
        cloud = CloudStorageViewModel(services: services)
        uninstaller = UninstallerViewModel(services: services)
        updates = UpdatesViewModel(services: services)
        startup = StartupViewModel(services: services)
        performance = PerformanceViewModel(services: services, monitor: monitor)
        security = SecurityViewModel(services: services)
        antivirus = AntivirusViewModel(services: services)
        network = NetworkViewModel(services: services)
        guardian = GuardianController(services: services)
        automation = AutomationViewModel(services: services, runnerFactory: { AppEnvironment.makeAutomationRunner() })
        history = HistoryViewModel(services: services)
    }

    /// Every feature that contributes to Smart Scan.
    nonisolated static func smartScanProviders() -> [any SmartScanProvider] {
        [
            SystemJunkSmartScanProvider(),
            LeftoversSmartScanProvider(),
            LargeFilesSmartScanProvider(),
            DuplicatesSmartScanProvider(),
            StartupSmartScanProvider(),
            SecuritySmartScanProvider(),
            PrivacySmartScanProvider(),
            DeveloperSmartScanProvider(),
        ]
    }

    /// The runner used by the background agent and by "Run Now".
    nonisolated static func makeAutomationRunner() -> AutomationRunner {
        var runner = AutomationRunner()
        runner.extraProviders = [
            AutomationCategory.developerCachesID: DeveloperSmartScanProvider(),
            AutomationCategory.browserCachesID: PrivacySmartScanProvider(),
        ]
        runner.securityScan = {
            // Background runs must never trigger privacy prompts: skip login items
            // (System Events) and the protected Downloads folder.
            let report = await SecurityScanner(loginItems: .skip, includesDownloads: false).scan { _, _ in }
            return AutomationSecurityResult(summary: report.summary, alertCount: report.threatCount + report.suspiciousCount)
        }
        return runner
    }

    /// The environment of the running app, shared by its windows, the menu bar item and the app delegate.
    static let shared = AppEnvironment()

    @ObservationIgnored private var startedBackgroundServices = false

    /// Starts the work that keeps running in the menu bar while no window is open: the port watch and
    /// Network Shield, and Guardian (Startup Guard, Web Shield). Called at launch; idempotent.
    func startBackgroundServices() {
        connectNavigation()
        guard !startedBackgroundServices else { return }
        startedBackgroundServices = true
        network.start()
        guardian.start()
    }

    /// Lets features open other sections (findings, dashboard tiles, notifications, the menu bar).
    /// Opening a section also brings the main window back if it was closed.
    func connectNavigation() {
        let navigation = self.navigation
        AppPresence.shared.navigation = navigation
        let open: (AppSection) -> Void = { AppPresence.shared.openSection($0) }
        dashboard.navigate = open
        dashboard.startSmartScan = { [weak self] in
            guard let self else { return }
            navigation.open(.smartScan)
            if smartScan.phase != .scanning { smartScan.start() }
        }
        smartScan.navigate = open
        uninstaller.navigate = open
        updates.navigate = open
        performance.openSection = open
        antivirus.navigate = open
        network.navigate = open
        guardian.navigate = open
        NotificationService.shared.onOpenSection = open
    }

    /// Small counters shown next to sidebar items.
    var sidebarBadges: [AppSection: String] {
        var badges: [AppSection: String] = [:]
        if smartScan.phase == .results, smartScan.totalReclaimable > 0 {
            badges[.smartScan] = ByteFormatting.string(smartScan.totalReclaimable)
        }
        if systemJunk.phase == .results, systemJunk.totalBytes > 0 {
            badges[.systemJunk] = ByteFormatting.string(systemJunk.totalBytes)
        }
        if updates.availableUpdateCount > 0 {
            badges[.updates] = "\(updates.availableUpdateCount)"
        }
        return badges
    }
}
