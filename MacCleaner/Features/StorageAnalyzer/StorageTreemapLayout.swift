import CoreGraphics
import Foundation

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
///
/// Items are placed in rows along the shorter side of the remaining space; a
/// row grows while adding the next (smaller) item doesn't make the worst
/// aspect ratio in the row worse. The result keeps rectangles close to squares,
/// which makes sizes easy to compare and labels easy to fit.
enum StorageSquarifiedLayout {
    /// Lays out non-negative weights in `rect`.
    ///
    /// - Returns: One rectangle per weight, in input order. Each rectangle's area is
    ///   proportional to its weight and together they tile `rect`. Zero or negative
    ///   weights get an empty rectangle at `rect.origin`.
    static func layout(sizes: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: CGRect(origin: rect.origin, size: .zero), count: sizes.count)
        let positive = sizes.indices.filter { sizes[$0] > 0 && sizes[$0].isFinite }
        let total = positive.reduce(0.0) { $0 + sizes[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        // Largest first; ties keep input order so layouts are deterministic.
        let order = positive.sorted { sizes[$0] != sizes[$1] ? sizes[$0] > sizes[$1] : $0 < $1 }
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { sizes[$0] * scale }

        var remaining = rect
        var start = 0
        while start < areas.count {
            let shortSide = Double(min(remaining.width, remaining.height))
            guard shortSide > 0 else { break }

            var end = start + 1
            var rowSum = areas[start]
            var rowMin = areas[start]
            var rowMax = areas[start]
            var worst = worstAspectRatio(sum: rowSum, minimum: rowMin, maximum: rowMax, side: shortSide)
            while end < areas.count {
                let area = areas[end]
                let candidate = worstAspectRatio(sum: rowSum + area, minimum: min(rowMin, area), maximum: max(rowMax, area), side: shortSide)
                if candidate > worst { break }
                rowSum += area
                rowMin = min(rowMin, area)
                rowMax = max(rowMax, area)
                worst = candidate
                end += 1
            }

            let isLastRow = end == areas.count
            if remaining.width >= remaining.height {
                // A vertical strip on the left, items stacked top to bottom.
                let stripWidth = isLastRow ? Double(remaining.width) : rowSum / Double(remaining.height)
                var y = Double(remaining.minY)
                for index in start..<end {
                    let height = index == end - 1 ? Double(remaining.maxY) - y : areas[index] / stripWidth
                    result[order[index]] = CGRect(x: Double(remaining.minX), y: y, width: stripWidth, height: max(0, height))
                    y += height
                }
                remaining = CGRect(
                    x: remaining.minX + CGFloat(stripWidth), y: remaining.minY,
                    width: max(0, remaining.width - CGFloat(stripWidth)), height: remaining.height
                )
            } else {
                // A horizontal strip at the top, items left to right.
                let stripHeight = isLastRow ? Double(remaining.height) : rowSum / Double(remaining.width)
                var x = Double(remaining.minX)
                for index in start..<end {
                    let width = index == end - 1 ? Double(remaining.maxX) - x : areas[index] / stripHeight
                    result[order[index]] = CGRect(x: x, y: Double(remaining.minY), width: max(0, width), height: stripHeight)
                    x += width
                }
                remaining = CGRect(
                    x: remaining.minX, y: remaining.minY + CGFloat(stripHeight),
                    width: remaining.width, height: max(0, remaining.height - CGFloat(stripHeight))
                )
            }
            start = end
        }
        return result
    }

    /// The worst (largest) aspect ratio of a row of areas laid along a side of length `side`.
    static func worstAspectRatio(sum: Double, minimum: Double, maximum: Double, side: Double) -> Double {
        guard sum > 0, minimum > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * maximum / sumSquared, sumSquared / (sideSquared * minimum))
    }
}

/// One rectangle of a nested treemap.
struct StorageTreemapTile: Identifiable, Sendable {
    var id: Int
    var node: StorageNode
    var rect: CGRect
    /// 0 for children of the displayed folder, 1 for grandchildren…
    var depth: Int
    /// Index of the displayed folder's child that contains this tile (for coloring by folder).
    var topLevelIndex: Int
    /// The folder's own children are drawn inside it, below a header strip.
    var isContainer: Bool
    var headerHeight: CGFloat
}

/// Builds nested treemap tiles for a folder: its children, and for folders with
/// enough room, their children too, up to `maxDepth` levels.
enum StorageTreemapLayout {
    struct Options: Sendable {
        var maxDepth = 3
        /// Space between a container's border and its children.
        var padding: CGFloat = 2
        /// Header strip of containers wide enough for a label.
        var headerHeight: CGFloat = 17
        /// A folder needs at least this width and height to show its children.
        var minimumContainerSide: CGFloat = 44
        /// Tiles smaller than this (in points²) are not drawn on their own.
        var minimumTileArea: CGFloat = 6
        var maximumTiles = 6_000
    }

    static func tiles(for node: StorageNode, in rect: CGRect, options: Options = Options()) -> [StorageTreemapTile] {
        var tiles: [StorageTreemapTile] = []
        // Breadth-first, so the tile budget is spent on the upper levels first.
        var queue: [(node: StorageNode, rect: CGRect, depth: Int, topLevel: Int?)] = [(node, rect, 0, nil)]
        var head = 0
        while head < queue.count {
            let (parent, area, depth, topLevel) = queue[head]
            head += 1
            let children = parent.children.filter { $0.size > 0 }
            guard !children.isEmpty, area.width > 0, area.height > 0 else { continue }
            let rects = StorageSquarifiedLayout.layout(sizes: children.map { Double($0.size) }, in: area)
            for (index, child) in children.enumerated() {
                let childRect = rects[index]
                guard childRect.width * childRect.height >= options.minimumTileArea else { continue }
                guard tiles.count < options.maximumTiles else { return tiles }
                let top = topLevel ?? index
                let canNest = child.kind == .directory && !child.children.isEmpty && depth + 1 < options.maxDepth
                    && childRect.width >= options.minimumContainerSide && childRect.height >= options.minimumContainerSide
                let header: CGFloat = canNest && childRect.width >= 64 && childRect.height >= options.minimumContainerSide + options.headerHeight
                    ? options.headerHeight : 0
                tiles.append(StorageTreemapTile(
                    id: tiles.count, node: child, rect: childRect, depth: depth, topLevelIndex: top,
                    isContainer: canNest, headerHeight: header
                ))
                if canNest {
                    let inner = CGRect(
                        x: childRect.minX + options.padding,
                        y: childRect.minY + header + (header > 0 ? 0 : options.padding),
                        width: childRect.width - 2 * options.padding,
                        height: childRect.height - header - (header > 0 ? 1 : 2) * options.padding
                    )
                    if inner.width > 2, inner.height > 2 {
                        queue.append((child, inner, depth + 1, top))
                    }
                }
            }
        }
        return tiles
    }

    /// The deepest tile containing `point` (tiles are stored parents first).
    static func hitTest(_ point: CGPoint, in tiles: [StorageTreemapTile]) -> StorageTreemapTile? {
        for tile in tiles.reversed() where tile.rect.contains(point) {
            return tile
        }
        return nil
    }
}
