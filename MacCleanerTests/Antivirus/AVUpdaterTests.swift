import Foundation
import Testing
@testable import MacCleaner

/// Small ClamAV-format databases for updater tests.
enum AVSyntheticDatabase {
    static func headerLine(version: Int) -> String {
        "ClamAV-VDB:16 Oct 2026 06-24 +0000:\(version):10:90:X:X:mac-cleaner-tests:1792131857"
    }

    /// A `.cvd`-like file: the 512-byte header and some body (the fake toolkit only reads the header).
    static func writeContainer(version: Int, to url: URL) throws {
        var data = Data(headerLine(version: version).utf8)
        data.append(contentsOf: [UInt8](repeating: 0x20, count: 512 - data.count))
        data.append(Data("body".utf8))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// An unpacked daily database (`daily.ndb` + a signed-format `daily.info`) packed into `daily.cld`.
    static func writeDaily(version: Int, signatures: String, to url: URL) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let ndb = Data(signatures.utf8)
        try ndb.write(to: work.appendingPathComponent("daily.ndb"))
        try Data("ClamAV test COPYING\n".utf8).write(to: work.appendingPathComponent("COPYING"))
        let info = "\(headerLine(version: version))\ndaily.ndb:\(ndb.count):\(AVFileHasher.sha256(data: ndb))\nDSIG:sig\(version)\n"
        try Data(info.utf8).write(to: work.appendingPathComponent("daily.info"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AVClamAVLocalDatabase.pack(.daily, from: work, to: url)
    }

    /// A patch from `version - 1` that appends one signature to `daily.ndb`.
    static func patch(to version: Int, previousSignatures: String) -> (cdiff: Data, signatures: String) {
        let added = "Test.Sig.Version\(version):0:*:deadbeef\(version)"
        let signatures = previousSignatures + added + "\n"
        let ndb = Data(signatures.utf8)
        let script = """
        OPEN daily.ndb
        ADD \(added)
        CLOSE
        OPEN daily.info
        XCHG 1 ClamAV-VDB:16 \(headerLine(version: version))
        XCHG 2 daily.ndb: daily.ndb:\(ndb.count):\(AVFileHasher.sha256(data: ndb))
        XCHG 3 DSIG: DSIG:sig\(version)
        CLOSE
        """
        return (AVTestGzip.cdiff(version: version, script: script), signatures)
    }
}

/// An updater wired to fakes, with a controllable clock.
struct AVUpdaterRig {
    let directory: AVTestFolder
    let transport = AVFakeTransport()
    let toolkit = AVFakeToolkit()
    let clock = AVTestClock()
    var versions: AVFakeVersionLookup
    var freshclam: AVFreshclamTool?
    var runFreshclam: (@Sendable (AVFreshclamTool, AVPaths, @escaping @Sendable (AVUpdateProgress) -> Void) async throws -> AVFreshclamReport)?

    init(main: Int, daily: Int) throws {
        directory = try AVTestFolder("AVUpdater")
        versions = .versions(main: main, daily: daily)
    }

    var paths: AVPaths { directory.paths }

    func updater() -> AVDefinitionsUpdater {
        AVDefinitionsUpdater(environment: environment())
    }

    func environment() -> AVDefinitionsUpdater.Environment {
        let clock = self.clock
        let tool = freshclam
        let run = runFreshclam
        return AVDefinitionsUpdater.Environment(
            paths: paths, transport: transport, versionLookup: versions, toolkit: toolkit, verifier: AVAcceptingVerifier(),
            userAgent: AVUserAgent.make(appVersion: "2.0.0"),
            locateFreshclam: { tool },
            runFreshclam: { tool, paths, progress in
                guard let run else { throw CommandError.toolNotFound("freshclam") }
                return try await run(tool, paths, progress)
            },
            now: { clock.now }
        )
    }

    /// Settings with the abuse.ch feeds off unless asked for (most tests are about ClamAV).
    static func settings(feeds: Bool = false) -> AVSettingsSnapshot {
        var settings = AVSettingsSnapshot()
        settings.useFreshclam = true
        settings.sources = AVSourceSelection(malwareBazaarRecent: feeds, malwareBazaarFull: false, urlhaus: feeds, threatFox: feeds)
        return settings
    }

    func serveContainers(main: Int, daily: Int) throws {
        let mainURL = directory.child("served/main.cvd")
        try AVSyntheticDatabase.writeContainer(version: main, to: mainURL)
        transport.serve("https://database.clamav.net/main.cvd", file: mainURL)
        let dailyURL = directory.child("served/daily.cvd")
        try AVSyntheticDatabase.writeContainer(version: daily, to: dailyURL)
        transport.serve("https://database.clamav.net/daily.cvd", file: dailyURL)
    }
}

@Suite("Antivirus definitions updater")
struct AVUpdaterTests {
    // MARK: - Policy

    @Test func plansPatchesFullDownloadsAndWaits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var file = AVDatabaseFileState()
        #expect(AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 100, cdnRetryAfter: nil, now: now) == .downloadFull)
        file.version = 98
        #expect(AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 100, cdnRetryAfter: nil, now: now) == .applyPatches(from: 99, to: 100))
        #expect(AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 98, cdnRetryAfter: nil, now: now) == .upToDate)
        #expect(AVUpdatePolicy.plan(.daily, state: file, remoteVersion: nil, cdnRetryAfter: nil, now: now) == .upToDate)
        file.version = 10
        #expect(AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 100, cdnRetryAfter: nil, now: now) == .downloadFull)
        file.lastFullDownload = now.addingTimeInterval(-3600)
        guard case .wait(let until, _) = AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 100, cdnRetryAfter: nil, now: now) else {
            Issue.record("expected a wait")
            return
        }
        #expect(until == now.addingTimeInterval(23 * 3600))
        file.version = 99
        file.cdiffFailedTarget = 100
        #expect(AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 100, cdnRetryAfter: nil, now: now) != .applyPatches(from: 100, to: 100))
        file.cdiffFailedTarget = nil
        if case .wait = AVUpdatePolicy.plan(.daily, state: file, remoteVersion: 100, cdnRetryAfter: now.addingTimeInterval(60), now: now) {} else {
            Issue.record("the CDN cool-down must be honored")
        }
    }

