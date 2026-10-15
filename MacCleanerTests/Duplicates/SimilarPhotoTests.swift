import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacCleaner

@Suite("Similar photo grouping")
struct SimilarPhotoGroupingTests {
    @Test func leaderClusteringDoesNotChainLooselyRelatedPhotos() {
        // A chain 0–1–2–3 where only neighbors are close.
        let edges = [
            SimilarPhotoEdge(first: 0, second: 1, distance: 0.1),
            SimilarPhotoEdge(first: 1, second: 2, distance: 0.1),
            SimilarPhotoEdge(first: 2, second: 3, distance: 0.1),
            SimilarPhotoEdge(first: 0, second: 3, distance: 0.9),
        ]
        let clusters = SimilarPhotoClustering.cluster(count: 5, edges: edges, threshold: 0.2)
        #expect(clusters.count == 1)
        #expect(clusters.first?.leader == 1)
        #expect(Set(clusters.first?.members ?? []) == [0, 1, 2])
        // Photo 3 is only close to photo 2, which already belongs to a group; photo 4 has no match.
        #expect(!clusters.flatMap(\.members).contains(3))
        #expect(!clusters.flatMap(\.members).contains(4))
    }

    @Test func stricterThresholdsProduceSmallerGroups() {
        let edges = [
            SimilarPhotoEdge(first: 0, second: 1, distance: 0.05),
            SimilarPhotoEdge(first: 0, second: 2, distance: 0.3),
        ]
        #expect(SimilarPhotoClustering.cluster(count: 3, edges: edges, threshold: 0.4).first?.members.count == 3)
        #expect(SimilarPhotoClustering.cluster(count: 3, edges: edges, threshold: 0.1).first?.members.count == 2)
        #expect(SimilarPhotoClustering.cluster(count: 3, edges: edges, threshold: 0.01).isEmpty)
    }

    @Test func comparerMatchesBruteForceAcrossBlocks() throws {
        let count = 600
        let dimension = 32
        var generator = SimilarTestGenerator(seed: 42)
        var vectors: [Float] = []
        for _ in 0..<count {
            let raw = (0..<dimension).map { _ in Float(generator.next() * 2 - 1) }
            let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
            vectors.append(contentsOf: raw.map { $0 / norm })
        }
        let maximum: Float = 1.1
        let result = try SimilarPhotoComparer.edges(
            vectors: vectors, count: count, dimension: dimension, maximumDistance: maximum, cancellation: DuplicateCancellation()
        )
        #expect(result.maximumDistance == maximum)

        func distance(_ i: Int, _ j: Int) -> Float {
            var sum: Float = 0
            for k in 0..<dimension {
                let difference = vectors[i * dimension + k] - vectors[j * dimension + k]
                sum += difference * difference
            }
            return sum.squareRoot()
        }
        var expected = Set<Int>()
        for i in 0..<count {
            for j in (i + 1)..<count where distance(i, j) < maximum - 0.001 {
                expected.insert(i * count + j)
            }
        }
        let reported = Set(result.edges.map { Int($0.first) * count + Int($0.second) })
        #expect(!expected.isEmpty)
        #expect(expected.isSubset(of: reported))
        for edge in result.edges {
            #expect(edge.first < edge.second)
            #expect(abs(edge.distance - distance(Int(edge.first), Int(edge.second))) < 0.001)
        }
    }

    @Test func comparerKeepsOnlyTheClosestPairsWhenThereAreTooMany() throws {
        let count = 40
        let dimension = 4
        // Every vector is identical: all 780 pairs match.
        let vectors = [Float](repeating: 0.5, count: count * dimension)
        let result = try SimilarPhotoComparer.edges(
            vectors: vectors, count: count, dimension: dimension, maximumDistance: 0.6, maximumEdges: 100,
            cancellation: DuplicateCancellation()
        )
        #expect(result.edges.count == 100)
    }

    @Test func similaritySettingMapsToCalibratedDistances() {
        #expect(SimilarPhotoThreshold.distance(forSimilarity: 0) == SimilarPhotoThreshold.loosest)
        #expect(abs(SimilarPhotoThreshold.distance(forSimilarity: 1) - SimilarPhotoThreshold.strictest) < 0.0001)
        #expect(SimilarPhotoThreshold.distance(forSimilarity: 0.8) < SimilarPhotoThreshold.distance(forSimilarity: 0.2))
        #expect(SimilarPhotoThreshold.label(forSimilarity: 1) == "Nearly identical")
        #expect(SimilarPhotoThreshold.label(forSimilarity: 0) == "Loosely similar")
    }

