// Renders the app icon (all macOS sizes) into the asset catalog.
// Usage: swift scripts/generate-icon.swift MacCleaner/Resources/Assets.xcassets/AppIcon.appiconset
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
    cg.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // macOS icon grid: the shape occupies ~80% of the canvas with a soft shadow.
    let inset = canvas * 0.098
    let body = CGRect(x: inset, y: inset * 1.15, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = body.width * 0.225
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.03, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
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
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: body.minX + body.width * 0.28, y: body.maxY - body.height * 0.22), startRadius: 0,
                          endCenter: CGPoint(x: body.minX + body.width * 0.28, y: body.maxY - body.height * 0.22), endRadius: body.width * 0.75, options: [])

    // A faint disk ring, hinting at storage.
    let ringRect = body.insetBy(dx: body.width * 0.16, dy: body.height * 0.16)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(body.width * 0.035)
    cg.strokeEllipse(in: ringRect)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    cg.setLineCap(.round)
    cg.addArc(center: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2, startAngle: .pi * 0.5, endAngle: .pi * 0.5 - .pi * 1.35, clockwise: true)
    cg.strokePath()
    cg.restoreGState()

    // Sparkles symbol in the middle.
    let pointSize = body.width * 0.36
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let rect = CGRect(x: body.midX - symbolSize.width / 2, y: body.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -canvas * 0.006), blur: canvas * 0.02, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        symbol.draw(in: rect)
        cg.restoreGState()
    }

    // Hairline highlight on the edge.
    cg.addPath(shape)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(max(1, canvas * 0.004))
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.points * entry.scale
    let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
    try renderIcon(size: pixels).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(entry.points)x\(entry.points)", "scale": "\(entry.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outputDirectory.path)")
