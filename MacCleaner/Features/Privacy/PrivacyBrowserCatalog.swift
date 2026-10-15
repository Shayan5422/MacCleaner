import AppKit
import Foundation

/// A browser Mac Cleaner knows how to clean, and where it keeps its data.
struct PrivacyBrowser: Identifiable, Sendable, Hashable {
    enum Engine: String, Sendable, Hashable {
        case safari, chromium, firefox
    }

    var id: String
    var name: String
    var engine: Engine
    /// Every app that shares this data folder; the first one is the main app.
    var bundleIdentifiers: [String]
    /// Data folder relative to ~/Library/Application Support (Chromium and Firefox).
    var supportFolder: String?
    /// Cache folder relative to ~/Library/Caches (Chromium and Firefox).
    var cacheFolder: String?

    var primaryBundleIdentifier: String { bundleIdentifiers[0] }

    static let safari = PrivacyBrowser(id: "safari", name: "Safari", engine: .safari, bundleIdentifiers: ["com.apple.Safari"])
    static let chrome = PrivacyBrowser(id: "chrome", name: "Google Chrome", engine: .chromium, bundleIdentifiers: ["com.google.Chrome"], supportFolder: "Google/Chrome", cacheFolder: "Google/Chrome")
    static let firefox = PrivacyBrowser(
        id: "firefox", name: "Firefox", engine: .firefox,
        bundleIdentifiers: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
        supportFolder: "Firefox", cacheFolder: "Firefox"
    )
    static let edge = PrivacyBrowser(id: "edge", name: "Microsoft Edge", engine: .chromium, bundleIdentifiers: ["com.microsoft.edgemac"], supportFolder: "Microsoft Edge", cacheFolder: "Microsoft Edge")
    static let brave = PrivacyBrowser(id: "brave", name: "Brave", engine: .chromium, bundleIdentifiers: ["com.brave.Browser"], supportFolder: "BraveSoftware/Brave-Browser", cacheFolder: "BraveSoftware/Brave-Browser")
    static let arc = PrivacyBrowser(id: "arc", name: "Arc", engine: .chromium, bundleIdentifiers: ["company.thebrowser.Browser"], supportFolder: "Arc/User Data", cacheFolder: "Arc/User Data")
    static let vivaldi = PrivacyBrowser(id: "vivaldi", name: "Vivaldi", engine: .chromium, bundleIdentifiers: ["com.vivaldi.Vivaldi"], supportFolder: "Vivaldi", cacheFolder: "Vivaldi")
    static let opera = PrivacyBrowser(id: "opera", name: "Opera", engine: .chromium, bundleIdentifiers: ["com.operasoftware.Opera"], supportFolder: "com.operasoftware.Opera", cacheFolder: "com.operasoftware.Opera")
    static let chromium = PrivacyBrowser(id: "chromium", name: "Chromium", engine: .chromium, bundleIdentifiers: ["org.chromium.Chromium"], supportFolder: "Chromium", cacheFolder: "Chromium")

    static let all: [PrivacyBrowser] = [.safari, .chrome, .firefox, .edge, .brave, .arc, .vivaldi, .opera, .chromium]

    static func browser(withID id: String) -> PrivacyBrowser? {
        all.first { $0.id == id }
    }

    init(id: String, name: String, engine: Engine, bundleIdentifiers: [String], supportFolder: String? = nil, cacheFolder: String? = nil) {
        self.id = id
        self.name = name
        self.engine = engine
        self.bundleIdentifiers = bundleIdentifiers
        self.supportFolder = supportFolder
        self.cacheFolder = cacheFolder
    }

    func supportRoot(home: String) -> String? {
        supportFolder.map { home + "/Library/Application Support/" + $0 }
    }

    func cacheRoot(home: String) -> String? {
        cacheFolder.map { home + "/Library/Caches/" + $0 }
    }
}

/// Installed-app and running-app checks for browsers.
enum PrivacyBrowserApps {
    /// Location of each installed browser app, keyed by browser id.
    static func applicationPaths(for browsers: [PrivacyBrowser] = PrivacyBrowser.all) -> [String: String] {
        var paths: [String: String] = [:]
        let workspace = NSWorkspace.shared
        for browser in browsers {
            for identifier in browser.bundleIdentifiers {
                if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
                    paths[browser.id] = url.path
                    break
                }
            }
        }
        return paths
    }

    /// Ids of browsers with at least one running app.
    static func runningBrowserIDs(among browsers: [PrivacyBrowser] = PrivacyBrowser.all) -> Set<String> {
        var running = Set<String>()
        for browser in browsers where !runningApplications(of: browser).isEmpty {
            running.insert(browser.id)
        }
        return running
    }

    static func runningApplications(of browser: PrivacyBrowser) -> [NSRunningApplication] {
        browser.bundleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated }
    }

    /// Asks the browser to quit the same way ⌘Q does, so it can save its state
    /// and ask about open downloads. Returns false if it wasn't running.
    @discardableResult
    static func requestQuit(_ browser: PrivacyBrowser) -> Bool {
        let apps = runningApplications(of: browser)
        for app in apps { app.terminate() }
        return !apps.isEmpty
    }
}