    @Test func exifDatesAreParsedWithTheirOffset() throws {
        let date = try #require(SimilarPhotoAnalyzer.parseExifDate("2021:07:04 10:30:00", offset: "-04:00"))
        #expect(date == Date(timeIntervalSince1970: 1_625_409_000))
        #expect(SimilarPhotoAnalyzer.parseExifDate("0000:00:00 00:00:00", offset: nil) == nil)
        #expect(SimilarPhotoAnalyzer.parseExifDate("garbage", offset: nil) == nil)
    }
}

@Suite("Similar photo finder")
struct SimilarPhotoFinderTests {
    @Test func resizedAndCroppedCopiesAreGroupedButNothingIsSelected() async throws {
        let fixture = try DuplicateTestFixture()
        let beach = SimilarTestImages.scene(seed: 1, width: 1600, height: 1200)
        let original = fixture.path("Trip/beach.png")
        try SimilarTestImages.save(beach, to: original, type: .png)
        let resized = fixture.path("Exports/beach-small.jpg")
        try SimilarTestImages.save(SimilarTestImages.resized(beach, width: 800, height: 600), to: resized, type: .jpeg, quality: 0.85,
                                   exif: [kCGImagePropertyExifDateTimeOriginal: "2021:07:04 10:30:00", kCGImagePropertyExifOffsetTimeOriginal: "-04:00"])
        let stripes = fixture.path("Trip/stripes.png")
        try SimilarTestImages.save(SimilarTestImages.stripes(width: 1600, height: 1200), to: stripes, type: .png)
        let checker = fixture.path("Trip/checker.png")
        try SimilarTestImages.save(SimilarTestImages.checkerboard(width: 1200, height: 1200), to: checker, type: .png)

        let result = try await SimilarPhotoFinder(policy: fixture.policy)
            .findSimilarPhotos(options: fixture.options())

        #expect(result.imagesFound == 4)
        #expect(result.imagesAnalyzed == 4)
        let groups = result.groups(threshold: 0.3)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.photos.map(\.file.path)) == [original, resized])
        // Highest resolution first, with dimensions and the EXIF capture date read.
        #expect(group.photos.first?.file.path == original)
        #expect(group.photos.first?.dimensionsText == "1600 × 1200")
        #expect(group.highestResolutionID == original)
        let small = try #require(group.photos.first { $0.file.path == resized })
        #expect(small.pixelWidth == 800)
        #expect(small.captureDate == Date(timeIntervalSince1970: 1_625_409_000))
        #expect(group.photos.allSatisfy { !$0.file.isProtected })
        // Similar photos are never pre-selected.
        let marks = DuplicateMarkSet()
        #expect(marks.markedCount(in: group.photos) == 0)
    }
}

/// Deterministic numbers in 0..<1.
struct SimilarTestGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// Synthetic test images with clearly different structure.
enum SimilarTestImages {
    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// A gradient "sky" with random shapes.
    static func scene(seed: UInt64, width: Int, height: Int) -> CGImage {
        guard let context = context(width: width, height: height) else { fatalError("No context") }
        var generator = SimilarTestGenerator(seed: seed)
        let colors = [
            CGColor(red: generator.next(), green: generator.next(), blue: generator.next(), alpha: 1),
            CGColor(red: generator.next(), green: generator.next(), blue: generator.next(), alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }
        for _ in 0..<14 {
            context.setFillColor(CGColor(red: generator.next(), green: generator.next(), blue: generator.next(), alpha: 1))
            let rect = CGRect(
                x: generator.next() * Double(width), y: generator.next() * Double(height),
                width: (0.05 + generator.next() * 0.3) * Double(width), height: (0.05 + generator.next() * 0.3) * Double(height)
            )
            if generator.next() > 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        guard let image = context.makeImage() else { fatalError("No image") }
        return image
    }

    static func stripes(width: Int, height: Int) -> CGImage {
        guard let context = context(width: width, height: height) else { fatalError("No context") }
        for index in 0..<24 {
            context.setFillColor(index.isMultiple(of: 2) ? CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: index * height / 24, width: width, height: height / 24 + 1))
        }
        guard let image = context.makeImage() else { fatalError("No image") }
        return image
    }

    static func checkerboard(width: Int, height: Int) -> CGImage {
        guard let context = context(width: width, height: height) else { fatalError("No context") }
        let cell = 75
        for row in 0..<(height / cell + 1) {
            for column in 0..<(width / cell + 1) {
                let light = (row + column).isMultiple(of: 2)
                context.setFillColor(light ? CGColor(red: 0.95, green: 0.95, blue: 0.85, alpha: 1) : CGColor(red: 0.05, green: 0.4, blue: 0.2, alpha: 1))
                context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
            }
        }
        guard let image = context.makeImage() else { fatalError("No image") }
        return image
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard let context = context(width: width, height: height) else { fatalError("No context") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { fatalError("No image") }
        return resized
    }

    static func save(_ image: CGImage, to path: String, type: UTType, quality: Double = 0.9, exif: [CFString: Any]? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
