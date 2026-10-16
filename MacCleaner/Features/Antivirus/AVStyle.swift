import SwiftUI

extension AntivirusViewModel.ProtectionState {
    var tint: Color {
        switch self {
        case .protected: return .green
        case .attention: return .orange
        case .threats: return .red
        case .notSetUp: return .gray
        }
    }
}

extension AVThreatCategory {
    var tint: Color {
        switch self {
        case .malware: return .red
        case .pua: return .orange
        case .testFile: return .blue
        case .maliciousDownload: return Color(red: 0.86, green: 0.30, blue: 0.20)
        }
    }
}

/// "Malware", "PUA", "Test file" or "Malware site".
struct AVCategoryBadge: View {
    var category: AVThreatCategory

    var body: some View {
        Badge(text: category.badgeTitle, symbol: category.symbolName, tint: category.tint)
            .help(category.explanation)
    }
}

/// A status tile with an accessory (toggle or button), matching `StatTile`.
struct AVStatusTile<Accessory: View>: View {
    var title: String
    var value: String
    var caption: String?
    var symbol: String
    var tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                accessory()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// A labeled value inside a card (left label, right value).
struct AVInfoRow: View {
    var label: String
    var value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// Text that explains a limitation, with an Open Settings button when there is one.
struct AVLimitationsView: View {
    let limitations: [AVLimitation]
    var services: AppServices
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(limitations) { limitation in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(limitation.title).font(.callout.weight(.medium))
                            Text(limitation.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if let pane = limitation.pane {
                            Button("Open Settings") { services.permissions.open(pane) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("\(limitations.count) thing\(limitations.count == 1 ? "" : "s") couldn't be checked", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A dismissible confirmation banner.
struct AVStatusBanner: View {
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(0.2)))
        .task(id: message) {
            try? await Task.sleep(for: .seconds(8))
            onDismiss()
        }
    }
}

enum AVText {
    /// "3.6 million", "355,765".
    static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return millions.formatted(.number.precision(.fractionLength(millions < 10 ? 1 : 0))) + " million"
        }
        return NumberFormatting.count(value)
    }
}

/// A path with a Reveal in Finder button, aligned with `AVInfoRow`.
struct AVPathRow: View {
    var label: String
    var path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(PathUtilities.abbreviate(path))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 4)
            if FileManager.default.fileExists(atPath: path) {
                Button {
                    FinderActions.reveal(path)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(label) in Finder")
            }
        }
        .font(.callout)
    }
}
