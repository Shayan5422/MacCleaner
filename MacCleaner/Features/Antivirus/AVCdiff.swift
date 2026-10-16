import CryptoKit
import Foundation
import Security

/// ClamAV incremental database updates (`daily-<version>.cdiff`), applied the way freshclam does.
///
/// A `.cdiff` file is `ClamAV-Diff:<version>:<script length>:` + a gzip-compressed script +
/// `:` + an RSA-PSS signature (2048-bit ClamAV key) over the SHA-256 of everything before that
/// last colon. Scripts edit the extracted database files line by line:
/// `OPEN`, `ADD`, `DEL`, `XCHG`, `MOVE`, `UNLINK`, `CLOSE`.
enum AVCdiff {
    enum Failure: LocalizedError, Equatable {
        case malformed(String)
        case badSignature
        case conflict(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "The update patch is malformed (\(detail))."
            case .badSignature: return "The update patch isn't signed by ClamAV."
            case .conflict(let detail): return "The update patch doesn't match the local database (\(detail))."
            }
        }
    }

    struct Patch: Sendable {
        var version: Int
        var script: String
    }

    /// Checks the signature and extracts the script.
    static func open(_ data: Data, verifier: any AVCdiffVerifying = AVClamAVPSSVerifier.shared) throws -> Patch {
        guard let last = data.lastIndex(of: UInt8(ascii: ":")), last > data.startIndex else { throw Failure.malformed("no signature") }
        let signed = data[data.startIndex..<last]
        let signature = String(decoding: data[data.index(after: last)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signature.isEmpty, signature.count < 400 else { throw Failure.malformed("signature") }
        guard verifier.verify(sha256: Data(SHA256.hash(data: signed)), signature: signature) else { throw Failure.badSignature }

        // Header: ClamAV-Diff:<version>:<length>:
        var colons = 0
        var headerEnd = signed.startIndex
        while headerEnd < signed.endIndex, colons < 3 {
            if signed[headerEnd] == UInt8(ascii: ":") { colons += 1 }
            headerEnd = signed.index(after: headerEnd)
        }
        let header = String(decoding: signed[signed.startIndex..<headerEnd], as: UTF8.self)
        let fields = header.split(separator: ":", omittingEmptySubsequences: false)
        guard colons == 3, fields.count >= 3, fields[0] == "ClamAV-Diff", let version = Int(fields[1]), let length = Int(fields[2]), length >= 0, length <= 64_000_000 else {
            throw Failure.malformed("header")
        }
        var script = Data()
        script.reserveCapacity(length)
        try AVDefsGzip.decompress(Data(signed[headerEnd...]), maxOutput: Int64(length) + 1) { script.append(contentsOf: $0) }
        guard script.count == length else { throw Failure.malformed("script length") }
        return Patch(version: version, script: String(decoding: script, as: UTF8.self))
    }

    // MARK: - Applying

    /// Applies `script` to the database files in `directory` (file names only, no paths).
    static func apply(_ script: String, in directory: URL) throws {
        var editor: Editor?
        var lineNumber = 0
        for rawLine in script.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let command = line.prefix { $0 != " " }
            let rest = line.count > command.count ? String(line.dropFirst(command.count + 1)) : ""
            switch command {
            case "OPEN":
                guard editor == nil else { throw Failure.malformed("OPEN while a file is open (line \(lineNumber))") }
                editor = Editor(name: try fileName(rest))
            case "ADD":
                guard editor != nil else { throw Failure.malformed("ADD without OPEN (line \(lineNumber))") }
                editor?.additions.append(rest)
            case "DEL":
                guard editor != nil else { throw Failure.malformed("DEL without OPEN (line \(lineNumber))") }
                let (number, prefix) = try numbered(rest, lineNumber)
                editor?.deletions[number] = prefix
            case "XCHG":
                guard editor != nil else { throw Failure.malformed("XCHG without OPEN (line \(lineNumber))") }
                let (number, remainder) = try numbered(rest, lineNumber)
                guard let space = remainder.firstIndex(of: " ") else { throw Failure.malformed("XCHG (line \(lineNumber))") }
                editor?.exchanges[number] = (String(remainder[..<space]), String(remainder[remainder.index(after: space)...]))
            case "CLOSE":
                guard let open = editor else { throw Failure.malformed("CLOSE without OPEN (line \(lineNumber))") }
                try open.commit(in: directory)
                editor = nil
            case "MOVE":
                guard editor == nil else { throw Failure.malformed("MOVE while a file is open (line \(lineNumber))") }
                try move(rest, in: directory, lineNumber: lineNumber)
            case "UNLINK":
                guard editor == nil else { throw Failure.malformed("UNLINK while a file is open (line \(lineNumber))") }
                let url = directory.appendingPathComponent(try fileName(rest))
                do { try FileManager.default.removeItem(at: url) } catch { throw Failure.conflict("can't remove \(rest)") }
            default:
                throw Failure.malformed("unknown command \(command) (line \(lineNumber))")
            }
        }
        if editor != nil { throw Failure.malformed("file not closed") }
    }

    private struct Editor {
        var name: String
        var additions: [String] = []
        var deletions: [Int: String] = [:]
        var exchanges: [Int: (String, String)] = [:]

        func commit(in directory: URL) throws {
            let url = directory.appendingPathComponent(name)
            for number in deletions.keys where exchanges[number] != nil {
                throw Failure.conflict("line \(number) of \(name) is both deleted and replaced")
            }
            var file = AVLineFile()
            if let data = try? Data(contentsOf: url) {
                file = AVLineFile(data)
            } else if !deletions.isEmpty || !exchanges.isEmpty {
                throw Failure.conflict("\(name) is missing")
            }
            if let missing = (Array(deletions.keys) + Array(exchanges.keys)).first(where: { $0 < 1 || $0 > file.lines.count }) {
                throw Failure.conflict("line \(missing) of \(name) doesn't exist")
            }
            var output: [Data] = []
            output.reserveCapacity(file.lines.count + additions.count)
            for (index, line) in file.lines.enumerated() {
                let number = index + 1
                if let prefix = deletions[number] {
                    guard line.starts(with: Data(prefix.utf8)) else { throw Failure.conflict("DEL at line \(number) of \(name)") }
                    continue
                }
                if let (prefix, replacement) = exchanges[number] {
                    guard line.starts(with: Data(prefix.utf8)) else { throw Failure.conflict("XCHG at line \(number) of \(name)") }
                    output.append(Data(replacement.utf8))
                    continue
                }
                output.append(line)
            }
            output += additions.map { Data($0.utf8) }
            // Appending lines always ends the file with a newline (fputs + '\n' in ClamAV).
            try AVLineFile(lines: output, endsWithNewline: file.endsWithNewline || !additions.isEmpty).data.write(to: url, options: .atomic)
        }
    }

    /// `MOVE src dst start_line start_prefix end_line end_prefix`: moves lines start…end of `src` to the end of `dst`.
    private static func move(_ arguments: String, in directory: URL, lineNumber: Int) throws {
        let parts = arguments.split(separator: " ", maxSplits: 5).map(String.init)
        guard parts.count == 6, let start = Int(parts[2]), let end = Int(parts[4]), start >= 1, end >= start else {
            throw Failure.malformed("MOVE (line \(lineNumber))")
        }
        let source = directory.appendingPathComponent(try fileName(parts[0]))
        let destination = directory.appendingPathComponent(try fileName(parts[1]))
        guard let data = try? Data(contentsOf: source) else { throw Failure.conflict("\(parts[0]) is missing") }
        var file = AVLineFile(data)
        guard end <= file.lines.count, file.lines[start - 1].starts(with: Data(parts[3].utf8)), file.lines[end - 1].starts(with: Data(parts[5].utf8)) else {
            throw Failure.conflict("MOVE from \(parts[0])")
        }
        var target = (try? Data(contentsOf: destination)).map { AVLineFile($0) } ?? AVLineFile()
        target.lines += file.lines[(start - 1)..<end]
        target.endsWithNewline = true
        file.lines.removeSubrange((start - 1)..<end)
        try target.data.write(to: destination, options: .atomic)
        try file.data.write(to: source, options: .atomic)
    }

    private static func numbered(_ text: String, _ lineNumber: Int) throws -> (Int, String) {
        guard let space = text.firstIndex(of: " "), let number = Int(text[..<space]) else {
            throw Failure.malformed("line number (line \(lineNumber))")
        }
        return (number, String(text[text.index(after: space)...]))
    }

    /// Database file names are flat ("daily.ndb"); anything else is refused.
    private static func fileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name.count < 128 else { throw Failure.malformed("file name \(raw)") }
        return name
    }
}

