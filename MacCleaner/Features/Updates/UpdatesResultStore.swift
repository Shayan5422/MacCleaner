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
        for key in compact.results.keys { compact.results[key]?.releaseNotesText = nil }
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

/// Runs `brew upgrade --cask <token>` after the person confirmed it, and shows the output.
@MainActor
@Observable
final class UpdatesHomebrewRun: Identifiable {
    enum State: Equatable {
        case running
        case finished(succeeded: Bool, output: String)
    }

    let id = UUID()
    let appName: String
    let appPath: String
    let cask: UpdatesHomebrewCask
    let brewPath: String
    private(set) var state: State = .running
    private(set) var startedAt = Date()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(appName: String, appPath: String, cask: UpdatesHomebrewCask, brewPath: String) {
        self.appName = appName
        self.appPath = appPath
        self.cask = cask
        self.brewPath = brewPath
    }

    var isRunning: Bool { state == .running }

    func start(logger: ActivityLogger, onFinish: @escaping @MainActor (Bool) -> Void) {
        guard task == nil, cask.hasSafeToken else { return }
        startedAt = Date()
        let brew = brewPath
        let arguments = cask.upgradeArguments
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
                logger.info("Homebrew cask upgrade finished, exit code \(result.exitCode)", category: .updates)
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
