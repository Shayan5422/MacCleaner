import AppKit
import SwiftUI

/// Visual identity of each section: a tint and a matching gradient for icon tiles.
extension AppSection {
    var tint: Color {
        switch self {
        case .dashboard: return Color(red: 0.25, green: 0.47, blue: 0.98)
        case .smartScan: return Color(red: 0.47, green: 0.36, blue: 0.96)
        case .systemJunk: return Color(red: 0.13, green: 0.70, blue: 0.53)
        case .privacy: return Color(red: 0.62, green: 0.35, blue: 0.90)
        case .developer: return Color(red: 0.96, green: 0.52, blue: 0.16)
        case .storage: return Color(red: 0.18, green: 0.55, blue: 0.96)
        case .duplicates: return Color(red: 0.07, green: 0.66, blue: 0.72)
        case .cloud: return Color(red: 0.22, green: 0.66, blue: 0.95)
        case .uninstaller: return Color(red: 0.93, green: 0.30, blue: 0.38)
        case .updates: return Color(red: 0.20, green: 0.50, blue: 0.95)
        case .startup: return Color(red: 0.36, green: 0.40, blue: 0.92)
        case .performance: return Color(red: 0.95, green: 0.29, blue: 0.53)
        case .security: return Color(red: 0.18, green: 0.68, blue: 0.40)
        case .antivirus: return Color(red: 0.86, green: 0.24, blue: 0.27)
        case .network: return Color(red: 0.10, green: 0.62, blue: 0.80)
        case .automation: return Color(red: 0.92, green: 0.62, blue: 0.10)
        case .history: return Color(red: 0.50, green: 0.53, blue: 0.60)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint.mix(with: .white, by: 0.18), tint.mix(with: .black, by: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension SmartScanArea {
    var tint: Color { section.tint }
}

extension CleanupSafety {
    var tint: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }
}

extension FindingSeverity {
    var tint: Color {
        switch self {
        case .info: return .secondary
        case .recommendation: return .blue
        case .suspicious: return .orange
        case .threat: return .red
        }
    }
}

extension Color {
    /// Blends two colors in sRGB (works on macOS 14, where `Color.mix` isn't available).
    func mix(with other: Color, by fraction: Double) -> Color {
        let first = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let second = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        let t = max(0, min(1, fraction))
        return Color(
            .sRGB,
            red: first.redComponent + (second.redComponent - first.redComponent) * t,
            green: first.greenComponent + (second.greenComponent - first.greenComponent) * t,
            blue: first.blueComponent + (second.blueComponent - first.blueComponent) * t,
            opacity: first.alphaComponent + (second.alphaComponent - first.alphaComponent) * t
        )
    }

    /// Card and panel surfaces that adapt to light and dark mode.
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let subtleBorder = Color.primary.opacity(0.08)
    static let hoverFill = Color.primary.opacity(0.05)
}

/// Spacing and radii used throughout the app.
enum Metrics {
    static let pagePadding: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 10
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 10
}

/// Stable chart colors for categories (storage types, process groups...).
enum ChartPalette {
    static let colors: [Color] = [
        Color(red: 0.25, green: 0.47, blue: 0.98), Color(red: 0.13, green: 0.70, blue: 0.53),
        Color(red: 0.96, green: 0.52, blue: 0.16), Color(red: 0.62, green: 0.35, blue: 0.90),
        Color(red: 0.95, green: 0.29, blue: 0.53), Color(red: 0.07, green: 0.66, blue: 0.72),
        Color(red: 0.92, green: 0.72, blue: 0.10), Color(red: 0.50, green: 0.53, blue: 0.60),
        Color(red: 0.36, green: 0.40, blue: 0.92), Color(red: 0.80, green: 0.36, blue: 0.24),
    ]

    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// Deterministic color for a string key (same key → same color across launches).
    static func color(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return color(at: Int(hash % UInt64(colors.count)))
    }
}
