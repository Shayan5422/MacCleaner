import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacCleaner

/// `AVEngine.scanFile`: what is skipped, what is read, and what the result reports.
///
/// On-disk samples use a custom test signature rather than EICAR: endpoint security software
/// (including on the development Mac) often blocks or deletes EICAR files as soon as they're written.
struct AVScanFileTests {
    private let marker = Data("on-disk-sample-marker-91c2".utf8) + AVFixtures.filler(200, seed: 4)

    private func engine() throws -> AVEngine {
        try AVFixtures.engine(["t.ndb": "Test.OnDisk-1:0:*:\(AVFixtures.hex("on-disk-sample-marker-91c2"))\n"])
    }

    @Test func detectsAndReportsTheFileHash() throws {
        let directory = AVTestDirectory()
        let url = try directory.write("sample.bin", marker)
        let result = try engine().scanFile(atPath: url.path, options: AVScanOptions())
        #expect(result.isInfected)
        #expect(result.skipped == nil)
        #expect(result.bytesScanned == Int64(marker.count))
        #expect(result.sha256 == AVHex.string(SHA256.hash(data: marker)))
        #expect(result.detections.first?.memberPath == nil)
    }

    @Test func cleanFilesHaveNoHash() throws {
        let directory = AVTestDirectory()
        let url = try directory.write("clean.txt", Data("hello\n".utf8))
        let result = AVEngine.builtIn().scanFile(atPath: url.path, options: AVScanOptions())
        #expect(!result.isInfected)
        #expect(result.sha256 == nil)
        #expect(result.bytesScanned == 6)
    }

