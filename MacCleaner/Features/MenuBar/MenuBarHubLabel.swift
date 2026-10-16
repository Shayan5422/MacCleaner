import AppKit
import SwiftUI

/// The menu bar item: Mac Cleaner's glyph, an optional value (open ports, CPU or free
/// disk space) and a dot when something needs attention.
///
/// Live sampling (`isMenuBarExtraActive`) only runs while the label shows CPU or
/// performance alerts are on (they're evaluated with each sample); free space is read
/// once a minute while it's shown.
struct MenuBarHubLabel: View {
    let environment: AppEnvironment
    var preferences: MenuBarPreferences = .shared
    var events: ProtectionEventLog = .shared

    @Environment(\.openWindow) private var openWindow
    @State private var freeSpace: Int64?

    var body: some View {
        let status = MenuBarStatus.current(environment)
        let style = preferences.labelStyle
        let alert = MenuBarGlyph.alert(protection: status.protectionState, events: events)
        Image(nsImage: MenuBarGlyph.image(text: text(for: style, status: status), alert: alert))
            .accessibilityLabel(accessibilityText(style: style, status: status, alert: alert))
            .onAppear {
                AppPresence.shared.openWindowAction = openWindow
                environment.monitor.isMenuBarExtraActive = needsSampling
            }
            .onDisappear { environment.monitor.isMenuBarExtraActive = false }
            .onChange(of: needsSampling) { _, needed in
                environment.monitor.isMenuBarExtraActive = needed
            }
            .task(id: style) {
                guard style == .freeDisk else { return }
                while !Task.isCancelled {
                    freeSpace = await BackgroundWork.run(qos: .utility) { VolumeService.startupVolume()?.effectiveAvailable }
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }

    private var needsSampling: Bool {
        preferences.labelStyle == .cpu || environment.services.settings.performanceAlertsEnabled
    }

    private func text(for style: MenuBarLabelStyle, status: MenuBarStatus) -> String? {
        switch style {
        case .iconOnly:
            return nil
        case .openPorts:
            guard let count = status.openPortCount, count > 0 else { return nil }
            return "\(count)"
        case .cpu:
            guard let sample = environment.monitor.latest, sample.isCPUAvailable else { return "\u{2007}\u{2007}–%" }
            // Figure spaces pad short values so the item doesn't jitter.
            let digits = String(Int((sample.cpuUsage * 100).rounded()))
            return String(repeating: "\u{2007}", count: max(0, 3 - digits.count)) + digits + "%"
        case .freeDisk:
            return freeSpace.map { ByteFormatting.string($0) }
        }
    }

    private func accessibilityText(style: MenuBarLabelStyle, status: MenuBarStatus, alert: MenuBarGlyph.Alert?) -> String {
        var parts = ["Mac Cleaner"]
        switch alert {
        case .threat?: parts.append("threats found")
        case .attention?: parts.append("new activity to review")
        case nil: break
        }
        if let text = text(for: style, status: status)?.trimmingCharacters(in: .whitespaces) {
            switch style {
            case .openPorts: parts.append("\(text) open ports")
            case .cpu: parts.append("CPU \(text)")
            case .freeDisk: parts.append("\(text) free")
            case .iconOnly: break
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// Draws the menu bar item: a ring with sparkles (like the app icon) and optional text.
enum MenuBarGlyph {
    enum Alert: Equatable {
        /// Threats found: a red dot.
        case threat
        /// Unseen suspicious activity: an orange dot.
        case attention
    }

    /// Red for unhandled threats, orange for unseen suspicious (or worse) events.
    @MainActor
    static func alert(protection: MenuBarProtectionState?, events: ProtectionEventLog) -> Alert? {
        if case .threats(let count)? = protection, count > 0 { return .threat }
        let unseen = events.events.prefix(events.unseenCount)
        if unseen.contains(where: { $0.severity == .threat }) { return .threat }
        if unseen.contains(where: { $0.severity >= .suspicious }) { return .attention }
        return nil
    }

    static let glyphSize: CGFloat = 18

    /// Without an alert the image is a template, so macOS tints it like every other menu
    /// bar item. With an alert it's drawn in the menu bar's text color (resolved when it's
    /// drawn) with a colored dot.
    static func image(text: String?, alert: Alert?) -> NSImage {
        let pointSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let textSize = text.map { ($0 as NSString).size(withAttributes: [.font: font(pointSize)]) } ?? .zero
        let width = glyphSize + (text == nil ? 0 : 3 + ceil(textSize.width))
        let size = NSSize(width: width, height: glyphSize)
        let isTemplate = alert == nil

        let image = NSImage(size: size, flipped: false) { _ in
            let ink: NSColor = isTemplate ? .black : .labelColor
            drawGlyph(ink: ink, alert: alert)
            if let text {
                let attributes: [NSAttributedString.Key: Any] = [.font: font(pointSize), .foregroundColor: ink]
                let y = (glyphSize - textSize.height) / 2
                (text as NSString).draw(at: NSPoint(x: glyphSize + 3, y: y), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "Mac Cleaner"
        return image
    }

    private static func font(_ pointSize: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
    }

    private static func drawGlyph(ink: NSColor, alert: Alert?) {
        let center = NSPoint(x: glyphSize / 2, y: glyphSize / 2)
        // The ring of the app icon, open on the lower left.
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: 7.4, startAngle: 235, endAngle: 205, clockwise: false)
        ring.lineWidth = 1.5
        ring.lineCapStyle = .round
        ink.setStroke()
        ring.stroke()

        // The sparkles inside it.
        let configuration = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        if let sparkles = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let symbolSize = sparkles.size
            let rect = NSRect(x: center.x - symbolSize.width / 2, y: center.y - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height)
            sparkles.draw(in: rect)
        }

        if let alert {
            let dot = NSRect(x: glyphSize - 7, y: glyphSize - 7, width: 6.5, height: 6.5)
            // A knockout around the dot keeps it readable against the ring.
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            (alert == .threat ? NSColor.systemRed : NSColor.systemOrange).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
