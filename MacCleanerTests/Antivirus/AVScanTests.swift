import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Antivirus scans")
struct AVScanTests {
    private func configuration(_ scanner: any AVFileScanning = AVFakeScanner()) -> AVScanConfiguration {
        var configuration = AVScanConfiguration(scanner: scanner)
        configuration.workerCount = 3
        return configuration
    }

    @Test func findsThreatsAndCountsFiles() async throws {
        let tree = try AVTestFolder("AVScan")
        try tree.makeFile("folder/clean.txt")
        try tree.makeFile("folder/nested/deeper/evil.bin", contents: AVFakeScanner.malwareMarker + Data(" payload".utf8))
        try tree.makeFile("folder/adware.pkg", contents: AVFakeScanner.puaMarker)
        try tree.makeFile("folder/.hidden-dropper", contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("single.txt", contents: AVFakeScanner.malwareMarker)
        let plan = AVScanPlanner.custom(paths: [tree.child("folder").path, tree.child("single.txt").path])
        let report = await AVScanCoordinator.run(plan: plan, configuration: configuration())
        #expect(report.filesScanned == 5)
        #expect(report.threats.count == 4)
        #expect(report.threats.first?.category == .malware)
        #expect(report.threats.filter { $0.category == .malware }.count == 3)
        #expect(report.threats.contains { $0.category == .pua && $0.name == "PUA.Osx.Test.Fake" })
        let evil = try #require(report.threats.first { $0.fileName == "evil.bin" })
        #expect(evil.sha256 == AVFileHasher.sha256(path: evil.path))
        #expect(evil.snapshot == FileSnapshot.capture(path: evil.path))
        #expect(!report.wasCancelled)
        #expect(report.summary.threatsFound == 4)
    }

    @Test func detectsTheEICARTestFileWithoutDefinitions() throws {
        #expect(AVEICAR.data.count == 68)
        #expect(AVEICAR.matches(AVEICAR.data))
        #expect(AVEICAR.matches(AVEICAR.data + Data("  \r\n".utf8)))
        #expect(!AVEICAR.matches(AVEICAR.data + Data("x".utf8)))
        #expect(!AVEICAR.matches(Data("x".utf8) + AVEICAR.data))
        let tree = try AVTestFolder("AVEicar")
        let path = try tree.makeFile("test-file.txt", contents: AVEICAR.data)
        let result = AVBuiltInScanner().scanFile(atPath: path, options: AVScanOptions())
        // Another antivirus on the Mac (seen with Avast) may delete the file as soon as it's written.
        if FileManager.default.fileExists(atPath: path) || result.isInfected {
            #expect(result.detections.first?.kind == .testFile)
            #expect(result.detections.first?.source == .builtIn)
            #expect(result.sha256 == AVFileHasher.sha256(data: AVEICAR.data))
        }
        let clean = try tree.makeFile("clean.txt", contents: Data(repeating: 0x41, count: 4_000))
        #expect(!AVBuiltInScanner().scanFile(atPath: clean, options: AVScanOptions()).isInfected)
    }

    @Test func honorsExclusionsAllowListsAndLimits() async throws {
        let tree = try AVTestFolder("AVScan")
        let allowed = try tree.makeFile("root/allowed.bin", contents: AVFakeScanner.malwareMarker + Data("allowed".utf8))
        try tree.makeFile("root/excluded/evil.bin", contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("root/antivirus-data/evil.bin", contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("root/big.bin", contents: AVFakeScanner.malwareMarker + Data(count: 5_000))
        try tree.makeFile("root/found.bin", contents: AVFakeScanner.malwareMarker + Data("found".utf8))
        var configuration = configuration()
        configuration.exclusions = ExclusionList(paths: [tree.child("root/excluded").path])
        configuration.skippedRoots = [tree.child("root/antivirus-data").path]
        configuration.allowedHashes = [try #require(AVFileHasher.sha256(path: allowed))]
        configuration.options.maxFileSize = 1_000
        let report = await AVScanCoordinator.run(plan: AVScanPlanner.custom(paths: [tree.child("root").path]), configuration: configuration)
        #expect(report.threats.map(\.fileName) == ["found.bin"])
        #expect(report.allowedCount == 1)
        #expect(report.skippedTooLarge == 1)
        #expect(report.filesScanned == 2)
    }

    @Test func scansOnlyProgramsWithTheCodeFilter() async throws {
        let tree = try AVTestFolder("AVScan")
        try tree.makeFile("Apps/Tool.app/Contents/MacOS/Tool", contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("Apps/Tool.app/Contents/Resources/install.sh", contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("Apps/Tool.app/Contents/Resources/helper", contents: AVFakeScanner.malwareMarker, mode: 0o755)
        try tree.makeFile("Apps/Tool.app/Contents/Resources/picture.png", contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("Apps/Tool.app/Contents/Resources/notes", contents: AVFakeScanner.malwareMarker, mode: 0o644)
        try tree.makeFile("Apps/Tool.app/Contents/Frameworks/libx.dylib", contents: AVFakeScanner.malwareMarker)
        let plan = AVScanPlan(kind: .quick, targets: [AVScanTarget(path: tree.child("Apps").path, filter: .code, label: "apps")])
        let report = await AVScanCoordinator.run(plan: plan, configuration: configuration())
        #expect(Set(report.threats.map(\.fileName)) == ["Tool", "install.sh", "helper", "libx.dylib"])
    }

    @Test func neverEntersSystemLocations() async throws {
        let plan = AVScanPlanner.custom(paths: ["/System/Library/CoreServices", "/usr/bin/true"])
        #expect(plan.targets.isEmpty && plan.files.isEmpty)
        #expect(plan.limitations.count == 2)
        #expect(AVScanScope.isSystemPath("/System/Volumes/Data/System/Library") == true)
        #expect(AVScanScope.isSystemPath("/System/Volumes/Data/Users/someone") == false)
        #expect(AVScanScope.isSystemPath("/usr/local/bin/tool") == false)
        #expect(AVScanScope.isSystemPath("/usr/libexec/thing") == true)
        #expect(AVScanScope.isSystemPath("/Library/Apple/System") == true)
    }

    @Test func reportsFoldersItCouldNotRead() async throws {
        let tree = try AVTestFolder("AVScan")
        try tree.makeFile("open/readable.txt")
        let locked = try tree.makeDirectory("open/locked")
        try tree.makeFile("open/locked/inside.txt")
        chmod(locked, 0o000)
        let denied = try tree.makeDirectory("denied")
        chmod(denied, 0o000)
        defer { chmod(locked, 0o755); chmod(denied, 0o755) }
        let plan = AVScanPlan(kind: .quick, targets: [
            AVScanTarget(path: tree.child("open").path, label: "the test folder"),
            AVScanTarget(path: denied, label: "your Downloads folder", isPrivacyProtected: true),
        ])
        let report = await AVScanCoordinator.run(plan: plan, configuration: configuration())
        #expect(report.filesScanned == 1)
        #expect(report.limitations.contains { $0.title.contains("couldn't be read") && $0.pane == .fullDiskAccess })
        #expect(report.limitations.contains { $0.title.contains("wasn't allowed to read your Downloads folder") && $0.pane == .filesAndFolders })
    }

    @Test func stopsWhenCancelled() async throws {
        let tree = try AVTestFolder("AVScan")
        for index in 0..<200 { try tree.makeFile("many/file\(index).txt") }
        var configuration = configuration(AVFakeScanner(delay: 0.01))
        configuration.workerCount = 1
        let plan = AVScanPlanner.custom(paths: [tree.child("many").path])
        let task = Task { await AVScanCoordinator.run(plan: plan, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let report = await task.value
        #expect(report.wasCancelled)
        #expect(report.filesScanned < 200)
    }

    @Test func reportsProgressWithHonestTotals() async throws {
        let tree = try AVTestFolder("AVScan")
        for index in 0..<40 { try tree.makeFile("files/file\(index).txt", contents: Data(count: 1_000)) }
        var configuration = configuration(AVFakeScanner(delay: 0.02))
        configuration.workerCount = 1
        let session = AVScanSession(configuration: configuration, kind: .custom)
        let plan = AVScanPlanner.custom(paths: [tree.child("files").path])
        let thread = Task.detached { session.run(plan: plan) }
        try await Task.sleep(for: .milliseconds(200))
        let progress = session.snapshot()
        #expect(progress.filesFound == 40)
        #expect(progress.listingComplete)
        #expect(progress.fraction != nil)
        #expect(progress.filesScanned < 40)
        let report = await thread.value
        #expect(report.filesScanned == 40)
        #expect(session.snapshot().fraction == 1)
    }

    @Test func flagsDownloadsFromKnownMalwareSites() async throws {
        let tree = try AVTestFolder("AVScan")
        let file = try tree.makeFile("Downloads/invoice.dmg", contents: Data("not detected by signatures".utf8))
        try AVDownloadOriginTests.setWhereFroms(["https://dg.888idrcatchy.org/u3", "https://example.com/page"], on: file)
        let now = Date()
        var database = AVIntelDatabase()
        database.merge([AVIndicator(kind: .url, value: "https://dg.888idrcatchy.org/u3", source: .threatFox, threatType: "payload_delivery",
                                    malware: "Vidar", firstSeen: now, lastSeen: now, reference: "1969891")])
        var configuration = configuration()
        configuration.downloadRoots = [tree.child("Downloads").path]
        configuration.intel = database.index()
        let report = await AVScanCoordinator.run(plan: AVScanPlanner.custom(paths: [tree.child("Downloads").path]), configuration: configuration)
        let threat = try #require(report.threats.first)
        #expect(threat.category == .maliciousDownload)
        #expect(threat.origin?.intelMatch?.malware == "Vidar")
        #expect(threat.origin?.downloadURL == "https://dg.888idrcatchy.org/u3")
        #expect(threat.sha256 != nil)
        #expect(threat.name == "Downloaded from a known malware site")
    }

    @Test func plansAQuickScanOfLikelyPlaces() async throws {
        let tree = try AVTestFolder("AVQuick")
        let home = tree.path
        let program = try tree.makeFile("Library/Application Support/Updater/agent", contents: Data("#!/bin/sh\n".utf8), mode: 0o755)
        let plist: [String: Any] = ["Label": "com.example.updater", "ProgramArguments": [program, "--quiet"], "RunAtLoad": true]
        let agents = try tree.makeDirectory("Library/LaunchAgents")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: agents + "/com.example.updater.plist"))
        let adwarePlist: [String: Any] = ["Label": "com.genieo.engine", "Program": "/Applications/Genieo.app/Contents/MacOS/Genieo"]
        try PropertyListSerialization.data(fromPropertyList: adwarePlist, format: .xml, options: 0).write(to: URL(fileURLWithPath: agents + "/com.genieo.engine.plist"))
        let running = try tree.makeFile("bin/running-tool", contents: Data("x".utf8), mode: 0o755)
        let sources = AVQuickScanSources(
            home: home,
            runningExecutables: { [running, "/usr/libexec/syspolicyd"] },
            launchdFolders: [agents],
            loginItemPaths: { nil },
            applicationFolders: [tree.child("Applications").path],
            includesPrivacyProtectedFolders: false,
            knownAdwareLocations: { [] },
            extraRoots: []
        )
        let plan = await AVScanPlanner.quickScan(sources: sources)
        #expect(plan.files.contains(running))
        #expect(plan.files.contains(program))
        #expect(!plan.files.contains("/usr/libexec/syspolicyd"))
        #expect(plan.targets.contains { $0.path == agents && $0.maxDepth == 1 })
        #expect(plan.targets.contains { $0.path == home + "/Library/Application Support" && $0.filter == .code })
        #expect(!plan.targets.contains { $0.path.hasSuffix("/Downloads") })
        #expect(plan.limitations.contains { $0.title.contains("Login items") })
        #expect(plan.limitations.contains { $0.title.contains("Downloads and Desktop") })
        let rule = try #require(plan.ruleMatches.first)
        #expect(rule.ruleMatch?.family == "Genieo")
        #expect(rule.category == .pua)
    }

    @Test func findsBrowserExtensionFolders() throws {
        let tree = try AVTestFolder("AVQuick")
        try tree.makeDirectory("Library/Application Support/Google/Chrome/Default/Extensions/abc")
        try tree.makeDirectory("Library/Application Support/Google/Chrome/Profile 2/Extensions")
        try tree.makeDirectory("Library/Application Support/Google/Chrome/System Profile/Extensions")
        try tree.makeDirectory("Library/Application Support/Firefox/Profiles/x1.default/extensions")
        try tree.makeDirectory("Library/Application Support/BraveSoftware/Brave-Browser/Default/Extensions")
        let targets = AVScanPlanner.browserExtensionTargets(home: tree.path)
        #expect(targets.count == 4)
        #expect(targets.contains { $0.label == "Firefox extensions" })
        #expect(!targets.contains { $0.path.contains("System Profile") })
    }

    @Test func dropsUnwantedSoftwareMadeForWindowsOrLinux() {
        struct Fixed: AVFileScanning {
            var detections: [AVDetection]
            func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult { AVFileScanResult(path: path, detections: detections) }
        }
        func detection(_ name: String, _ kind: AVThreatKind) -> AVDetection { AVDetection(signatureName: name, kind: kind, source: .clamav, memberPath: nil) }
        #expect(AVReportingPolicy.isWindowsOrLinux("PUA.Win.Trojan.Xored-1"))
        #expect(AVReportingPolicy.isWindowsOrLinux("Unix.Tool.Netcat-1"))
        #expect(!AVReportingPolicy.isWindowsOrLinux("PUA.Osx.Adware.Gt32SupportGeeks-1"))
        #expect(!AVReportingPolicy.isWindowsOrLinux("Osx.Trojan.Amos-1"))
        #expect(!AVReportingPolicy.isWindowsOrLinux("MalwareBazaar.SHA256"))
        let windowsPUA = AVReportingPolicy.Scanner(base: Fixed(detections: [detection("PUA.Win.Trojan.Xored-1", .pua)]))
        #expect(!windowsPUA.scanFile(atPath: "/x", options: AVScanOptions()).isInfected)
        let mixed = AVReportingPolicy.Scanner(base: Fixed(detections: [
            detection("PUA.Win.Trojan.Xored-1", .pua), detection("Win.Trojan.Agent-1", .malware), detection("PUA.Osx.Adware.Foo-1", .pua),
        ]))
        #expect(mixed.scanFile(atPath: "/x", options: AVScanOptions()).detections.map(\.signatureName) == ["Win.Trojan.Agent-1", "PUA.Osx.Adware.Foo-1"])
    }
}

@Suite("Quick Scan in Downloads and Desktop")
struct AVQuickScanCarrierTests {
    @Test func downloadsAndDesktopAreLimitedToFilesThatCanCarryMalware() async throws {
        let tree = try AVTestFolder("AVQuickCarriers")
        let sources = AVQuickScanSources(
            home: tree.path,
            runningExecutables: { [] },
            launchdFolders: [],
            loginItemPaths: { [] },
            applicationFolders: [],
            includesPrivacyProtectedFolders: true,
            knownAdwareLocations: { [] },
            extraRoots: []
        )
        let plan = await AVScanPlanner.quickScan(sources: sources)
        for folder in ["/Downloads", "/Desktop"] {
            let target = try #require(plan.targets.first { $0.path == tree.path + folder })
            #expect(target.filter == .carriers)
            #expect(target.skippedFolderNames.isSuperset(of: ["node_modules", ".git", "DerivedData"]))
            #expect(target.arrivedWithinDays == AVScanPlanner.recentDays)
        }
        #expect(!plan.limitations.contains { $0.title.contains("Downloads and Desktop") })
    }

    @Test func carrierFilterKeepsProgramsArchivesAndDocumentsOnly() throws {
        let tree = try AVTestFolder("AVCarrierFilter")
        let tool = try tree.makeFile("tool", contents: Data("#!/bin/sh\n".utf8), mode: 0o755)
        let note = try tree.makeFile("notes", contents: Data("hello".utf8), mode: 0o644)
        for name in ["Invoice.pdf", "setup.exe", "Archive.zip", "Installer.dmg", "report.docm", "page.html", "run.sh", "ext.crx"] {
            #expect(AVCodeFilter.includesCarrier(name: name, parent: "Downloads", path: "/nonexistent/" + name), "\(name)")
        }
        for name in ["photo.jpg", "song.mp3", "movie.mov", "data.csv", "README.md", "notes.txt"] {
            #expect(!AVCodeFilter.includesCarrier(name: name, parent: "Downloads", path: "/nonexistent/" + name), "\(name)")
        }
        // Files without an extension count when they're executable.
        #expect(AVCodeFilter.includesCarrier(name: "tool", parent: "Downloads", path: tool))
        #expect(!AVCodeFilter.includesCarrier(name: "notes", parent: "Downloads", path: note))
    }
}

@Suite("Recent files")
struct AVRecentFileTests {
    /// A file counts as recent when it was modified or created on this volume after the cutoff;
    /// an archive member keeps its old modification date but gets a new creation date when extracted.
    @Test func recentByModificationOrCreation() throws {
        let tree = try AVTestFolder("AVRecent")
        let file = try tree.makeFile("old-member.txt")
        let now = Date().timeIntervalSince1970
        let longAgo = now - 400 * 86_400
        #expect(AVScanSession.arrived(after: now - 90 * 86_400, modified: now, path: file))
        // Old modification date, but created just now (like an extracted archive member).
        #expect(AVScanSession.arrived(after: now - 90 * 86_400, modified: longAgo, path: file))
        // A cutoff in the future: nothing about the file is newer.
        #expect(!AVScanSession.arrived(after: now + 3600, modified: longAgo, path: file))
    }
}
