import Accelerate
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Models

/// A photo that looks like at least one other photo.
struct SimilarPhoto: Identifiable, Sendable, Hashable, DuplicateSelectable {
    var file: DuplicateFile
    /// Pixel dimensions as displayed (EXIF orientation applied); 0 when unknown.
    var pixelWidth: Int
    var pixelHeight: Int
    /// When the photo was taken, from EXIF metadata.
    var captureDate: Date?

    var id: String { file.id }
    var protectionReason: String? { file.protectionReason }
    var pixelCount: Int { pixelWidth * pixelHeight }

    var dimensionsText: String {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : "Unknown dimensions"
    }
}

/// Photos that look alike. Nothing in a group is ever selected automatically.
struct SimilarPhotoGroup: Identifiable, Sendable, Hashable {
    /// Path of the group's reference photo.
    var id: String
    /// Highest resolution first, then largest file.
    var photos: [SimilarPhoto]
    /// Largest feature-print distance between the reference photo and another member.
    var maximumDistance: Float

    var totalBytes: Int64 { photos.reduce(0) { $0 + $1.file.allocatedSize } }
    var displayName: String { photos.first?.file.name ?? "Similar photos" }

    /// The photo with the most pixels (ties: the larger file). Informational only.
    var highestResolutionID: String? {
        guard photos.count > 1, let first = photos.first, first.pixelCount > 0 else { return nil }
        return photos.dropFirst().allSatisfy({ $0.pixelCount == first.pixelCount }) ? nil : first.id
    }

    var looksIdentical: Bool { maximumDistance < 0.02 }
}

/// A pair of photos and the distance between their feature prints (0 = identical).
struct SimilarPhotoEdge: Sendable, Hashable {
    var first: Int32
    var second: Int32
    var distance: Float
}

/// Outcome of a similar-photo scan. Keeps the pairwise distances so the similarity
/// threshold can be changed without analyzing the photos again.
struct SimilarPhotoScanResult: Sendable {
    /// Photos that have at least one similar photo at the loosest threshold.
    var photos: [SimilarPhoto] = []
    var edges: [SimilarPhotoEdge] = []
    /// Loosest threshold `edges` covers.
    var maximumDistance: Float = SimilarPhotoThreshold.loosest
    var roots: [String] = []
    var unavailableRoots: [DuplicateUnavailableRoot] = []
    var imagesFound = 0
    var imagesAnalyzed = 0
    var cloudOnlySkipped = 0
    var unreadableImages = 0
    var changedFiles = 0
    var unreadableFolders = 0
    var startedAt = Date()
    var duration: TimeInterval = 0

    /// Groups of similar photos at `threshold`, largest groups (by bytes) first.
    func groups(threshold: Float) -> [SimilarPhotoGroup] {
        let clusters = SimilarPhotoClustering.cluster(count: photos.count, edges: edges, threshold: min(threshold, maximumDistance))
        return clusters.map { cluster in
            let members = cluster.members.map { photos[$0] }.sorted { lhs, rhs in
                if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
                if lhs.file.logicalSize != rhs.file.logicalSize { return lhs.file.logicalSize > rhs.file.logicalSize }
                return lhs.file.path < rhs.file.path
            }
            return SimilarPhotoGroup(id: photos[cluster.leader].id, photos: members, maximumDistance: cluster.maximumDistance)
        }
        .sorted { lhs, rhs in
            lhs.totalBytes != rhs.totalBytes ? lhs.totalBytes > rhs.totalBytes : lhs.id < rhs.id
        }
    }
}

/// Maps the similarity setting to Vision feature-print distances.
///
/// Calibrated on revision 2 feature prints (unit-length vectors): resized copies
/// measure below 0.1; recompressed, slightly cropped or brightened copies 0.05–0.45;
/// unrelated photos mostly above 0.6.
enum SimilarPhotoThreshold {
    static let strictest: Float = 0.1
    static let loosest: Float = 0.6
    static let defaultSimilarity = 0.5

    /// `similarity` runs from 0 (loosest) to 1 (strictest).
    static func distance(forSimilarity similarity: Double) -> Float {
        let clamped = Float(max(0, min(1, similarity)))
        return loosest - (loosest - strictest) * clamped
    }

