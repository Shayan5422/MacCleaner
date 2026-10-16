import Foundation

/// Something automatic cleaning may include. Only regenerable data qualifies:
/// personal files, downloads and anything marked for review never do.
struct AutomationCategory: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String
    var detail: String

    static let developerCachesID = "automation.developerCaches"
    static let browserCachesID = "automation.browserCaches"

    static var all: [AutomationCategory] {
        JunkCategory.all.filter(\.allowsAutomaticCleaning).map {
            AutomationCategory(id: $0.id, title: $0.title, symbol: $0.symbol, detail: $0.consequence)
        } + [
            AutomationCategory(id: developerCachesID, title: "Developer Caches", symbol: "hammer",
                               detail: "Simulator caches, Xcode previews and package-manager caches that tools re-download when needed."),
            AutomationCategory(id: browserCachesID, title: "Browser Caches", symbol: "globe",
                               detail: "Cached web content. Browsers rebuild it; you stay signed in. Caches of open browsers are skipped."),
        ]
    }

    static let defaultSelection: Set<String> = [
        JunkCategory.applicationCaches.id, JunkCategory.temporaryFiles.id, JunkCategory.logs.id, JunkCategory.crashReports.id,
    ]
}

/// The person's automation settings, stored as JSON in Application Support so
/// the background agent (a separate process) reads the same values.
struct AutomationConfiguration: Codable, Sendable, Equatable {
    enum Frequency: String, Codable, Sendable, CaseIterable, Identifiable {
        case daily, weekly, monthly
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Scan and tell the person what could be cleaned.
        case notifyOnly
        /// Clean the chosen safe categories automatically.
        case clean
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notifyOnly: return "Only notify me"
            case .clean: return "Clean automatically"
            }
        }
    }

    var isEnabled = false
    var scheduleEnabled = true
    var frequency: Frequency = .weekly
    /// 1 = Sunday … 7 = Saturday (Gregorian calendar weekday numbering).
    var weekday = 1
    /// 1…28 so every month has the day.
    var dayOfMonth = 1
    var hour = 10
    var minute = 0
    var mode: Mode = .notifyOnly
    var categories: Set<String> = AutomationCategory.defaultSelection
    var dryRun = false
    /// Announce a cleanup and perform it on the next check (about an hour later), giving time to skip it.
    var notifyBeforeCleaning = true
    var notifyAfterCleaning = true
    var storageTriggerEnabled = false
    var storageTriggerGB = 20
    var junkAlertEnabled = false
    var junkAlertGB = 5
    var securityScanEnabled = false
    /// Antivirus options. Optional so configurations saved by earlier versions still decode.
    var antivirusDefinitionsUpdate: Bool?
    var antivirusQuickScan: Bool?

    /// "Update virus definitions in the background" (at most every 4 hours, on each agent check).
    var updatesVirusDefinitions: Bool {
        get { antivirusDefinitionsUpdate ?? false }
        set { antivirusDefinitionsUpdate = newValue }
    }

    /// "Quick virus scan on each scheduled run".
    var runsVirusScan: Bool {
        get { antivirusQuickScan ?? false }
        set { antivirusQuickScan = newValue }
    }
}

/// Bookkeeping written by the runner.
struct AutomationState: Codable, Sendable, Equatable {
    var lastScheduledRun: Date?
    var lastThresholdRun: Date?
    var lastJunkCheck: Date?
    var lastSecurityScan: Date?
    var lastVirusScan: Date?
    /// A cleanup announced with "notify before cleaning", waiting for the next check.
    var pendingCleanupSince: Date?
    var pendingTrigger: AutomationRunRecord.Trigger?
    var skipPendingCleanup = false
}

/// One automatic run, shown in the Automation history.
struct AutomationRunRecord: Codable, Sendable, Identifiable, Hashable {
    enum Trigger: String, Codable, Sendable {
        case schedule, storageThreshold, manual, junkCheck, virusDefinitions

        var title: String {
            switch self {
            case .schedule: return "Scheduled"
            case .storageThreshold: return "Low storage"
            case .manual: return "Run manually"
            case .junkCheck: return "Junk check"
            case .virusDefinitions: return "Virus definitions"
            }
        }
    }

    enum Outcome: String, Codable, Sendable {
        case cleaned, dryRun, notified, announced, skipped, deferred, failed, nothingToDo, updated
    }

    var id = UUID()
    var date = Date()
    var trigger: Trigger
    var outcome: Outcome
    var bytes: Int64 = 0
    var itemCount = 0
    var skippedCount = 0
    var failedCount = 0
    var message: String
}

/// Reads and writes automation files. Writes are atomic, so the app and the
/// background agent never see half-written files.
struct AutomationStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Cleaner", isDirectory: true)
    }

    private var configurationURL: URL { directory.appendingPathComponent("Automation.json") }
    private var stateURL: URL { directory.appendingPathComponent("AutomationState.json") }
    private var historyURL: URL { directory.appendingPathComponent("AutomationHistory.json") }

    func loadConfiguration() -> AutomationConfiguration { load(configurationURL) ?? AutomationConfiguration() }
    func save(_ configuration: AutomationConfiguration) { save(configuration, to: configurationURL) }

    func loadState() -> AutomationState { load(stateURL) ?? AutomationState() }
    func save(_ state: AutomationState) { save(state, to: stateURL) }

    func loadHistory() -> [AutomationRunRecord] { load(historyURL) ?? [] }

    func append(_ record: AutomationRunRecord) {
        var history = loadHistory()
        history.insert(record, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        save(history, to: historyURL)
    }

    func clearHistory() { save([AutomationRunRecord](), to: historyURL) }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            ActivityLogger.shared.error("Couldn't save automation file: \(error.localizedDescription)", category: .automation)
        }
    }
}

/// Calendar math for schedules.
enum AutomationSchedule {
    /// The most recent scheduled moment at or before `date`.
    static func previousSlot(for configuration: AutomationConfiguration, atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = configuration.hour
        components.minute = configuration.minute
        components.second = 0
        switch configuration.frequency {
        case .daily: break
        case .weekly: components.weekday = configuration.weekday
        case .monthly: components.day = min(max(configuration.dayOfMonth, 1), 28)
        }
        if calendar.date(date, matchesComponents: components) { return date }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, direction: .backward)
    }

    /// The next scheduled moment after `date`.
    static func nextSlot(for configuration: AutomationConfiguration, after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = configuration.hour
        components.minute = configuration.minute
        components.second = 0
        switch configuration.frequency {
        case .daily: break
        case .weekly: components.weekday = configuration.weekday
        case .monthly: components.day = min(max(configuration.dayOfMonth, 1), 28)
        }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, direction: .forward)
    }

    /// `true` when a scheduled slot has passed since the last scheduled run.
    static func isDue(_ configuration: AutomationConfiguration, lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard configuration.scheduleEnabled, let slot = previousSlot(for: configuration, atOrBefore: now, calendar: calendar) else { return false }
        return (lastRun ?? .distantPast) < slot
    }
}
