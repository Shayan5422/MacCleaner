import AppKit
import SwiftUI

enum StorageChartStyle: String, CaseIterable, Identifiable, Sendable {
    case treemap, sunburst

    var id: String { rawValue }
    var title: String { self == .treemap ? "Treemap" : "Sunburst" }
    var symbolName: String { self == .treemap ? "square.grid.3x3.square" : "circle.circle" }
}

enum StorageColorMode: String, CaseIterable, Identifiable, Sendable {
    /// Color by kind of file (Videos, Documents…).
    case kind
    /// Color by the displayed folder's child that contains the item.
    case folder

    var id: String { rawValue }
    var title: String { self == .kind ? "Color by Kind" : "Color by Folder" }
}

/// What the charts do when people interact with them.
struct StorageChartActions {
    /// Zoom into a folder.
    var open: (StorageNode) -> Void
    /// Select a file or package.
    var select: (StorageNode) -> Void
    /// Go to the parent folder (sunburst center).
    var goUp: () -> Void
}

// MARK: - Palette

/// Fills precomputed once, so drawing thousands of tiles never converts colors.
@MainActor
enum StorageChartPalette {
    struct Shade {
        var top: Color
        var bottom: Color
        var label: Color
    }

    /// Frame of folders that show their children inside them (color by kind).
    static let containerFrame = Color(red: 0.23, green: 0.26, blue: 0.31)
    static let containerLabel = Color.white.opacity(0.92)

    /// `[category][variant]`: 0 files at the top level, 1–2 deeper levels, 3 combined small items.
    private static let categoryShades: [[Shade]] = StorageCategory.allCases.map { makeVariants($0.color) }
    /// `[palette index][variant]`.
    private static let folderShades: [[Shade]] = ChartPalette.colors.map { makeVariants($0) }
    private static let folderFrames: [Color] = ChartPalette.colors.map { $0.mix(with: .black, by: 0.42) }

    static func shade(for node: StorageNode, depth: Int, topLevelIndex: Int, mode: StorageColorMode) -> Shade {
        let variant = node.kind == .smallFiles ? 3 : min(2, depth)
        switch mode {
        case .kind:
            return categoryShades[Int(node.category.rawValue)][variant]
        case .folder:
            let shades = folderShades[((topLevelIndex % folderShades.count) + folderShades.count) % folderShades.count]
            return shades[node.kind == .smallFiles ? 3 : (depth + (node.kind == .directory ? 0 : 1)) % 3]
        }
    }

    static func frame(topLevelIndex: Int, mode: StorageColorMode) -> Color {
        switch mode {
        case .kind: return containerFrame
        case .folder: return folderFrames[((topLevelIndex % folderFrames.count) + folderFrames.count) % folderFrames.count]
        }
    }

    private static func makeVariants(_ base: Color) -> [Shade] {
        let variants: [Color] = [
            base,
            base.mix(with: .white, by: 0.12),
            base.mix(with: .white, by: 0.22),
            base.mix(with: Color(white: 0.55), by: 0.55),
        ]
        return variants.map { color in
            Shade(top: color.mix(with: .white, by: 0.14), bottom: color.mix(with: .black, by: 0.06), label: labelColor(on: color))
        }
    }

    private static func labelColor(on color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62 ? Color.black.opacity(0.78) : Color.white.opacity(0.95)
    }
}

// MARK: - Tooltip

