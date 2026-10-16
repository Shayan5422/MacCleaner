import Foundation
import Testing
@testable import MacCleaner

/// Runs the real engine on the real ClamAV downloads. Slow (minutes) and needs the fixture
/// files, so it only runs when `MACCLEANER_AV_REAL_ENGINE=1` is set.
@Suite("Antivirus with the real engine", .enabled(if: ProcessInfo.processInfo.environment["MACCLEANER_AV_REAL_ENGINE"] == "1" && AVRealFiles.hasClamAV))
struct AVEngineIntegrationTests {
    @Test func installsScansAndPatchesWithTheRealEngine() async throws {
        let directory = try AVTestFolder("AVRealEngine")
        let transport = AVFakeTransport()
        transport.serve("https://database.clamav.net/main.cvd", file: AVRealFiles.url("clamav/main.cvd"))
        transport.serve("https://database.clamav.net/daily.cvd", file: AVRealFiles.url("clamav/daily.cvd"))
        if let recent = AVRealFiles.url("abusech/mb-recent.txt") { transport.serve(AVFeedID.malwareBazaarRecent.url.absoluteString, file: recent) }
        let updater = AVDefinitionsUpdater(environment: AVDefinitionsUpdater.Environment(
            paths: directory.paths, transport: transport, versionLookup: AVFakeVersionLookup.versions(main: 63, daily: 28155),
            toolkit: AVLiveToolkit(), locateFreshclam: { nil }, runFreshclam: { _, _, _ in throw CommandError.toolNotFound("freshclam") }
        ))
        var settings = AVSettingsSnapshot()
        settings.sources = AVSourceSelection(malwareBazaarRecent: true, malwareBazaarFull: false, urlhaus: false, threatFox: false)
        let outcome = await updater.update(trigger: .firstInstall, settings: settings)
        #expect(outcome.problem == nil, "\(outcome.problem ?? "")")
        let engine = try #require(outcome.engine)
        #expect(engine.summary.signatureCount > 1_000_000)
        #expect(outcome.state.installed?.clamavVersions == ["main": 63, "daily": 28155])

        // The EICAR test file (another antivirus on the Mac may delete it first).
        let eicar = try directory.makeFile("eicar-test.txt", contents: AVEICAR.data)
        let result = engine.scanner.scanFile(atPath: eicar, options: AVScanOptions())
        if FileManager.default.fileExists(atPath: eicar) || result.isInfected {
            #expect(result.isInfected)
        }
        let clean = try directory.makeFile("clean.txt", contents: Data("Nothing to see here.\n".utf8))
        #expect(!engine.scanner.scanFile(atPath: clean, options: AVScanOptions()).isInfected)

        // A database patched by Mac Cleaner verifies with the engine's own check of the signed index.
        let unpacked = URL(fileURLWithPath: try directory.makeDirectory("daily"))
        _ = try AVClamAVLocalDatabase.unpack(try #require(AVRealFiles.url("clamav/daily.cvd")), to: unpacked)
        if let cdiff = AVRealFiles.url("cdiff/daily-28155.cdiff") {
            let info = unpacked.appendingPathComponent("daily.info")
            var lines = try String(contentsOf: info, encoding: .utf8).components(separatedBy: "\n")
            lines[0] = "ClamAV-VDB:15 Oct 2026 previous version"
            lines[24] = "DSIG:efF/zZFXlSp-previous"
            try Data(lines.joined(separator: "\n").utf8).write(to: info)
            try AVCdiff.apply(try AVCdiff.open(Data(contentsOf: cdiff)).script, in: unpacked)
        }
        let cld = directory.child("daily.cld")
        try AVClamAVLocalDatabase.pack(.daily, from: unpacked, to: cld)
        let header = try ClamAVDatabaseFile.verify(at: cld)
        #expect(header.version == 28155)
        #expect(header.verification == .signedIndex)
    }
}
