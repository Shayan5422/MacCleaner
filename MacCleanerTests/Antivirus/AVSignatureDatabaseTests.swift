import Foundation
import Testing
@testable import MacCleaner

struct AVRejectingVerifier: AVCdiffVerifying {
    func verify(sha256: Data, signature: String) -> Bool { false }
}

@Suite("ClamAV's own signature databases")
struct AVSignatureDatabaseTests {
    /// `<folder>/test.ndb` listed in `<folder>/test.info` (signature checked by the verifier passed in).
    @discardableResult
    private func makeIndexedDatabase(in tree: AVTestFolder, folder: String = "db", contents: Data) throws -> String {
        let file = try tree.makeFile("\(folder)/test.ndb", contents: contents)
        let info = "ClamAV-VDB:16 Oct 2026 06-24 +0000:1:1:90:X:X:test:0\ntest.ndb:\(contents.count):\(AVFileHasher.sha256(data: contents))\nDSIG:signature\n"
        try tree.makeFile("\(folder)/test.info", contents: Data(info.utf8))
        return file
    }

    @Test func setsAsideOnlyFilesListedInASignedIndex() throws {
        let tree = try AVTestFolder("AVSignatureDB")
        let file = try makeIndexedDatabase(in: tree, contents: Data("Signature:0:*:41424344".utf8))
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: file, indexVerifier: AVAcceptingVerifier()))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: file, indexVerifier: AVRejectingVerifier()))
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: tree.child("db/test.info").path, indexVerifier: AVAcceptingVerifier()))

        // Different contents (same size, then another size) no longer match the index.
        try Data("Signature:0:*:41424345".utf8).write(to: URL(fileURLWithPath: file))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: file, indexVerifier: AVAcceptingVerifier()))
        try Data("Signature:0:*:4142434546".utf8).write(to: URL(fileURLWithPath: file))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: file, indexVerifier: AVAcceptingVerifier()))

        // The same contents without an index, or under a name that isn't a database file.
        let alone = try tree.makeFile("alone/test.ndb", contents: Data("Signature:0:*:41424344".utf8))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: alone, indexVerifier: AVAcceptingVerifier()))
        let other = try makeIndexedDatabase(in: tree, folder: "renamed", contents: Data("x".utf8))
        let renamed = tree.child("renamed/test.txt").path
        try FileManager.default.moveItem(atPath: other, toPath: renamed)
        #expect(!AVSignatureDatabases.isCandidate(path: renamed))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: renamed, indexVerifier: AVAcceptingVerifier()))
    }

    @Test func trustsContainersOnlyWhenTheirSignatureCoversEverything() throws {
        let tree = try AVTestFolder("AVSignatureDB")
        var header = Data("ClamAV-VDB:16 Oct 2026 06-24 +0000:63:3287027:90:md5:signature:builder:1700000000".utf8)
        header.append(Data(repeating: 0x20, count: 512 - header.count))
        let cvd = try tree.makeFile("main.cvd", contents: header + Data(repeating: 0x41, count: 1_024))
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: cvd, verifyContainer: { _ in .signedContainer }))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: cvd, verifyContainer: { _ in .structureOnly }))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: cvd, verifyContainer: { _ in nil }))
        // A .cld rebuilt from patches: only the files in its index are signed, not the archive.
        let cld = try tree.makeFile("daily.cld", contents: header + Data(repeating: 0x41, count: 1_024))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: cld, verifyContainer: { _ in .signedIndex }))
        // Binary data hidden in the header, which the MD5 doesn't cover.
        var hidden = header
        hidden[400] = 0xCF
        let tampered = try tree.makeFile("other/main.cvd", contents: hidden + Data(repeating: 0x41, count: 1_024))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: tampered, verifyContainer: { _ in .signedContainer }))
    }

    @Test func refusesDataAfterAnIndexSignature() throws {
        let tree = try AVTestFolder("AVSignatureDB")
        try makeIndexedDatabase(in: tree, contents: Data("x".utf8))
        let info = tree.child("db/test.info")
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: info.path, indexVerifier: AVAcceptingVerifier()))
        var data = try Data(contentsOf: info)
        data.append(Data("\n\r\n  ".utf8))
        try data.write(to: info)
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: info.path, indexVerifier: AVAcceptingVerifier()))
        data.append(AVFakeScanner.malwareMarker)
        try data.write(to: info)
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: info.path, indexVerifier: AVAcceptingVerifier()))
    }

    @Test func verifiesRealDatabaseFilesWithClamAVsKey() throws {
        guard let info = AVRealFiles.url("x-daily/daily.info"), let msb = AVRealFiles.url("x-daily/daily.msb") else { return }
        let tree = try AVTestFolder("AVSignatureDB")
        try tree.makeDirectory("db")
        try FileManager.default.copyItem(at: info, to: tree.child("db/daily.info"))
        try FileManager.default.copyItem(at: msb, to: tree.child("db/daily.msb"))
        let copy = tree.child("db/daily.msb").path
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: copy))
        #expect(AVSignatureDatabases.isVerifiedDatabase(path: tree.child("db/daily.info").path))
        // The patch key doesn't sign indexes.
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: copy, indexVerifier: AVClamAVPSSVerifier.shared))

        // One changed byte in the file, or in the signed index, and it's an ordinary file again.
        var bytes = try Data(contentsOf: msb)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: URL(fileURLWithPath: copy))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: copy))
        try FileManager.default.removeItem(atPath: copy)
        try FileManager.default.copyItem(at: msb, to: URL(fileURLWithPath: copy))
        var index = try String(contentsOf: info, encoding: .utf8)
        index = index.replacingOccurrences(of: "ClamAV-VDB:", with: "ClamAV-VDB: ")
        try Data(index.utf8).write(to: tree.child("db/daily.info"))
        #expect(!AVSignatureDatabases.isVerifiedDatabase(path: copy))
    }

    @Test func scansDontReportVerifiedDatabases() async throws {
        let tree = try AVTestFolder("AVSignatureDB")
        try makeIndexedDatabase(in: tree, contents: AVFakeScanner.malwareMarker)
        try tree.makeFile("db/evil.ndb", contents: AVFakeScanner.malwareMarker + Data(" not in the index".utf8))
        var configuration = AVScanConfiguration(scanner: AVFakeScanner())
        configuration.workerCount = 2
        configuration.isVerifiedSignatureDatabase = { AVSignatureDatabases.isVerifiedDatabase(path: $0, indexVerifier: AVAcceptingVerifier()) }
        let report = await AVScanCoordinator.run(plan: AVScanPlanner.custom(paths: [tree.child("db").path]), configuration: configuration)
        #expect(report.threats.map(\.fileName) == ["evil.ndb"])
        #expect(report.ignoredSignatureDatabases == 1)
        #expect(report.filesScanned == 3)
    }
}
