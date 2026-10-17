import SwiftUI
import UIKit

/// The areas of the app, each with the Mac app's tint and a symbol.
enum MobileSection: String, CaseIterable, Identifiable, Sendable {
    case overview, photos, videos, contacts, files, protection, guides

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .contacts: return "Contacts"
        case .files: return "Files"
        case .protection: return "Protection"
        case .guides: return "Guides"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .photos: return "photo.on.rectangle.angled"
        case .videos: return "film.stack"
        case .contacts: return "person.2.crop.square.stack"
        case .files: return "folder"
        case .protection: return "checkmark.shield"
        case .guides: return "lightbulb"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return Color(red: 0.25, green: 0.47, blue: 0.98)
        case .photos: return Color(red: 0.07, green: 0.66, blue: 0.72)
        case .videos: return Color(red: 0.93, green: 0.30, blue: 0.38)
        case .contacts: return Color(red: 0.36, green: 0.40, blue: 0.92)
        case .files: return Color(red: 0.18, green: 0.55, blue: 0.96)
        case .protection: return Color(red: 0.18, green: 0.68, blue: 0.40)
        case .guides: return Color(red: 0.92, green: 0.62, blue: 0.10)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint.mix(with: .white, by: 0.18), tint.mix(with: .black, by: 0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// The app's accent: the purple of the Mac app's icon.
    static let brand = Color(red: 0.42, green: 0.36, blue: 0.98)

    /// Blends `fraction` (0…1) of `other` into this color.
    func mix(with other: Color, by fraction: Double) -> Color {
        let first = UIColor(self), second = UIColor(other)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(min(1, max(0, fraction)))
        return Color(red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t),
                     blue: Double(b1 + (b2 - b1) * t), opacity: Double(a1 + (a2 - a1) * t))
    }
}
