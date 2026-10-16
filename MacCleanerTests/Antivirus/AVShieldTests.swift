import Darwin
import Foundation
import Testing
@testable import MacCleaner

/// Collects shield notices from any thread.
final class AVNoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [AVShieldNotice] = []

    func append(_ notice: AVShieldNotice) { lock.withLock { notices.append(notice) } }

    var detections: [(AVThreat, AVShieldKind)] {
        lock.withLock { notices.compactMap { if case .detection(let threat, let kind) = $0 { return (threat, kind) } else { return nil } } }
    }

    var deniedFolders: [String] {
        lock.withLock { notices.compactMap { if case .accessDenied(let folder) = $0 { return folder } else { return nil } } }
    }

    var activities: [AVShieldActivity] {
        lock.withLock { notices.compactMap { if case .activity(let activity) = $0 { return activity } else { return nil } } }
    }
}

/// File probes tests control.
final class AVProbeTable: @unchecked Sendable {
    private let lock = NSLock()
    private var probes: [String: AVFileProbe] = [:]

    func set(_ path: String, size: Int64, dataless: Bool = false, regular: Bool = true) {
        lock.withLock { probes[path] = AVFileProbe(size: size, modified: TimeInterval(size), isRegular: regular, isDataless: dataless) }
    }

    func remove(_ path: String) { lock.withLock { probes[path] = nil } }
    func probe(_ path: String) -> AVFileProbe? { lock.withLock { probes[path] } }
}

@Suite("Antivirus shields")
struct AVShieldTests {
    @Test func waitsUntilAFileStopsChanging() {
        let clock = AVTestClock()
        let probes = AVProbeTable()
        let tracker = AVFileSettleTracker(settleInterval: 1.5, probe: { probes.probe($0) }, now: { clock.now })
        let path = "/Users/me/Downloads/video.mov"
        probes.set(path, size: 100)
        tracker.record([AVFileEvent(path: path, flags: AVFileEvent.created)])
        #expect(tracker.poll().isEmpty) // first look
        clock.advance(1.0)
        probes.set(path, size: 5_000) // still being written
        #expect(tracker.poll().isEmpty)
        clock.advance(1.0)
        #expect(tracker.poll().isEmpty) // stable for 1 s only
        clock.advance(0.6)
        #expect(tracker.poll() == [path])
        #expect(tracker.pendingCount == 0)
        clock.advance(5)
        #expect(tracker.poll().isEmpty)
    }

    @Test func ignoresDownloadsInProgressUntilRenamed() {
        let clock = AVTestClock()
        let probes = AVProbeTable()
        let tracker = AVFileSettleTracker(settleInterval: 1.5, probe: { probes.probe($0) }, now: { clock.now })
        for partial in ["/Users/me/Downloads/setup.dmg.crdownload", "/Users/me/Downloads/setup.dmg.part",
                        "/Users/me/Downloads/setup.dmg.partial", "/Users/me/Downloads/setup.dmg.download/setup.dmg"] {
            probes.set(partial, size: 10)
            tracker.record([AVFileEvent(path: partial, flags: AVFileEvent.modified)])
        }
        #expect(tracker.pendingCount == 0)
        #expect(AVFileSettleTracker.isPartialDownload("/a/b.download/c"))
        #expect(!AVFileSettleTracker.isPartialDownload("/a/downloaded/c.txt"))
        let final = "/Users/me/Downloads/setup.dmg"
        probes.set(final, size: 10)
        tracker.record([AVFileEvent(path: final, flags: AVFileEvent.renamed)])
        _ = tracker.poll()
        clock.advance(2)
        #expect(tracker.poll() == [final])
    }

