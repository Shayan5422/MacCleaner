import Foundation

/// Keeps the virus definitions current and installs new ones atomically.
///
/// 1. ClamAV databases: with ClamAV's own `freshclam` when it's installed (and the setting is
///    on), otherwise with `AVBuiltInClamAVUpdater` (DNS check, signed CDIFF patches, at most one
///    full download per file per day).
/// 2. abuse.ch feeds, downloaded in-app.
/// 3. When anything changed, the engine database is compiled into a fresh folder, swapped into
///    `engine/` and loaded. If compiling or loading fails, the previous database stays in use.
actor AVDefinitionsUpdater {
    enum Trigger: String, Sendable {
        /// The person clicked "Download Virus Definitions".
        case firstInstall
        /// "Update Now".
        case manual
        /// Periodic update while the app runs, or the background agent.
        case automatic
        /// Compiles the downloaded definitions again without going online: the installed database
        /// was compiled by another build of Mac Cleaner, or it can't be loaded.
        case rebuild
    }

    struct Environment: Sendable {
        var paths: AVPaths
        var transport: any AVHTTPTransport
        var versionLookup: any AVVersionLookup
        var toolkit: any AVDatabaseToolkit
        var verifier: any AVCdiffVerifying = AVClamAVPSSVerifier.shared
        var userAgent: String = AVUserAgent.make()
        var locateFreshclam: @Sendable () async -> AVFreshclamTool?
        var runFreshclam: @Sendable (AVFreshclamTool, AVPaths, @escaping @Sendable (AVUpdateProgress) -> Void) async throws -> AVFreshclamReport
        var now: @Sendable () -> Date = { Date() }

        static func live(paths: AVPaths = .standard) -> Environment {
            Environment(
                paths: paths,
                transport: AVURLSessionTransport(),
                versionLookup: AVDNSVersionLookup(),
                toolkit: AVLiveToolkit(),
                locateFreshclam: {
                    guard let path = await AVFreshclamLocator.locate() else { return nil }
                    return AVFreshclamTool(path: path, version: await AVFreshclamLocator.version(of: path))
                },
                runFreshclam: { tool, paths, progress in try await AVFreshclamRunner(paths: paths).run(tool: tool, progress: progress) }
            )
        }
    }

    struct Outcome: Sendable {
        var state: AVDefinitionsState
        /// A new engine database was compiled and loaded.
        var installedNewDatabase = false
        var engine: AVLoadedEngine?
        /// Rebuilt threat-intel index when the feeds changed.
        var intel: AVThreatIntelIndex?
        var intelChanged = false
        var updater: AVUpdaterKind?
        var messages: [String] = []
        /// Something went wrong; the previous definitions (if any) stay in use.
        var problem: String?
        /// Nothing ran (not due, first install not requested, or another process is updating).
        var skippedReason: String?
    }

    let environment: Environment
    private var running: Task<Outcome, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    var paths: AVPaths { environment.paths }

    func currentState() -> AVDefinitionsState { AVStateFile(url: environment.paths.stateFile).load() }

    /// Runs an update. A call made while one is running waits for it and gets the same outcome.
    func update(trigger: Trigger, settings: AVSettingsSnapshot, progress: @escaping @Sendable (AVUpdateProgress) -> Void = { _ in }) async -> Outcome {
        if let running { return await running.value }
        let task = Task { await self.perform(trigger: trigger, settings: settings, progress: progress) }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    func cancel() {
        running?.cancel()
    }

    // MARK: - Steps

    private func perform(trigger: Trigger, settings: AVSettingsSnapshot, progress: @escaping @Sendable (AVUpdateProgress) -> Void) async -> Outcome {
        let paths = environment.paths
        let stateFile = AVStateFile(url: paths.stateFile)
        var state = stateFile.load()
        var outcome = Outcome(state: state)

        if trigger == .automatic && !state.firstInstallRequested {
            outcome.skippedReason = "Virus definitions haven't been installed yet."
            return outcome
        }
        guard let lock = AVProcessLock(url: paths.updateLock) else {
            outcome.skippedReason = "Another Mac Cleaner process is updating the virus definitions."
            return outcome
        }
        defer { withExtendedLifetime(lock) {} }
        do {
            try paths.prepare()
        } catch {
            outcome.problem = "Mac Cleaner couldn't create its definitions folder: \(error.localizedDescription)"
            return outcome
        }
        paths.cleanTemporary(now: environment.now())
        if trigger == .rebuild {
            let feeds = AVFeedUpdater(paths: paths, transport: environment.transport, allowsConstrainedNetwork: false,
                                      now: environment.now, progress: progress)
            do {
                if let compiled = try await compileIfNeeded(feeds: feeds, settings: settings, force: true, state: &state, progress: progress) {
                    outcome.installedNewDatabase = true
                    outcome.engine = compiled
                }
            } catch {
                outcome.problem = Self.describeCompileFailure(error, hadPrevious: state.installed != nil)
            }
            state.lastError = outcome.problem
            do { try stateFile.save(state) } catch { outcome.problem = outcome.problem ?? "Couldn't save the update state: \(error.localizedDescription)" }
            outcome.state = state
            return outcome
        }
        if trigger == .firstInstall { state.firstInstallRequested = true }

        let now = environment.now()
        let versionsDue = AVUpdatePolicy.isVersionCheckDue(lastCheck: state.lastVersionCheck, now: now, manual: trigger != .automatic)
            || !state.hasClamAVDatabases
        if versionsDue {
            progress(AVUpdateProgress(phase: .checking, message: "Checking for new virus definitions…"))
            let result = await updateClamAV(settings: settings, trigger: trigger, state: &state, progress: progress)
            outcome.messages += result.messages
            if let problem = result.problem { outcome.problem = problem }
            outcome.updater = state.lastUpdater
        }

        let feeds = AVFeedUpdater(paths: paths, transport: environment.transport, allowsConstrainedNetwork: trigger != .automatic,
                                  now: environment.now, progress: progress)
        let feedResult = await feeds.update(state: &state, sources: settings.sources, manual: trigger != .automatic)
        outcome.messages += feedResult.messages
        if outcome.problem == nil, let problem = feedResult.problems.first { outcome.problem = problem }
        if versionsDue || feedResult.hashListsChanged || feedResult.intelChanged { state.lastCheck = environment.now() }

        if !Task.isCancelled {
            do {
                if let compiled = try await compileIfNeeded(feeds: feeds, settings: settings, force: feedResult.hashListsChanged, state: &state, progress: progress) {
                    outcome.installedNewDatabase = true
                    outcome.engine = compiled
                }
            } catch {
                outcome.problem = Self.describeCompileFailure(error, hadPrevious: state.installed != nil)
            }
        }

        if feedResult.intelChanged || outcome.installedNewDatabase {
            var enabled = Set<AVIntelSource>()
            if settings.sources.urlhaus { enabled.insert(.urlhaus) }
            if settings.sources.threatFox { enabled.insert(.threatFox) }
            let database = AVIntelDatabase.read(from: feeds.indicatorsURL)
            outcome.intel = enabled.isEmpty || database.count == 0 ? nil : database.index(sources: enabled)
            outcome.intelChanged = true
        }

        state.lastError = outcome.problem
        do { try stateFile.save(state) } catch { outcome.problem = outcome.problem ?? "Couldn't save the update state: \(error.localizedDescription)" }
        outcome.state = state
        return outcome
    }

    private func updateClamAV(settings: AVSettingsSnapshot, trigger: Trigger, state: inout AVDefinitionsState, progress: @escaping @Sendable (AVUpdateProgress) -> Void) async -> AVClamAVUpdateResult {
        let paths = environment.paths
        if settings.useFreshclam, let tool = await environment.locateFreshclam() {
            state.lastUpdater = .freshclam
            state.freshclamVersion = tool.version
            do {
                let report = try await environment.runFreshclam(tool, paths, progress)
                state.lastVersionCheck = environment.now()
                if let until = report.coolDownUntil { state.cdnRetryAfter = until }
                Self.syncDatabasesFromDisk(paths: paths, state: &state, now: environment.now())
                var result = AVClamAVUpdateResult(changed: report.changed, upToDate: report.succeeded, messages: [report.summary])
                if report.succeeded {
                    state.lastSuccessfulCheck = environment.now()
                    return result
                }
                guard Self.isLocalFreshclamProblem(report.exitCode) else {
                    result.problem = report.summary
                    return result
                }
                result.messages.append("freshclam couldn't run with Mac Cleaner's settings (\(report.summary)); using the built-in updater.")
            } catch {
                state.lastVersionCheck = environment.now()
                // freshclam couldn't start at all: fall through to the built-in updater for this run.
            }
        } else {
            state.freshclamVersion = nil
        }

        state.lastUpdater = .builtIn
        let context = AVClamAVUpdateContext(paths: paths, transport: environment.transport, toolkit: environment.toolkit,
                                            verifier: environment.verifier, userAgent: environment.userAgent,
                                            allowsConstrainedNetwork: trigger != .automatic, now: environment.now, progress: progress)
        let updater = AVBuiltInClamAVUpdater(context: context)
        var versions = await environment.versionLookup.currentVersions()
        if versions == nil { versions = await updater.versionsFromHeaders(state: &state) }
        if let versions { state.lastVersionInfo = versions }
        state.lastVersionCheck = environment.now()
        let result = await updater.update(state: &state, versions: versions)
        if result.upToDate && versions != nil { state.lastSuccessfulCheck = environment.now() }
        return result
    }

    /// Compiles and installs when the inputs differ from the installed database. Returns the new engine.
    private func compileIfNeeded(feeds: AVFeedUpdater, settings: AVSettingsSnapshot, force: Bool, state: inout AVDefinitionsState,
                                 progress: @escaping @Sendable (AVUpdateProgress) -> Void) async throws -> AVLoadedEngine? {
        let paths = environment.paths
        guard let main = AVClamAVLocalDatabase.current(.main, in: paths.clamav),
              let daily = AVClamAVLocalDatabase.current(.daily, in: paths.clamav) else { return nil }
        let lists = feeds.hashListInputs(sources: settings.sources)
        let versions = ["main": main.header.version, "daily": daily.header.version]
        let counts = Dictionary(lists.map { ($0.feed.rawValue, $0.count) }, uniquingKeysWith: +)
        let engineExists = !((try? FileManager.default.contentsOfDirectory(atPath: paths.engine.path)) ?? []).isEmpty
        if let installed = state.installed, installed.clamavVersions == versions, installed.hashListCounts == counts,
           installed.compiledByBuild == AVAppBuild.current, engineExists, !force {
            return nil
        }

        progress(AVUpdateProgress(phase: .compiling, message: "Preparing the virus definitions for scanning…"))
        let inputs = AVDatabaseInputs(clamavFiles: [main.url, daily.url], sha256Lists: lists.map { ($0.url, $0.source) })
        let staging = paths.root.appendingPathComponent("engine.staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let toolkit = environment.toolkit
        let summary: AVDatabaseSummary
        do {
            summary = try await BackgroundWork.run(qos: .utility) {
                try toolkit.compile(inputs, into: staging) { fraction, message in
                    progress(AVUpdateProgress(phase: .compiling, message: message.isEmpty ? "Compiling the definitions…" : message, fraction: fraction))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        progress(AVUpdateProgress(phase: .loading, message: "Loading the new definitions…"))
        let previous = try AVFileOps.installDirectory(staging, at: paths.engine)
        let engine: AVLoadedEngine
        do {
            let enginePath = paths.engine
            engine = try await BackgroundWork.run(qos: .utility) { try toolkit.load(from: enginePath) }
        } catch {
            if let previous {
                try? AVFileOps.restoreDirectory(previous, at: paths.engine)
                try? FileManager.default.removeItem(at: previous)
            } else {
                try? FileManager.default.removeItem(at: paths.engine)
            }
            throw error
        }
        if let previous { try? FileManager.default.removeItem(at: previous) }

        let now = environment.now()
        state.installed = AVInstalledDatabase(summary: summary, compiledAt: now, clamavVersions: versions, hashListCounts: counts,
                                              compiledByBuild: AVAppBuild.current)
        state.lastUpdated = now
        return engine
    }

    // MARK: - Helpers

    /// Updates the per-database state from the files (after freshclam ran).
    static func syncDatabasesFromDisk(paths: AVPaths, state: inout AVDefinitionsState, now: Date) {
        for database in AVClamAVDatabase.allCases {
            var file = state[database]
            if let local = AVClamAVLocalDatabase.current(database, in: paths.clamav) {
                if file.version != local.header.version { file.lastUpdated = now }
                file.version = local.header.version
                file.buildTime = local.header.buildTime
                file.signatureCount = local.header.signatureCount
                file.fileName = local.url.lastPathComponent
                file.fileSize = AVBuiltInClamAVUpdater.size(of: local.url)
                file.lastError = nil
            }
            state[database] = file
        }
    }

    /// freshclam exit codes that point at Mac Cleaner's setup rather than the network.
    static func isLocalFreshclamProblem(_ code: Int32) -> Bool {
        [40, 50, 53, 55, 56, 57, 60, 61, 62].contains(code)
    }

    static func describeCompileFailure(_ error: Error, hadPrevious: Bool) -> String {
        let keep = hadPrevious ? " The previous definitions stay in use." : ""
        if let engineError = error as? AVEngineError, engineError == .notImplemented {
            return "The antivirus engine isn't available in this build, so the downloaded definitions can't be used yet." + keep
        }
        return "The new definitions couldn't be prepared: \(error.localizedDescription)" + keep
    }
}
