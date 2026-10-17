import Foundation
import Observation
import SafariServices

/// Security checkup, Safari protection and link check.
///
/// The checkup reads what iOS lets an app see (passcode, Face ID, VPN, the Safari extension) and
/// compares the running iOS with Apple's update catalog. Safari protection downloads abuse.ch's
/// lists while the app is open, at most every 12 hours, and hands Safari the rules built from them.
@MainActor
@Observable
final class ProtectionModel {
    enum Status: Equatable, Sendable {
        case unknown
        case protected
        case attention(String)
    }

    /// What the link check found.
    enum LinkCheckOutcome: Equatable, Sendable {
        /// The text isn't a link or domain.
        case invalid
        case checked(CheckedLink, LinkVerdict)
        /// No lists on this device and none could be downloaded.
        case listsUnavailable(String)
    }

    // MARK: Security checkup (nil until checked)

    private(set) var passcode: PasscodeState?
    private(set) var biometrics: BiometricsState?
    private(set) var networkRoute: NetworkRouteState?
    private(set) var safariExtension: SafariExtensionState?
    private(set) var software: SoftwareUpdateState?
    /// When Apple's catalog was read.
    private(set) var softwareCheckedAt: Date?
    private(set) var isCheckingSoftware = false

    // MARK: Lists and Safari's rules

    private(set) var feedState: ProtectionFeedState
    private(set) var isUpdatingLists = false
    /// "Downloading the ThreatFox list…" while updating.
    private(set) var updateMessage: String?
    /// The last update's problem, for the person.
    private(set) var listProblem: String?
    /// Safari didn't accept the new rules.
    private(set) var safariReloadProblem: String?
    /// The link check's index, once loaded.
    private(set) var linkIndex: ThreatIndex?

    let device: DeviceInfo
    /// False when the App Group container is missing: Safari can't get the rules then.
    let canShareRulesWithSafari: Bool

    @ObservationIgnored private let storage: ProtectionStorage
    @ObservationIgnored private let transport: any FeedTransport
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let allowsNetwork: Bool
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var linkIndexTask: Task<ThreatIndex, Never>?
    @ObservationIgnored private var lastSoftwareFailure: Date?

    private static let catalogCacheKey = "protection.softwareCatalog"

    convenience init() {
        self.init(storage: .shared(), transport: URLSessionFeedTransport.shared, defaults: .standard,
                  device: .current(), allowsNetwork: !Self.isRunningTests)
    }

    init(storage: ProtectionStorage, transport: any FeedTransport, defaults: UserDefaults, device: DeviceInfo, allowsNetwork: Bool) {
        self.storage = storage
        self.transport = transport
        self.defaults = defaults
        self.device = device
        self.allowsNetwork = allowsNetwork
        canShareRulesWithSafari = storage.blockerListURL != nil
        feedState = storage.loadState()
    }

    // MARK: Summary

    var status: Status {
        ProtectionStatusRules.status(passcode: passcode, software: software, safari: safariExtension, systemName: systemName)
    }

    /// Whether the Safari content blocker is turned on in Settings, nil if not known yet.
    var safariProtectionEnabled: Bool? {
        switch safariExtension {
        case .on?: return true
        case .off?: return false
        case .unknown?, nil: return nil
        }
    }

    /// Whether this is the newest iOS Apple offers for the device, nil if not known.
    var systemUpToDate: Bool? { software?.isUpToDate }

    var passcodeSet: Bool? {
        switch passcode {
        case .set?: return true
        case .notSet?: return false
        case .unknown?, nil: return nil
        }
    }

    /// The update Apple offers, e.g. "27.0.2".
    var availableSystemVersion: String? {
        if case .updateAvailable(let version, _)? = software { return version.description }
        return nil
    }

    /// "iOS" or "iPadOS".
    var systemName: String { device.isPad ? "iPadOS" : "iOS" }
    var runningVersion: SystemVersion { SystemVersion(device.systemVersion) }

    /// When the lists behind Safari's rules were last checked.
    var listsUpdated: Date? { feedState.safariListsChecked }

    // MARK: Refresh

