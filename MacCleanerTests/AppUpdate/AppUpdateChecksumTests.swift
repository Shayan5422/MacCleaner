import Foundation
import Testing
@testable import MacCleaner

struct AppUpdateChecksumTests {
    private static let releaseFile = """
    6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157  Mac-Cleaner-1.0.0.dmg
    35d4c19696cfdcf1debd14fd034344db7cc9f1ed6bca986aecf1cf7107cae606  Mac-Cleaner-1.0.0.zip
    """

    @Test func parsesShasumOutput() {
        let sums = AppUpdateChecksums.parse(Self.releaseFile)
        #expect(sums.count == 2)
        #expect(sums["Mac-Cleaner-1.0.0.dmg"] == "6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157")
        #expect(sums["Mac-Cleaner-1.0.0.zip"] == "35d4c19696cfdcf1debd14fd034344db7cc9f1ed6bca986aecf1cf7107cae606")
    }

    @Test func acceptsBinaryModePathsAndUppercaseButIgnoresMalformedLines() {
        let text = """
        6B7778CCE550AB6A87EA9A56770165CDC629A74905CF41C385D26DEE2C29A157 *build/release/Mac-Cleaner-1.0.0.dmg
        not-a-hash  Mac-Cleaner-1.0.0.zip
        1234  short.dmg
        # a comment

        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """
        let sums = AppUpdateChecksums.parse(text)
        #expect(sums == ["Mac-Cleaner-1.0.0.dmg": "6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157"])
    }

    @Test func hashesFilesInChunks() throws {
        let folder = try TemporaryTree("Checksums")
        let small = try folder.makeFile("abc.txt", size: 0)
        try Data("abc".utf8).write(to: URL(fileURLWithPath: small))
        #expect(try AppUpdateChecksums.sha256(of: URL(fileURLWithPath: small)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // Larger than one read chunk: the result matches the system's shasum.
        let large = try folder.makeFile("large.bin", size: 3 * 1024 * 1024 + 17)
        let expected = try Self.shasum(large)
        #expect(try AppUpdateChecksums.sha256(of: URL(fileURLWithPath: large)) == expected)
    }

    @Test func verifiesAgainstTheChecksumFileAndGitHubsDigest() throws {
        let folder = try TemporaryTree("ChecksumVerify")
        let path = try folder.makeFile("Mac-Cleaner-1.2.0.dmg", size: 4096)
        let url = URL(fileURLWithPath: path)
        let hash = try AppUpdateChecksums.sha256(of: url)
        let file = "\(hash)  Mac-Cleaner-1.2.0.dmg\n"

        try AppUpdateChecksums.verify(file: url, fileName: "Mac-Cleaner-1.2.0.dmg", checksumFile: file, githubDigest: nil)
        try AppUpdateChecksums.verify(file: url, fileName: "Mac-Cleaner-1.2.0.dmg", checksumFile: file, githubDigest: hash.uppercased())

        let wrong = String(repeating: "0", count: 64) + "  Mac-Cleaner-1.2.0.dmg"
        #expect(throws: AppUpdateError.checksumMismatch) {
            try AppUpdateChecksums.verify(file: url, fileName: "Mac-Cleaner-1.2.0.dmg", checksumFile: wrong, githubDigest: nil)
        }
        #expect(throws: AppUpdateError.checksumNotListed("Mac-Cleaner-1.2.0.dmg")) {
            try AppUpdateChecksums.verify(file: url, fileName: "Mac-Cleaner-1.2.0.dmg", checksumFile: "\(hash)  Other.dmg", githubDigest: nil)
        }
        #expect(throws: AppUpdateError.checksumsDisagree) {
            try AppUpdateChecksums.verify(file: url, fileName: "Mac-Cleaner-1.2.0.dmg", checksumFile: file, githubDigest: String(repeating: "a", count: 64))
        }
    }

    private static func shasum(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(output.prefix(64))
    }
}