    @Test func onlyRegularFilesAreRead() throws {
        let directory = AVTestDirectory()
        let target = try directory.write("sample.bin", marker)
        let link = directory.file("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let engine = AVEngine.builtIn()
        #expect(engine.scanFile(atPath: link.path, options: AVScanOptions()).skipped == .notRegularFile)
        #expect(engine.scanFile(atPath: directory.url.path, options: AVScanOptions()).skipped == .notRegularFile)
        let fifo = directory.file("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(engine.scanFile(atPath: fifo.path, options: AVScanOptions()).skipped == .notRegularFile)
    }

    @Test func respectsTheSizeLimit() throws {
        let directory = AVTestDirectory()
        let url = try directory.write("big.bin", Data(count: 10_000))
        var options = AVScanOptions()
        options.maxFileSize = 9_999
        let result = AVEngine.builtIn().scanFile(atPath: url.path, options: options)
        #expect(result.skipped == .tooLarge)
        #expect(result.bytesScanned == 0)
    }

    @Test func unreadableAndMissingFiles() throws {
        let directory = AVTestDirectory()
        let url = try directory.write("locked.bin", marker)
        chmod(url.path, 0)
        defer { chmod(url.path, 0o644) }
        let engine = AVEngine.builtIn()
        if getuid() != 0 {
            guard case .unreadable? = engine.scanFile(atPath: url.path, options: AVScanOptions()).skipped else {
                Issue.record("expected an unreadable file")
                return
            }
        }
        guard case .unreadable? = engine.scanFile(atPath: directory.file("missing").path, options: AVScanOptions()).skipped else {
            Issue.record("expected a missing file to be unreadable")
            return
        }
    }

    @Test func scanningDoesNotModifyTheFile() throws {
        let directory = AVTestDirectory()
        let zip = AVFixtures.zip([.init(name: "inner/sample.bin", data: marker)])
        let url = try directory.write("sample.zip", zip)
        var before = stat()
        stat(url.path, &before)
        let result = try engine().scanFile(atPath: url.path, options: AVScanOptions())
        var after = stat()
        stat(url.path, &after)
        #expect(result.detections.first?.memberPath == "inner/sample.bin")
        #expect(try Data(contentsOf: url) == zip)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        #expect(before.st_size == after.st_size)
    }

    @Test func missingDatabaseMeansNotInstalled() {
        let directory = AVTestDirectory()
        #expect(throws: AVEngineError.notInstalled) { _ = try AVEngine.load(from: directory.url) }
        #expect(AVDatabaseCompiler.installedSummary(in: directory.url) == nil)
    }

    @Test func damagedDatabaseIsRejected() throws {
        let directory = AVTestDirectory()
        try directory.write(AVDatabaseFormat.fileName, Data("not a database at all, just text that is long enough....................".utf8))
        #expect(throws: AVEngineError.self) { _ = try AVEngine.load(from: directory.url) }
    }

    @Test func databaseWithAnotherFormatVersionIsRejectedThenRebuilt() throws {
        let directory = AVTestDirectory()
        let container = try directory.write("test.cld", AVFixtures.cld(files: [("t.ndb", Data("Test.Version-1:0:*:\(AVFixtures.hex("format-version-marker"))\n".utf8))]))
        let databaseDirectory = directory.file("db")
        _ = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [container]), into: databaseDirectory)
        let file = databaseDirectory.appendingPathComponent(AVDatabaseFormat.fileName)
        let original = try Data(contentsOf: file)
        #expect(original.count > 12)
        for other in [AVDatabaseFormat.version - 1, AVDatabaseFormat.version + 1] {
            var bytes = original
            bytes.replaceSubrange(8..<12, with: withUnsafeBytes(of: other.littleEndian) { Data($0) })
            try bytes.write(to: file)
            #expect(throws: AVEngineError.invalidDatabase(AVDatabaseFormat.versionMismatchMessage(found: other))) {
                _ = try AVEngine.load(from: databaseDirectory)
            }
            #expect(AVDatabaseCompiler.installedSummary(in: databaseDirectory) == nil)
        }
        // Compiling again replaces the incompatible file.
        _ = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [container]), into: databaseDirectory)
        let engine = try AVEngine.load(from: databaseDirectory)
        #expect(engine.names(Data("..format-version-marker..".utf8) + AVFixtures.filler(64)) == ["Test.Version-1"])
    }

    @Test func failedCompileLeavesThePreviousDatabase() throws {
        let directory = AVTestDirectory()
        let good = try directory.write("test.cld", AVFixtures.cld(files: [("t.ndb", Data("Test.Keep-1:0:*:\(AVFixtures.hex("keep-this-signature"))\n".utf8))]))
        let databaseDirectory = directory.file("db")
        _ = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [good]), into: databaseDirectory)
        let broken = try directory.write("broken.cvd", AVFixtures.header(md5: String(repeating: "a", count: 32)) + Data(count: 100))
        #expect(throws: AVEngineError.self) {
            _ = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [broken]), into: databaseDirectory)
        }
        let engine = try AVEngine.load(from: databaseDirectory)
        #expect(engine.names(Data("....keep-this-signature....".utf8) + AVFixtures.filler(64)) == ["Test.Keep-1"])
        // No temporary files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: databaseDirectory.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
        #expect(AVDatabaseCompiler.installedSummary(in: databaseDirectory)?.bodySignatureCount == 1)
    }

    @Test func concurrentScansShareOneEngine() async throws {
        let engine = try AVFixtures.engine(["t.ndb": "Test.Shared-1:0:*:\(AVFixtures.hex("shared-marker"))\n"])
        let infected = AVFixtures.filler(50_000) + Data("shared-marker".utf8) + AVFixtures.filler(1000)
        let clean = AVFixtures.filler(50_000, seed: 5)
        let results = await withTaskGroup(of: (Bool, Bool).self) { group in
            for index in 0..<32 {
                group.addTask {
                    let data = index.isMultiple(of: 2) ? infected : clean
                    return (index.isMultiple(of: 2), !engine.scan(data: data, name: "s", options: AVScanOptions()).isEmpty)
                }
            }
            var all = [(Bool, Bool)]()
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 32)
        #expect(results.allSatisfy { $0.0 == $0.1 })
    }
}