    static func label(forSimilarity similarity: Double) -> String {
        label(forDistance: distance(forSimilarity: similarity))
    }

    static func label(forDistance distance: Float) -> String {
        if distance <= 0.15 { return "Nearly identical" }
        if distance <= 0.28 { return "Very similar" }
        if distance <= 0.42 { return "Similar" }
        return "Loosely similar"
    }
}

enum SimilarScanStage: Int, CaseIterable, Sendable, Comparable, Identifiable {
    case scanning, analyzing, comparing, results

    static func < (lhs: SimilarScanStage, rhs: SimilarScanStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .scanning: return "Scanning"
        case .analyzing: return "Analyzing photos"
        case .comparing: return "Comparing"
        case .results: return "Results"
        }
    }

    var activeTitle: String {
        switch self {
        case .scanning: return "Scanning folders…"
        case .analyzing: return "Analyzing photos…"
        case .comparing: return "Comparing photos…"
        case .results: return "Preparing results…"
        }
    }
}

struct SimilarScanProgress: Sendable, Equatable {
    var stage: SimilarScanStage
    var fraction: Double?
    var message: String
}

// MARK: - Finder

/// Finds visually similar photos with Apple's Vision framework.
///
/// Each image is decoded at reduced size with ImageIO and described by a Vision
/// feature print; photos whose feature prints are close are grouped. Similarity
/// is a judgment call, so results are only suggestions: nothing is ever selected
/// automatically.
struct SimilarPhotoFinder: Sendable {
    var policy: SafetyPolicy

    init(policy: SafetyPolicy = .current) {
        self.policy = policy
    }

