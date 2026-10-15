import Foundation

/// Shared services, created once at launch and handed to every feature's view
/// model (dependency injection instead of singletons, so tests can substitute
/// temporary stores).
@MainActor
final class AppServices {
    let settings: SettingsManager
    let permissions: PermissionManager
    let history: HistoryStore
    let cleanupEngine: CleanupEngine
    let scanner: FileSystemScanner
    let logger: ActivityLogger
    let notifications: NotificationService
    let policy: SafetyPolicy

    init(
        settings: SettingsManager = SettingsManager(),
        permissions: PermissionManager = PermissionManager(),
        history: HistoryStore = HistoryStore(),
        logger: ActivityLogger = .shared,
        notifications: NotificationService = .shared,
        policy: SafetyPolicy = .current
    ) {
        self.settings = settings
        self.permissions = permissions
        self.history = history
        self.logger = logger
        self.notifications = notifications
        self.policy = policy
        self.scanner = FileSystemScanner()
        self.cleanupEngine = CleanupEngine(policy: policy, history: history, logger: logger)
    }

    /// Cleanup options that respect the person's settings.
    ///
    /// - Parameter regenerableData: `true` for caches, logs and similar data, where
    ///   the "junk cleanup method" setting applies. Personal files, apps and app
    ///   data always go to the Trash so they can be recovered.
    func cleanupOptions(title: String, regenerableData: Bool, source: CleanupHistoryEntry.Source = .manual) -> CleanupOptions {
        var options = CleanupOptions(title: title, method: regenerableData ? settings.junkCleanupMethod : .moveToTrash, source: source)
        options.skipItemsInUse = settings.skipItemsInUse
        return options
    }
}
