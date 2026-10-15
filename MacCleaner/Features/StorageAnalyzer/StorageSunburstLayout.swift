import CoreGraphics
import Foundation

/// One arc of a sunburst. Angles are in radians, measured clockwise from 12 o'clock.
struct StorageSunburstSegment: Identifiable, Sendable {
    var id: Int
    var node: StorageNode
    /// 1 for the children of the center folder, 2 for grandchildren…
    var ring: Int
    var startAngle: Double
    var endAngle: Double
    /// Index of the center folder's child that contains this segment (for coloring by folder).
    var topLevelIndex: Int

    var span: Double { endAngle - startAngle }
    var midAngle: Double { (startAngle + endAngle) / 2 }
}

/// Geometry of a sunburst: rings of arcs around the displayed folder, each
/// child's arc proportional to its share of the parent's size.
enum StorageSunburstLayout {
    static let fullCircle = 2 * Double.pi

    /// Splits `[start, end)` among `sizes` in proportion to each size's share of `total`
    /// (normally the parent's size, so children of a parent with other content don't fill the whole span).
    static func angles(sizes: [Double], total: Double, start: Double, end: Double) -> [(start: Double, end: Double)] {
        let span = max(0, end - start)
        guard total > 0, span > 0 else { return sizes.map { _ in (start, start) } }
        var cursor = start
        return sizes.map { size in
            let width = size > 0 ? span * min(1, size / total) : 0
            let range = (start: cursor, end: min(end, cursor + width))
            cursor = range.end
            return range
        }
    }

    /// Segments for `center` and up to `rings` levels below it. Arcs narrower than
    /// `minimumAngle` (radians) are left out together with their descendants.
    static func segments(for center: StorageNode, rings: Int = 4, minimumAngle: Double = 0.004, maximumSegments: Int = 6_000) -> [StorageSunburstSegment] {
        var segments: [StorageSunburstSegment] = []
        var queue: [(node: StorageNode, ring: Int, start: Double, end: Double, topLevel: Int?)] = [(center, 0, 0, fullCircle, nil)]
        var head = 0
        while head < queue.count {
            let (parent, ring, start, end, topLevel) = queue[head]
            head += 1
            guard ring < rings, parent.kind == .directory, parent.size > 0 else { continue }
            let children = parent.children.filter { $0.size > 0 }
            let ranges = angles(sizes: children.map { Double($0.size) }, total: Double(parent.size), start: start, end: end)
            for (index, child) in children.enumerated() {
                let range = ranges[index]
                guard range.end - range.start >= minimumAngle else { continue }
                guard segments.count < maximumSegments else { return segments }
                let top = topLevel ?? index
                segments.append(StorageSunburstSegment(
                    id: segments.count, node: child, ring: ring + 1,
                    startAngle: range.start, endAngle: range.end, topLevelIndex: top
                ))
                if child.kind == .directory {
                    queue.append((child, ring + 1, range.start, range.end, top))
                }
            }
        }
        return segments
    }

    /// Angle of `point` around `center`, clockwise from 12 o'clock, in `[0, 2π)`.
    /// Uses screen coordinates (y grows downward).
    static func angle(of point: CGPoint, around center: CGPoint) -> Double {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += fullCircle }
        return angle
    }

    /// The ring under `point`: 0 inside the center circle, 1… for rings, nil outside.
    static func ring(at point: CGPoint, center: CGPoint, innerRadius: Double, ringWidth: Double, rings: Int) -> Int? {
        let distance = hypot(Double(point.x - center.x), Double(point.y - center.y))
        if distance < innerRadius { return 0 }
        guard ringWidth > 0 else { return nil }
        let ring = Int((distance - innerRadius) / ringWidth) + 1
        return ring <= rings ? ring : nil
    }

    /// The segment under `point`, or nil (center circle, gaps, outside).
    static func hitTest(_ point: CGPoint, center: CGPoint, innerRadius: Double, ringWidth: Double, rings: Int, segments: [StorageSunburstSegment]) -> StorageSunburstSegment? {
        guard let ring = ring(at: point, center: center, innerRadius: innerRadius, ringWidth: ringWidth, rings: rings), ring > 0 else { return nil }
        let angle = angle(of: point, around: center)
        return segments.first { $0.ring == ring && angle >= $0.startAngle && angle < $0.endAngle }
    }

    /// Point on the circle of `radius` at `angle` (clockwise from 12 o'clock).
    static func point(at angle: Double, radius: Double, center: CGPoint) -> CGPoint {
        CGPoint(x: Double(center.x) + radius * sin(angle), y: Double(center.y) - radius * cos(angle))
    }
}