struct StorageChartTooltip: View {
    var node: StorageNode
    var share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(node.category.color)
                Text(node.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 4) {
                Text(ByteFormatting.string(node.size)).monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(NumberFormatting.percent(share, digits: share < 0.1 ? 1 : 0)).monospacedDigit()
            }
            .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.subtleBorder))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .fixedSize()
    }

    private var symbol: String {
        switch node.kind {
        case .directory: return node.isUnreadable ? "lock.fill" : "folder.fill"
        case .package: return node.category.symbolName
        case .smallFiles: return "square.grid.2x2"
        case .file: return node.category.symbolName
        }
    }

    private var detail: String {
        switch node.kind {
        case .directory:
            if node.isUnreadable { return "Couldn't be read — contents not included" }
            if node.isCloudOnly { return "In the cloud, not downloaded" }
            return "\(NumberFormatting.count(node.itemCount)) files · click to open"
        case .smallFiles:
            return "Files under 1 MB each, combined"
        case .package, .file:
            var parts = [node.kindDescription]
            if let date = node.modificationDate { parts.append("modified \(DateFormatting.relative(date))") }
            if node.flags.contains(.sharedHardLink) { parts.append("hard link, counted once") }
            if node.flags.contains(.sharedClone) { parts.append("APFS clone, shared blocks counted once") }
            return parts.joined(separator: " · ")
        }
    }

    /// Places the tooltip next to the pointer, inside `bounds`.
    static func position(for point: CGPoint, in bounds: CGSize, estimatedSize: CGSize = CGSize(width: 250, height: 72)) -> CGPoint {
        var x = point.x + 16
        var y = point.y + 18
        if x + estimatedSize.width > bounds.width { x = point.x - estimatedSize.width - 12 }
        if y + estimatedSize.height > bounds.height { y = point.y - estimatedSize.height - 12 }
        return CGPoint(x: max(4, x) + estimatedSize.width / 2, y: max(4, y) + estimatedSize.height / 2)
    }
}

// MARK: - Treemap

/// Interactive squarified treemap of a folder, drawn with `Canvas`.
struct StorageTreemapView<Menu: View>: View {
    let node: StorageNode
    let version: Int
    let colorMode: StorageColorMode
    let selection: Set<ObjectIdentifier>
    let actions: StorageChartActions
    @ViewBuilder let menu: (StorageNode) -> Menu

    @State private var tiles: [StorageTreemapTile] = []
    @State private var generation = 0
    @State private var hoverPoint: CGPoint?
    @State private var hoveredTileID: Int?
    @Environment(\.colorScheme) private var colorScheme

