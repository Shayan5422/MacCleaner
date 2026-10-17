// Renders the iOS app icon: the Mac app's artwork, full-bleed and opaque (iOS applies its own mask).
// Usage: swift iOS/scripts/generate-ios-icon.swift iOS/MacCleanerMobile/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(size: Int) -> Data {
    let canvas = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let body = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    let colors = [
        NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.55, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.10, green: 0.78, blue: 0.82, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Soft glow in the upper left.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    let glowCenter = CGPoint(x: body.minX + body.width * 0.28, y: body.maxY - body.height * 0.22)
    cg.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: body.width * 0.75, options: [])

    // A faint ring, hinting at storage.
    let ringRect = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.2)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(body.width * 0.04)
    cg.strokeEllipse(in: ringRect)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    cg.setLineCap(.round)
    cg.addArc(center: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2,
              startAngle: .pi * 0.5, endAngle: .pi * 0.5 - .pi * 1.35, clockwise: true)
    cg.strokePath()

    // Sparkles in the middle.
    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.34, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let rect = CGRect(x: body.midX - symbolSize.width / 2, y: body.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -canvas * 0.006), blur: canvas * 0.02, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        symbol.draw(in: rect)
        cg.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return opaquePNG(rep.cgImage!)
}

/// The image without an alpha channel: the App Store refuses icons that have one.
func opaquePNG(_ image: CGImage) -> Data {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

let name = "AppIcon-1024.png"
try renderIcon(size: 1024).write(to: outputDirectory.appendingPathComponent(name))
let contents: [String: Any] = [
    "images": [["filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(name) to \(outputDirectory.path)")
