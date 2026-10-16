import Foundation

/// A small arbitrary-precision unsigned integer: just enough arithmetic to verify ClamAV's RSA
/// signatures (`s^e mod n` with a public exponent). Little-endian 32-bit limbs, always
/// normalized (no leading zero limbs). Not constant-time, which is fine because only public
/// values are involved.
struct AVBigUInt: Equatable, Sendable {
    private(set) var limbs: [UInt32]

    init() { limbs = [] }

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    /// Parses a non-empty string of decimal digits.
    init?(decimal: String) {
        guard !decimal.isEmpty else { return nil }
        var result = AVBigUInt()
        for c in decimal.utf8 {
            guard c >= 0x30, c <= 0x39 else { return nil }
            result.multiply(bySmall: 10, adding: UInt32(c - 0x30))
        }
        self = result
    }

    /// Big-endian bytes, as in RFC 8017's OS2IP.
    init(bigEndianBytes bytes: [UInt8]) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 4] |= UInt32(byte) << (8 * UInt32(index % 4))
        }
        self.init(limbs: limbs)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] >> UInt32(index % 32) & 1 == 1
    }

    /// Big-endian bytes left-padded to `count`, or nil when the value doesn't fit (RFC 8017 I2OSP).
    func bigEndianBytes(count: Int) -> [UInt8]? {
        guard bitWidth <= count * 8 else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        for index in 0..<min(count, limbs.count * 4) {
            out[count - 1 - index] = UInt8(truncatingIfNeeded: limbs[index / 4] >> (8 * UInt32(index % 4)))
        }
        return out
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    private mutating func multiply(bySmall factor: UInt32, adding addend: UInt32) {
        var carry = UInt64(addend)
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }
        if carry != 0 { limbs.append(UInt32(carry)) }
        normalize()
    }

    static func < (lhs: AVBigUInt, rhs: AVBigUInt) -> Bool {
        compare(lhs.limbs, rhs.limbs) < 0
    }

    private static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var index = a.count - 1
        while index >= 0 {
            if a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
            index -= 1
        }
        return 0
    }

    static func * (lhs: AVBigUInt, rhs: AVBigUInt) -> AVBigUInt {
        guard !lhs.isZero, !rhs.isZero else { return AVBigUInt() }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in lhs.limbs.indices {
            var carry: UInt64 = 0
            let a = UInt64(lhs.limbs[i])
            for j in rhs.limbs.indices {
                let sum = a * UInt64(rhs.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var k = i + rhs.limbs.count
            while carry != 0, k < out.count {
                let sum = UInt64(out[k]) + carry
                out[k] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                k += 1
            }
        }
        return AVBigUInt(limbs: out)
    }

    /// `self mod modulus` by binary long division (shift and subtract). Slow per bit, but the
    /// operands are at most a few thousand bits and only a few dozen reductions are needed.
    func remainder(dividingBy modulus: AVBigUInt) -> AVBigUInt {
        precondition(!modulus.isZero, "modulus must be non-zero")
        if self < modulus { return self }
        let width = modulus.limbs.count + 1
        var remainder = [UInt32](repeating: 0, count: width)
        let m = modulus.limbs + [0]
        var index = bitWidth - 1
        while index >= 0 {
            // remainder = remainder << 1 | bit
            var carry: UInt32 = bit(index) ? 1 : 0
            for limb in 0..<width {
                let next = remainder[limb] >> 31
                remainder[limb] = remainder[limb] << 1 | carry
                carry = next
            }
            if AVBigUInt.compare(remainder, m) >= 0 {
                var borrow: Int64 = 0
                for limb in 0..<width {
                    var difference = Int64(remainder[limb]) - Int64(m[limb]) - borrow
                    if difference < 0 { difference += 1 << 32; borrow = 1 } else { borrow = 0 }
                    remainder[limb] = UInt32(truncatingIfNeeded: difference)
                }
            }
            index -= 1
        }
        return AVBigUInt(limbs: remainder)
    }

    /// `self^exponent mod modulus` (left-to-right square and multiply).
    func power(_ exponent: AVBigUInt, modulus: AVBigUInt) -> AVBigUInt {
        var result = AVBigUInt(1).remainder(dividingBy: modulus)
        let base = remainder(dividingBy: modulus)
        var index = exponent.bitWidth - 1
        while index >= 0 {
            result = (result * result).remainder(dividingBy: modulus)
            if exponent.bit(index) {
                result = (result * base).remainder(dividingBy: modulus)
            }
            index -= 1
        }
        return result
    }
}