    @Test func backsOffByStatus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AVUpdatePolicy.retryDate(status: 429, retryAfter: 7_200, failures: 1, now: now) == now.addingTimeInterval(7_200))
        #expect(AVUpdatePolicy.retryDate(status: 429, retryAfter: 5, failures: 1, now: now) == now.addingTimeInterval(900))
        #expect(AVUpdatePolicy.retryDate(status: 403, retryAfter: nil, failures: 1, now: now) == now.addingTimeInterval(86_400))
        #expect(AVUpdatePolicy.retryDate(status: 503, retryAfter: nil, failures: 1, now: now) == now.addingTimeInterval(900))
        #expect(AVUpdatePolicy.retryDate(status: 503, retryAfter: nil, failures: 3, now: now) == now.addingTimeInterval(3_600))
        #expect(AVUpdatePolicy.retryDate(status: nil, retryAfter: nil, failures: 2, now: now) == now.addingTimeInterval(3_600))
        #expect(AVUpdatePolicy.isVersionCheckDue(lastCheck: now.addingTimeInterval(-3 * 3600), now: now, manual: false) == false)
        #expect(AVUpdatePolicy.isVersionCheckDue(lastCheck: now.addingTimeInterval(-5 * 3600), now: now, manual: false))
        #expect(AVUpdatePolicy.isVersionCheckDue(lastCheck: now, now: now, manual: true))
        let response = AVHTTPResponse(statusCode: 429, headers: ["Retry-After": "Fri, 31 Dec 2032 23:59:59 GMT"])
        #expect((response.retryAfter(now: now) ?? 0) > 0)
    }

    // MARK: - Updates

    @Test func automaticUpdatesWaitForTheFirstInstall() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 100)
        let outcome = await rig.updater().update(trigger: .automatic, settings: AVUpdaterRig.settings())
        #expect(outcome.skippedReason != nil)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func installsDownloadsAndThenStaysQuiet() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        let updater = rig.updater()
        let outcome = await updater.update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(outcome.problem == nil)
        #expect(outcome.installedNewDatabase)
        #expect(outcome.engine != nil)
        #expect(outcome.state.installed?.clamavVersions == ["main": 63, "daily": 100])
        #expect(outcome.state[.daily].lastFullDownload == rig.clock.now)
        #expect(outcome.state.lastUpdater == .builtIn)
        #expect(FileManager.default.fileExists(atPath: rig.paths.engine.appendingPathComponent("compiled.txt").path))
        #expect(rig.transport.requests.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("ClamAV/1.4.6 (OS: darwin, ARCH: ") == true })
        #expect(rig.transport.requests.allSatisfy { $0.headers["User-Agent"]?.hasSuffix("MacCleaner/2.0.0") == true })

        // Saved state survives a new updater.
        let saved = AVStateFile(url: rig.paths.stateFile).load()
        #expect(saved == outcome.state)

        // An hour later nothing is due: no requests, no compile.
        rig.clock.advance(3600)
        let quiet = await rig.updater().update(trigger: .automatic, settings: AVUpdaterRig.settings())
        #expect(rig.transport.requests.count == 2)
        #expect(!quiet.installedNewDatabase)
        #expect(rig.toolkit.compileCount == 1)
    }

    @Test func compilesAgainAfterAnAppUpdateWithoutGoingOnline() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        let first = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(first.state.installed?.compiledByBuild == AVAppBuild.current)
        let requests = rig.transport.requests.count

        // A database compiled by another build of Mac Cleaner is compiled again from the local files.
        let stateFile = AVStateFile(url: rig.paths.stateFile)
        var state = stateFile.load()
        state.installed?.compiledByBuild = "1.0.0 (1)"
        try stateFile.save(state)
        let rebuilt = await rig.updater().update(trigger: .rebuild, settings: AVUpdaterRig.settings())
        #expect(rebuilt.problem == nil)
        #expect(rebuilt.installedNewDatabase)
        #expect(rebuilt.engine != nil)
        #expect(rebuilt.state.installed?.compiledByBuild == AVAppBuild.current)
        #expect(rig.toolkit.compileCount == 2)
        #expect(rig.transport.requests.count == requests)

        // Automatic updates notice it too (databases from before the build was recorded).
        state = stateFile.load()
        state.installed?.compiledByBuild = nil
        try stateFile.save(state)
        rig.clock.advance(3600)
        let automatic = await rig.updater().update(trigger: .automatic, settings: AVUpdaterRig.settings())
        #expect(automatic.installedNewDatabase)
        #expect(rig.toolkit.compileCount == 3)
        #expect(rig.transport.requests.count == requests)
    }

    @Test func patchesTheDailyDatabaseWithCdiffs() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        _ = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        // Replace the downloaded daily with an unpackable one at version 100.
        var signatures = "Test.Sig.Base:0:*:00112233\n"
        try FileManager.default.removeItem(at: rig.paths.clamav.appendingPathComponent("daily.cvd"))
        try AVSyntheticDatabase.writeDaily(version: 100, signatures: signatures, to: rig.paths.clamav.appendingPathComponent("daily.cld"))
        for version in 101...103 {
            let patch = AVSyntheticDatabase.patch(to: version, previousSignatures: signatures)
            signatures = patch.signatures
            rig.transport.serve("https://database.clamav.net/daily-\(version).cdiff", body: patch.cdiff)
        }
        rig.versions = .versions(main: 63, daily: 103)
        rig.clock.advance(5 * 3600)
        let outcome = await rig.updater().update(trigger: .automatic, settings: AVUpdaterRig.settings())
        #expect(outcome.problem == nil)
        #expect(outcome.installedNewDatabase)
        #expect(outcome.state[.daily].version == 103)
        #expect(outcome.state[.daily].fileName == "daily.cld")
        #expect(rig.transport.count("daily.cvd") == 1) // only the first install
        #expect(rig.transport.count(".cdiff") == 3)
        let unpacked = try rig.directory.makeDirectory("check")
        _ = try AVClamAVLocalDatabase.unpack(rig.paths.clamav.appendingPathComponent("daily.cld"), to: URL(fileURLWithPath: unpacked))
        try AVClamAVLocalDatabase.verifyUnpacked(.daily, in: URL(fileURLWithPath: unpacked), expectedVersion: 103)
        #expect(try String(contentsOfFile: unpacked + "/daily.ndb", encoding: .utf8) == signatures)
    }

    @Test func fallsBackToOneFullDownloadADay() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        _ = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        try FileManager.default.removeItem(at: rig.paths.clamav.appendingPathComponent("daily.cvd"))
        try AVSyntheticDatabase.writeDaily(version: 100, signatures: "Test.Sig:0:*:00\n", to: rig.paths.clamav.appendingPathComponent("daily.cld"))
        // Patches are missing (404): a newer daily needs a full download, which waits 24 hours.
        rig.versions = .versions(main: 63, daily: 101)
        rig.clock.advance(5 * 3600)
        let blocked = await rig.updater().update(trigger: .manual, settings: AVUpdaterRig.settings())
        #expect(rig.transport.count("daily-101.cdiff") == 1)
        #expect(rig.transport.count("daily.cvd") == 1)
        #expect(blocked.state[.daily].version == 100)
        #expect(blocked.state[.daily].cdiffFailedTarget == 101)
        #expect(blocked.messages.contains { $0.contains("once a day") })

        // A day after the first download, the full download is allowed.
        try AVSyntheticDatabase.writeContainer(version: 101, to: rig.directory.child("served/daily.cvd"))
        rig.clock.advance(20 * 3600)
        let outcome = await rig.updater().update(trigger: .automatic, settings: AVUpdaterRig.settings())
        #expect(rig.transport.count("daily.cvd") == 2)
        #expect(outcome.state[.daily].version == 101)
        #expect(outcome.installedNewDatabase)
    }

    @Test func honorsRetryAfterAndForbidden() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 100)
        rig.transport.serve("https://database.clamav.net/main.cvd", status: 429, headers: ["Retry-After": "7200"])
        let limited = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(limited.problem?.contains("limiting") == true)
        #expect(limited.state.cdnRetryAfter == rig.clock.now.addingTimeInterval(7_200))
        #expect(limited.state[.main].lastFullDownload == nil) // nothing was transferred
        #expect(rig.transport.count("daily.cvd") == 0) // the CDN said stop

        rig.clock.advance(3600)
        let waiting = await rig.updater().update(trigger: .manual, settings: AVUpdaterRig.settings())
        #expect(rig.transport.count("database.clamav.net") == 1)
        #expect(waiting.problem != nil)

        rig.clock.advance(2 * 3600)
        rig.transport.reset("https://database.clamav.net/main.cvd")
        rig.transport.serve("https://database.clamav.net/main.cvd", status: 403)
        let forbidden = await rig.updater().update(trigger: .manual, settings: AVUpdaterRig.settings())
        #expect(forbidden.state.cdnRetryAfter == rig.clock.now.addingTimeInterval(86_400))
    }

    @Test func backsOffAfterServerErrors() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 100)
        rig.transport.serve("https://database.clamav.net/main.cvd", status: 503)
        rig.transport.serve("https://database.clamav.net/daily.cvd", status: 503)
        let first = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(first.state[.main].consecutiveFailures == 1)
        #expect(first.state[.main].nextAllowedFullDownload == rig.clock.now.addingTimeInterval(900))
        rig.clock.advance(60)
        _ = await rig.updater().update(trigger: .manual, settings: AVUpdaterRig.settings())
        #expect(rig.transport.count("main.cvd") == 1) // still backing off
    }

    @Test func keepsThePreviousDatabaseWhenCompilingFails() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        let installed = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        let before = try Data(contentsOf: rig.paths.engine.appendingPathComponent("compiled.txt"))

        try AVSyntheticDatabase.writeContainer(version: 101, to: rig.directory.child("served/daily.cvd"))
        rig.versions = .versions(main: 63, daily: 101)
        rig.toolkit.compileError = AVEngineError.invalidDatabase("synthetic failure")
        rig.clock.advance(25 * 3600)
        let failed = await rig.updater().update(trigger: .manual, settings: AVUpdaterRig.settings())
        #expect(failed.problem?.contains("previous definitions stay in use") == true)
        #expect(!failed.installedNewDatabase)
        #expect(failed.state.installed == installed.state.installed)
        #expect(try Data(contentsOf: rig.paths.engine.appendingPathComponent("compiled.txt")) == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.paths.root.path).filter { $0.hasPrefix("engine.staging") }
        #expect(leftovers.isEmpty)

        // The next run retries the compile with the kept download (no new download).
        rig.toolkit.compileError = nil
        rig.clock.advance(5 * 3600)
        let retried = await rig.updater().update(trigger: .automatic, settings: AVUpdaterRig.settings())
        #expect(retried.installedNewDatabase)
        #expect(retried.state.installed?.clamavVersions["daily"] == 101)
        #expect(rig.transport.count("daily.cvd") == 2)
    }

    @Test func rollsBackWhenTheNewDatabaseDoesNotLoad() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        let installed = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        let before = try Data(contentsOf: rig.paths.engine.appendingPathComponent("compiled.txt"))
        try AVSyntheticDatabase.writeContainer(version: 101, to: rig.directory.child("served/daily.cvd"))
        rig.versions = .versions(main: 63, daily: 101)
        rig.clock.advance(25 * 3600)
        rig.toolkit.loadError = AVEngineError.invalidDatabase("won't load")
        let outcome = await rig.updater().update(trigger: .manual, settings: AVUpdaterRig.settings())
        #expect(!outcome.installedNewDatabase)
        #expect(outcome.problem != nil)
        #expect(outcome.state.installed == installed.state.installed)
        #expect(rig.toolkit.compileCount == 2)
        #expect(try Data(contentsOf: rig.paths.engine.appendingPathComponent("compiled.txt")) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.paths.root.path).allSatisfy { !$0.hasPrefix("engine.staging") })
    }

    @Test func readsVersionsFromHeadersWhenDNSFails() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        rig.versions = AVFakeVersionLookup(info: nil)
        let outcome = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(outcome.state.lastVersionInfo?.source == .databaseHeaders)
        #expect(outcome.state.lastVersionInfo?.daily == 100)
        #expect(rig.transport.requests.contains { $0.headers["Range"] == "bytes=0-511" })
        #expect(outcome.installedNewDatabase)
    }

    @Test func usesFreshclamWhenItIsInstalled() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        let source = rig.directory.child("freshclam-output")
        try AVSyntheticDatabase.writeContainer(version: 63, to: source.appendingPathComponent("main.cvd"))
        try AVSyntheticDatabase.writeDaily(version: 100, signatures: "Test.Sig:0:*:00\n", to: source.appendingPathComponent("daily.cld"))
        rig.freshclam = AVFreshclamTool(path: "/opt/homebrew/bin/freshclam", version: "ClamAV 1.4.3")
        rig.runFreshclam = { _, paths, _ in
            try paths.prepare()
            for name in ["main.cvd", "daily.cld"] {
                try? FileManager.default.removeItem(at: paths.clamav.appendingPathComponent(name))
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: paths.clamav.appendingPathComponent(name))
            }
            return AVFreshclamOutput.report(lines: ["main.cvd updated (version: 63, sigs: 10, f-level: 90, builder: test)",
                                                    "daily.cld updated (version: 100, sigs: 10, f-level: 90, builder: test)"], exitCode: 0)
        }
        let outcome = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(outcome.problem == nil)
        #expect(outcome.state.lastUpdater == .freshclam)
        #expect(outcome.state.freshclamVersion == "ClamAV 1.4.3")
        #expect(outcome.state[.daily].version == 100)
        #expect(outcome.installedNewDatabase)
        #expect(rig.transport.count("database.clamav.net") == 0)

        // With the setting off, the built-in updater runs instead.
        var settings = AVUpdaterRig.settings()
        settings.useFreshclam = false
        rig.versions = .versions(main: 63, daily: 100)
        rig.clock.advance(5 * 3600)
        let builtIn = await rig.updater().update(trigger: .automatic, settings: settings)
        #expect(builtIn.state.lastUpdater == .builtIn)
    }

    @Test func fallsBackWhenFreshclamCannotUseTheConfiguration() async throws {
        var rig = try AVUpdaterRig(main: 63, daily: 100)
        try rig.serveContainers(main: 63, daily: 100)
        rig.freshclam = AVFreshclamTool(path: "/opt/homebrew/bin/freshclam", version: nil)
        rig.runFreshclam = { _, _, _ in AVFreshclamOutput.report(lines: ["ERROR: Parse error at line 3"], exitCode: 56) }
        let outcome = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings())
        #expect(outcome.state.lastUpdater == .builtIn)
        #expect(outcome.installedNewDatabase)
        #expect(rig.transport.count("main.cvd") == 1)
    }

    @Test(.enabled(if: AVRealFiles.hasClamAV && AVRealFiles.hasFeeds))
    func installsTheRealDownloadsAndFeeds() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 28155)
        rig.transport.serve("https://database.clamav.net/main.cvd", file: AVRealFiles.url("clamav/main.cvd"))
        rig.transport.serve("https://database.clamav.net/daily.cvd", file: AVRealFiles.url("clamav/daily.cvd"))
        rig.transport.serve(AVFeedID.malwareBazaarRecent.url.absoluteString, file: AVRealFiles.url("abusech/mb-recent.txt"))
        rig.transport.serve(AVFeedID.urlhausOnline.url.absoluteString, file: AVRealFiles.url("abusech/urlhaus-online.txt"))
        rig.transport.serve(AVFeedID.urlhausHosts.url.absoluteString, file: AVRealFiles.url("abusech/urlhaus-hostfile.txt"))
        rig.transport.serve(AVFeedID.threatFoxRecent.url.absoluteString, file: AVRealFiles.url("abusech/threatfox-recent.json"))
        let outcome = await rig.updater().update(trigger: .firstInstall, settings: AVUpdaterRig.settings(feeds: true))
        #expect(outcome.problem == nil)
        #expect(outcome.state.installed?.clamavVersions == ["main": 63, "daily": 28155])
        #expect((outcome.state[.malwareBazaarRecent].entryCount) > 500)
        #expect(outcome.state[.threatFoxRecent].entryCount > 5_000)
        #expect(outcome.intel?.match(host: "github.com") == nil)
        let lists = try #require(rig.toolkit.lastInputs?.sha256Lists)
        #expect(lists.contains { $0.source == .malwareBazaar })
        #expect(lists.contains { $0.source == .threatFox })
        #expect(rig.transport.requests.filter { $0.url.host?.hasSuffix("abuse.ch") == true }.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("ClamAV") == false })

        // Turning a feed off removes its data and rebuilds without it.
        var settings = AVUpdaterRig.settings(feeds: true)
        settings.sources.threatFox = false
        rig.clock.advance(5 * 3600)
        let without = await rig.updater().update(trigger: .automatic, settings: settings)
        #expect(without.installedNewDatabase)
        #expect(rig.toolkit.lastInputs?.sha256Lists.contains { $0.source == .threatFox } == false)
    }

    // MARK: - freshclam

    @Test func parsesFreshclamOutput() {
        let lines = [
            "ClamAV update process started at Thu Oct 16 14:00:00 2026",
            "daily database available for update (local version: 28150, remote version: 28155)",
            "Downloading database patch # 28151...",
            "Time:    0.1s, ETA:    0.0s [========================>]    1.07KiB/2.14KiB",
            "Testing database: '/tmp/clamav-6d6a.tmp-daily.cld' ...",
            "daily.cld updated (version: 28155, sigs: 2077600, f-level: 90, builder: raynman)",
            "main.cvd database is up-to-date (version: 63, sigs: 3287027, f-level: 90, builder: tomjudge)",
            "WARNING: You are on cool-down until after: 2026-10-17 05:44:34",
        ]
        let utc = TimeZone(identifier: "UTC")!
        #expect(AVFreshclamOutput.event(for: lines[2], timeZone: utc) == .downloadingPatch(28151))
        #expect(AVFreshclamOutput.event(for: lines[3], timeZone: utc) == .progress(0.5))
        let report = AVFreshclamOutput.report(lines: lines, exitCode: 0, timeZone: utc)
        #expect(report.updated == ["daily": 28155])
        #expect(report.upToDate == ["main": 63])
        #expect(report.coolDownUntil == ISO8601DateFormatter().date(from: "2026-10-17T05:44:34Z"))
        #expect(report.succeeded)
        #expect(report.changed)
        let failed = AVFreshclamOutput.report(lines: ["ERROR: Can't download daily.cvd from https://database.clamav.net/daily.cvd"], exitCode: 58)
        #expect(!failed.succeeded)
        #expect(failed.summary.contains("Can't download"))
        #expect(AVFreshclamOutput.version(from: "ClamAV 1.4.3/28155/Thu Oct 16 06:24:00 2026\n") == "ClamAV 1.4.3")
    }

    @Test func writesAPrivateFreshclamConfiguration() throws {
        let directory = try AVTestFolder()
        let paths = directory.paths
        try AVFreshclamConfiguration.write(paths: paths)
        let text = try String(contentsOf: paths.freshclamConfig, encoding: .utf8)
        #expect(text.contains("DatabaseDirectory \(paths.clamav.path)\n"))
        #expect(text.contains("UpdateLogFile \(paths.freshclamLog.path)\n"))
        #expect(text.contains("DatabaseMirror database.clamav.net\n"))
        #expect(text.contains("ScriptedUpdates yes\n"))
        #expect(text.contains("Bytecode no\n"))
        #expect(text.contains("Foreground yes\n"))
        #expect(!text.contains("Example"))
        let arguments = AVFreshclamConfiguration.arguments(paths: paths)
        #expect(arguments.first == "--config-file=\(paths.freshclamConfig.path)")
        #expect(arguments.contains("--stdout"))
        #expect(!arguments.contains("--daemon"))
        let install = AVHomebrew.installCommand(brew: "/opt/homebrew/bin/brew")
        #expect(install.executable == "/opt/homebrew/bin/brew")
        #expect(install.arguments == ["install", "clamav"])
        #expect(install.display == "brew install clamav")
        #expect(AVHomebrew.environment()["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func findsFreshclamAtKnownLocations() async {
        let found = await AVFreshclamLocator.locate(candidates: ["/nonexistent/freshclam", "/usr/local/bin/freshclam"],
                                                    isExecutable: { $0 == "/usr/local/bin/freshclam" }, brew: nil)
        #expect(found == "/usr/local/bin/freshclam")
        let missing = await AVFreshclamLocator.locate(candidates: ["/nonexistent/freshclam"], isExecutable: { _ in false }, brew: nil)
        #expect(missing == nil)
    }
}