    private struct LayoutKey: Equatable {
        var node: ObjectIdentifier
        var version: Int
        var width: CGFloat
        var height: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                StorageTreemapCanvas(tiles: tiles, generation: generation, colorMode: colorMode, colorScheme: colorScheme)
                    .equatable()
                StorageTreemapOverlay(tiles: tiles, hoveredTileID: hoveredTileID, selection: selection)
                    .allowsHitTesting(false)
                if let point = hoverPoint, let tile = hoveredTile {
                    StorageChartTooltip(node: tile.node, share: node.size > 0 ? Double(tile.node.size) / Double(node.size) : 0)
                        .position(StorageChartTooltip.position(for: point, in: size))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverPoint = location
                    let id = StorageTreemapLayout.hitTest(location, in: tiles)?.id
                    if id != hoveredTileID { hoveredTileID = id }
                case .ended:
                    hoverPoint = nil
                    hoveredTileID = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let tile = StorageTreemapLayout.hitTest(value.location, in: tiles) else { return }
                activate(tile.node)
            })
            .contextMenu {
                if let tile = hoveredTile { menu(tile.node) }
            }
            .onChange(of: LayoutKey(node: node.id, version: version, width: size.width, height: size.height), initial: true) {
                relayout(size: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap of \(node.displayName)")
        .accessibilityHint("Each rectangle's area shows how much space an item uses.")
        .accessibilityChildren {
            ForEach(tiles.filter { $0.depth == 0 }.prefix(40), id: \.id) { tile in
                Rectangle()
                    .accessibilityLabel(tile.node.displayName)
                    .accessibilityValue("\(ByteFormatting.string(tile.node.size)), \(tile.node.kindDescription)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { activate(tile.node) }
            }
        }
    }

    private var hoveredTile: StorageTreemapTile? {
        guard let hoveredTileID, hoveredTileID < tiles.count else { return nil }
        return tiles[hoveredTileID]
    }

    private func activate(_ target: StorageNode) {
        switch target.kind {
        case .directory:
            if !target.children.isEmpty { actions.open(target) } else { actions.select(target) }
        case .smallFiles:
            if let parent = target.parent, parent !== node { actions.open(parent) }
        case .file, .package:
            actions.select(target)
        }
    }

    private func relayout(size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        tiles = StorageTreemapLayout.tiles(for: node, in: rect)
        hoveredTileID = nil
        generation &+= 1
    }
}

/// The tiles themselves. Equatable on the layout generation so hover changes don't redraw them.
private struct StorageTreemapCanvas: View, Equatable {
    let tiles: [StorageTreemapTile]
    let generation: Int
    let colorMode: StorageColorMode
    /// Part of the equality so a light/dark switch redraws the tiles.
    let colorScheme: ColorScheme

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.colorMode == rhs.colorMode && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        Canvas { context, _ in
            var labelBudget = 260
            for tile in tiles {
                let rect = tile.rect.insetBy(dx: 0.5, dy: 0.5)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                let radius = min(3, min(rect.width, rect.height) / 4)
                let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

                if tile.isContainer {
                    let frame = StorageChartPalette.frame(topLevelIndex: tile.topLevelIndex, mode: colorMode)
                    context.fill(path, with: .color(frame))
                    if tile.headerHeight > 0, labelBudget > 0 {
                        labelBudget -= 1
                        drawLabel(tile.node.displayName, size: tile.node.size, in: CGRect(x: rect.minX + 6, y: rect.minY + 2, width: rect.width - 12, height: tile.headerHeight - 3),
                                  color: StorageChartPalette.containerLabel, bold: true, context: &context)
                    }
                    continue
                }

                let shade = StorageChartPalette.shade(for: tile.node, depth: tile.depth, topLevelIndex: tile.topLevelIndex, mode: colorMode)
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [shade.top, shade.bottom]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                ))
                if tile.node.kind == .directory {
                    context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.75)
                }
                if labelBudget > 0, rect.width >= 46, rect.height >= 17 {
                    labelBudget -= 1
                    drawLabel(tile.node.displayName, size: rect.height >= 32 ? tile.node.size : nil,
                              in: rect.insetBy(dx: 5, dy: 3), color: shade.label, bold: tile.depth == 0, context: &context)
                }
            }
        }
    }

    private func drawLabel(_ name: String, size: Int64?, in rect: CGRect, color: Color, bold: Bool, context: inout GraphicsContext) {
        guard rect.width > 18, rect.height > 10 else { return }
        let font = Font.system(size: 11, weight: bold ? .semibold : .medium)
        guard let title = StorageChartText.fitted(name, font: font, color: color, width: rect.width, in: context) else { return }
        // Draw into a clipped copy of the context so text can never spill into neighboring tiles.
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.draw(title, at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
        if let size, rect.height >= 26,
           let sizeText = StorageChartText.fitted(ByteFormatting.string(size), font: .system(size: 10).monospacedDigit(), color: color.opacity(0.85),
                                                  width: rect.width, in: context, truncates: false) {
            clipped.draw(sizeText, at: CGPoint(x: rect.minX, y: rect.minY + 14), anchor: .topLeading)
        }
    }
}

/// Text measured to fit a width, truncated with an ellipsis when needed.
enum StorageChartText {
    static func fitted(_ string: String, font: Font, color: Color, width: CGFloat, in context: GraphicsContext, truncates: Bool = true) -> GraphicsContext.ResolvedText? {
        guard width > 4 else { return nil }
        var candidate = string
        for _ in 0..<5 {
            let resolved = context.resolve(Text(candidate).font(font).foregroundColor(color))
            let measured = resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100)).width
            if measured <= width { return resolved }
            guard truncates, measured > 0 else { return nil }
            let visible = candidate.hasSuffix("…") ? candidate.count - 1 : candidate.count
            let keep = Int(Double(visible) * Double(width / measured)) - 1
            guard keep >= 2 else { return nil }
            candidate = String(string.prefix(keep)) + "…"
        }
        return nil
    }
}

/// Hover and selection outlines, drawn above the tiles.
private struct StorageTreemapOverlay: View {
    let tiles: [StorageTreemapTile]
    let hoveredTileID: Int?
    let selection: Set<ObjectIdentifier>

