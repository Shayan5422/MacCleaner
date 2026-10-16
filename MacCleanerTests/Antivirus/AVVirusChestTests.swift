import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Antivirus Virus Chest")
struct AVVirusChestTests {
    private func makeChest(_ directory: AVTestFolder) -> AVVirusChest {
        let home = directory.child("home").path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let policy = AVQuarantinePolicy(home: home, ownBundlePath: "/Applications/Mac Cleaner.app",
                                        ownDataDirectory: home + "/Library/Application Support/Mac Cleaner")
        return AVVirusChest(paths: directory.paths, policy: policy, logger: ActivityLogger(directory: directory.child("logs")))
    }

    private func request(_ path: String, category: AVThreatCategory = .malware) -> AVQuarantineRequest {
        AVQuarantineRequest(path: path, expected: FileSnapshot.capture(path: path), signatureName: "Osx.Test.FakeMalware", category: category,
                            sha256: AVFileHasher.sha256(path: path), source: .scan)
    }

    @Test func quarantinesAndRestoresAFile() async throws {
        let directory = try AVTestFolder("AVChest")
        let chest = makeChest(directory)
        let content = AVFakeScanner.malwareMarker + Data(" original bytes".utf8)
        let path = try directory.makeFile("home/Downloads/invoice.dmg", contents: content, mode: 0o751)
        AVDownloadOriginTests.setQuarantine("0083;6a2c78e7;Safari;", on: path)

        let item = try await chest.quarantine(request(path))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(item.originalPath == path)
        #expect(item.originalMode == 0o751)
        #expect(item.originalOwner == getuid())
        #expect(item.sha256 == AVFileHasher.sha256(data: content))
        #expect(await chest.items().map(\.id) == [item.id])

        // Stored masked: the payload doesn't contain the original bytes and is private.
        let payload = directory.paths.quarantine.appendingPathComponent(item.id + ".mcchest")
        let stored = try Data(contentsOf: payload)
        #expect(stored.range(of: AVFakeScanner.malwareMarker) == nil)
        #expect(stored.prefix(8) == Data("MCCHEST1".utf8))
        var info = stat()
        stat(payload.path, &info)
        #expect(info.st_mode & 0o777 == 0o600)
        stat(directory.paths.quarantine.path, &info)
        #expect(info.st_mode & 0o777 == 0o700)

        let restored = try await chest.restore(item)
        #expect(restored == path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == content)
        stat(path, &info)
        #expect(info.st_mode & 0o7777 == 0o751)
        #expect(SecurityQuarantineInfo.read(path: path)?.agent == "Safari")
        #expect(await chest.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
    }

    @Test func quarantinesAndRestoresAnAppBundle() async throws {
        let directory = try AVTestFolder("AVChest")
        let chest = makeChest(directory)
        let app = try directory.makeDirectory("home/Applications/Evil.app")
        try directory.makeFile("home/Applications/Evil.app/Contents/MacOS/Evil", contents: AVFakeScanner.malwareMarker, mode: 0o755)
        try directory.makeFile("home/Applications/Evil.app/Contents/Info.plist", contents: Data("<plist/>".utf8))
        try directory.makeFile("home/Applications/Evil.app/Contents/Resources/a/b/c.txt", contents: Data("deep".utf8))
        let item = try await chest.quarantine(request(app))
        #expect(item.isDirectory)
        #expect(!FileManager.default.fileExists(atPath: app))
        let restored = try await chest.restore(item)
        #expect(restored == app)
        #expect(try Data(contentsOf: URL(fileURLWithPath: app + "/Contents/MacOS/Evil")) == AVFakeScanner.malwareMarker)
        #expect(try String(contentsOfFile: app + "/Contents/Resources/a/b/c.txt", encoding: .utf8) == "deep")
        #expect(FileManager.default.isExecutableFile(atPath: app + "/Contents/MacOS/Evil"))
    }

    @Test func restoresElsewhereWhenTheOriginalPlaceIsTaken() async throws {
        let directory = try AVTestFolder("AVChest")
        let chest = makeChest(directory)
        let path = try directory.makeFile("home/Desktop/tool", contents: Data("first".utf8))
        let item = try await chest.quarantine(request(path))
        try directory.makeFile("home/Desktop/tool", contents: Data("new file with the same name".utf8))
        await #expect(throws: AVChestError.destinationExists(path)) { try await chest.restore(item) }
        let other = try directory.makeDirectory("home/Restored")
        let restored = try await chest.restore(item, toFolder: other)
        #expect(restored == other + "/tool")
        #expect(try String(contentsOfFile: restored, encoding: .utf8) == "first")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new file with the same name")
    }

    @Test func refusesItemsThatChangedSinceTheScan() async throws {
        let directory = try AVTestFolder("AVChest")
        let chest = makeChest(directory)
        let path = try directory.makeFile("home/Downloads/file.bin", contents: AVFakeScanner.malwareMarker)
        let scanned = request(path)
        try FileManager.default.removeItem(atPath: path)
        try directory.makeFile("home/Downloads/file.bin", contents: Data("a different file now".utf8))
        await #expect(throws: AVChestError.changedSinceScan) { try await chest.quarantine(scanned) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "a different file now")
        #expect(await chest.items().isEmpty)
    }

