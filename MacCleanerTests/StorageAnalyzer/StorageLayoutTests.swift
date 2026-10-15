import CoreGraphics
import Foundation
import Testing
@testable import MacCleaner

@Suite("Storage treemap layout")
struct StorageTreemapLayoutTests {
    private let bounds = CGRect(x: 10, y: 20, width: 800, height: 500)

    /// Deterministic pseudo-random sizes spanning several orders of magnitude.
    private func sampleSizes(count: Int, seed: UInt64) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return pow(10, 1 + unit * 5)
        }
    }

    @Test(arguments: [1, 2, 7, 40, 300])
    func rectanglesStayInsideTheBounds(count: Int) {
        let rects = StorageSquarifiedLayout.layout(sizes: sampleSizes(count: count, seed: UInt64(count)), in: bounds)
        #expect(rects.count == count)
        for rect in rects {
            #expect(rect.minX >= bounds.minX - 1e-6)
            #expect(rect.minY >= bounds.minY - 1e-6)
            #expect(rect.maxX <= bounds.maxX + 1e-6)
            #expect(rect.maxY <= bounds.maxY + 1e-6)
        }
    }

    @Test(arguments: [3, 25, 200])
    func areasAreProportionalToSizes(count: Int) {
        let sizes = sampleSizes(count: count, seed: 99 &+ UInt64(count))
        let rects = StorageSquarifiedLayout.layout(sizes: sizes, in: bounds)
        let total = sizes.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        var covered = 0.0
        for (size, rect) in zip(sizes, rects) {
            let expected = size / total * area
            let actual = Double(rect.width * rect.height)
            covered += actual
            #expect(abs(actual - expected) <= max(1e-6, expected * 1e-6), "size \(size) got \(actual), expected \(expected)")
        }
        #expect(abs(covered - area) < area * 1e-9, "Rectangles must tile the bounds")
    }

    @Test func rectanglesDoNotOverlap() {
        let rects = StorageSquarifiedLayout.layout(sizes: sampleSizes(count: 120, seed: 7), in: bounds)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
                #expect(overlapArea < 1e-6, "Rects \(i) and \(j) overlap by \(overlapArea)")
            }
        }
    }

    @Test func equalSizesFormNearSquares() {
        let rects = StorageSquarifiedLayout.layout(sizes: Array(repeating: 1, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for rect in rects {
            let aspect = max(rect.width / rect.height, rect.height / rect.width)
            #expect(aspect <= 1.5)
        }
    }

    @Test func zeroAndNegativeSizesGetEmptyRectangles() {
        let rects = StorageSquarifiedLayout.layout(sizes: [5, 0, -3, 5], in: bounds)
        #expect(rects[1].width * rects[1].height == 0)
        #expect(rects[2].width * rects[2].height == 0)
        #expect(abs(Double(rects[0].width * rects[0].height) - Double(bounds.width * bounds.height) / 2) < 1e-6)
    }

    @Test func worstAspectRatioMatchesDefinition() {
        // A row of areas 6 and 6 along a side of 4 is a strip 12 / 4 = 3 thick,
        // so each rectangle is 3 × 2: worst aspect ratio 1.5.
        let ratio = StorageSquarifiedLayout.worstAspectRatio(sum: 12, minimum: 6, maximum: 6, side: 4)
        #expect(abs(ratio - 1.5) < 1e-12)
        // Adding a much smaller item to the row makes it worse.
        #expect(StorageSquarifiedLayout.worstAspectRatio(sum: 13, minimum: 1, maximum: 6, side: 4) > ratio)
    }

    @Test func nestedTilesStayInsideTheirParents() {
        let tree = StorageTestTree.make()
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let options = StorageTreemapLayout.Options()
        let tiles = StorageTreemapLayout.tiles(for: tree.root, in: bounds, options: options)
        let topLevel = tiles.filter { $0.depth == 0 }
        // Children too small to draw (tiny.txt) are left out; everything else gets a tile.
        let drawable = tree.root.children.filter {
            Double($0.size) / Double(tree.root.size) * Double(bounds.width * bounds.height) >= Double(options.minimumTileArea)
        }
        #expect(topLevel.count == drawable.count)
        #expect(!topLevel.contains { $0.node.name == "tiny.txt" })
        for tile in tiles where tile.depth > 0 {
            guard let parentNode = tile.node.parent, let parentTile = tiles.first(where: { $0.node === parentNode }) else {
                Issue.record("Nested tile without a parent tile")
                continue
            }
            #expect(parentTile.rect.insetBy(dx: -1e-6, dy: -1e-6).contains(tile.rect))
            #expect(parentTile.isContainer)
        }
        // Hit testing returns the deepest tile under the point.
        if let nested = tiles.last(where: { $0.depth > 0 }) {
            let hit = StorageTreemapLayout.hitTest(CGPoint(x: nested.rect.midX, y: nested.rect.midY), in: tiles)
            #expect(hit?.node === nested.node)
        }
    }
}

@Suite("Storage sunburst layout")
struct StorageSunburstLayoutTests {
    @Test func anglesSplitTheSpanProportionally() {
        let ranges = StorageSunburstLayout.angles(sizes: [1, 2, 3], total: 6, start: 0, end: 2 * .pi)
        #expect(ranges.count == 3)
        #expect(abs(ranges[0].end - ranges[0].start - 2 * .pi / 6) < 1e-12)
        #expect(abs(ranges[1].end - ranges[1].start - 4 * .pi / 6) < 1e-12)
        #expect(abs(ranges[2].end - 2 * .pi) < 1e-12)
        // Contiguous.
        #expect(ranges[0].end == ranges[1].start)
        #expect(ranges[1].end == ranges[2].start)
    }

    @Test func childrenOfALargerParentDontFillTheSpan() {
        let ranges = StorageSunburstLayout.angles(sizes: [1, 1], total: 4, start: .pi / 2, end: .pi)
        #expect(abs(ranges[0].start - .pi / 2) < 1e-12)
        #expect(abs(ranges[1].end - (.pi / 2 + .pi / 4)) < 1e-12)
    }

    @Test func emptyTotalsGiveEmptyArcs() {
        let ranges = StorageSunburstLayout.angles(sizes: [3, 4], total: 0, start: 1, end: 2)
        #expect(ranges.allSatisfy { $0.start == $0.end })
    }

    @Test func anglesStartAtTwelveOClockAndRunClockwise() {
        let center = CGPoint(x: 100, y: 100)
        #expect(abs(StorageSunburstLayout.angle(of: CGPoint(x: 100, y: 50), around: center)) < 1e-12)
        #expect(abs(StorageSunburstLayout.angle(of: CGPoint(x: 150, y: 100), around: center) - .pi / 2) < 1e-12)
        #expect(abs(StorageSunburstLayout.angle(of: CGPoint(x: 100, y: 150), around: center) - .pi) < 1e-12)
        #expect(abs(StorageSunburstLayout.angle(of: CGPoint(x: 50, y: 100), around: center) - 3 * .pi / 2) < 1e-12)
        // point(at:) is the inverse.
        let point = StorageSunburstLayout.point(at: 1.1, radius: 40, center: center)
        #expect(abs(StorageSunburstLayout.angle(of: point, around: center) - 1.1) < 1e-9)
    }

    @Test func ringsAreFoundByDistance() {
        let center = CGPoint.zero
        #expect(StorageSunburstLayout.ring(at: CGPoint(x: 5, y: 0), center: center, innerRadius: 10, ringWidth: 20, rings: 3) == 0)
        #expect(StorageSunburstLayout.ring(at: CGPoint(x: 15, y: 0), center: center, innerRadius: 10, ringWidth: 20, rings: 3) == 1)
        #expect(StorageSunburstLayout.ring(at: CGPoint(x: 0, y: 55), center: center, innerRadius: 10, ringWidth: 20, rings: 3) == 3)
        #expect(StorageSunburstLayout.ring(at: CGPoint(x: 0, y: 75), center: center, innerRadius: 10, ringWidth: 20, rings: 3) == nil)
    }

    @Test func segmentsNestInsideTheirParents() {
        let tree = StorageTestTree.make()
        let segments = StorageSunburstLayout.segments(for: tree.root, rings: 3, minimumAngle: 0)
        let firstRing = segments.filter { $0.ring == 1 }
        let span = firstRing.reduce(0) { $0 + $1.span }
        #expect(abs(span - 2 * .pi) < 1e-9, "The root's children fill the circle")
        for segment in segments where segment.ring > 1 {
            guard let parent = segments.first(where: { $0.node === segment.node.parent }) else {
                Issue.record("Segment without parent segment")
                continue
            }
            #expect(segment.startAngle >= parent.startAngle - 1e-12)
            #expect(segment.endAngle <= parent.endAngle + 1e-12)
            #expect(segment.ring == parent.ring + 1)
        }
        // Proportional to size.
        for segment in firstRing {
            #expect(abs(segment.span - 2 * .pi * Double(segment.node.size) / Double(tree.root.size)) < 1e-9)
        }
        // Hit test in the middle of a first-ring arc finds it.
        if let target = firstRing.first {
            let point = StorageSunburstLayout.point(at: target.midAngle, radius: 15, center: .zero)
            let hit = StorageSunburstLayout.hitTest(point, center: .zero, innerRadius: 10, ringWidth: 20, rings: 3, segments: segments)
            #expect(hit?.node === target.node)
        }
    }

    @Test func narrowArcsAreLeftOut() {
        let tree = StorageTestTree.make()
        let all = StorageSunburstLayout.segments(for: tree.root, rings: 4, minimumAngle: 0)
        let filtered = StorageSunburstLayout.segments(for: tree.root, rings: 4, minimumAngle: 0.5)
        #expect(filtered.count < all.count)
        #expect(filtered.allSatisfy { $0.span >= 0.5 })
    }
}

/// A small in-memory tree for layout tests.
enum StorageTestTree {
    struct Built {
        var root: StorageNode
    }

    static func make() -> Built {
        let root = StorageNode(name: "Root", kind: .directory, parent: nil, inode: 1)
        func folder(_ name: String, in parent: StorageNode) -> StorageNode {
            let node = StorageNode(name: name, kind: .directory, parent: parent, inode: 0)
            parent.children.append(node)
            return node
        }
        func file(_ name: String, size: Int64, in parent: StorageNode) {
            let node = StorageNode(name: name, kind: .file, parent: parent, inode: 0)
            node.size = size
            node.itemCount = 1
            parent.children.append(node)
        }
        let movies = folder("Movies", in: root)
        file("a.mov", size: 4_000_000_000, in: movies)
        file("b.mov", size: 1_000_000_000, in: movies)
        let projects = folder("Projects", in: root)
        let app = folder("App", in: projects)
        file("build.zip", size: 600_000_000, in: app)
        file("assets.psd", size: 300_000_000, in: app)
        file("notes.pdf", size: 5_000_000, in: projects)
        file("disk.dmg", size: 2_000_000_000, in: root)
        file("tiny.txt", size: 2_000, in: root)
        StorageTreeBuilder.aggregate(root)
        return Built(root: root)
    }
}
