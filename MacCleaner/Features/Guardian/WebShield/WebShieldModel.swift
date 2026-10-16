import AppKit
import Foundation
import Observation

/// A visit to a known malware site, as the Web Shield keeps it: the host and the feed entry that
/// matched. The visited address itself isn't stored.
struct WebShieldWarning: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    /// When the Web Shield found it.
    var date: Date
    /// When the browser recorded the visit.
    var visitDate: Date?
    var host: String
    /// The feed's indicator (a malware URL or domain from the feed).
    var indicator: String
    var threatType: String
    var malware: String?
    /// Feed name, e.g. "URLhaus (abuse.ch)".
    var source: String
    var reference: URL?
    var browserID: String
    var browserName: String
    var profileName: String?

    var listingPhrase: String {
        WebShieldMatcher.listingPhrase(ThreatIntelMatch(indicator: indicator, threatType: threatType, malware: malware,
                                                        confidence: nil, source: source, firstSeen: nil, reference: reference))
    }
}

/// What the Web Shield keeps between launches: read positions and warnings.
struct WebShieldState: Codable, Sendable {
    var cursors: [String: WebShieldCursor] = [:]
    var warnings: [WebShieldWarning] = []
}

/// Warns when a browser opened a site listed by the threat feeds the Antivirus page loads
/// (abuse.ch URLhaus and ThreatFox).
///
/// Mac Cleaner can't block pages (that needs a browser or network extension). Instead, while a
/// browser runs, the Web Shield reads the visits added to its history since the last check, about
/// every 25 seconds, and checks them against the feeds on this Mac. It keeps only matches, never
/// sends or stores the addresses you visit, and does nothing until the feeds are loaded (no feeds
/// means "not checked", not "safe").
@MainActor
@Observable
final class WebShieldModel {
    struct BrowserState: Identifiable, Hashable {
        var browser: PrivacyBrowser
        var applicationPath: String?
        var isRunning: Bool
        var isWatched: Bool
        /// nil until the Web Shield has looked.
        var access: WebShieldAccess?
        var profileCount: Int = 0
        var lastCheck: Date?
        var lastError: String?

        var id: String { browser.id }
        var isInstalled: Bool { applicationPath != nil }
    }

    enum Status: Equatable {
        case off
        case waitingForFeeds
        /// On, no watched browser running.
        case idle
        case watching
        /// A watched browser runs, but macOS blocks its history (Full Disk Access needed).
        case needsAccess
    }

    private(set) var browsers: [BrowserState] = []
    private(set) var warnings: [WebShieldWarning] = []
    private(set) var lastCheck: Date?
    private(set) var feedsLoaded = false
    private(set) var isChecking = false
    private(set) var isRunning = false
    private(set) var isPolling = false

    var navigate: ((AppSection) -> Void)?

    @ObservationIgnored let settings: GuardianSettings
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let eventLog: ProtectionEventLog
    @ObservationIgnored private let stateURL: URL?
    @ObservationIgnored private let scratchDirectory: URL
    @ObservationIgnored private let home: String
    @ObservationIgnored private let lookupProvider: @Sendable () -> (any ThreatIntelLookup)?
    @ObservationIgnored let pollInterval: TimeInterval
    @ObservationIgnored private var cursors: [String: WebShieldCursor] = [:]
    @ObservationIgnored private var sourceCache: [String: Discovery] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var finalChecks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var checkAgain = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// The history databases found for one browser, remembered for a few minutes.
    struct Discovery: Sendable {
        var date: Date
        var sources: [WebShieldHistorySource]
        var access: WebShieldAccess
    }

    init(
        settings: GuardianSettings,
        notifications: NotificationService = .shared,
        eventLog: ProtectionEventLog = .shared,
        storageDirectory: URL? = GuardianStorage.defaultDirectory,
        scratchDirectory: URL = GuardianStorage.defaultScratchDirectory,
        home: String = LaunchdLocations.home,
        pollInterval: TimeInterval = 25,
        lookupProvider: @escaping @Sendable () -> (any ThreatIntelLookup)? = { ThreatIntelRegistry.shared.lookup }
    ) {
        self.settings = settings
        self.notifications = notifications
        self.eventLog = eventLog
        self.stateURL = storageDirectory?.appendingPathComponent("WebShield.json")
        self.scratchDirectory = scratchDirectory
        self.home = home
        self.pollInterval = pollInterval
        self.lookupProvider = lookupProvider
        let state = GuardianStorage.load(WebShieldState.self, from: stateURL) ?? WebShieldState()
        cursors = state.cursors
        warnings = state.warnings.sorted { $0.date > $1.date }
        feedsLoaded = lookupProvider() != nil
        browsers = PrivacyBrowser.all.map {
            BrowserState(browser: $0, applicationPath: nil, isRunning: false, isWatched: settings.isBrowserWatched($0.id))
        }
    }

    // MARK: - Status

    var status: Status {
        if !settings.webShieldEnabled { return .off }
        if !feedsLoaded { return .waitingForFeeds }
        let running = runningWatchedBrowsers
        if running.isEmpty { return .idle }
        return running.allSatisfy { $0.access == .needsFullDiskAccess } ? .needsAccess : .watching
    }