    /// Reads the checkup again (cheap) and the update catalog when the cached copy is older than 12
    /// hours. While Safari protection is on, starts downloading the lists when they're due.
    /// Overlapping calls share one refresh.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        passcode = SecurityChecks.passcode()
        biometrics = SecurityChecks.biometrics()
        networkRoute = SecurityChecks.networkRoute()
        safariExtension = await SecurityChecks.safariExtension()
        await checkSoftwareUpdate()
        if safariExtension == .on, safariListsNeedUpdate { startSafariListUpdate() }
    }

    private var safariListsNeedUpdate: Bool {
        let now = Date()
        return feedState.blocklist == nil || ThreatFeed.safariFeeds.contains {
            FeedUpdatePolicy.isDue(feedState[$0], hasData: storage.hasData($0), now: now, manual: false)
        }
    }

    // MARK: iOS version

    private func checkSoftwareUpdate() async {
        let now = Date()
        let model = device.modelIdentifier
        let cache = loadCatalogCache()
        if let cache, cache.isFresh(for: model, at: now) {
            software = .evaluate(running: runningVersion, releases: cache.releases)
            softwareCheckedAt = cache.fetchedAt
            return
        }
        // After a failure, wait a little before asking Apple again.
        if software != nil, let failure = lastSoftwareFailure, now.timeIntervalSince(failure) < 120 { return }
        guard allowsNetwork else { return }
        isCheckingSoftware = true
        defer { isCheckingSoftware = false }
        do {
            let releases = try await SoftwareCatalogClient.releases(for: model, transport: transport)
            let fetched = SoftwareCatalogCache(fetchedAt: Date(), model: model, releases: releases)
            saveCatalogCache(fetched)
            software = .evaluate(running: runningVersion, releases: releases)
            softwareCheckedAt = fetched.fetchedAt
            lastSoftwareFailure = nil
        } catch {
            lastSoftwareFailure = Date()
            // An older copy of the catalog still proves that an update is out.
            if let cache, cache.model == model,
               case .updateAvailable = SoftwareUpdateState.evaluate(running: runningVersion, releases: cache.releases) {
                software = .evaluate(running: runningVersion, releases: cache.releases)
                softwareCheckedAt = cache.fetchedAt
            } else {
                software = .couldNotCheck(SoftwareCatalogClient.problem(for: error))
                softwareCheckedAt = nil
            }
        }
    }

    private func loadCatalogCache() -> SoftwareCatalogCache? {
        defaults.data(forKey: Self.catalogCacheKey).flatMap { try? JSONDecoder().decode(SoftwareCatalogCache.self, from: $0) }
    }

    private func saveCatalogCache(_ cache: SoftwareCatalogCache) {
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.catalogCacheKey) }
    }

    // MARK: Lists

    /// "Update Now": every list, including the link check's, even before 12 hours have passed.
    func updateListsNow() async {
        await updateLists(ThreatFeed.allCases, manual: true, userInitiated: true)
    }

    /// The automatic update of Safari's lists, in the background.
    private func startSafariListUpdate() {
        guard updateTask == nil else { return }
        Task { await self.updateLists(ThreatFeed.safariFeeds, manual: false, userInitiated: false) }
    }

    /// Downloads the lists that are due (any of `feeds` checked over a minute ago when `manual`).
    /// Only what the person asked for runs in Low Data Mode.
    private func updateLists(_ feeds: [ThreatFeed], manual: Bool, userInitiated: Bool) async {
        while let running = updateTask { await running.value }
        guard allowsNetwork, !feeds.isEmpty else { return }
        let updater = FeedUpdater(storage: storage, transport: transport)
        isUpdatingLists = true
        updateMessage = "Checking the lists…"
        let task = Task {
            let outcome = await updater.update(feeds, manual: manual, allowsConstrainedNetwork: userInitiated) { message in
                Task { @MainActor in
                    if self.isUpdatingLists { self.updateMessage = message }
                }
            }
            await self.apply(outcome, userInitiated: userInitiated)
        }
        updateTask = task
        await task.value
        updateTask = nil
        isUpdatingLists = false
        updateMessage = nil
    }

    private func apply(_ outcome: FeedUpdater.Outcome, userInitiated: Bool) async {
        feedState = outcome.state
        if let problem = outcome.problems.first {
            listProblem = problem
        } else if outcome.offline {
            // Automatic updates just try again later; the saved lists keep working.
            if userInitiated { listProblem = "No internet connection. The lists update when you're back online." }
        } else {
            listProblem = nil
        }
        if outcome.listsChanged {
            linkIndex = nil
            linkIndexTask = nil
        }
        if outcome.rulesChanged { await reloadSafari() }
    }

    private func reloadSafari() async {
        do {
            try await SecurityChecks.reloadContentBlocker()
            safariReloadProblem = nil
        } catch {
            // While the extension is off, Safari reads the rules when it's turned on.
            safariReloadProblem = safariExtension == .on ? "Safari couldn't load the new rules. They'll be tried again with the next update." : nil
        }
    }

    // MARK: Link check

    /// Loads the lists for the link check, downloading the ones that are missing or due first.
    func prepareLinkCheck() async {
        let now = Date()
        let due = ThreatFeed.allCases.filter {
            FeedUpdatePolicy.isDue(feedState[$0], hasData: storage.hasData($0), now: now, manual: false)
        }
        await updateLists(due, manual: false, userInitiated: false)
        _ = await loadedLinkIndex()
    }

    /// Looks a link up in the lists saved on this device; the link isn't sent anywhere. Lists that
    /// were never downloaded are fetched first, as the person asked for the check.
    func checkLink(_ input: String) async -> LinkCheckOutcome {
        guard let link = CheckedLink(input) else { return .invalid }
        if link.isLocal { return .checked(link, .localAddress) }
        await updateLists(ThreatFeed.allCases.filter { !storage.hasData($0) }, manual: true, userInitiated: true)
        let index = await loadedLinkIndex()
        guard !index.isEmpty else {
            return .listsUnavailable(listProblem ?? "Couldn't download the lists. Check your connection and try again.")
        }
        return .checked(link, index.verdict(for: link))
    }

    private func loadedLinkIndex() async -> ThreatIndex {
        if let linkIndex { return linkIndex }
        if let linkIndexTask { return await linkIndexTask.value }
        let storage = self.storage
        let task = Task { await storage.loadLinkIndex(at: Date()) }
        linkIndexTask = task
        let index = await task.value
        if linkIndexTask == task {
            linkIndex = index
            linkIndexTask = nil
        }
        return index
    }

    // MARK: Environment

    /// Unit tests run inside the app: it shouldn't download anything then.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

