import Foundation
import Observation

/// App preferences, persisted in `UserDefaults`.
///
/// Background work never reads this object directly: it receives value
/// snapshots (`scanPreferences`, `PreferencesSnapshot`) so settings changed
/// mid-scan can't cause inconsistent results.
@MainActor
@Observable
final class SettingsManager {
    enum Key {
        static let junkCleanupMethod = "junkCleanupMethod"
        static let skipItemsInUse = "skipItemsInUse"
        static let confirmBeforeCleaning = "confirmBeforeCleaning"
        static let largeFileThresholdMB = "largeFileThresholdMB"
        static let oldFileAgeDays = "oldFileAgeDays"
        static let oldDownloadAgeDays = "oldDownloadAgeDays"
        static let logAgeDays = "logAgeDays"
        static let includeHiddenFiles = "includeHiddenFiles"
        static let exclusions = "exclusions"
        static let monitorRefreshInterval = "monitorRefreshInterval"
        static let showMenuBarExtra = "showMenuBarExtra"
        static let performanceAlertsEnabled = "performanceAlertsEnabled"
        static let cpuAlertThreshold = "cpuAlertThreshold"
        static let memoryPressureAlerts = "memoryPressureAlerts"
        static let lowDiskAlertGB = "lowDiskAlertGB"
        static let checkUpdatesOnline = "checkUpdatesOnline"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let lastSmartScanDate = "lastSmartScanDate"
        static let lastSmartScanReclaimable = "lastSmartScanReclaimable"
        /// Set once 2.0 has applied its menu bar default (see `init`).
        static let menuBarDefaultVersion = "menuBarDefaultVersion"
    }

    private let defaults: UserDefaults

