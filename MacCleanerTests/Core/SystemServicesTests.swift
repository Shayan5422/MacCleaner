import Foundation
import Testing
@testable import MacCleaner

@Suite("Process runner")
struct CoreProcessRunnerTests {
    @Test func capturesOutputAndExitCode() async throws {
        let result = try await ProcessRunner.run("/bin/echo", arguments: ["hello", "world"])
        #expect(result.succeeded)
        #expect(result.standardOutput == "hello world\n")
        let failing = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"])
        #expect(failing.exitCode == 3)
        #expect(failing.standardError.contains("oops"))
    }

    @Test func enforcesTimeout() async throws {
        let started = Date()
        let result = try await ProcessRunner.run("/bin/sleep", arguments: ["10"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func backgroundChildHoldingOutputDoesNotHang() async throws {
        let started = Date()
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 15 & echo done"], timeout: 20)
        #expect(result.standardOutput.contains("done"))
        #expect(Date().timeIntervalSince(started) < 10, "must not wait for the background child")
    }

    @Test func missingToolThrows() async {
        await #expect(throws: CommandError.self) {
            _ = try await ProcessRunner.run("/nonexistent/tool")
        }
    }

    @Test func argumentsAreNeverInterpretedByAShell() async throws {
        let result = try await ProcessRunner.run("/bin/echo", arguments: ["$(whoami); rm -rf /"])
        #expect(result.standardOutput == "$(whoami); rm -rf /\n")
    }
}

@Suite("Processes, signatures and apps")
struct CoreSystemInspectionTests {
    @Test func listsOwnProcessWithMemory() throws {
        let me = try #require(ProcessInspector.snapshot(pid: getpid()))
        #expect(me.memoryFootprint > 0)
        #expect(me.isOwnedByCurrentUser)
        #expect(ProcessInspector.allProcesses().count > 10)
    }

    @Test func appleAppsHaveValidAppleSignatures() {
        let info = CodeSignatureInspector.inspect(path: "/System/Applications/Calculator.app")
        #expect(info.status == .valid)
        #expect(info.isAppleSigned)
        #expect(info.developerName == "Apple")
    }

    @Test func scriptsAreUnsigned() throws {
        let tree = try TemporaryTree()
        let script = try tree.makeFile("tool.sh", size: 20)
        let info = CodeSignatureInspector.inspect(path: script)
        #expect(info.status == .unsigned || info.status == .unknown)
        #expect(!info.isAppleSigned)
    }

    @Test func readsAppBundleMetadata() throws {
        let tree = try TemporaryTree()
        try tree.makeDirectory("Sample.app/Contents/MacOS")
        try tree.makeDirectory("Sample.app/Contents/_MASReceipt")
        try tree.makeFile("Sample.app/Contents/_MASReceipt/receipt", size: 10)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample", "CFBundleShortVersionString": "2.1",
            "CFBundleVersion": "210", "CFBundleExecutable": "Sample", "SUFeedURL": "https://example.com/appcast.xml",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: tree.path("Sample.app/Contents/Info.plist")))
        let info = try #require(ApplicationCatalog.read(path: tree.path("Sample.app")))
        #expect(info.bundleIdentifier == "com.example.sample")
        #expect(info.displayVersion == "2.1 (210)")
        #expect(info.isAppStoreApp)
        #expect(info.sparkleFeedURL?.host() == "example.com")
        #expect(info.executablePath?.hasSuffix("Contents/MacOS/Sample") == true)
    }

    @Test func startupVolumeHasCapacity() throws {
        let volume = try #require(VolumeService.startupVolume())
        #expect(volume.totalCapacity > 0)
        #expect(volume.usedCapacity > 0)
        #expect(volume.isRootFileSystem)
        #expect(volume.scanRootPath == "/System/Volumes/Data")
    }
}

@Suite("History store")
struct CoreHistoryStoreTests {
    @Test func keepsNewestFirstAndCaps() async throws {
        let support = try TemporaryTree("Support")
        let store = HistoryStore(directory: URL(fileURLWithPath: support.root))
        for index in 0..<(HistoryStore.maximumEntries + 5) {
            await store.append(CleanupHistoryEntry(title: "Run \(index)", source: .manual, method: .moveToTrash, dryRun: false,
                                                   bytes: 1, itemCount: 1, skippedCount: 0, failedCount: 0, items: []))
        }
        let entries = await store.allEntries()
        #expect(entries.count == HistoryStore.maximumEntries)
        #expect(entries.first?.title == "Run \(HistoryStore.maximumEntries + 4)")

        // Persisted across instances.
        let reloaded = await HistoryStore(directory: URL(fileURLWithPath: support.root)).allEntries()
        #expect(reloaded.count == HistoryStore.maximumEntries)
    }

    @Test func restoreNeverOverwrites() async throws {
        let support = try TemporaryTree("Support")
        let files = try TemporaryTree()
        let original = try files.makeFile("doc.txt")
        let trashed = try files.makeFile("trash/doc.txt")
        let store = HistoryStore(directory: URL(fileURLWithPath: support.root))
        let entry = CleanupHistoryEntry(title: "T", source: .manual, method: .moveToTrash, dryRun: false, bytes: 1, itemCount: 1,
                                        skippedCount: 0, failedCount: 0,
                                        items: [.init(originalPath: original, trashedPath: trashed, bytes: 1, category: "Files")])
        await store.append(entry)
        let result = await store.restore(entryID: entry.id)
        #expect(result.restored.isEmpty)
        #expect(result.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: trashed))
    }
}