    func findSimilarPhotos(
        options: DuplicateScanOptions,
        progress: @escaping @Sendable (SimilarScanProgress) -> Void = { _ in }
    ) async throws -> SimilarPhotoScanResult {
        let cancellation = DuplicateCancellation()
        return try await withTaskCancellationHandler {
            try await scan(options: options, cancellation: cancellation, progress: progress)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func scan(
        options: DuplicateScanOptions,
        cancellation: DuplicateCancellation,
        progress: @escaping @Sendable (SimilarScanProgress) -> Void
    ) async throws -> SimilarPhotoScanResult {
        let started = Date()
        var result = SimilarPhotoScanResult(startedAt: started)

        // 1. Scanning: images ImageIO can decode.
        progress(SimilarScanProgress(stage: .scanning, fraction: nil, message: "Looking for photos…"))
        let walkProgress = WalkProgress()
        let poller = DuplicateWalkPoller.start(walkProgress) { snapshot in
            progress(SimilarScanProgress(stage: .scanning, fraction: nil, message: DuplicateFinder.scanningMessage(snapshot)))
        }
        var imageOptions = options
        imageOptions.kinds = .images
        let supported = SimilarPhotoAnalyzer.supportedExtensions
        let collection: DuplicateCollection
        do {
            collection = try await DuplicateFileCollector.collect(options: imageOptions, progress: walkProgress) { _, entry in
                supported.contains((entry.name as NSString).pathExtension.lowercased())
            }
            poller.cancel()
        } catch {
            poller.cancel()
            throw error
        }
        result.roots = collection.roots
        result.unavailableRoots = collection.unavailableRoots
        result.cloudOnlySkipped = collection.cloudOnlySkipped
        result.unreadableFolders = collection.unreadableFolders

        // Hard links are one photo; sort for deterministic grouping.
        let inodes = DuplicateInode.collapse(collection.files).sorted { $0.primary.path < $1.primary.path }
        result.imagesFound = inodes.count
        guard inodes.count >= 2 else {
            result.duration = Date().timeIntervalSince(started)
            return result
        }

        // 2. Analyzing: one feature print per photo, a few at a time.
        try Task.checkCancellation()
        let total = inodes.count
        let done = DuplicateLockedBox(0)
        let throttle = DuplicateProgressThrottle()
        progress(SimilarScanProgress(stage: .analyzing, fraction: 0, message: "Analyzing \(NumberFormatting.count(total)) photos…"))
        let concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let analyses = try await DuplicateWorkQueue.run(
            inodes.map(\.hashTarget), limits: DuplicateIOLimits(uniformLimit: concurrency), device: { $0.identity.device }
        ) { target in
            defer {
                let count = done.withLock { value -> Int in
                    value += 1
                    return value
                }
                if throttle.shouldReport(force: count == total) {
                    progress(SimilarScanProgress(
                        stage: .analyzing, fraction: Double(count) / Double(total),
                        message: "Analyzed \(NumberFormatting.count(count)) of \(NumberFormatting.count(total)) photos"
                    ))
                }
            }
            try cancellation.check()
            return try SimilarPhotoAnalyzer.analyze(target)
        }

        var analyzed: [(inode: DuplicateInode, analysis: SimilarPhotoAnalyzer.Analysis)] = []
        var dimension = 0
        for (index, outcome) in analyses.enumerated() {
            switch outcome {
            case .success(let analysis):
                if dimension == 0 { dimension = analysis.vector.count }
                guard analysis.vector.count == dimension else { result.unreadableImages += 1; continue }
                analyzed.append((inodes[index], analysis))
            case .failure(let error):
                switch error as? DuplicateHashFailure {
                case .changed?: result.changedFiles += 1
                case .cloudOnly?: result.cloudOnlySkipped += 1
                default: result.unreadableImages += 1
                }
            }
        }
        result.imagesAnalyzed = analyzed.count
        guard analyzed.count >= 2, dimension > 0 else {
            result.duration = Date().timeIntervalSince(started)
            return result
        }

        // 3. Comparing every pair of feature prints.
        try Task.checkCancellation()
        progress(SimilarScanProgress(stage: .comparing, fraction: 0, message: "Comparing \(NumberFormatting.count(analyzed.count)) photos…"))
        var vectors: [Float] = []
        vectors.reserveCapacity(analyzed.count * dimension)
        for item in analyzed { vectors.append(contentsOf: item.analysis.vector) }
        let count = analyzed.count
        let featureDimension = dimension
        let packedVectors = vectors
        let comparison = try await BackgroundWork.run {
            try SimilarPhotoComparer.edges(
                vectors: packedVectors, count: count, dimension: featureDimension,
                maximumDistance: SimilarPhotoThreshold.loosest, cancellation: cancellation
            ) { fraction in
                if throttle.shouldReport() {
                    progress(SimilarScanProgress(stage: .comparing, fraction: fraction, message: "Comparing photos…"))
                }
            }
        }

        // 4. Results: describe only photos that have a similar photo.
        try Task.checkCancellation()
        progress(SimilarScanProgress(stage: .results, fraction: nil, message: "Preparing results…"))
        var referenced = Set<Int32>()
        for edge in comparison.edges {
            referenced.insert(edge.first)
            referenced.insert(edge.second)
        }
        let kept = referenced.sorted()
        var remap: [Int32: Int32] = [:]
        for (newIndex, oldIndex) in kept.enumerated() { remap[oldIndex] = Int32(newIndex) }
        let selected = kept.map { analyzed[Int($0)] }
        let policy = self.policy
        let photos: [SimilarPhoto] = await BackgroundWork.run {
            selected.map { item in
                let path = item.inode.primary.path
                let file = DuplicateFile(
                    path: path,
                    entry: item.inode.primary.entry,
                    creationDate: DuplicateFileDates.creationDate(path: path),
                    hardLinkPaths: item.inode.aliases,
                    protectionReason: policy.evaluate(path: path, purpose: .userFile).reason,
                    managedLibraryName: DuplicateManagedLibrary.name(for: path, home: policy.home)
                )
                return SimilarPhoto(
                    file: file, pixelWidth: item.analysis.pixelWidth, pixelHeight: item.analysis.pixelHeight,
                    captureDate: item.analysis.captureDate
                )
            }
        }
        result.photos = photos
        result.edges = comparison.edges.compactMap { edge in
            guard let first = remap[edge.first], let second = remap[edge.second] else { return nil }
            return SimilarPhotoEdge(first: first, second: second, distance: edge.distance)
        }
        result.maximumDistance = comparison.maximumDistance
        result.duration = Date().timeIntervalSince(started)
        return result
    }
}

// MARK: - Analysis

/// Describes one image with a Vision feature print.
enum SimilarPhotoAnalyzer {
    /// Longest side of the image handed to Vision. Feature prints are computed at a
    /// small internal resolution, so decoding the full image would only cost time.
    static let analysisPixelSize = 512

    struct Analysis: Sendable {
        /// Unit-length feature print.
        var vector: [Float]
        var pixelWidth: Int
        var pixelHeight: Int
        var captureDate: Date?
    }

    /// Lowercased extensions of image formats ImageIO can decode on this Mac
    /// (JPEG, PNG, HEIC/HEIF, TIFF, GIF, WebP, camera RAW formats, …).
    static let supportedExtensions: Set<String> = {
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        let candidates = [
            "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "hif", "tif", "tiff", "gif", "webp", "bmp", "avif",
            "jxl", "jp2", "psd", "tga", "exr", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf",
            "rw2", "raf", "srw", "pef", "3fr", "erf", "kdc", "mos", "mrw", "x3f", "iiq", "rwl",
        ]
        return Set(candidates.filter { ext in
            guard let type = UTType(filenameExtension: ext) else { return false }
            return readable.contains(type.identifier)
        })
    }()

    static func analyze(_ target: DuplicateHashTarget) throws -> Analysis {
        try DuplicateReadPolicy.perform {
            var info = stat()
            guard lstat(target.path, &info) == 0 else { throw DuplicateHashFailure.changed }
            guard FileObjectType(mode: info.st_mode) == .regular,
                  info.st_dev == target.identity.device,
                  UInt64(info.st_ino) == target.identity.inode else {
                throw DuplicateHashFailure.changed
            }
            if info.st_flags & FileFlags.dataless != 0 { throw DuplicateHashFailure.cloudOnly }

            let url = URL(fileURLWithPath: target.path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else {
                throw DuplicateHashFailure.unreadable(EINVAL)
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if (5...8).contains(orientation) { swap(&width, &height) }

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: analysisPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw DuplicateHashFailure.unreadable(EINVAL)
            }

            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw DuplicateHashFailure.unreadable(EIO)
            }
            guard let observation = request.results?.first else { throw DuplicateHashFailure.unreadable(EIO) }
            let vector = normalized(floats(of: observation))
            guard !vector.isEmpty else { throw DuplicateHashFailure.unreadable(EIO) }
            return Analysis(vector: vector, pixelWidth: width, pixelHeight: height, captureDate: captureDate(properties))
        }
    }

    private static func floats(of observation: VNFeaturePrintObservation) -> [Float] {
        let data = observation.data
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return [] }
            var values = [Float](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return values
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return [] }
            var values = [Double](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return values.map { Float($0) }
        default:
            return []
        }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        let norm = vDSP.sumOfSquares(vector).squareRoot()
        guard norm.isFinite, norm > 0 else { return [] }
        return vDSP.divide(vector, norm)
    }

    /// Capture date from EXIF (or TIFF) metadata, honoring the recorded time zone offset.
    static func captureDate(_ properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        return parseExifDate(text, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    /// Parses "yyyy:MM:dd HH:mm:ss" with an optional "+hh:mm" offset.
    static func parseExifDate(_ text: String, offset: String?) -> Date? {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 6, numbers[0] > 1900, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
        var components = DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4], second: numbers[5]
        )
        components.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let seconds = (parts[0] * 3600 + parts[1] * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}

// MARK: - Comparison

/// Finds pairs of similar feature prints.
enum SimilarPhotoComparer {
    /// Computes distances between all pairs with blocked matrix products (vDSP),
    /// keeping pairs within `maximumDistance`. If an unusually large number of pairs
    /// match (for example thousands of nearly blank screenshots), only the closest
    /// `maximumEdges` are kept and the returned maximum distance shrinks accordingly.
    ///
    /// - Parameter vectors: `count` unit-length vectors of `dimension` floats, packed row by row.
    static func edges(
        vectors: [Float],
        count: Int,
        dimension: Int,
        maximumDistance: Float,
        maximumEdges: Int = 1_000_000,
        cancellation: DuplicateCancellation,
        progress: (Double) -> Void = { _ in }
    ) throws -> (edges: [SimilarPhotoEdge], maximumDistance: Float) {
        guard count >= 2, dimension > 0, vectors.count == count * dimension else { return ([], maximumDistance) }
        let block = 256
        var limit = maximumDistance
        var edges: [SimilarPhotoEdge] = []
        var transposed = [Float](repeating: 0, count: dimension * block)
        var products = [Float](repeating: 0, count: block * block)
        let blockCount = (count + block - 1) / block
        let totalBlocks = Double(blockCount * (blockCount + 1) / 2)
        var finishedBlocks = 0.0

        func keepClosest() {
            edges.sort { $0.distance < $1.distance }
            if edges.count > maximumEdges { edges.removeLast(edges.count - maximumEdges) }
            limit = edges.last?.distance ?? limit
        }

        try vectors.withUnsafeBufferPointer { all in
            guard let base = all.baseAddress else { return }
            for columnStart in stride(from: 0, to: count, by: block) {
                let columns = min(block, count - columnStart)
                // transposed = (rows columnStart..<columnStart+columns)ᵀ: dimension × columns.
                transposed.withUnsafeMutableBufferPointer { target in
                    guard let targetBase = target.baseAddress else { return }
                    vDSP_mtrans(base + columnStart * dimension, 1, targetBase, 1, vDSP_Length(dimension), vDSP_Length(columns))
                }
                for rowStart in stride(from: 0, through: columnStart, by: block) {
                    try cancellation.check()
                    let rows = min(block, count - rowStart)
                    products.withUnsafeMutableBufferPointer { output in
                        transposed.withUnsafeBufferPointer { matrix in
                            guard let outputBase = output.baseAddress, let matrixBase = matrix.baseAddress else { return }
                            vDSP_mmul(
                                base + rowStart * dimension, 1, matrixBase, 1, outputBase, 1,
                                vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(dimension)
                            )
                        }
                    }
                    // Unit vectors: distance² = 2 − 2·(dot product).
                    let minimumDot = 1 - (limit * limit) / 2
                    for row in 0..<rows {
                        let globalRow = rowStart + row
                        let rowOffset = row * columns
                        for column in 0..<columns {
                            let globalColumn = columnStart + column
                            guard globalColumn > globalRow else { continue }
                            let dot = products[rowOffset + column]
                            guard dot >= minimumDot else { continue }
                            let distance = max(0, 2 - 2 * dot).squareRoot()
                            guard distance <= limit else { continue }
                            edges.append(SimilarPhotoEdge(first: Int32(globalRow), second: Int32(globalColumn), distance: distance))
                        }
                    }
                    if edges.count > maximumEdges * 2 { keepClosest() }
                    finishedBlocks += 1
                    progress(finishedBlocks / totalBlocks)
                }
            }
        }
        if edges.count > maximumEdges { keepClosest() }
        return (edges, limit)
    }
}

/// Groups photos from their similar pairs.
enum SimilarPhotoClustering {
    struct Cluster: Sendable, Hashable {
        var leader: Int
        var members: [Int]
        var maximumDistance: Float
    }

    /// Leader clustering: the photo with the most similar neighbors starts a group with
    /// all of its ungrouped neighbors, then the next one, and so on. Every photo in a
    /// group is within `threshold` of the group's reference photo, so groups never
    /// grow into long chains of loosely related photos.
    static func cluster(count: Int, edges: [SimilarPhotoEdge], threshold: Float) -> [Cluster] {
        guard count >= 2 else { return [] }
        var neighbors = [[(index: Int, distance: Float)]](repeating: [], count: count)
        for edge in edges where edge.distance <= threshold {
            let first = Int(edge.first)
            let second = Int(edge.second)
            guard first != second, first < count, second < count else { continue }
            neighbors[first].append((second, edge.distance))
            neighbors[second].append((first, edge.distance))
        }
        let order = (0..<count).filter { !neighbors[$0].isEmpty }.sorted { lhs, rhs in
            neighbors[lhs].count != neighbors[rhs].count ? neighbors[lhs].count > neighbors[rhs].count : lhs < rhs
        }
        var assigned = [Bool](repeating: false, count: count)
        var clusters: [Cluster] = []
        for leader in order where !assigned[leader] {
            let free = neighbors[leader].filter { !assigned[$0.index] }.sorted { $0.index < $1.index }
            guard !free.isEmpty else { continue }
            assigned[leader] = true
            for neighbor in free { assigned[neighbor.index] = true }
            clusters.append(Cluster(
                leader: leader,
                members: [leader] + free.map(\.index),
                maximumDistance: free.map(\.distance).max() ?? 0
            ))
        }
        return clusters
    }
}
