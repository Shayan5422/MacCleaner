import AppKit
import Darwin
import Foundation

/// A running app as seen by `NSWorkspace`, captured as a value.
struct PerformanceRunningApp: Sendable, Hashable {
    var pid: pid_t
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    /// Regular (Dock) or accessory (menu bar) apps. Agents and helpers are not user-facing.
    var isUserFacing: Bool
}

/// Running apps indexed for classifying processes.
struct PerformanceAppDirectory: Sendable {
    private(set) var byPID: [pid_t: PerformanceRunningApp] = [:]
    private(set) var userFacingByBundlePath: [String: PerformanceRunningApp] = [:]

    init(apps: [PerformanceRunningApp]) {
        for app in apps {
            byPID[app.pid] = app
            if app.isUserFacing, let path = app.bundlePath {
                userFacingByBundlePath[path] = app
            }
        }
    }

    @MainActor
    static func current() -> PerformanceAppDirectory {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> PerformanceRunningApp? in
            guard !app.isTerminated else { return nil }
            let path = app.bundleURL?.path
            return PerformanceRunningApp(
                pid: app.processIdentifier,
                name: app.localizedName ?? path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "App",
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: path,
                isUserFacing: app.activationPolicy == .regular || app.activationPolicy == .accessory
            )
        }
        return PerformanceAppDirectory(apps: apps)
    }
}

/// What a process is, from the point of view of what Mac Cleaner may do with it.
enum PerformanceProcessRole: Sendable, Hashable {
    /// Mac Cleaner itself.
    case thisApp
    /// Owned by another user or by macOS (root): no actions.
    case otherUser
    /// Essential to macOS or the login session: no actions.
    case protectedSystem
    /// A macOS component running for the current user (in /System, /usr…): no actions.
    case macOSComponent
    /// Web content process of Safari or an app showing web pages: no actions (close the tab instead).
    case webContent
    /// A user-facing app: Quit, and Force Quit after two confirmations.
    case app(PerformanceRunningApp)
    /// A helper process of a user-facing app: actions apply to the app.
    case appHelper(PerformanceRunningApp)
    /// The current user's background process outside system locations: Stop (SIGTERM) with a warning.
    case background
    /// Not enough information to decide (no executable path): no actions.
    case unknown

    var title: String {
        switch self {
        case .thisApp: return "Mac Cleaner"
        case .otherUser: return "System"
        case .protectedSystem, .macOSComponent: return "macOS"
        case .webContent: return "Web Content"
        case .app: return "App"
        case .appHelper: return "App Helper"
        case .background: return "Background"
        case .unknown: return "Process"
        }
    }

    /// The app that Quit / Force Quit act on.
    var actionableApp: PerformanceRunningApp? {
        switch self {
        case .app(let app), .appHelper(let app): return app
        default: return nil
        }
    }

    var canStopProcess: Bool {
        if case .background = self { return true }
        return false
    }
}

/// Rules for which processes Mac Cleaner may quit or stop. Everything not explicitly
/// allowed is left alone: other users' and root processes, launchd, WindowServer,
/// kernel_task, loginwindow, Finder, Dock, SystemUIServer, other parts of macOS, and
/// Mac Cleaner itself.
enum PerformanceProcessPolicy {
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "Spotlight", "WindowManager", "coreaudiod", "cfprefsd",
        "distnoted", "UserEventAgent", "securityd", "opendirectoryd", "logd", "mds", "mds_stores", "syslogd",
    ]

    /// Folders that only contain parts of macOS.
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/var/"]

    static let webContentPrefixes = ["com.apple.WebKit.", "com.apple.Safari."]

    static func isSystemPath(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") { return false }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }

    static let currentUID = getuid()
    static let ownPID = getpid()
    /// Mac Cleaner's own bundle (nil when not running from an app bundle, as in unit tests).
    static let ownBundlePath: String? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : nil

    static func role(
        of process: PerformanceProcess,
        apps: PerformanceAppDirectory,
        currentUID: uid_t = PerformanceProcessPolicy.currentUID,
        ownPID: pid_t = PerformanceProcessPolicy.ownPID,
        ownBundlePath: String? = PerformanceProcessPolicy.ownBundlePath
    ) -> PerformanceProcessRole {
        if process.pid == ownPID { return .thisApp }
        if let ownBundlePath, let bundle = process.appBundlePath, bundle == ownBundlePath { return .thisApp }
        if process.uid != currentUID { return .otherUser }
        if process.pid <= 1 || protectedNames.contains(process.name) { return .protectedSystem }
        if webContentPrefixes.contains(where: { process.name.hasPrefix($0) }) { return .webContent }

        if let app = apps.byPID[process.pid], app.isUserFacing {
            // Apps that are part of the macOS session (Finder, Dock, Control Center…) live in /System/Library.
            if let path = app.bundlePath, path.hasPrefix("/System/Library/") { return .protectedSystem }
            if let ownBundlePath, app.bundlePath == ownBundlePath { return .thisApp }
            return .app(app)
        }
        if let bundle = process.appBundlePath, let app = apps.userFacingByBundlePath[bundle], app.pid != process.pid {
            if bundle.hasPrefix("/System/Library/") { return .macOSComponent }
            return .appHelper(app)
        }
        guard let path = process.executablePath else { return .unknown }
        if isSystemPath(path) { return .macOSComponent }
        return .background
    }
}

/// Plain-language descriptions of macOS processes that are often busy.
enum PerformanceKnownProcesses {
    static func explanation(for name: String) -> String? {
        switch name {
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd":
            return "Spotlight is indexing files so searches stay fast. This settles down once indexing finishes, typically after big file changes or a macOS update."
        case "photoanalysisd", "mediaanalysisd", "photolibraryd":
            return "Photos is analyzing your library (people, objects, memories). It works mostly while your Mac is idle and stops when it's done."
        case "bird", "cloudd", "fileproviderd", "nsurlsessiond":
            return "iCloud is syncing files or data. It calms down when the sync is complete."
        case "backupd", "backupd-helper":
            return "Time Machine is backing up. Activity drops when the backup finishes."
        case "softwareupdated", "mobileassetd":
            return "macOS is downloading or preparing updates."
        case "XprotectService", "XProtect", "XProtectPluginService", "syspolicyd", "trustd":
            return "macOS is checking apps and files for security. This is usually brief."
        case "kernel_task":
            return "The macOS kernel. High numbers here can also mean macOS is keeping the CPU idle on purpose to control temperature."
        case "WindowServer":
            return "Draws everything on screen. It gets busier with many windows, animations, or external displays."
        default:
            return nil
        }
    }
}
