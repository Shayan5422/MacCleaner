import CryptoKit
import Foundation
import Testing
@testable import MacCleanerMobile

struct FileHasherTests {
    @Test func theQuickDigestCoversTheFirst64KB() throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let content = FileTestFolder.randomData(200_000)
        let file = try folder.write(content, to: "file.bin")
        #expect(try FileHasher.partialDigest(of: file) == FileHasher.hex(SHA256.hash(data: content.prefix(64 * 1024))))
    }

    @Test func theFullDigestStreamsTheWholeFile() throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        // Several 1 MB chunks and a partial one.
        let content = FileTestFolder.randomData(3 * 1024 * 1024 + 12_345)
        let file = try folder.write(content, to: "file.bin")
        #expect(try FileHasher.fullDigest(of: file) == FileHasher.hex(SHA256.hash(data: content)))
        #expect(FileHasher.hex(SHA256.hash(data: content)).count == 64)
    }

    @Test func smallFilesHaveOneDigest() throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let file = try folder.write(FileTestFolder.randomData(10_000), to: "small.bin")
        #expect(try FileHasher.partialDigest(of: file) == FileHasher.fullDigest(of: file))
        let empty = try folder.write(Data(), to: "empty.bin")
        #expect(try FileHasher.fullDigest(of: empty) == FileHasher.hex(SHA256.hash(data: Data())))
    }

    @Test func filesThatDifferAfterTheStartOnlyDifferInFull() throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        var content = FileTestFolder.randomData(300_000)
        let first = try folder.write(content, to: "first.bin")
        content[250_000] ^= 0xFF
        let second = try folder.write(content, to: "second.bin")
        #expect(try FileHasher.partialDigest(of: first) == FileHasher.partialDigest(of: second))
        #expect(try FileHasher.fullDigest(of: first) != FileHasher.fullDigest(of: second))
    }

    @Test func hashingStopsWhenCancelled() async throws {
        let folder = try FileTestFolder()
        defer { folder.remove() }
        let file = try folder.write(FileTestFolder.randomData(2 * 1024 * 1024), to: "file.bin")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileHasher.fullDigest(of: file)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func unreadableFilesThrow() {
        #expect(throws: (any Error).self) { try FileHasher.partialDigest(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")) }
    }
}
