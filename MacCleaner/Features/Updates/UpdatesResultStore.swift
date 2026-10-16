import Foundation

/// Remembers the last update check so results survive relaunches. A stored result is
/// shown only while the installed version is unchanged, and always with its date.
enum UpdatesResultStore {
    struct Snapshot: Codable, Sendable {
        var checkedAt: Date
        /// Results by app path.
        var results: [String: UpdatesCheckResult]
    }

    /// Updates known from the last check, for the dashboard.
    struct Summary: Sendable, Hashable {
        var availableUpdates: Int
        var checkedAt: Date
    }

    private static let key = "updates.lastResults.v1"

    static func load(defaults: UserDefaults = .standard) -> Snapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot, defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Release notes can be long; they're fetched again with the next check.
        var compact = snapshot
        for key in compact.results.keys {
            compact.results[key]?.releaseNotesText = nil
            compact.results[key]?.releaseNotesHTML = nil
        }
        if let data = try? encoder.encode(compact) { defaults.set(data, forKey: key) }
    }

    /// The number of apps that had an update at the last check and still have the
    /// version that was checked. Reads a few Info.plist files; call off the main thread
    /// (or use the async variant).
    static func lastKnownSummary(defaults: UserDefaults = .standard) -> Summary? {
        guard let snapshot = load(defaults: defaults) else { return nil }
        let count = snapshot.results.filter { path, result in
            guard result.status == .updateAvailable, let info = ApplicationCatalog.read(path: path) else { return false }
            return info.displayVersion == result.installedVersionAtCheck
        }.count
        return Summary(availableUpdates: count, checkedAt: snapshot.checkedAt)
    }

    static func lastKnownSummary() async -> Summary? {
        await BackgroundWork.run(qos: .utility) { lastKnownSummary(defaults: .standard) }
    }
}

/// Runs `brew upgrade --cask <tokens>` after the person confirmed it, and shows the output.
@MainActor
@Observable
final class UpdatesHomebrewRun: Identifiable {
    enum State: Equatable {
        case running
        case finished(succeeded: Bool, output: String)
    }

    /// One app the command updates.
    struct Item: Sendable, Hashable {
        var appName: String
        var appPath: String
        var cask: UpdatesHomebrewCask
    }

    let id = UUID()
    let items: [Item]
    let brewPath: String
    private(set) var state: State = .running
    private(set) var startedAt = Date()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(items: [Item], brewPath: String) {
        self.items = items
        self.brewPath = brewPath
    }

    convenience init(appName: String, appPath: String, cask: UpdatesHomebrewCask, brewPath: String) {
        self.init(items: [Item(appName: appName, appPath: appPath, cask: cask)], brewPath: brewPath)
    }

    var isRunning: Bool { state == .running }

    /// "Xcode" or "3 apps".
    var title: String {
        items.count == 1 ? items[0].appName : "\(items.count) apps"
    }

    /// Unique tokens of casks that pass the safety check.
    var tokens: [String] {
        var seen = Set<String>()
        return items.map(\.cask).filter(\.hasSafeToken).map(\.upgradeToken).filter { seen.insert($0).inserted }
    }

    var arguments: [String] { ["upgrade", "--cask"] + tokens }
    var command: String { "brew " + arguments.joined(separator: " ") }

    func start(logger: ActivityLogger, onFinish: @escaping @MainActor (Bool) -> Void) {
        guard task == nil, !tokens.isEmpty, tokens.count == Set(items.map(\.cask.upgradeToken)).count else { return }
        startedAt = Date()
        let brew = brewPath
        let arguments = arguments
        task = Task {
            do {
                let result = try await ProcessRunner.run(
                    brew,
                    arguments: arguments,
                    environment: UpdatesHomebrew.environment(),
                    timeout: 30 * 60,
                    maxOutputBytes: 2 * 1024 * 1024
                )
                var output = result.combinedOutput
                if result.timedOut { output += "\n\nHomebrew took longer than 30 minutes and was stopped." }
                if !result.succeeded, output.localizedCaseInsensitiveContains("sudo") || output.localizedCaseInsensitiveContains("password") {
                    output += "\n\nThis update needs an administrator password. Copy the command and run it in Terminal."
                }
                if Task.isCancelled { output += "\n\nStopped." }
                state = .finished(succeeded: result.succeeded, output: output.isEmpty ? "Homebrew finished without output." : output)
                logger.info("Homebrew cask upgrade of \(arguments.count - 2) cask(s) finished, exit code \(result.exitCode)", category: .updates)
                onFinish(result.succeeded)
            } catch {
                state = .finished(succeeded: false, output: error.localizedDescription)
                logger.error("Homebrew cask upgrade couldn't run: \(error.localizedDescription)", category: .updates)
                onFinish(false)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
