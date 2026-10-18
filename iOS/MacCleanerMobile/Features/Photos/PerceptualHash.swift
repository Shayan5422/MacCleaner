import CoreGraphics
import Foundation

/// A 64-bit difference hash (dHash) of an image, its average brightness, and a finer hash that copies
/// must also agree on.
///
/// The image is shrunk to 9 × 8 gray cells, and each bit says whether a cell is brighter than the
/// one to its right. Copies of a photo (recompressed, resized, slightly brighter) get the same or
/// nearly the same bits; unrelated photos differ in about half of them.
struct ImageFingerprint: Sendable, Hashable, Codable {
    var hash: UInt64
    /// Average brightness from 0 (black) to 255 (white). The hash ignores brightness, so this is
    /// what tells a dark frame from a bright one when neither has any detail.
    var luma: UInt8
    var detail: DetailHash?

    /// Number of differing bits of the 64-bit hash, 0…64.
    func distance(to other: ImageFingerprint) -> Int {
        PerceptualHash.hammingDistance(hash, other.hash)
    }
}

/// The same idea on a 17 × 16 grid: 256 bits, plus which of them are clear-cut.
///
/// At 9 × 8, two different photos of a texture (grass, gravel, a crowd) can look alike because only
/// their overall light falls into the cells. At 17 × 16 their detail shows, but so do near-ties,
/// where two cells are almost equally bright and a recompressed copy can flip the bit. So bits are
/// only compared where at least one of the two images has a clear difference between the cells.
struct DetailHash: Sendable, Hashable, Codable {
    /// Four words, row by row.
    var bits: [UInt64]
    /// Set where the two cells differ by at least `PerceptualHash.detailMargin` levels.
    var strong: [UInt64]

    func distance(to other: DetailHash) -> Int {
        guard bits.count == other.bits.count, strong.count == bits.count, other.strong.count == bits.count else { return .max }
        var count = 0
        for word in bits.indices {
            count += ((bits[word] ^ other.bits[word]) & (strong[word] | other.strong[word])).nonzeroBitCount
        }
        return count
    }
}

enum PerceptualHash {
    static let columns = 9
    static let rows = 8
    /// Each cell is drawn at this many pixels square and averaged, which is steadier than letting
    /// Core Graphics shrink the image to 9 × 8 in one step.
    static let cellSize = 8

    static let detailColumns = 17
    static let detailRows = 16
    static let detailCellSize = 4
    /// Brightness levels (of 255) two neighboring cells must differ by for their bit to count.
    static let detailMargin = 2

    static func hammingDistance(_ first: UInt64, _ second: UInt64) -> Int {
        (first ^ second).nonzeroBitCount
    }

    /// The fingerprint of an image of any size (Photos hands over thumbnails of about 64 × 64).
    static func fingerprint(of image: CGImage) -> ImageFingerprint? {
        guard let cells = cellSums(of: image, columns: columns, rows: rows, cellSize: cellSize),
              let detailCells = cellSums(of: image, columns: detailColumns, rows: detailRows, cellSize: detailCellSize) else { return nil }
        var fingerprint = fingerprint(cellSums: cells, pixelsPerCell: cellSize * cellSize)
        fingerprint.detail = detailHash(cellSums: detailCells, pixelsPerCell: detailCellSize * detailCellSize)
        return fingerprint
    }

    /// Bits from a 9 × 8 grid of brightness sums, row by row, most significant bit first.
    static func fingerprint(cellSums cells: [Int], pixelsPerCell: Int) -> ImageFingerprint {
        precondition(cells.count == columns * rows)
        var hash: UInt64 = 0
        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                hash <<= 1
                if cells[row * columns + column] > cells[row * columns + column + 1] { hash |= 1 }
            }
        }
        let average = cells.reduce(0, +) / max(1, cells.count * pixelsPerCell)
        return ImageFingerprint(hash: hash, luma: UInt8(clamping: average), detail: nil)
    }

    /// Bits and clear-cut bits from a 17 × 16 grid of brightness sums, row by row.
    static func detailHash(cellSums cells: [Int], pixelsPerCell: Int) -> DetailHash {
        precondition(cells.count == detailColumns * detailRows)
        var bits = [UInt64](repeating: 0, count: 4)
        var strong = [UInt64](repeating: 0, count: 4)
        var index = 0
        for row in 0..<detailRows {
            for column in 0..<(detailColumns - 1) {
                let difference = cells[row * detailColumns + column] - cells[row * detailColumns + column + 1]
                let word = index / 64, bit = UInt64(63 - index % 64)
                if difference > 0 { bits[word] |= 1 << bit }
                if abs(difference) >= detailMargin * pixelsPerCell { strong[word] |= 1 << bit }
                index += 1
            }
        }
        return DetailHash(bits: bits, strong: strong)
    }

    /// The image drawn in gray at `columns × cellSize` by `rows × cellSize` pixels, summed per cell.
    private static func cellSums(of image: CGImage, columns: Int, rows: Int, cellSize: Int) -> [Int]? {
        let width = columns * cellSize
        let height = rows * cellSize
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var cells = [Int](repeating: 0, count: columns * rows)
        for y in 0..<height {
            let cellRow = (y / cellSize) * columns
            for x in 0..<width {
                cells[cellRow + x / cellSize] += Int(pixels[y * width + x])
            }
        }
        return cells
    }
}