    @Test func refusesProtectedLocations() throws {
        let directory = try AVTestFolder("AVChest")
        let home = directory.child("home").path
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        let policy = AVQuarantinePolicy(home: home, ownBundlePath: "/Applications/Mac Cleaner.app", ownDataDirectory: home + "/Library/Application Support/Mac Cleaner")
        func refused(_ path: String) -> Bool { if case .refused = policy.evaluate(path) { return true } else { return false } }
        #expect(refused("/System/Library/CoreServices/Finder.app"))
        #expect(refused("/usr/bin/true"))
        #expect(refused("/bin/sh"))
        #expect(refused("/Applications"))
        #expect(refused("/Applications/Mac Cleaner.app/Contents/MacOS/Mac Cleaner"))
        #expect(refused(home))
        #expect(refused(home + "/Downloads"))
        #expect(refused(home + "/Library/Keychains/login.keychain-db"))
        #expect(refused(home + "/Library/Application Support/Mac Cleaner/Antivirus/state.json"))
        #expect(refused("relative/path"))
        #expect(refused(home + "/../etc"))
        #expect(refused(home + "/Downloads/missing.bin"))
    }

    @Test func refusesSymlinkedAndLockedItems() throws {
        let directory = try AVTestFolder("AVChest")
        let home = directory.child("home").path
        let policy = AVQuarantinePolicy(home: home, ownBundlePath: "/Applications/Mac Cleaner.app", ownDataDirectory: home + "/Library/Application Support/Mac Cleaner")
        try directory.makeFile("home/real/file.bin")
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/real")
        if case .refused(let reason) = policy.evaluate(home + "/link/file.bin") { #expect(reason.contains("symbolic link")) } else { Issue.record("symlinked parent allowed") }
        let locked = try directory.makeFile("home/real/locked.bin")
        chflags(locked, UInt32(UF_IMMUTABLE))
        defer { chflags(locked, 0) }
        if case .refused(let reason) = policy.evaluate(locked) { #expect(reason.contains("locked")) } else { Issue.record("locked item allowed") }
        #expect(policy.evaluate(home + "/real/file.bin") == .allowed)
    }

    @Test func explainsItemsThatNeedAnAdministrator() async throws {
        let directory = try AVTestFolder("AVChest")
        let chest = makeChest(directory)
        let folder = try directory.makeDirectory("home/ReadOnly")
        let path = try directory.makeFile("home/ReadOnly/agent", contents: AVFakeScanner.malwareMarker)
        chmod(folder, 0o555)
        defer { chmod(folder, 0o755) }
        do {
            _ = try await chest.quarantine(request(path))
            Issue.record("expected a refusal")
        } catch let error as AVChestError {
            guard case .needsAdministrator = error else { Issue.record("unexpected \(error)"); return }
            #expect(error.suggestsFinder)
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func deletesAndDetectsDamage() async throws {
        let directory = try AVTestFolder("AVChest")
        let chest = makeChest(directory)
        let first = try directory.makeFile("home/Downloads/a.bin", contents: AVFakeScanner.malwareMarker)
        let second = try directory.makeFile("home/Downloads/b.bin", contents: AVFakeScanner.malwareMarker + Data("b".utf8))
        let itemA = try await chest.quarantine(request(first))
        let itemB = try await chest.quarantine(request(second))
        #expect(await chest.items().count == 2)
        try await chest.delete(itemA)
        #expect(await chest.items().map(\.id) == [itemB.id])
        #expect(!FileManager.default.fileExists(atPath: first))

        let payload = directory.paths.quarantine.appendingPathComponent(itemB.id + ".mcchest")
        var bytes = try Data(contentsOf: payload)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: payload)
        do {
            _ = try await chest.restore(itemB)
            Issue.record("damaged payload restored")
        } catch let error as AVChestError {
            guard case .damaged = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: second))
    }

    @Test func roundTripsThePayloadFormat() throws {
        let directory = try AVTestFolder("AVChest")
        let archive = try directory.makeFile("payload.zip", contents: Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let masked = directory.child("masked.mcchest")
        let (size, hash) = try AVChestPayload.write(archive: URL(fileURLWithPath: archive), to: masked)
        #expect(size == 300_000)
        #expect(try Data(contentsOf: masked).count == 300_000 + 116)
        let output = directory.child("restored.zip")
        try AVChestPayload.read(masked, expectedSHA256: hash, to: output)
        #expect(try Data(contentsOf: output) == Data(contentsOf: URL(fileURLWithPath: archive)))
        #expect(throws: AVChestError.self) { try AVChestPayload.read(masked, expectedSHA256: String(repeating: "0", count: 64), to: directory.child("x")) }
    }

    @Test func decidesWhatIsMovedAutomatically() {
        var settings = AVSettingsSnapshot()
        let malware = AVThreat(path: "/Users/me/Downloads/a.dmg", detections: [AVDetection(signatureName: "Osx.Trojan.X", kind: .malware, source: .clamav, memberPath: nil)])
        let pua = AVThreat(path: "/Users/me/Downloads/b.pkg", detections: [AVDetection(signatureName: "PUA.Osx.X", kind: .pua, source: .clamav, memberPath: nil)])
        let insideApp = AVThreat(path: "/Applications/Tool.app/Contents/MacOS/tool", detections: [AVDetection(signatureName: "Osx.Trojan.X", kind: .malware, source: .clamav, memberPath: nil)])
        let siteOnly = AVThreat(path: "/Users/me/Downloads/c.zip", origin: AVDownloadOrigin(urls: ["https://x.example/c.zip"]))
        let rule = AVThreat(path: "/Users/me/Library/LaunchAgents/com.genieo.engine.plist", ruleMatch: AVRuleMatch(title: "Genieo", family: "Genieo", isMalware: false))
        #expect(AVAutoQuarantine.applies(to: malware, settings: settings))
        #expect(!AVAutoQuarantine.applies(to: pua, settings: settings))
        #expect(!AVAutoQuarantine.applies(to: insideApp, settings: settings))
        #expect(!AVAutoQuarantine.applies(to: siteOnly, settings: settings))
        #expect(!AVAutoQuarantine.applies(to: rule, settings: settings))
        settings.puaAction = .quarantine
        settings.autoQuarantineMalware = false
        #expect(AVAutoQuarantine.applies(to: pua, settings: settings))
        #expect(!AVAutoQuarantine.applies(to: malware, settings: settings))
        #expect(insideApp.enclosingApp == "/Applications/Tool.app")
        #expect(siteOnly.category == .maliciousDownload)
        #expect(rule.category == .pua)
    }
}

@Suite("Review hardening")
struct AVReviewHardeningTests {
    /// abuse.ch's hash lists aren't signed: their matches never move files on their own.
    @Test func unsignedHashListMatchesWaitForThePerson() {
        let settings = AVSettingsSnapshot()
        let bazaarOnly = AVThreat(path: "/Users/me/Downloads/tool", detections: [
            AVDetection(signatureName: "MalwareBazaar.KnownMalware", kind: .malware, source: .malwareBazaar, memberPath: nil),
        ])
        let threatFoxOnly = AVThreat(path: "/Users/me/Downloads/tool2", detections: [
            AVDetection(signatureName: "ThreatFox.KnownMalware", kind: .malware, source: .threatFox, memberPath: nil),
        ])
        let alsoClamAV = AVThreat(path: "/Users/me/Downloads/tool3", detections: [
            AVDetection(signatureName: "MalwareBazaar.KnownMalware", kind: .malware, source: .malwareBazaar, memberPath: nil),
            AVDetection(signatureName: "Osx.Trojan.X", kind: .malware, source: .clamav, memberPath: nil),
        ])
        #expect(!AVAutoQuarantine.applies(to: bazaarOnly, settings: settings))
        #expect(!AVAutoQuarantine.applies(to: threatFoxOnly, settings: settings))
        #expect(AVAutoQuarantine.applies(to: alsoClamAV, settings: settings))
    }

    /// A tampered record (an id or name with "../") is ignored, so restore and delete can't act outside the chest.
    @Test func tamperedChestRecordsAreIgnored() async throws {
        let directory = try AVTestFolder("AVChestTamper")
        let home = directory.child("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let policy = AVQuarantinePolicy(home: home, ownBundlePath: "/Applications/Mac Cleaner.app",
                                        ownDataDirectory: home + "/Library/Application Support/Mac Cleaner")
        let chest = AVVirusChest(paths: directory.paths, policy: policy, logger: ActivityLogger(directory: directory.child("logs")))
        let path = try directory.makeFile("home/Downloads/sample.bin", contents: AVFakeScanner.malwareMarker)
        let item = try await chest.quarantine(AVQuarantineRequest(
            path: path, expected: FileSnapshot.capture(path: path), signatureName: "Osx.Test.FakeMalware", category: .malware,
            sha256: AVFileHasher.sha256(path: path), source: .scan))
        #expect(AVVirusChest.isWellFormed(item))
        var traversal = item
        traversal.id = "../../escape"
        #expect(!AVVirusChest.isWellFormed(traversal))
        var badName = item
        badName.name = "../x"
        #expect(!AVVirusChest.isWellFormed(badName))
        var badPath = item
        badPath.originalPath = "/Users/me/../../etc/sample.bin"
        #expect(!AVVirusChest.isWellFormed(badPath))

        let metadata = directory.paths.quarantine.appendingPathComponent(item.id + ".json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        json["name"] = "../../evil"
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        #expect(await chest.items().isEmpty)
    }
}
