import SwiftUI

/// A rounded tile with a section's gradient and symbol.
struct IconTile: View {
    var symbol: String
    var gradient: LinearGradient
    var size: CGFloat = 36

    init(section: MobileSection, size: CGFloat = 36) {
        symbol = section.symbol
        gradient = section.gradient
        self.size = size
    }

    init(symbol: String, tint: Color, size: CGFloat = 36) {
        self.symbol = symbol
        gradient = LinearGradient(colors: [tint.mix(with: .white, by: 0.18), tint.mix(with: .black, by: 0.12)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// Grouped-background card.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Circular gauge with a gradient stroke and centered content.
struct RingGauge<Center: View>: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction.isFinite ? fraction : 0)))
                .stroke(AngularGradient(colors: [tint.mix(with: .white, by: 0.25), tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, fraction))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .padding(lineWidth / 2)
    }
}

/// A number with a title and caption, for summary rows.
struct StatTile: View {
    var title: String
    var value: String
    var caption: String? = nil
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.headline).foregroundStyle(tint)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.subheadline.weight(.medium))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Explains what access a feature needs and asks for it (or sends the person to Settings).
struct PermissionCard: View {
    var section: MobileSection
    var title: String
    var message: String
    var buttonTitle: String
    var action: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(section: section, size: 44)
                Text(title).font(.headline)
            }
            Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(section.tint)
        }
    }
}

/// A scan in progress.
struct ProgressCard: View {
    var title: String
    var message: String
    var fraction: Double?

    var body: some View {
        Card {
            Text(title).font(.headline)
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(message).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Nothing to show (yet).
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
    }
}

/// Opens this app's page in Settings, where the person can change its access to Photos, Contacts and more.
@MainActor
func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
