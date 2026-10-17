import Foundation

/// Sends one HTTP request. The app uses URLSession; tests use a stand-in.
protocol FeedTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession without a URL cache: Protection keeps its own copies of the lists.
struct URLSessionFeedTransport: FeedTransport {
    static let shared = URLSessionFeedTransport()

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Where Protection keeps its files: a Protection folder in the App Group container, shared with
/// the Safari extension, which reads `blockerList.json` at the container's top level.
struct ProtectionStorage: Sendable {
    static let appGroup = "group.com.maccleaner.MacCleaner.mobile"

    let directory: URL
    /// nil without the App Group container: Safari can't get the rules then.
    let blockerListURL: URL?

    static func shared() -> ProtectionStorage {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return ProtectionStorage(directory: container.appendingPathComponent("Protection", isDirectory: true),
                                     blockerListURL: container.appendingPathComponent("blockerList.json"))
        }
        return ProtectionStorage(directory: URL.applicationSupportDirectory.appendingPathComponent("Protection", isDirectory: true),
                                 blockerListURL: nil)
    }

    func url(for feed: ThreatFeed) -> URL { directory.appendingPathComponent(feed.fileName) }
    var stateURL: URL { directory.appendingPathComponent("feeds.json") }

    func hasData(_ feed: ThreatFeed) -> Bool {
        FileManager.default.fileExists(atPath: url(for: feed).path)
    }

    /// Creates the folder, kept out of backups: the lists download again.
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    func loadState() -> ProtectionFeedState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ProtectionFeedState.self, from: data) else { return ProtectionFeedState() }
        return state
    }

    func save(_ state: ProtectionFeedState) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    func urlhausHosts() -> [String] { ThreatFeedParser.hosts(read(.urlhausHosts)) }
    func urlhausAddresses() -> [String] { ThreatFeedParser.addresses(read(.urlhausOnline)) }
    func threatFoxStore() -> ThreatFoxStore { ThreatFoxStore.decode(read(.threatFox)) }

    /// The saved lists, indexed for the link check (empty when nothing was downloaded yet).
    @concurrent
    func loadLinkIndex(at date: Date) async -> ThreatIndex {
        ThreatIndex(urlhausHosts: urlhausHosts(), urlhausAddresses: urlhausAddresses(), threatFox: threatFoxStore().current(at: date))
    }

    private func read(_ feed: ThreatFeed) -> Data {
        (try? Data(contentsOf: url(for: feed))) ?? Data()
    }
}

/// What Protection remembers about its downloads (`feeds.json`).
struct ProtectionFeedState: Codable, Sendable, Equatable {
    var feeds: [String: FeedFileState] = [:]
    /// The rules Safari last got.
    var blocklist: BlocklistInfo?

    subscript(feed: ThreatFeed) -> FeedFileState {
        get { feeds[feed.rawValue] ?? FeedFileState() }
        set { feeds[feed.rawValue] = newValue }
    }

    /// When the lists behind Safari's rules were last checked (the older of the two), nil before both were.
    var safariListsChecked: Date? {
        let dates = ThreatFeed.safariFeeds.compactMap { self[$0].lastChecked }
        return dates.count == ThreatFeed.safariFeeds.count ? dates.min() : nil
    }

    /// When every list was last checked, nil before all of them were.
    var allListsChecked: Date? {
        let dates = ThreatFeed.allCases.compactMap { self[$0].lastChecked }
        return dates.count == ThreatFeed.allCases.count ? dates.min() : nil
    }
}

/// One feed's download state.
struct FeedFileState: Codable, Sendable, Equatable {
    var etag: String?
    var lastModified: String?
    /// The last answer from abuse.ch: a new list or "not modified".
    var lastChecked: Date?
    /// When the list last changed.
    var lastChanged: Date?
    var lastAttempt: Date?
    var failures = 0
    var lastError: String?
    var entryCount = 0
}

/// The rules Safari last got.
struct BlocklistInfo: Codable, Sendable, Equatable {
    var siteCount: Int
    var linkCount: Int
    var omittedCount: Int
    var builtAt: Date

    var ruleCount: Int { siteCount + linkCount }
}

