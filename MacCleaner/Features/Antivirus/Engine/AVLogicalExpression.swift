import Foundation

/// Binary encoding and evaluation of logical expressions (`AVLogicalNode`).
///
/// Semantics follow ClamAV: a bare subsignature is true when it matched at least once; `A=X`,
/// `A>X` and `A<X` compare the total number of matches of every subsignature inside `A` (for a
/// parenthesized block, the sum over all of them, regardless of the `&`/`|` inside); `,Y`
/// additionally requires at least `Y` different subsignatures of `A` to have matched.
///
/// Encoding (little-endian):
/// * `0x01 id:UInt16` — subsignature
/// * `0x02 leftLength:UInt32 left right` — and
/// * `0x03 leftLength:UInt32 left right` — or
/// * `0x04 op:UInt8 value:UInt32 distinct:UInt32 (0xFFFFFFFF = none) child` — count comparison
enum AVLogicalExpressionCodec {
    private static let leafCode: UInt8 = 1, andCode: UInt8 = 2, orCode: UInt8 = 3, countCode: UInt8 = 4

    static func encode(_ node: AVLogicalNode) -> [UInt8] {
        var out = [UInt8]()
        encode(node, into: &out)
        return out
    }

    private static func encode(_ node: AVLogicalNode, into out: inout [UInt8]) {
        switch node {
        case .subsig(let id):
            out.append(leafCode)
            append(UInt16(truncatingIfNeeded: id), to: &out)
        case .and(let a, let b), .or(let a, let b):
            if case .and = node { out.append(andCode) } else { out.append(orCode) }
            let left = encode(a)
            append(UInt32(left.count), to: &out)
            out.append(contentsOf: left)
            encode(b, into: &out)
        case .count(let child, let op, let value, let distinct):
            out.append(countCode)
            out.append(op.rawValue)
            append(UInt32(clamping: value), to: &out)
            append(distinct.map { UInt32(clamping: $0) } ?? UInt32.max, to: &out)
            encode(child, into: &out)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    /// Evaluates an encoded expression. `count(id)` returns the number of matches of a
    /// subsignature; it's only called for subsignatures whose count is needed, so callers can
    /// compute expensive counts lazily. Malformed code evaluates to false.
    static func evaluate(_ code: AVByteView, count: (Int) -> Int) -> Bool {
        var depth = 0
        return evaluate(code, 0, code.count, count: count, depth: &depth) ?? false
    }

    private static func evaluate(_ code: AVByteView, _ start: Int, _ end: Int, count: (Int) -> Int, depth: inout Int) -> Bool? {
        depth += 1
        defer { depth -= 1 }
        guard depth < 256, start < end, let op = code.u8(start) else { return nil }
        switch op {
        case leafCode:
            guard let id = code.u16le(start + 1) else { return nil }
            return count(Int(id)) > 0
        case andCode, orCode:
            guard let leftLength = code.u32le(start + 1).map(Int.init), start + 5 + leftLength <= end else { return nil }
            let leftStart = start + 5, rightStart = leftStart + leftLength
            guard let left = evaluate(code, leftStart, rightStart, count: count, depth: &depth) else { return nil }
            // Short-circuit: the right side's counts may be expensive.
            if op == andCode && !left { return false }
            if op == orCode && left { return true }
            return evaluate(code, rightStart, end, count: count, depth: &depth)
        case countCode:
            guard let relation = code.u8(start + 1), let value = code.u32le(start + 2), let distinct = code.u32le(start + 6) else { return nil }
            guard let (total, different) = tally(code, start + 10, end, count: count, depth: &depth) else { return nil }
            if distinct != UInt32.max, different < Int(distinct) { return false }
            switch relation {
            case AVLogicalNode.CountOperator.equal.rawValue: return total == Int(value)
            case AVLogicalNode.CountOperator.greater.rawValue: return total > Int(value)
            case AVLogicalNode.CountOperator.less.rawValue: return total < Int(value)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Sum of match counts and number of distinct matched subsignatures below a node.
    private static func tally(_ code: AVByteView, _ start: Int, _ end: Int, count: (Int) -> Int, depth: inout Int) -> (Int, Int)? {
        depth += 1
        defer { depth -= 1 }
        guard depth < 256, start < end, let op = code.u8(start) else { return nil }
        switch op {
        case leafCode:
            guard let id = code.u16le(start + 1) else { return nil }
            let n = count(Int(id))
            return (n, n > 0 ? 1 : 0)
        case andCode, orCode:
            guard let leftLength = code.u32le(start + 1).map(Int.init), start + 5 + leftLength <= end else { return nil }
            guard let left = tally(code, start + 5, start + 5 + leftLength, count: count, depth: &depth),
                  let right = tally(code, start + 5 + leftLength, end, count: count, depth: &depth) else { return nil }
            return (left.0 &+ right.0, left.1 + right.1)
        case countCode:
            return tally(code, start + 10, end, count: count, depth: &depth)
        default:
            return nil
        }
    }
}

/// Compile-time analysis used to pick which subsignatures go into the prefilter.
enum AVLogicalAnalysis {
    /// A set of subsignatures such that the expression can only be true when at least one of
    /// them matched, or nil when the expression can be true without any of them matching.
    ///
    /// The scanner only looks for these "trigger" subsignatures in its main pass; the others
    /// are searched for afterwards, and only in files where a trigger matched.
    ///
    /// - Parameters:
    ///   - leaf: The trigger set for one subsignature: itself for a body pattern that can be
    ///     prefiltered, the trigger set of a PCRE's trigger expression, a byte compare's reference,
    ///     or nil when it can't be found by the prefilter.
    ///   - cost: Expected prefilter work of a set (lower is better), used to choose between the
    ///     sides of an `&`.
    static func requiredSet(_ node: AVLogicalNode, leaf: (Int) -> Set<Int>?, cost: (Set<Int>) -> Double) -> Set<Int>? {
        switch node {
        case .subsig(let id):
            return leaf(id)
        case .and(let a, let b):
            let left = requiredSet(a, leaf: leaf, cost: cost), right = requiredSet(b, leaf: leaf, cost: cost)
            switch (left, right) {
            case let (l?, r?): return cost(l) <= cost(r) ? l : r
            case let (l?, nil): return l
            case let (nil, r?): return r
            default: return nil
            }
        case .or(let a, let b):
            guard let left = requiredSet(a, leaf: leaf, cost: cost), let right = requiredSet(b, leaf: leaf, cost: cost) else { return nil }
            return left.union(right)
        case .count(let child, let op, let value, let distinct):
            // True only if the block has at least one match: then any of its subsignatures can trigger.
            let needsAMatch: Bool
            if let distinct, distinct > 0 {
                needsAMatch = true
            } else {
                switch op {
                case .equal: needsAMatch = value > 0
                case .greater: needsAMatch = true
                case .less: needsAMatch = false
                }
            }
            guard needsAMatch else { return nil }
            var union = Set<Int>()
            for id in child.subsigs {
                guard let set = leaf(id) else { return nil }
                union.formUnion(set)
            }
            return union
        }
    }

    /// How many matches of each subsignature the expression can distinguish (so searches can stop
    /// early): 1 for plain presence, `X+1` for `=X`/`>X`, `X` for `<X`. Int.max when unbounded.
    static func neededCounts(_ node: AVLogicalNode, into needed: inout [Int: Int]) {
        func raise(_ id: Int, _ value: Int) { needed[id] = max(needed[id] ?? 0, value) }
        switch node {
        case .subsig(let id):
            raise(id, 1)
        case .and(let a, let b), .or(let a, let b):
            neededCounts(a, into: &needed)
            neededCounts(b, into: &needed)
        case .count(let child, let op, let value, _):
            let limit: Int
            switch op {
            case .equal, .greater: limit = value == Int.max ? Int.max : value + 1
            case .less: limit = max(1, value)
            }
            // In a block the sum matters, so every member may need the full count.
            for id in child.subsigs { raise(id, limit) }
            neededCounts(child, into: &needed)
        }
    }
}