    var installedBrowsers: [BrowserState] { browsers.filter(\.isInstalled) }
    /// Watched browsers that are open now.
    var runningWatchedBrowsers: [BrowserState] { browsers.filter { $0.isInstalled && $0.isWatched && $0.isRunning } }
    /// Open browsers whose history is actually being checked.
    var watchedRunningBrowsers: [BrowserState] { runningWatchedBrowsers.filter { $0.access != .needsFullDiskAccess } }
    var browsersNeedingAccess: [BrowserState] { browsers.filter { $0.isInstalled && $0.isWatched && $0.access == .needsFullDiskAccess } }
    var recentWarnings: [WebShieldWarning] { Array(warnings.prefix(5)) }

    // MARK: - Lifecycle

    /// Starts watching browsers launch and quit (idempotent). Polling runs only while it's needed.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        GuardianStorage.clearScratch(scratchDirectory)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                let terminated = notification.name == NSWorkspace.didTerminateApplicationNotification
                MainActor.assumeIsolated { self?.applicationChanged(bundleIdentifier: bundleID, terminated: terminated) }
            }
            observers.append((workspaceCenter, token))
        }
        let feedToken = NotificationCenter.default.addObserver(forName: ThreatIntelRegistry.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.feedsChanged() }
        }
        observers.append((NotificationCenter.default, feedToken))
        reconfigure()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        stopPolling()
        finalChecks.values.forEach { $0.cancel() }
        finalChecks = [:]
    }

    /// Called by the controller when a Web Shield setting changes.
    func settingsChanged(_ key: GuardianSettings.Key) {
        switch key {
        case .webShieldEnabled:
            if settings.webShieldEnabled {
                // Visits made while it was off are never read: start over from now.
                cursors = [:]
                persist()
            }
        case .webShieldDisabledBrowsers:
            for index in browsers.indices {
                let watched = settings.isBrowserWatched(browsers[index].browser.id)
                if watched && !browsers[index].isWatched {
                    let id = browsers[index].browser.id
                    cursors = cursors.filter { !Self.sourceID($0.key, belongsTo: id) }
                    persist()
                }
                browsers[index].isWatched = watched
            }
        default:
            break
        }
        reconfigure()
    }

    private func feedsChanged() {
        let loaded = lookupProvider() != nil
        let becameAvailable = loaded && !feedsLoaded
        feedsLoaded = loaded
        reconfigure()
        // Fresh feeds: check right away instead of waiting for the next tick.
        if becameAvailable, isPolling { Task { await checkNow() } }
    }

    private func applicationChanged(bundleIdentifier: String?, terminated: Bool) {
        guard let bundleIdentifier, let browser = PrivacyBrowser.all.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) else { return }
        reconfigure()
        if terminated {
            // Browsers write their last visits when they quit: one more check shortly after.
            finalChecks[browser.id]?.cancel()
            finalChecks[browser.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { return }
                await self.checkNow(browserIDs: [browser.id])
                self.finalChecks[browser.id] = nil
            }
        }
    }

    /// Refreshes installed/running state and starts or stops polling.
    func reconfigure() {
        refreshBrowserStates()
        // Blocked browsers are polled too (a quick check), so granting Full Disk Access takes effect without a restart.
        let shouldPoll = isRunning && settings.webShieldEnabled && feedsLoaded && !runningWatchedBrowsers.isEmpty
        if shouldPoll { startPolling() } else { stopPolling() }
    }

    private func refreshBrowserStates() {
        let paths = PrivacyBrowserApps.applicationPaths()
        let running = PrivacyBrowserApps.runningBrowserIDs()
        for index in browsers.indices {
            let id = browsers[index].browser.id
            browsers[index].applicationPath = paths[id]
            browsers[index].isRunning = running.contains(id)
            browsers[index].isWatched = settings.isBrowserWatched(id)
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        isPolling = true
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let model = self { await model.checkNow() } else { return }
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    // MARK: - Checking

    /// Checks the watched browsers: by default those running now; `browserIDs` to check others
    /// (a browser that just quit, or every installed browser for "Check Now").
    func checkNow(browserIDs: Set<String>? = nil) async {
        guard settings.webShieldEnabled, let lookup = lookupProvider() else {
            feedsLoaded = lookupProvider() != nil
            return
        }
        feedsLoaded = true
        if isChecking {
            checkAgain = true
            return
        }
        isChecking = true
        defer { isChecking = false }
        refreshBrowserStates()

        let targets = browsers.filter { state in
            state.isInstalled && state.isWatched && (browserIDs.map { $0.contains(state.id) } ?? state.isRunning)
        }.map(\.browser)
        guard !targets.isEmpty else {
            lastCheck = Date()
            return
        }

        let cursors = self.cursors
        let cache = sourceCache
        let scratch = scratchDirectory.path
        let home = self.home
        let result = await BackgroundWork.run(qos: .utility) { () -> (discovered: [String: Discovery], outcome: WebShieldScanner.Outcome) in
            let now = Date()
            var discovered: [String: Discovery] = [:]
            var sources: [WebShieldHistorySource] = []
            for browser in targets {
                let found: Discovery
                if let cached = cache[browser.id], now.timeIntervalSince(cached.date) < 300, cached.access == .readable {
                    found = cached
                } else {
                    let fresh = WebShieldSources.discover(browser: browser, home: home)
                    found = Discovery(date: now, sources: fresh.sources, access: fresh.access)
                }
                discovered[browser.id] = found
                sources += found.sources
            }
            let outcome = WebShieldScanner.check(sources: sources, cursors: cursors, lookup: lookup, scratchDirectory: scratch, now: now)
            return (discovered, outcome)
        }
        for (browserID, discovery) in result.discovered {
            sourceCache[browserID] = discovery
            if let index = browsers.firstIndex(where: { $0.id == browserID }) {
                browsers[index].access = discovery.access
                browsers[index].profileCount = discovery.sources.count
                if discovery.sources.isEmpty { browsers[index].lastCheck = Date() }
            }
        }
        apply(result.outcome)
        if checkAgain {
            checkAgain = false
            Task { await self.checkNow(browserIDs: browserIDs) }
        }
    }

    /// "Check Now": every watched, installed browser, running or not.
    func checkAllNow() async {
        refreshBrowserStates()
        await checkNow(browserIDs: Set(browsers.filter { $0.isInstalled && $0.isWatched }.map(\.id)))
    }

    private func apply(_ outcome: WebShieldScanner.Outcome) {
        let now = Date()
        lastCheck = now
        for result in outcome.sources {
            if let cursor = result.cursor { cursors[result.source.id] = cursor }
            guard let index = browsers.firstIndex(where: { $0.id == result.source.browserID }) else { continue }
            browsers[index].lastCheck = now
            switch result.error {
            case nil:
                browsers[index].lastError = nil
                browsers[index].access = .readable
            case .needsFullDiskAccess?:
                browsers[index].access = .needsFullDiskAccess
                sourceCache[result.source.browserID] = nil
            case .missing?:
                sourceCache[result.source.browserID] = nil
            case .unreadable(let reason)?:
                browsers[index].lastError = reason
            case .unexpectedSchema?:
                browsers[index].lastError = "This version's history format isn't supported."
            }
        }
        report(outcome.matches, sources: outcome.sources.map(\.source))
        persist()
    }

    /// Records matches: a warning, an activity event and (when allowed) a notification, once per site every 6 hours.
    func report(_ matches: [WebShieldMatch], sources: [WebShieldHistorySource]) {
        guard !matches.isEmpty else { return }
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var reportedHosts = Set<String>()
        for found in matches {
            guard reportedHosts.insert(found.host).inserted else { continue }
            if warnings.contains(where: { $0.host == found.host && now.timeIntervalSince($0.date) < 6 * 3600 }) { continue }
            let source = sourcesByID[found.sourceID]
            let warning = WebShieldWarning(
                id: UUID(), date: now, visitDate: found.visitDate, host: found.host, indicator: found.match.indicator,
                threatType: found.match.threatType, malware: found.match.malware, source: found.match.source,
                reference: found.match.reference, browserID: source?.browserID ?? "", browserName: source?.browserName ?? "A browser",
                profileName: source?.profileName
            )
            warnings.insert(warning, at: 0)
            let phrase = warning.listingPhrase
            eventLog.post(ProtectionEvent(kind: .maliciousSite, severity: .threat,
                                          title: "Known malware site opened: \(warning.host)",
                                          detail: "\(phrase) · \(warning.browserName)",
                                          section: .antivirus))
            if settings.webShieldNotifications {
                let notifications = self.notifications
                let body = Self.notificationBody(host: warning.host, phrase: phrase)
                let identifier = "guardian.webShield." + warning.host
                Task { await notifications.post(title: "Known Malware Site", body: body, identifier: identifier, section: .antivirus) }
            }
        }
        if warnings.count > 100 { warnings.removeLast(warnings.count - 100) }
    }

    /// "chrome|Profile 1" belongs to "chrome" (but not "chromium|Default").
    nonisolated static func sourceID(_ sourceID: String, belongsTo browserID: String) -> Bool {
        sourceID == browserID || sourceID.hasPrefix(browserID + "|")
    }

    nonisolated static func notificationBody(host: String, phrase: String) -> String {
        "Warning: you opened a known malware site — \(host). \(phrase). Close the tab and don't download or open anything from it."
    }

    func removeWarning(_ warning: WebShieldWarning) {
        warnings.removeAll { $0.id == warning.id }
        persist()
    }

    func clearWarnings() {
        warnings = []
        persist()
    }

    func checkMyDownloads() {
        navigate?(.antivirus)
    }

    /// Writes at most twice a second, off the main thread.
    private func persist() {
        guard let url = stateURL else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await GuardianStorage.save(WebShieldState(cursors: self.cursors, warnings: self.warnings), to: url)
        }
    }
}
