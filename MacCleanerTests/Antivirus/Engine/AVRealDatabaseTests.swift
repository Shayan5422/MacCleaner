import Foundation
import Testing
@testable import MacCleaner

/// Tests against the real ClamAV databases (main.cvd, daily.cvd). They're skipped when the
/// databases aren't on this Mac (set MACCLEANER_AVDB_DIR to a folder with clamav/main.cvd and
/// clamav/daily.cvd). The databases are compiled once per test run.
@Suite(.enabled(if: AVRealDatabase.isAvailable))
struct AVRealDatabaseTests {
    private func engine() throws -> AVEngine {
        let compiled = AVRealDatabase.compiled
        guard let engine = compiled.engine else { throw AVEngineError.invalidDatabase(compiled.error ?? "not compiled") }
        return engine
    }

    @Test func compilesWithExpectedCoverage() throws {
        let compiled = AVRealDatabase.compiled
        let summary = try #require(compiled.summary, "\(compiled.error ?? "")")
        #expect(summary.clamavVersions["main"] == 63)
        #expect(summary.clamavVersions["daily"] == 28155)
        #expect(summary.clamavVerification == ["main": .signedContainer, "daily": .signedContainer])
        #expect(summary.hashSignatureCount > 3_200_000)
        #expect(summary.bodySignatureCount > 100_000)
        #expect(summary.logicalSignatureCount > 300_000)
        // Over 99.9% of the signatures that are body, logical or hash signatures are used.
        let coverage = try #require(summary.coverage)
        let byType = coverage.byType
        for type in ["hdb", "hsb", "mdb", "ndb", "ldb"] {
            let entry = try #require(byType[type])
            #expect(Double(entry.unsupported) / Double(entry.loaded + entry.unsupported) < 0.01, "\(type): \(entry)")
        }
    }

    @Test func eicarIsDetectedByClamAVToo() throws {
        let detections = try engine().scan(data: Data(AVBuiltInSignatures.eicar), name: "eicar.com", options: AVScanOptions())
        #expect(detections.contains(AVDetection(signatureName: "EICAR-Test-File", kind: .testFile, source: .builtIn, memberPath: nil)))
        #expect(detections.contains { $0.source == .clamav && $0.kind == .testFile && $0.signatureName.lowercased().contains("eicar") })
    }

    // MARK: Real macOS signatures on synthetic samples

    private struct Sample {
        var name: String
        var parts: [Data]
        var machO: Bool
        var data: Data
    }

    /// Literal (wildcard-free) Osx./Macos./Multios. body signatures for any file or Mach-O,
    /// each embedded in a sample of the right type.
    private func bodySamples(_ text: String, limit: Int) -> [Sample] {
        var samples = [Sample]()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 4, ["Osx.", "Macos.", "Multios."].contains(where: { fields[0].hasPrefix($0) }),
                  fields[1] == "0" || fields[1] == "9", fields[2] == "*", fields[3].count >= 16,
                  let bytes = AVHex.decode(String(fields[3])) else { continue }
            samples.append(Sample(name: String(fields[0]), parts: [Data(bytes)], machO: fields[1] == "9", data: wrap([Data(bytes)], machO: fields[1] == "9")))
            if samples.count >= limit { break }
        }
        return samples
    }

    /// Logical Osx./Macos. signatures whose expression is an AND of literal subsignatures.
    private func logicalSamples(_ text: String, limit: Int) -> [Sample] {
        var samples = [Sample]()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 5, ["Osx.", "Macos."].contains(where: { fields[0].hasPrefix($0) }) else { continue }
            let tdb = fields[1].split(separator: ",")
            guard tdb.allSatisfy({ $0.hasPrefix("Engine:") || $0.hasPrefix("Target:") }),
                  let target = tdb.first(where: { $0.hasPrefix("Target:") }), target == "Target:0" || target == "Target:9" else { continue }
            let subsigs = fields.dropFirst(3)
            guard subsigs.count <= 6, fields[2].allSatisfy({ $0.isNumber || $0 == "&" }),
                  Set(fields[2].split(separator: "&").compactMap { Int($0) }) == Set(0..<subsigs.count) else { continue }
            let parts = subsigs.compactMap { AVHex.decode(String($0)) }.map { Data($0) }
            guard parts.count == subsigs.count, parts.allSatisfy({ $0.count >= 4 }) else { continue }
            samples.append(Sample(name: String(fields[0]), parts: parts, machO: target == "Target:9", data: wrap(parts, machO: target == "Target:9")))
            if samples.count >= limit { break }
        }
        return samples
    }

    /// Puts the parts, separated by filler, into a Mach-O or a binary blob.
    private func wrap(_ parts: [Data], machO: Bool) -> Data {
        var body = Data()
        for (index, part) in parts.enumerated() {
            body += AVFixtures.filler(64, seed: UInt64(index + 1)) + part
        }
        body += AVFixtures.filler(64, seed: 99)
        if machO { return AVFixtures.machO(code: body) }
        return Data([0, 1]) + body
    }

    private func signatureText(_ file: String) throws -> String {
        let url = try #require(file.hasPrefix("main") ? AVRealDatabase.mainCVD : AVRealDatabase.dailyCVD)
        let database = try ClamAVContainer.unpack(at: url)
        return try #require(database.withFile(file) { String(decoding: $0.buffer, as: UTF8.self) })
    }

    @Test func realMacBodySignaturesMatchSyntheticSamples() throws {
        let engine = try engine()
        var samples = bodySamples(try signatureText("main.ndb"), limit: 25)
        samples += bodySamples(try signatureText("daily.ndb"), limit: 10)
        #expect(samples.count >= 20)
        for sample in samples {
            let names = engine.names(sample.data)
            #expect(names.contains(sample.name), "\(sample.name) not detected (got \(names))")
        }
    }

    @Test func realMacLogicalSignaturesMatchSyntheticSamples() throws {
        let engine = try engine()
        var samples = logicalSamples(try signatureText("main.ldb"), limit: 20)
        samples += logicalSamples(try signatureText("daily.ldb"), limit: 20)
        #expect(samples.count >= 20)
        for sample in samples {
            let names = engine.names(sample.data)
            #expect(names.contains(sample.name), "\(sample.name) not detected (got \(names))")
            // Without the last subsignature's bytes the signature must not match.
            let partial = wrap(Array(sample.parts.dropLast()), machO: sample.machO)
            #expect(!engine.names(partial).contains(sample.name), "\(sample.name) matched without all its parts")
        }
    }

    @Test func cleanSystemFilesAreClean() throws {
        let engine = try engine()
        let paths = ["/bin/ls", "/bin/zsh", "/usr/bin/grep", "/usr/bin/python3", "/System/Library/CoreServices/SystemVersion.plist",
                     "/usr/share/dict/words", "/usr/lib/dyld"]
        for path in paths where FileManager.default.isReadableFile(atPath: path) {
            let result = engine.scanFile(atPath: path, options: AVScanOptions())
            #expect(result.detections.isEmpty, "\(path): \(result.detections.map(\.signatureName))")
        }
    }
}
