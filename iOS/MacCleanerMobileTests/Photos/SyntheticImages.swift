import CoreGraphics
import Foundation

/// Deterministic test pictures: a "scene" of soft shapes on a gradient, the broad structure a photo
/// has at 9 × 8, and the ways a copy or a second shot of it differs.
enum SyntheticImages {
    enum Variation: Sendable {
        case none
        /// Every channel multiplied by the factor (1.1 = 10% brighter), clipped at white.
        case brightness(Double)
        /// This fraction cut from every edge, then scaled back to the full size.
        case crop(Double)
        /// The camera moved: everything shifted right by this fraction of the width.
        case shift(Double)
        /// Random noise of up to ± the amplitude on every channel.
        case noise(Int)
        /// One shape moved by this fraction of the width: the subject moved between two shots.
        case moveSubject(Double)
    }

    static func scene(seed: UInt64, width: Int = 640, height: Int = 480, variation: Variation = .none) -> CGImage {
        var random = Random(seed: seed)
        let background = (random.unit(), random.unit())
        let angle = random.unit() * 2 * .pi
        let shapes = (0..<6).map { _ in
            Shape(x: random.unit(), y: random.unit(), radius: 0.12 + random.unit() * 0.25,
                  red: random.unit(), green: random.unit(), blue: random.unit())
        }

        let context = makeContext(width: width, height: height)
        let size = CGSize(width: width, height: height)
        context.saveGState()
        switch variation {
        case .crop(let fraction):
            let scale = 1 / (1 - 2 * fraction)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2)
        case .shift(let fraction):
            context.translateBy(x: size.width * fraction, y: 0)
        default:
            break
        }

        let colors = [CGColor(gray: background.0, alpha: 1), CGColor(gray: background.1, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let reach = max(size.width, size.height) / 2
            let offset = CGPoint(x: cos(angle) * reach, y: sin(angle) * reach)
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x - offset.x, y: center.y - offset.y),
                                       end: CGPoint(x: center.x + offset.x, y: center.y + offset.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for (index, shape) in shapes.enumerated() {
            var x = shape.x
            if case .moveSubject(let fraction) = variation, index == 0 { x += fraction }
            let radius = shape.radius * Double(min(width, height))
            context.setFillColor(CGColor(red: shape.red, green: shape.green, blue: shape.blue, alpha: 1))
            context.fillEllipse(in: CGRect(x: x * Double(width) - radius, y: shape.y * Double(height) - radius,
                                           width: radius * 2, height: radius * 1.6))
        }
        context.restoreGState()

        switch variation {
        case .brightness(let factor):
            adjustPixels(of: context) { value, _ in Int((Double(value) * factor).rounded()) }
        case .noise(let amplitude):
            var noise = Random(seed: seed &+ 0x9E37_79B9)
            adjustPixels(of: context) { value, _ in value + Int(noise.next() % UInt64(2 * amplitude + 1)) - amplitude }
        default:
            break
        }
        return context.makeImage()!
    }

    /// Gravel, grass, a crowd: a strong gradient (all a 9 × 8 hash sees) under patches of random
    /// brightness that differ from seed to seed.
    static func texture(seed: UInt64, width: Int = 320, height: Int = 240, variation: Variation = .none) -> CGImage {
        var random = Random(seed: seed)
        let context = makeContext(width: width, height: height)
        let columns = 24, rows = 18
        let tileWidth = Double(width) / Double(columns), tileHeight = Double(height) / Double(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let gradient = 0.15 + 0.7 * Double(column) / Double(columns - 1)
                let gray = min(1, max(0, gradient + (random.unit() - 0.5) * 0.3))
                context.setFillColor(CGColor(gray: gray, alpha: 1))
                context.fill(CGRect(x: Double(column) * tileWidth, y: Double(row) * tileHeight, width: tileWidth + 1, height: tileHeight + 1))
            }
        }
        if case .noise(let amplitude) = variation {
            var noise = Random(seed: seed &+ 0x9E37_79B9)
            adjustPixels(of: context) { value, _ in value + Int(noise.next() % UInt64(2 * amplitude + 1)) - amplitude }
        }
        return context.makeImage()!
    }

    /// A picture with no detail at all, like a photo taken in a pocket.
    static func flat(gray: Double, width: Int = 320, height: Int = 240) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private struct Shape {
        var x: Double
        var y: Double
        var radius: Double
        var red: Double
        var green: Double
        var blue: Double
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Applies `change` to the red, green and blue values of every pixel (alpha stays opaque).
    private static func adjustPixels(of context: CGContext, _ change: (Int, Int) -> Int) {
        guard let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        for row in 0..<context.height {
            for column in 0..<context.width {
                let base = row * context.bytesPerRow + column * 4
                for channel in 0..<3 {
                    pixels[base + channel] = UInt8(clamping: change(Int(pixels[base + channel]), channel))
                }
            }
        }
    }

    /// SplitMix64: a small seeded generator, so the pictures are the same on every run.
    struct Random: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        /// A value in 0..<1.
        mutating func unit() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }
}