    @Test func dropsRemovedCloudOnlyAndFolderEvents() {
        let clock = AVTestClock()
        let probes = AVProbeTable()
        let tracker = AVFileSettleTracker(settleInterval: 1.5, maxPending: 3, probe: { probes.probe($0) }, now: { clock.now })
        tracker.record([AVFileEvent(path: "/x/gone", flags: AVFileEvent.removed)])
        tracker.record([AVFileEvent(path: "/x/folder", flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir))])
        #expect(tracker.pendingCount == 0)
        probes.set("/x/cloud", size: 10, dataless: true)
        tracker.record([AVFileEvent(path: "/x/cloud", flags: AVFileEvent.created)])
        #expect(tracker.pendingCount == 1)
        #expect(tracker.poll().isEmpty)
        #expect(tracker.pendingCount == 0) // cloud-only files are never opened
        for index in 0..<5 { tracker.record([AVFileEvent(path: "/x/file\(index)", flags: AVFileEvent.created)]) }
        #expect(tracker.pendingCount == 3)
        #expect(tracker.droppedCount == 2)
    }

    private func makeShield(_ directory: AVTestFolder, source: AVFakeEventSource, clock: AVTestClock, box: AVNoticeBox,
                            intel: AVThreatIntelIndex? = nil, allowed: Set<String> = []) -> AVFileShield {
        var configuration = AVFileShield.Configuration(folders: [directory.child("watched").path, directory.child("Downloads").path],
                                                       downloadsFolder: directory.child("Downloads").path)
        configuration.allowedHashes = allowed
        configuration.skippedRoots = [directory.child("watched/antivirus").path]
        let tracker = AVFileSettleTracker(settleInterval: 1.5, now: { clock.now })
        return AVFileShield(source: source, scanner: { AVFakeScanner() }, intel: { intel }, configuration: configuration, tracker: tracker) { box.append($0) }
    }

    private func settle(_ shield: AVFileShield, clock: AVTestClock) {
        shield.processReady()
        clock.advance(2)
        shield.processReady()
    }

    @Test func scansNewFilesAndReportsThreats() throws {
        let directory = try AVTestFolder("AVShield")
        let source = AVFakeEventSource()
        let clock = AVTestClock()
        let box = AVNoticeBox()
        let shield = makeShield(directory, source: source, clock: clock, box: box)
        #expect(shield.start())
        #expect(source.watchedPaths.count == 2)
        let evil = try directory.makeFile("watched/evil.bin", contents: AVFakeScanner.malwareMarker)
        let clean = try directory.makeFile("watched/clean.txt")
        let skipped = try directory.makeFile("watched/antivirus/chest-item", contents: AVFakeScanner.malwareMarker)
        source.push([AVFileEvent(path: evil, flags: AVFileEvent.created), AVFileEvent(path: clean, flags: AVFileEvent.created),
                     AVFileEvent(path: skipped, flags: AVFileEvent.created)])
        settle(shield, clock: clock)
        let detections = box.detections
        #expect(detections.count == 1)
        #expect(detections.first?.0.path == evil)
        #expect(detections.first?.1 == .file)
        #expect(detections.first?.0.foundBy == .fileShield)
        #expect(detections.first?.0.snapshot == FileSnapshot.capture(path: evil))
        #expect(box.activities.contains { $0.path == clean && $0.outcome == .clean })
        #expect(shield.statistics.filesScanned == 2)
        #expect(shield.statistics.threatsFound == 1)
        shield.stop()
        #expect(!shield.isRunning)
    }

    @Test func respectsTheAllowList() throws {
        let directory = try AVTestFolder("AVShield")
        let source = AVFakeEventSource()
        let clock = AVTestClock()
        let box = AVNoticeBox()
        let content = AVFakeScanner.malwareMarker + Data("known good".utf8)
        let shield = makeShield(directory, source: source, clock: clock, box: box, allowed: [AVFileHasher.sha256(data: content)])
        shield.start()
        let path = try directory.makeFile("watched/tool", contents: content)
        source.push([AVFileEvent(path: path, flags: AVFileEvent.created)])
        settle(shield, clock: clock)
        #expect(box.detections.isEmpty)
    }

    @Test func flagsDownloadsFromMalwareSites() throws {
        let directory = try AVTestFolder("AVShield")
        let source = AVFakeEventSource()
        let clock = AVTestClock()
        let box = AVNoticeBox()
        let now = Date()
        var database = AVIntelDatabase()
        database.merge([AVIndicator(kind: .host, value: "evil-c2.example", source: .urlhaus, threatType: "malware_download", firstSeen: now, lastSeen: now)])
        let shield = makeShield(directory, source: source, clock: clock, box: box, intel: database.index())
        shield.start()
        let path = try directory.makeFile("Downloads/installer.pkg", contents: Data("no signature matches".utf8))
        try AVDownloadOriginTests.setWhereFroms(["https://files.evil-c2.example/installer.pkg"], on: path)
        let elsewhere = try directory.makeFile("watched/installer.pkg", contents: Data("no signature matches".utf8))
        try AVDownloadOriginTests.setWhereFroms(["https://files.evil-c2.example/installer.pkg"], on: elsewhere)
        source.push([AVFileEvent(path: path, flags: AVFileEvent.created), AVFileEvent(path: elsewhere, flags: AVFileEvent.created)])
        settle(shield, clock: clock)
        let detection = try #require(box.detections.first)
        #expect(box.detections.count == 1)
        #expect(detection.1 == .download)
        #expect(detection.0.category == .maliciousDownload)
        #expect(detection.0.origin?.intelMatch?.indicator == "evil-c2.example")
    }

    @Test func reportsFoldersItCannotRead() throws {
        let directory = try AVTestFolder("AVShield")
        let source = AVFakeEventSource()
        let clock = AVTestClock()
        let box = AVNoticeBox()
        let shield = makeShield(directory, source: source, clock: clock, box: box)
        shield.start()
        let path = try directory.makeFile("watched/private.txt", mode: 0o000)
        defer { chmod(path, 0o644) }
        let second = try directory.makeFile("watched/second.txt", mode: 0o000)
        defer { chmod(second, 0o644) }
        source.push([AVFileEvent(path: path, flags: AVFileEvent.created), AVFileEvent(path: second, flags: AVFileEvent.created)])
        settle(shield, clock: clock)
        #expect(box.deniedFolders == [directory.child("watched").path])
        #expect(shield.statistics.deniedFolders == [directory.child("watched").path])
    }

    @Test func watchesTheStandardFolders() {
        let folders = AVFileShield.Configuration.standardFolders(home: "/Users/me")
        #expect(folders.contains("/Users/me/Downloads"))
        #expect(folders.contains("/Users/me/Desktop"))
        #expect(folders.contains("/Users/me/Documents"))
        #expect(folders.contains("/Applications"))
        #expect(folders.contains("/Users/me/Applications"))
        #expect(folders.contains("/Library/LaunchDaemons"))
        #expect(folders.contains("/Library/LaunchAgents"))
        #expect(folders.contains("/Users/me/Library/LaunchAgents"))
        #expect(folders.contains("/Users/Shared"))
    }

    @Test func settingsUseAntivirusKeys() throws {
        let suite = "MacCleanerTests.Antivirus.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AVSettingsSnapshot(defaults: defaults).isRealTimeProtectionOn(definitionsInstalled: false) == false)
        #expect(AVSettingsSnapshot(defaults: defaults).isRealTimeProtectionOn(definitionsInstalled: true))
        defaults.set(false, forKey: AntivirusSettings.Key.realTimeProtection)
        defaults.set(50, forKey: AntivirusSettings.Key.maxFileSizeMB)
        defaults.set(true, forKey: AntivirusSettings.Key.sourceMalwareBazaarFull)
        let snapshot = AVSettingsSnapshot(defaults: defaults)
        #expect(snapshot.isRealTimeProtectionOn(definitionsInstalled: true) == false)
        #expect(snapshot.scanOptions.maxFileSize == 50_000_000)
        #expect(snapshot.sources.malwareBazaarFull)
        #expect(snapshot.puaAction == .notify)
        #expect(snapshot.autoQuarantineMalware)
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("antivirus.") }
        #expect(keys.count == 3)
    }
}

@MainActor
@Suite("Antivirus settings")
struct AVSettingsTests {
    @Test func storesAllowListAndExclusions() throws {
        let suite = "MacCleanerTests.Antivirus.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AntivirusSettings(defaults: defaults)
        #expect(settings.allow(sha256: String(repeating: "A", count: 64), name: "tool"))
        #expect(!settings.allow(sha256: "not-a-hash"))
        settings.addExclusion("/Users/me/Projects/malware-research")
        settings.puaAction = .quarantine
        let reloaded = AntivirusSettings(defaults: defaults)
        #expect(reloaded.isAllowed(sha256: String(repeating: "a", count: 64)))
        #expect(reloaded.exclusions.paths == ["/Users/me/Projects/malware-research"])
        #expect(reloaded.puaAction == .quarantine)
        reloaded.removeAllowed(sha256: String(repeating: "a", count: 64))
        #expect(AntivirusSettings(defaults: defaults).allowedHashes.isEmpty)
    }
}
