import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// What the menu bar item shows next to its icon.
enum MenuBarLabelStyle: String, CaseIterable, Identifiable, Sendable {
    case iconOnly, openPorts, cpu, freeDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .openPorts: return "Open ports"
        case .cpu: return "CPU"
        case .freeDisk: return "Free disk space"
        }
    }
}

/// Menu bar preferences that aren't part of `SettingsManager`.
@MainActor
@Observable
final class MenuBarPreferences {
    static let shared = MenuBarPreferences()

    enum Keys {
        static let labelStyle = "menuBar.labelStyle"
        static let hidesDockIcon = "menuBar.hidesDockIconWhenWindowClosed"
    }

    var labelStyle: MenuBarLabelStyle {
        didSet { defaults.set(labelStyle.rawValue, forKey: Keys.labelStyle) }
    }

    /// Hide the Dock icon while no window is open (the app keeps running in the menu bar).
    var hidesDockIconWhenWindowClosed: Bool {
        didSet {
            defaults.set(hidesDockIconWhenWindowClosed, forKey: Keys.hidesDockIcon)
            AppPresence.shared.updateActivationPolicy()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        labelStyle = defaults.string(forKey: Keys.labelStyle).flatMap(MenuBarLabelStyle.init(rawValue:)) ?? .openPorts
        hidesDockIconWhenWindowClosed = defaults.object(forKey: Keys.hidesDockIcon) as? Bool ?? true
    }

    /// The menu bar item is on unless the person turned it off (`SettingsManager.showMenuBarExtra`).
    static var isMenuBarItemShown: Bool {
        UserDefaults.standard.object(forKey: SettingsManager.Key.showMenuBarExtra) as? Bool ?? true
    }
}

/// Keeps Mac Cleaner in the menu bar when its windows close: hides the Dock icon while
/// no window is open (if the person wants that) and brings it back with the first window.
@MainActor
final class AppPresence {
    static let shared = AppPresence()

    /// Opens SwiftUI scenes from AppKit code (Dock clicks, launching the app again).
    /// Registered by the menu bar label, which exists while the app runs in the menu bar.
    var openWindowAction: OpenWindowAction?
    /// The main window's navigation, so any view can open another section.
    weak var navigation: NavigationModel?
    /// The app was started by macOS as a login item: it starts in the menu bar.
    private(set) var launchedAsLoginItem = false
    private var hidMainWindowAtLaunch = false
    private var observers: [any NSObjectProtocol] = []
    private var pendingUpdate: DispatchWorkItem?

    /// Reads the launch Apple event (call from `applicationWillFinishLaunching`).
    func noteLaunchEvent(_ event: NSAppleEventDescriptor?) {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return }
        launchedAsLoginItem = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Whether the main window should close right after it appears at launch (once).
    func shouldHideMainWindowAtLaunch() -> Bool {
        guard launchedAsLoginItem, MenuBarPreferences.isMenuBarItemShown, !hidMainWindowAtLaunch else { return false }
        hidMainWindowAtLaunch = true
        return true
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.windowAppeared(window) }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            })
        }
    }

    /// Windows that make Mac Cleaner a regular app: titled, normal-level windows (main,
    /// Settings, About, the update window), also while minimized to the Dock.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.level == .normal
            && (window.isVisible || window.isMiniaturized)
    }

    func updateActivationPolicy() {
        let hasWindows = NSApp.windows.contains(where: Self.isAppWindow)
        let wantsAccessory = !hasWindows && MenuBarPreferences.isMenuBarItemShown && MenuBarPreferences.shared.hidesDockIconWhenWindowClosed
        let policy: NSApplication.ActivationPolicy = wantsAccessory ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular, hasWindows { NSApp.activate() }
    }

    /// Brings the main window forward, opening it if it was closed.
    func showMainWindow() {
        bringToFront()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(AppWindowID.main) == true && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: AppWindowID.main)
        }
    }

    /// Shows `section` in the main window.
    func openSection(_ section: AppSection) {
        navigation?.open(section)
        showMainWindow()
    }

    /// Opens one of the app's windows from the menu bar or AppKit code.
    func open(windowID: String, using openWindow: OpenWindowAction? = nil) {
        bringToFront()
        if windowID == AppWindowID.main {
            if let openWindow, openWindowAction == nil { openWindowAction = openWindow }
            showMainWindow()
        } else {
            (openWindow ?? openWindowAction)?(id: windowID)
        }
    }

    /// Windows of an accessory app don't come forward unless the app is regular and active.
    func bringToFront() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    /// Window notifications can arrive while AppKit or SwiftUI is still setting the window
    /// up, so the policy changes on the next turn of the run loop, never in the middle.
    private func windowAppeared(_ window: NSWindow?) {
        guard let window, Self.isAppWindow(window), NSApp.activationPolicy() != .regular else { return }
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() != .regular, NSApp.windows.contains(where: Self.isAppWindow) else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    /// A closing window is still visible when the notification arrives, so check a moment later.
    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { AppPresence.shared.updateActivationPolicy() } }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// "Open Mac Cleaner at login" with `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItemController {
    static let shared = LoginItemController()

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// On while registered, including while macOS waits for the person's approval.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            ActivityLogger.shared.info("Open at login turned \(enabled ? "on" : "off")", category: .app)
        } catch {
            errorMessage = error.localizedDescription
            ActivityLogger.shared.error("Open at login couldn't be changed: \(error.localizedDescription)", category: .app)
        }
        refresh()
    }

    var statusText: String {
        if let errorMessage { return "macOS refused the change: \(errorMessage)" }
        switch status {
        case .enabled: return "Mac Cleaner starts in the menu bar when you log in, without opening its window."
        case .requiresApproval: return "Waiting for your approval in System Settings › General › Login Items & Extensions."
        case .notFound: return "macOS can't register this copy of Mac Cleaner. Move it to the Applications folder, open it from there and try again."
        case .notRegistered: return "Mac Cleaner starts only when you open it."
        @unknown default: return "The login item status couldn't be read."
        }
    }

    var needsApproval: Bool { status == .requiresApproval }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