/// A text file as byte lines (database files may contain bytes that aren't valid UTF-8).
struct AVLineFile {
    var lines: [Data] = []
    var endsWithNewline = true

    init() {}

    init(lines: [Data], endsWithNewline: Bool) {
        self.lines = lines
        self.endsWithNewline = endsWithNewline
    }

    init(_ data: Data) {
        guard !data.isEmpty else { return }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        endsWithNewline = data.last == 0x0A
        if endsWithNewline { parts.removeLast() }
        lines = parts
    }

    var data: Data {
        var output = Data()
        output.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })
        for (index, line) in lines.enumerated() {
            output.append(line)
            if index < lines.count - 1 || endsWithNewline { output.append(0x0A) }
        }
        return output
    }
}

/// Verifies the signature of a `.cdiff` (injectable for tests that use synthetic patches).
protocol AVCdiffVerifying: Sendable {
    func verify(sha256: Data, signature: String) -> Bool
}

/// ClamAV's RSA-PSS scheme (`cli_versig2`): 2048-bit key, SHA-256, 32-byte salt, the signature
/// written as a little-endian base-64 number. The public operation uses Security.framework.
final class AVClamAVPSSVerifier: AVCdiffVerifying, @unchecked Sendable {
    /// The key that signs `.cdiff` patches.
    static let shared = AVClamAVPSSVerifier(modulusHex: patchModulusHex, exponent: [0x05, 0xF5, 0xE9, 0x05])
    /// The key that signs database indexes (`daily.info`, `main.info`).
    static let databaseIndex = AVClamAVPSSVerifier(modulusHex: indexModulusHex, exponent: [0x05, 0xF5, 0xE9, 0x01])