    var body: some View {
        Canvas { context, _ in
            if !selection.isEmpty {
                for tile in tiles where selection.contains(tile.node.id) {
                    let path = Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3, style: .continuous)
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
                }
            }
            if let hoveredTileID, hoveredTileID < tiles.count {
                let rect = tiles[hoveredTileID].rect.insetBy(dx: 0.5, dy: 0.5)
                let path = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
                context.fill(path, with: .color(.white.opacity(0.16)))
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 3)
                context.stroke(path, with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Sunburst

/// Interactive sunburst: rings of arcs around the displayed folder.
struct StorageSunburstView<Menu: View>: View {
    let node: StorageNode
    let version: Int
    let colorMode: StorageColorMode
    let selection: Set<ObjectIdentifier>
    let canGoUp: Bool
    let actions: StorageChartActions
    @ViewBuilder let menu: (StorageNode) -> Menu

    @State private var segments: [StorageSunburstSegment] = []
    @State private var generation = 0
    @State private var hoverPoint: CGPoint?
    @State private var hoveredSegmentID: Int?
    @State private var isHoveringCenter = false
    @Environment(\.colorScheme) private var colorScheme

    static var rings: Int { 4 }

    private struct LayoutKey: Equatable {
        var node: ObjectIdentifier
        var version: Int
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = StorageSunburstGeometry(size: size, rings: Self.rings)
            ZStack(alignment: .topLeading) {
                StorageSunburstCanvas(segments: segments, generation: generation, colorMode: colorMode, geometry: geometry, colorScheme: colorScheme)
                    .equatable()
                StorageSunburstOverlay(segments: segments, hoveredSegmentID: hoveredSegmentID, selection: selection, geometry: geometry)
                    .allowsHitTesting(false)
                centerLabel(geometry: geometry)
                    .position(geometry.center)
                    .allowsHitTesting(false)
                if let point = hoverPoint, let segment = hoveredSegment {
                    StorageChartTooltip(node: segment.node, share: node.size > 0 ? Double(segment.node.size) / Double(node.size) : 0)
                        .position(StorageChartTooltip.position(for: point, in: size))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverPoint = location
                    let ring = StorageSunburstLayout.ring(at: location, center: geometry.center, innerRadius: geometry.innerRadius, ringWidth: geometry.ringWidth, rings: Self.rings)
                    let centerHover = ring == 0
                    if centerHover != isHoveringCenter { isHoveringCenter = centerHover }
                    let id = StorageSunburstLayout.hitTest(location, center: geometry.center, innerRadius: geometry.innerRadius, ringWidth: geometry.ringWidth, rings: Self.rings, segments: segments)?.id
                    if id != hoveredSegmentID { hoveredSegmentID = id }
                case .ended:
                    hoverPoint = nil
                    hoveredSegmentID = nil
                    isHoveringCenter = false
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                let ring = StorageSunburstLayout.ring(at: value.location, center: geometry.center, innerRadius: geometry.innerRadius, ringWidth: geometry.ringWidth, rings: Self.rings)
                if ring == 0 {
                    if canGoUp { actions.goUp() }
                    return
                }
                guard let segment = StorageSunburstLayout.hitTest(value.location, center: geometry.center, innerRadius: geometry.innerRadius, ringWidth: geometry.ringWidth, rings: Self.rings, segments: segments) else { return }
                activate(segment.node)
            })
            .contextMenu {
                if let segment = hoveredSegment { menu(segment.node) }
            }
        }
        .onChange(of: LayoutKey(node: node.id, version: version), initial: true) {
            segments = StorageSunburstLayout.segments(for: node, rings: Self.rings)
            hoveredSegmentID = nil
            generation &+= 1
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sunburst chart of \(node.displayName)")
        .accessibilityHint("Each arc's angle shows how much space an item uses.")
        .accessibilityChildren {
            ForEach(segments.filter { $0.ring == 1 }.prefix(40), id: \.id) { segment in
                Rectangle()
                    .accessibilityLabel(segment.node.displayName)
                    .accessibilityValue("\(ByteFormatting.string(segment.node.size)), \(segment.node.kindDescription)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { activate(segment.node) }
            }
        }
    }

    private var hoveredSegment: StorageSunburstSegment? {
        guard let hoveredSegmentID, hoveredSegmentID < segments.count else { return nil }
        return segments[hoveredSegmentID]
    }

    private func activate(_ target: StorageNode) {
        switch target.kind {
        case .directory:
            if !target.children.isEmpty { actions.open(target) } else { actions.select(target) }
        case .smallFiles:
            if let parent = target.parent, parent !== node { actions.open(parent) }
        case .file, .package:
            actions.select(target)
        }
    }

    private func centerLabel(geometry: StorageSunburstGeometry) -> some View {
        VStack(spacing: 2) {
            if isHoveringCenter && canGoUp {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Back").font(.caption.weight(.semibold))
            } else {
                Text(node.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                Text(ByteFormatting.string(node.size))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("\(NumberFormatting.count(node.itemCount)) files")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: max(40, geometry.innerRadius * 1.6))
    }
}

/// Radii of the sunburst for a given view size.
struct StorageSunburstGeometry: Equatable {
    var center: CGPoint
    var outerRadius: Double
    var innerRadius: Double
    var ringWidth: Double

    init(size: CGSize, rings: Int) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outerRadius = max(10, Double(min(size.width, size.height)) / 2 - 8)
        innerRadius = outerRadius * 0.27
        ringWidth = (outerRadius - innerRadius) / Double(max(1, rings))
    }

    func path(for segment: StorageSunburstSegment, inset: Double = 0) -> Path {
        let inner = innerRadius + Double(segment.ring - 1) * ringWidth + 1 + inset
        let outer = innerRadius + Double(segment.ring) * ringWidth - inset
        // Path angles start at 3 o'clock; segment angles start at 12 o'clock.
        let start = Angle.radians(segment.startAngle - .pi / 2)
        let end = Angle.radians(segment.endAngle - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: max(0, inner), startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct StorageSunburstCanvas: View, Equatable {
    let segments: [StorageSunburstSegment]
    let generation: Int
    let colorMode: StorageColorMode
    let geometry: StorageSunburstGeometry
    /// Part of the equality so a light/dark switch redraws the separators.
    let colorScheme: ColorScheme

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.colorMode == rhs.colorMode && lhs.geometry == rhs.geometry
            && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        Canvas { context, _ in
            let separator = Color.windowBackground
            for segment in segments {
                let path = geometry.path(for: segment)
                let shade = StorageChartPalette.shade(for: segment.node, depth: segment.ring - 1, topLevelIndex: segment.topLevelIndex, mode: colorMode)
                context.fill(path, with: .color(segment.node.kind == .directory && colorMode == .kind && segment.ring > 1
                                                ? shade.top : shade.bottom))
                if segment.span > 0.01 {
                    context.stroke(path, with: .color(separator), lineWidth: 1)
                }
            }
            // Labels on the inner ring where the arc is long enough.
            for segment in segments where segment.ring == 1 {
                let radius = geometry.innerRadius + geometry.ringWidth / 2
                guard segment.span * radius > 64 else { continue }
                let shade = StorageChartPalette.shade(for: segment.node, depth: 0, topLevelIndex: segment.topLevelIndex, mode: colorMode)
                let point = StorageSunburstLayout.point(at: segment.midAngle, radius: radius, center: geometry.center)
                let width = CGFloat(min(segment.span * radius * 0.8, geometry.ringWidth * 1.5))
                guard let title = StorageChartText.fitted(segment.node.displayName, font: .system(size: 10.5, weight: .semibold),
                                                          color: shade.label, width: width, in: context) else { continue }
                context.draw(title, at: point, anchor: .center)
            }
        }
    }
}

private struct StorageSunburstOverlay: View {
    let segments: [StorageSunburstSegment]
    let hoveredSegmentID: Int?
    let selection: Set<ObjectIdentifier>
    let geometry: StorageSunburstGeometry

    var body: some View {
        Canvas { context, _ in
            let centerCircle = Path(ellipseIn: CGRect(
                x: geometry.center.x - geometry.innerRadius, y: geometry.center.y - geometry.innerRadius,
                width: geometry.innerRadius * 2, height: geometry.innerRadius * 2
            ))
            context.fill(centerCircle, with: .color(Color.cardBackground))
            context.stroke(centerCircle, with: .color(Color.subtleBorder), lineWidth: 1)

            if !selection.isEmpty {
                for segment in segments where selection.contains(segment.node.id) {
                    context.stroke(geometry.path(for: segment, inset: 1), with: .color(.accentColor), lineWidth: 2.5)
                }
            }
            if let hoveredSegmentID, hoveredSegmentID < segments.count {
                let path = geometry.path(for: segments[hoveredSegmentID])
                context.fill(path, with: .color(.white.opacity(0.22)))
                context.stroke(path, with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}
