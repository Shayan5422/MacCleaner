import Foundation
import Testing
@testable import MacCleaner

/// Mac Cleaner's working folders must never be followed through a symbolic link: another process
/// could otherwise point them at the person's documents and have Mac Cleaner delete them.
@Suite("Secure working folders")
struct SecureDirectoryTests {
    /// A temporary folder by its real path: `/var` is itself a link to `/private/var`, and the safe
    /// removal refuses any path with a link in it (which is what keeps it safe).
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecureDirectory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // realpath (NSString's resolvingSymlinksInPath strips /private again).
        guard let real = realpath(root.path, nil) else { return root }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    @Test func clearingAFolderReplacedByALinkLeavesTheTargetAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let precious = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("thesis.txt"))
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createSymbolicLink(at: scratch, withDestinationURL: precious)

        SecureDirectory.removeContents(of: scratch)
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("thesis.txt").path))
    }

    @Test func clearingRemovesEntriesButNeverFollowsLinksInside() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let precious = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("thesis.txt"))
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("leftover"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: scratch.appendingPathComponent("leftover/copy.db"))
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("link"), withDestinationURL: precious)

        SecureDirectory.removeContents(of: scratch)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("thesis.txt").path))
    }

    @Test func ensureReplacesALinkWithARealPrivateFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let precious = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("thesis.txt"))
        let antivirus = AVPaths(root: root.appendingPathComponent("Antivirus", isDirectory: true))
        try FileManager.default.createDirectory(at: antivirus.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: antivirus.temporary, withDestinationURL: precious)

        try antivirus.prepare()
        var info = stat()
        #expect(lstat(antivirus.temporary.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o777 == 0o700)
        // The old link target wasn't touched or re-permissioned.
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("thesis.txt").path))
        var preciousInfo = stat()
        #expect(lstat(precious.path, &preciousInfo) == 0 && preciousInfo.st_mode & 0o777 != 0o700)
        antivirus.cleanTemporary(olderThan: -1)
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("thesis.txt").path))
    }

    @Test func ensureRefusesAFileInTheWay() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tmp")
        try Data("x".utf8).write(to: file)
        #expect(throws: SecureDirectory.Failure.self) { try SecureDirectory.ensure(file) }
    }
}