    /// ClamAV's public key for signed patches (modulus in hex, exponent 100002053).
    private static let patchModulusHex =
        "751c709765074b2f79f1390581433f72b8e29dc8de678481ed1b56a39215e9d0" +
        "298619228d8326d2b3b5db9dfcb832dc1fab5ec269986dad56b1c2fe661c1882" +
        "3918e61f8f4d6efbe6be587f0a0fe4db6af5c1c5c0592127e48c012698233a67" +
        "c1073fa0b52198edbe5ae2c1449a3b8acab7f791b282986fa0861ec925511f71" +
        "3a087c299d39da10173c25aaf328971b4feef396f72f1d7d533bda6505514f1b" +
        "ff8c5fad963334ed4ae2a8d35fdb941cb9f8dbf92002781fdfcf3b11bbbc3bec" +
        "64174f75560f6450a0835e3c9acc8be4f6c9af3f85c17d9b49b27792d7602b98" +
        "21c015f87679b65b25ad5c2e041da84e6ee076ac5274e693a0f874bc7fd10903"
    /// ClamAV's public key for database indexes (modulus in hex, exponent 100002049).
    private static let indexModulusHex =
        "57d749b7e7d61160421a14aeadb263bbaec4422cabda76e94db3fa98cd63bfe3" +
        "2a54c72b3026f2356dfa9543f9020219cbdcbdae9e642c4441c23a2523cf4fa6" +
        "d444722ec227b89e04dad097c38eeef93b588baabecc6fc20199fea6ea47a66c" +
        "736d4fec15b5a8d4411e1ae838e2a0a55b7398f4d48b346a7d747134c62bfdf9" +
        "5a4bce381fa151a2118b6788ccb3289512a6c8b3a84d640e0fca01d0f4611d7d" +
        "d1a47452027ddecfc1572d08370e63c51d9bd4773153ce7ad95c4ffb2f4a1147" +
        "e35304f827f34a4d5ef388bab077f7cae0b2fbbbfea09936b656b4c0c7c4e990" +
        "7c6c6d392e01b047746d2b8694bede7a5e0861f8d95ef844a29b71e7f8b8f0c9"
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/".utf8)

    private let key: SecKey?

    init(modulusHex: String, exponent: [UInt8]) {
        var modulus: [UInt8] = []
        var index = modulusHex.startIndex
        while index < modulusHex.endIndex {
            let next = modulusHex.index(index, offsetBy: 2)
            modulus.append(UInt8(modulusHex[index..<next], radix: 16) ?? 0)
            index = next
        }
        func length(_ count: Int) -> [UInt8] { count < 128 ? [UInt8(count)] : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)] }
        func integer(_ bytes: [UInt8]) -> [UInt8] {
            var value = Array(bytes.drop { $0 == 0 })
            if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
            return [0x02] + length(value.count) + value
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    func verify(sha256 digest: Data, signature: String) -> Bool {
        guard let key, digest.count == 32, let encoded = Self.decodeNumber(signature) else { return false }
        guard let decoded = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, encoded as CFData, nil) as Data?, decoded.count == 256 else { return false }
        let block = [UInt8](decoded)
        let hashLength = 32, blockLength = 256 - 32 - 1, saltLength = 32
        guard block[255] == 0xBC else { return false }
        let mask = Array(block[0..<blockLength])
        let expected = Array(block[blockLength..<(blockLength + hashLength)])
        var unmasked: [UInt8] = []
        var counter = 0
        while unmasked.count < blockLength {
            unmasked += SHA256.hash(data: expected + [0, 0, UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)])
            counter += 1
        }
        unmasked = Array(unmasked.prefix(blockLength))
        for index in 0..<blockLength { unmasked[index] ^= mask[index] }
        unmasked[0] &= 0x7F
        guard let marker = unmasked.firstIndex(of: 0x01), blockLength - marker - 1 == saltLength else { return false }
        let salt = unmasked[(marker + 1)...]
        let message = [UInt8](repeating: 0, count: 8) + [UInt8](digest) + salt
        return Array(SHA256.hash(data: message)) == expected
    }

    /// Little-endian base-64 digits → 256 big-endian bytes.
    private static func decodeNumber(_ text: String) -> Data? {
        var little = [UInt8](repeating: 0, count: 264)
        var bit = 0
        for character in text.utf8 {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            for offset in 0..<6 where (digit >> offset) & 1 == 1 {
                let position = bit + offset
                guard position / 8 < little.count else { return nil }
                little[position / 8] |= UInt8(1 << (position % 8))
            }
            bit += 6
        }
        guard little[256...].allSatisfy({ $0 == 0 }) else { return nil }
        return Data(little[0..<256].reversed())
    }
}