    var junkCleanupMethod: CleanupMethod { didSet { defaults.set(junkCleanupMethod.rawValue, forKey: Key.junkCleanupMethod) } }
    var skipItemsInUse: Bool { didSet { defaults.set(skipItemsInUse, forKey: Key.skipItemsInUse) } }
    var confirmBeforeCleaning: Bool { didSet { defaults.set(confirmBeforeCleaning, forKey: Key.confirmBeforeCleaning) } }
    var largeFileThresholdMB: Int { didSet { defaults.set(largeFileThresholdMB, forKey: Key.largeFileThresholdMB) } }
    var oldFileAgeDays: Int { didSet { defaults.set(oldFileAgeDays, forKey: Key.oldFileAgeDays) } }
    var oldDownloadAgeDays: Int { didSet { defaults.set(oldDownloadAgeDays, forKey: Key.oldDownloadAgeDays) } }
    var logAgeDays: Int { didSet { defaults.set(logAgeDays, forKey: Key.logAgeDays) } }
    var includeHiddenFiles: Bool { didSet { defaults.set(includeHiddenFiles, forKey: Key.includeHiddenFiles) } }
    var exclusions: ExclusionList { didSet { saveExclusions() } }
    var monitorRefreshInterval: Double { didSet { defaults.set(monitorRefreshInterval, forKey: Key.monitorRefreshInterval) } }
    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Key.showMenuBarExtra) } }
    var performanceAlertsEnabled: Bool { didSet { defaults.set(performanceAlertsEnabled, forKey: Key.performanceAlertsEnabled) } }
    var cpuAlertThreshold: Double { didSet { defaults.set(cpuAlertThreshold, forKey: Key.cpuAlertThreshold) } }
    var memoryPressureAlerts: Bool { didSet { defaults.set(memoryPressureAlerts, forKey: Key.memoryPressureAlerts) } }
    var lowDiskAlertGB: Int { didSet { defaults.set(lowDiskAlertGB, forKey: Key.lowDiskAlertGB) } }
    /// Allow contacting update feeds and the App Store to check for app updates.
    var checkUpdatesOnline: Bool { didSet { defaults.set(checkUpdatesOnline, forKey: Key.checkUpdatesOnline) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }
    var lastSmartScanDate: Date? { didSet { defaults.set(lastSmartScanDate, forKey: Key.lastSmartScanDate) } }
    var lastSmartScanReclaimable: Int64 { didSet { defaults.set(lastSmartScanReclaimable, forKey: Key.lastSmartScanReclaimable) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snapshot = PreferencesSnapshot(defaults: defaults)
        junkCleanupMethod = snapshot.junkCleanupMethod
        skipItemsInUse = snapshot.skipItemsInUse
        confirmBeforeCleaning = defaults.object(forKey: Key.confirmBeforeCleaning) as? Bool ?? true
        largeFileThresholdMB = snapshot.largeFileThresholdMB
        oldFileAgeDays = snapshot.scan.oldFileAgeDays
        oldDownloadAgeDays = snapshot.scan.oldDownloadAgeDays
        logAgeDays = snapshot.scan.logAgeDays
        includeHiddenFiles = snapshot.scan.includeHiddenFiles
        exclusions = snapshot.scan.exclusions
        monitorRefreshInterval = defaults.object(forKey: Key.monitorRefreshInterval) as? Double ?? 2
        // On by default: closing the window keeps Mac Cleaner in the menu bar. 1.x saved the item as
        // off without anyone choosing it, so 2.0 turns it on once; a later "off" is kept.
        if defaults.integer(forKey: Key.menuBarDefaultVersion) < 2 {
            defaults.set(2, forKey: Key.menuBarDefaultVersion)
            defaults.set(true, forKey: Key.showMenuBarExtra)
        }
        showMenuBarExtra = defaults.object(forKey: Key.showMenuBarExtra) as? Bool ?? true
        performanceAlertsEnabled = defaults.bool(forKey: Key.performanceAlertsEnabled)
        cpuAlertThreshold = defaults.object(forKey: Key.cpuAlertThreshold) as? Double ?? 0.9
        memoryPressureAlerts = defaults.object(forKey: Key.memoryPressureAlerts) as? Bool ?? true
        lowDiskAlertGB = defaults.object(forKey: Key.lowDiskAlertGB) as? Int ?? 10
        checkUpdatesOnline = defaults.object(forKey: Key.checkUpdatesOnline) as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        lastSmartScanDate = defaults.object(forKey: Key.lastSmartScanDate) as? Date
        lastSmartScanReclaimable = (defaults.object(forKey: Key.lastSmartScanReclaimable) as? NSNumber)?.int64Value ?? 0
    }

    /// Value snapshot of scan-related settings for background work.
    var scanPreferences: ScanPreferences {
        ScanPreferences(
            exclusions: exclusions,
            largeFileThresholdBytes: Int64(largeFileThresholdMB) * 1_000_000,
            oldFileAgeDays: oldFileAgeDays,
            oldDownloadAgeDays: oldDownloadAgeDays,
            logAgeDays: logAgeDays,
            includeHiddenFiles: includeHiddenFiles
        )
    }

    func addExclusion(_ path: String) {
        exclusions.add(path)
    }

    func removeExclusion(_ path: String) {
        exclusions.remove(path)
    }

    func resetToDefaults() {
        for key in [Key.junkCleanupMethod, Key.skipItemsInUse, Key.confirmBeforeCleaning, Key.largeFileThresholdMB,
                    Key.oldFileAgeDays, Key.oldDownloadAgeDays, Key.logAgeDays, Key.includeHiddenFiles,
                    Key.monitorRefreshInterval, Key.performanceAlertsEnabled, Key.cpuAlertThreshold,
                    Key.memoryPressureAlerts, Key.lowDiskAlertGB, Key.checkUpdatesOnline] {
            defaults.removeObject(forKey: key)
        }
        let fresh = SettingsManager(defaults: defaults)
        junkCleanupMethod = fresh.junkCleanupMethod
        skipItemsInUse = fresh.skipItemsInUse
        confirmBeforeCleaning = fresh.confirmBeforeCleaning
        largeFileThresholdMB = fresh.largeFileThresholdMB
        oldFileAgeDays = fresh.oldFileAgeDays
        oldDownloadAgeDays = fresh.oldDownloadAgeDays
        logAgeDays = fresh.logAgeDays
        includeHiddenFiles = fresh.includeHiddenFiles
        monitorRefreshInterval = fresh.monitorRefreshInterval
        performanceAlertsEnabled = fresh.performanceAlertsEnabled
        cpuAlertThreshold = fresh.cpuAlertThreshold
        memoryPressureAlerts = fresh.memoryPressureAlerts
        lowDiskAlertGB = fresh.lowDiskAlertGB
        checkUpdatesOnline = fresh.checkUpdatesOnline
    }

    private func saveExclusions() {
        if let data = try? JSONEncoder().encode(exclusions) {
            defaults.set(data, forKey: Key.exclusions)
        }
    }
}

/// Read-only view of the stored preferences, usable from any thread (for
/// example by the background automation runner).
struct PreferencesSnapshot: Sendable {
    var junkCleanupMethod: CleanupMethod
    var skipItemsInUse: Bool
    var largeFileThresholdMB: Int
    var scan: ScanPreferences

    init(defaults: UserDefaults = .standard) {
        junkCleanupMethod = (defaults.string(forKey: SettingsManager.Key.junkCleanupMethod)).flatMap(CleanupMethod.init(rawValue:)) ?? .moveToTrash
        skipItemsInUse = defaults.object(forKey: SettingsManager.Key.skipItemsInUse) as? Bool ?? true
        largeFileThresholdMB = defaults.object(forKey: SettingsManager.Key.largeFileThresholdMB) as? Int ?? 500
        var scan = ScanPreferences()
        scan.largeFileThresholdBytes = Int64(largeFileThresholdMB) * 1_000_000
        scan.oldFileAgeDays = defaults.object(forKey: SettingsManager.Key.oldFileAgeDays) as? Int ?? 180
        scan.oldDownloadAgeDays = defaults.object(forKey: SettingsManager.Key.oldDownloadAgeDays) as? Int ?? 90
        scan.logAgeDays = defaults.object(forKey: SettingsManager.Key.logAgeDays) as? Int ?? 7
        scan.includeHiddenFiles = defaults.bool(forKey: SettingsManager.Key.includeHiddenFiles)
        if let data = defaults.data(forKey: SettingsManager.Key.exclusions),
           let list = try? JSONDecoder().decode(ExclusionList.self, from: data) {
            scan.exclusions = list
        }
        self.scan = scan
    }
}