#if DEBUG
extension ProtectionModel {
    /// A model with fixed results that never downloads anything, for previews.
    static func preview(passcode: PasscodeState = .set, biometrics: BiometricsState = .enrolled(.faceID),
                        network: NetworkRouteState = .direct, safari: SafariExtensionState = .on,
                        software: SoftwareUpdateState = .upToDate(newerMajorRelease: nil),
                        blocklist: BlocklistInfo? = BlocklistInfo(siteCount: 4_210, linkCount: 1_152, omittedCount: 0, builtAt: .now),
                        device: DeviceInfo = DeviceInfo(modelIdentifier: "iPhone18,3", systemVersion: [27, 0, 1], isPad: false)) -> ProtectionModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProtectionPreview", isDirectory: true)
        let model = ProtectionModel(storage: ProtectionStorage(directory: folder, blockerListURL: folder.appendingPathComponent("blockerList.json")),
                                    transport: URLSessionFeedTransport.shared, defaults: .standard, device: device, allowsNetwork: false)
        model.passcode = passcode
        model.biometrics = biometrics
        model.networkRoute = network
        model.safariExtension = safari
        model.software = software
        model.softwareCheckedAt = Date(timeIntervalSinceNow: -2 * 3600)
        var state = ProtectionFeedState()
        for feed in ThreatFeed.allCases { state[feed].lastChecked = Date(timeIntervalSinceNow: -3 * 3600) }
        state.blocklist = blocklist
        model.feedState = state
        return model
    }
}
#endif

/// Reads Apple's software update catalog.
enum SoftwareCatalogClient {
    struct FetchError: Error, Equatable {
        var problem: SoftwareCheckProblem
    }

    @concurrent
    static func releases(for model: String, transport: any FeedTransport) async throws -> [SoftwareRelease] {
        var request = URLRequest(url: SoftwareCatalog.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(FeedUpdater.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else { throw FetchError(problem: .server(response.statusCode)) }
        let releases = try SoftwareCatalog.releases(in: data, model: model)
        guard !releases.isEmpty else { throw FetchError(problem: .unknownModel) }
        return releases
    }

    static func problem(for error: Error) -> SoftwareCheckProblem {
        if let error = error as? FetchError { return error.problem }
        if FeedUpdater.isConnectivityProblem(error) { return .offline }
        return .unreadable
    }
}