/// While the app runs, automatic updates keep a full interval between checks, also after one fails
/// (a failure used to be retried within a minute, again and again).
@MainActor
@Suite("Antivirus automatic update schedule")
struct AVAutomaticUpdateScheduleTests {
    @Test func aFailedUpdateIsNotRetriedBeforeTheInterval() async throws {
        let rig = try AVUpdaterRig(main: 63, daily: 28155)   // nothing is served: every download fails
        try rig.paths.prepare()
        var state = AVDefinitionsState()
        state.firstInstallRequested = true
        try AVStateFile(url: rig.paths.stateFile).save(state)
        let defaults = try #require(UserDefaults(suiteName: "AVSchedule-\(UUID().uuidString)"))
        let services = AppServices(settings: SettingsManager(defaults: defaults), permissions: PermissionManager(),
                                   history: HistoryStore(directory: rig.directory.child("History")),
                                   logger: ActivityLogger(directory: rig.directory.child("Logs")))
        var environment = AntivirusEnvironment(paths: rig.paths, engine: AVEngineHolder(), intel: AVIntelHolder(),
                                               updater: rig.environment(), makeEventSource: { AVFakeEventSource() },
                                               home: rig.directory.path)
        environment.firstAutoUpdateDelay = 0.05
        environment.autoUpdateInterval = 3600
        environment.startsShields = false
        let model = AntivirusViewModel(services: services, environment: environment, defaults: defaults,
                                       eventLog: ProtectionEventLog(directory: nil))
        model.start()

        try await Task.sleep(for: .seconds(2))
        // Stop the schedule first, so a regression can't keep the test host busy after the test.
        model.settings.automaticUpdates = false
        model.scheduleAutomaticUpdates()
        let problems = await services.logger.recentEvents().filter { $0.message.contains("definitions update problem") }
        #expect(problems.count == 1, "\(problems.map(\.message))")
    }
}
