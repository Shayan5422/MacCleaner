import CryptoKit
import Foundation

/// Verifies the two kinds of digital signatures ClamAV (Cisco Talos) puts on its databases.
///
/// * **CVD header signature** (`dsig`, the 7th header field): textbook RSA over the MD5 of the
///   archive. The signature is a 1024-bit integer `s` written in ClamAV's own base64 variant;
///   `s^e mod n` must equal the 16-byte MD5 (as an integer, so every higher byte is zero).
/// * **Database index signature** (`DSIG:` line of `<name>.info` inside the archive): RSA-PSS
///   (RFC 8017 EMSA-PSS) with SHA-256, MGF1-SHA-256 and a 32-byte salt over the SHA-256 of the
///   index text that precedes the `DSIG:` line, with a 2048-bit key (public exponent 100002049).
///   Applying a CDIFF rewrites the index and replaces this line with a new one made with the
///   same index key, which is why a `.cld` rebuilt from CDIFFs can still be checked here.
///
/// CDIFF patch files carry their own signature, made with a third, different ClamAV key (public
/// exponent 100002053). The engine never reads CDIFFs (freshclam or the app's own updater
/// applies them and checks that signature), so this type has no CDIFF key and nothing here
/// relies on one.
///
/// ClamAV's base64 variant: the alphabet is `a–z A–Z 0–9 + /` (lowercase first) and the
/// characters are 6-bit digits of a little-endian number — the first character is the least
/// significant digit.
///
/// The public keys are ClamAV's published verification keys (decimal), looked up as constants.
enum ClamAVSignatureVerifier {
    /// Key that signs `.cvd` headers (1024-bit modulus, public exponent 100001027).
    static let cvdModulus = AVBigUInt(decimal: "118640995551645342603070001658453189751527774412027743746599405743243142607464144767361060640655844749760788890022283424922762488917565551002467771109669598189410434699034532232228621591089508178591428456220796841621637175567590476666928698770143328137383952820383197532047771780196576957695822641224262693037")
    static let cvdExponent = AVBigUInt(decimal: "100001027")

    /// Key that signs the `DSIG:` line of `.info` database indexes (2048-bit modulus, public
    /// exponent 100002049). It does not verify CDIFF files; those use a different key.
    static let indexModulus = AVBigUInt(decimal: "11088894983048545473659556106627194923928941791795047620591658697413581043322715912172496806525381055880964520618400224333320534660299233983755341740679502866829909679955734391392668378361221524205396631090105151641270857277080310734320951653700508941717419168723942507890702904702707587451621691050754307850383399865346487203798464178537392211402786481359824461197231102895415093770394216666324484593935762408468516826633192140826667923494822045805347809932848454845886971706424360558667862775876072059437703365380209101697738577515476935085469455279994113145977994084618328482151013142393373316337519977244732747977")
    static let indexExponent = AVBigUInt(decimal: "100002049")

    private static let alphabet: [UInt8] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/".utf8)

    /// Decodes ClamAV's base64 variant into an integer, or nil on an invalid character.
    static func decodeSignature(_ text: String) -> AVBigUInt? {
        var table = [Int8](repeating: -1, count: 256)
        for (index, c) in alphabet.enumerated() { table[Int(c)] = Int8(index) }
        let characters = Array(text.utf8)
        guard !characters.isEmpty, characters.count <= 1024 else { return nil }
        // 6 bits per character, least significant first.
        var limbs = [UInt32](repeating: 0, count: (characters.count * 6 + 31) / 32 + 1)
        for (index, c) in characters.enumerated() {
            let digit = table[Int(c)]
            guard digit >= 0 else { return nil }
            let bit = index * 6
            let value = UInt64(UInt8(digit)) << UInt64(bit % 32)
            limbs[bit / 32] |= UInt32(truncatingIfNeeded: value)
            if bit / 32 + 1 < limbs.count {
                limbs[bit / 32 + 1] |= UInt32(truncatingIfNeeded: value >> 32)
            }
        }
        return AVBigUInt(limbs: limbs)
    }

    /// Checks a CVD header signature against the header's hex MD5.
    static func verifyCVDSignature(md5Hex: String, signature: String) -> Bool {
        guard let modulus = cvdModulus, let exponent = cvdExponent,
              let expected = AVHex.decode(md5Hex.lowercased()), expected.count == 16,
              let s = decodeSignature(signature), s < modulus else { return false }
        let m = s.power(exponent, modulus: modulus)
        // The signed value is the MD5 itself, so it must fit in 16 bytes.
        guard let digest = m.bigEndianBytes(count: 16) else { return false }
        return digest == expected
    }

    /// Checks an RSA-PSS (SHA-256) index signature over `messageDigest` (a SHA-256 digest).
    static func verifyIndexSignature(messageDigest: [UInt8], signature: String) -> Bool {
        guard let modulus = indexModulus, let exponent = indexExponent, messageDigest.count == 32,
              let s = decodeSignature(signature), s < modulus else { return false }
        let emLength = 256, hashLength = 32, saltLength = 32
        guard let em = s.power(exponent, modulus: modulus).bigEndianBytes(count: emLength),
              em[emLength - 1] == 0xBC else { return false }
        let dbLength = emLength - hashLength - 1
        let maskedDB = Array(em[0..<dbLength])
        let h = Array(em[dbLength..<(dbLength + hashLength)])
        // emBits = modBits - 1 = 2047, so the top bit of the encoded message must be clear.
        guard maskedDB[0] & 0x80 == 0 else { return false }
        var db = mgf1(seed: h, length: dbLength)
        for index in 0..<dbLength { db[index] ^= maskedDB[index] }
        db[0] &= 0x7F
        // DB = PS (zeros) || 0x01 || salt
        let separator = dbLength - saltLength - 1
        guard db[0..<separator].allSatisfy({ $0 == 0 }), db[separator] == 0x01 else { return false }
        let salt = db[(separator + 1)...]
        var hasher = SHA256()
        hasher.update(data: [UInt8](repeating: 0, count: 8))
        hasher.update(data: messageDigest)
        hasher.update(data: Array(salt))
        return Array(hasher.finalize()) == h
    }

    private static func mgf1(seed: [UInt8], length: Int) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(length + 32)
        var counter: UInt32 = 0
        while output.count < length {
            var hasher = SHA256()
            hasher.update(data: seed)
            hasher.update(data: withUnsafeBytes(of: counter.bigEndian) { Array($0) })
            output.append(contentsOf: hasher.finalize())
            counter += 1
        }
        return Array(output.prefix(length))
    }
}

/// Hash helpers over raw memory (CryptoKit).
enum AVDigest {
    static func md5(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var hasher = Insecure.MD5()
        hasher.update(bufferPointer: bytes)
        return Array(hasher.finalize())
    }

    static func sha1(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var hasher = Insecure.SHA1()
        hasher.update(bufferPointer: bytes)
        return Array(hasher.finalize())
    }

    static func sha256(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(bufferPointer: bytes)
        return Array(hasher.finalize())
    }

    static func md5(_ view: AVByteView) -> [UInt8] { md5(view.buffer) }
    static func sha1(_ view: AVByteView) -> [UInt8] { sha1(view.buffer) }
    static func sha256(_ view: AVByteView) -> [UInt8] { sha256(view.buffer) }

    static func sha256(_ data: Data) -> [UInt8] { data.withUnsafeBytes { sha256($0) } }
    static func md5(_ data: Data) -> [UInt8] { data.withUnsafeBytes { md5($0) } }
}