/// When a feed may be downloaded again.
enum FeedUpdatePolicy {
    /// Automatic checks happen at most every 12 hours.
    static let interval: TimeInterval = 12 * 3600
    /// "Update Now" right after a check doesn't download again.
    static let manualInterval: TimeInterval = 60

    static func isDue(_ file: FeedFileState, hasData: Bool, now: Date, manual: Bool) -> Bool {
        if hasData, let checked = file.lastChecked, now >= checked,
           now.timeIntervalSince(checked) < (manual ? manualInterval : interval) {
            return false
        }
        if !manual, file.failures > 0, let attempt = file.lastAttempt, now >= attempt,
           now.timeIntervalSince(attempt) < retryDelay(failures: file.failures) {
            return false
        }
        return true
    }

    /// 10 minutes after the first failure, doubling up to 12 hours.
    static func retryDelay(failures: Int) -> TimeInterval {
        min(interval, 600 * pow(2, Double(min(max(failures, 1), 10) - 1)))
    }
}

/// abuse.ch answered with an error.
enum FeedHTTPError: LocalizedError, Equatable {
    case rateLimited
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "abuse.ch is limiting downloads right now. Try again later."
        case .status(let code): return "abuse.ch answered with an error (HTTP \(code))."
        }
    }
}

/// Downloads the feeds with conditional requests (ETag, If-Modified-Since), keeps the parsed lists
/// in the App Group container and rebuilds Safari's rules when their lists change. Runs only while
/// the app is open; nothing is scheduled in the background.
struct FeedUpdater: Sendable {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "MacCleaner-iOS/\(version)"
    }()

    var storage: ProtectionStorage
    var transport: any FeedTransport
    var now: @Sendable () -> Date = { Date() }

    struct Outcome: Sendable {
        var state: ProtectionFeedState
        /// Safari's rules were rebuilt and should be reloaded.
        var rulesChanged = false
        /// A list changed: the link check should read them again.
        var listsChanged = false
        /// What went wrong, for the person.
        var problems: [String] = []
        /// A download failed for lack of a connection (or Low Data Mode).
        var offline = false
    }

    /// Downloads the feeds that are due (all of them when `manual`), then rebuilds Safari's rules
    /// when the host list or ThreatFox changed, or when Safari has no rules yet.
    @concurrent
    func update(_ feeds: [ThreatFeed], manual: Bool, allowsConstrainedNetwork: Bool,
                progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        var outcome = Outcome(state: storage.loadState())
        do {
            try storage.prepare()
        } catch {
            outcome.problems.append("Couldn't save the lists: \(error.localizedDescription)")
            return outcome
        }
        var safariListsChanged = false
        for feed in feeds {
            if Task.isCancelled { break }
            let hasData = storage.hasData(feed)
            guard FeedUpdatePolicy.isDue(outcome.state[feed], hasData: hasData, now: now(), manual: manual) else { continue }
            progress("Downloading the \(feed.title)…")
            do {
                if try await fetch(feed, hasData: hasData, allowsConstrainedNetwork: allowsConstrainedNetwork, state: &outcome.state) {
                    outcome.listsChanged = true
                    if ThreatFeed.safariFeeds.contains(feed) { safariListsChanged = true }
                }
            } catch {
                var file = outcome.state[feed]
                file.failures += 1
                file.lastAttempt = now()
                let message = Self.message(for: error, feed: feed)
                file.lastError = message
                outcome.state[feed] = file
                if Self.isConnectivityProblem(error) { outcome.offline = true } else { outcome.problems.append(message) }
            }
        }
        if let blockerURL = storage.blockerListURL, ThreatFeed.safariFeeds.contains(where: storage.hasData),
           safariListsChanged || outcome.state.blocklist == nil || !FileManager.default.fileExists(atPath: blockerURL.path) {
            progress("Building Safari's rules…")
            do {
                outcome.state.blocklist = try writeRules(to: blockerURL, state: outcome.state)
                outcome.rulesChanged = true
            } catch {
                outcome.problems.append("Couldn't save Safari's rules: \(error.localizedDescription)")
            }
        }
        do {
            try storage.save(outcome.state)
        } catch {
            outcome.problems.append("Couldn't save the download state: \(error.localizedDescription)")
        }
        return outcome
    }

    /// Downloads one feed. Returns true when its list changed.
    private func fetch(_ feed: ThreatFeed, hasData: Bool, allowsConstrainedNetwork: Bool, state: inout ProtectionFeedState) async throws -> Bool {
        var request = URLRequest(url: feed.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.allowsConstrainedNetworkAccess = allowsConstrainedNetwork
        var file = state[feed]
        if hasData {
            if let etag = file.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = file.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (data, response) = try await transport.data(for: request)
        let checkedAt = now()
        file.lastAttempt = checkedAt
        switch response.statusCode {
        case 200:
            guard data.count <= feed.maxBytes else { throw ThreatFeedError(message: "The \(feed.title) was larger than expected.") }
            file.entryCount = try save(data, for: feed, at: checkedAt)
            file.etag = response.value(forHTTPHeaderField: "ETag")
            file.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
            file.lastChanged = checkedAt
        case 304:
            break
        case 429:
            throw FeedHTTPError.rateLimited
        default:
            throw FeedHTTPError.status(response.statusCode)
        }
        file.lastChecked = checkedAt
        file.failures = 0
        file.lastError = nil
        state[feed] = file
        return response.statusCode == 200
    }

    /// Parses a download and saves its list. Returns the number of entries kept.
    private func save(_ data: Data, for feed: ThreatFeed, at date: Date) throws -> Int {
        let url = storage.url(for: feed)
        switch feed {
        case .urlhausHosts:
            let hosts = ThreatFeedParser.hosts(data)
            guard !hosts.isEmpty || data.count < 1_000 else { throw ThreatFeedError(message: "The URLhaus host list couldn't be read.") }
            try writeList(hosts, header: "URLhaus malware hosts (abuse.ch, CC0)", to: url)
            return hosts.count
        case .urlhausOnline:
            let addresses = ThreatFeedParser.addresses(data)
            guard !addresses.isEmpty || data.count < 1_000 else { throw ThreatFeedError(message: "The URLhaus link list couldn't be read.") }
            try writeList(addresses, header: "URLhaus malware addresses (abuse.ch, CC0)", to: url)
            return addresses.count
        case .threatFox:
            let indicators = try ThreatFeedParser.threatFox(data)
            var store = storage.threatFoxStore()
            store.merge(indicators, seenAt: date)
            store.expire(before: date.addingTimeInterval(-ThreatFoxStore.retention))
            try store.encoded().write(to: url, options: .atomic)
            return store.count
        }
    }

    /// Builds Safari's rules from the saved lists and writes them atomically.
    private func writeRules(to url: URL, state: ProtectionFeedState) throws -> BlocklistInfo {
        let date = now()
        let candidates = SafariBlocklist.candidates(urlhausHosts: storage.urlhausHosts(),
                                                    urlhausDate: state[.urlhausHosts].lastChecked,
                                                    threatFox: storage.threatFoxStore().current(at: date))
        let rules = SafariBlocklist.rules(from: candidates)
        try rules.json.write(to: url, options: .atomic)
        return BlocklistInfo(siteCount: rules.siteCount, linkCount: rules.linkCount, omittedCount: rules.omittedCount, builtAt: date)
    }

    private func writeList(_ lines: [String], header: String, to url: URL) throws {
        var text = "# \(header)\n"
        text.reserveCapacity(lines.reduce(header.utf8.count + 4) { $0 + $1.utf8.count + 1 })
        for line in lines { text += line + "\n" }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func isConnectivityProblem(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        if error.networkUnavailableReason != nil { return true }
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                      .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive]
        return codes.contains(error.code)
    }

    static func message(for error: Error, feed: ThreatFeed) -> String {
        if let error = error as? URLError {
            if error.networkUnavailableReason == .constrained { return "Low Data Mode is on, so the lists weren't downloaded." }
            if isConnectivityProblem(error) { return "No internet connection." }
            return "The \(feed.title) couldn't be downloaded (\(error.localizedDescription))."
        }
        return error.localizedDescription
    }
}
