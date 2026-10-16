import Foundation
import Observation

/// The Guardian features' own settings, stored in `UserDefaults` under keys prefixed `guardian.`.
/// Pass a separate `UserDefaults` suite in tests.
@MainActor
@Observable
final class GuardianSettings {
    enum Key: String, CaseIterable, Sendable {
        case watchStartupItems = "guardian.startup.watch"
        case notifyNewStartupItems = "guardian.startup.notifyNewItems"
        case notifyOtherStartupChanges = "guardian.startup.notifyOtherChanges"
        case scanNewStartupItems = "guardian.startup.scanNewItems"
        case analyzeLogin = "guardian.login.analyze"
        case webShieldEnabled = "guardian.webShield.enabled"
        case webShieldNotifications = "guardian.webShield.notify"
        case webShieldDisabledBrowsers = "guardian.webShield.disabledBrowsers"
    }

    /// Compare startup items with the last check and record what was added, removed or changed.
    var watchStartupItems: Bool { didSet { store(.watchStartupItems, watchStartupItems) } }
    /// Notify when something new will start automatically (and when a program or signature changes).
    var notifyNewStartupItems: Bool { didSet { store(.notifyNewStartupItems, notifyNewStartupItems) } }
    /// Also notify when items are removed or turned on/off.
    var notifyOtherStartupChanges: Bool { didSet { store(.notifyOtherStartupChanges, notifyOtherStartupChanges) } }
    /// Let the antivirus check the program of a new startup item (when the engine is available).
    var scanNewStartupItems: Bool { didSet { store(.scanNewStartupItems, scanNewStartupItems) } }
    /// Work out what opened automatically at the last login.
    var analyzeLogin: Bool { didSet { store(.analyzeLogin, analyzeLogin) } }
    /// Watch browser history for known malware sites (only does something once threat feeds are loaded).
    var webShieldEnabled: Bool { didSet { store(.webShieldEnabled, webShieldEnabled) } }
    var webShieldNotifications: Bool { didSet { store(.webShieldNotifications, webShieldNotifications) } }
    /// `PrivacyBrowser.id`s the person excluded from the Web Shield.
    private(set) var webShieldDisabledBrowsers: Set<String> {
        didSet {
            defaults.set(webShieldDisabledBrowsers.sorted(), forKey: Key.webShieldDisabledBrowsers.rawValue)
            onChange?(.webShieldDisabledBrowsers)
        }
    }

    /// Called after a setting changes (the controller reconfigures the affected feature).
    @ObservationIgnored var onChange: ((Key) -> Void)?
    @ObservationIgnored let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.rawValue) == nil ? fallback : defaults.bool(forKey: key.rawValue)
        }
        watchStartupItems = bool(.watchStartupItems, true)
        notifyNewStartupItems = bool(.notifyNewStartupItems, true)
        notifyOtherStartupChanges = bool(.notifyOtherStartupChanges, false)
        scanNewStartupItems = bool(.scanNewStartupItems, true)
        analyzeLogin = bool(.analyzeLogin, true)
        webShieldEnabled = bool(.webShieldEnabled, true)
        webShieldNotifications = bool(.webShieldNotifications, true)
        webShieldDisabledBrowsers = Set(defaults.stringArray(forKey: Key.webShieldDisabledBrowsers.rawValue) ?? [])
    }

    func isBrowserWatched(_ browserID: String) -> Bool {
        !webShieldDisabledBrowsers.contains(browserID)
    }

    func setBrowser(_ browserID: String, watched: Bool) {
        if watched {
            webShieldDisabledBrowsers.remove(browserID)
        } else {
            webShieldDisabledBrowsers.insert(browserID)
        }
    }

    private func store(_ key: Key, _ value: Bool) {
        defaults.set(value, forKey: key.rawValue)
        onChange?(key)
    }
}
