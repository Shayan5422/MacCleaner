import AppKit
import SwiftUI

// MARK: - Page structure

/// Rounded gradient tile with an SF Symbol, used as a section's identity mark.
struct IconTile: View {
    var symbol: String
    var gradient: LinearGradient
    var size: CGFloat = 44

    init(symbol: String, gradient: LinearGradient, size: CGFloat = 44) {
        self.symbol = symbol
        self.gradient = gradient
        self.size = size
    }

    init(section: AppSection, size: CGFloat = 44) {
        self.init(symbol: section.symbolName, gradient: section.gradient, size: size)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(gradient)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

/// Title area at the top of every page.
struct PageHeader<Trailing: View>: View {
    var section: AppSection
    var title: String?
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(section: AppSection, title: String? = nil, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(section: section, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? section.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.bottom, 4)
    }
}

/// Standard scrolling page layout with consistent padding.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                content()
            }
            .padding(Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.windowBackground)
    }
}

// MARK: - Cards

struct CardModifier: ViewModifier {
    var padding: CGFloat = Metrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.subtleBorder, lineWidth: 1)
            )
    }
}

extension View {
    /// Wraps the view in a rounded, bordered card surface.
    func card(padding: CGFloat = Metrics.cardPadding) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// A titled card.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || symbol != nil {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(.secondary)
                    }
                    if let title {
                        Text(title).font(.headline)
                    }
                    Spacer()
                    accessory()
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Metrics

/// Compact statistic with icon, value and caption.
struct StatTile: View {
    var title: String
    var value: String
    var caption: String?
    var symbol: String
    var tint: Color
    /// Stretch to the height of the tallest tile in a `TileRow`.
    var fillsHeight = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// A row of tiles that all get the height of the tallest one (use `StatTile(fillsHeight: true)`).
struct TileRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Circular gauge with a gradient stroke and centered content.
struct RingGauge<Center: View>: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction.isFinite ? fraction : 0)))
                .stroke(
                    AngularGradient(colors: [tint.mix(with: .white, by: 0.25), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, fraction))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: fraction)
            center()
        }
        .padding(lineWidth / 2)
    }
}

/// One segment of a `UsageBar`.
struct UsageSegment: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var bytes: Int64
    var color: Color
}

/// Horizontal stacked bar for storage composition.
struct UsageBar: View {
    var segments: [UsageSegment]
    var total: Int64
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(2, proxy.size.width * CGFloat(Double(segment.bytes) / Double(max(total, 1)))))
                        .help("\(segment.label): \(ByteFormatting.string(segment.bytes))")
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .accessibilityLabel(segments.map { "\($0.label) \(ByteFormatting.string($0.bytes))" }.joined(separator: ", "))
    }
}

/// Legend entry for charts and usage bars.
struct LegendItem: View {
    var color: Color
    var label: String
    var value: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            if let value {
                Text(value).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

// MARK: - Badges

struct Badge: View {
    var text: String
    var symbol: String?
    var tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

struct SafetyBadge: View {
    var safety: CleanupSafety

    var body: some View {
        Badge(text: safety.title, symbol: safety.symbolName, tint: safety.tint)
            .help(safety.explanation)
    }
}

struct SeverityBadge: View {
    var severity: FindingSeverity

    var body: some View {
        Badge(text: severity.title, symbol: severity.symbolName, tint: severity == .info ? .gray : severity.tint)
    }
}

// MARK: - Text helpers

/// File size with monospaced digits.
struct SizeText: View {
    var bytes: Int64
    var font: Font = .body

    var body: some View {
        Text(ByteFormatting.string(bytes))
            .font(font)
            .monospacedDigit()
    }
}

/// A path abbreviated with `~`, truncated in the middle, selectable for copying.
struct PathText: View {
    var path: String
    var font: Font = .caption

    var body: some View {
        Text(PathUtilities.abbreviate(path))
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: - Callouts

/// Inline explanation or warning box.
struct InfoCallout: View {
    enum Style {
        case info, warning, danger, success

        var tint: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .danger: return .red
            case .success: return .green
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    var style: Style = .info
    var title: String?
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(style.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.tint.opacity(0.18)))
    }
}

/// Banner shown when Full Disk Access is missing and results may be incomplete.
struct FullDiskAccessBanner: View {
    @Environment(PermissionManager.self) private var permissions
    var reason: String = "Some folders are protected by macOS, so results may be incomplete."

    var body: some View {
        if permissions.fullDiskAccess == .notGranted {
            HStack(spacing: 12) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access is off").font(.callout.weight(.semibold))
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { permissions.open(.fullDiskAccess) }
                Button("Check Again") { permissions.refresh() }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.2)))
        }
    }
}

// MARK: - Progress

/// Progress card for long operations, with a cancel button.
struct ScanProgressCard: View {
    var title: String
    var message: String
    /// nil shows an indeterminate bar.
    var fraction: Double?
    var tint: Color = .accentColor
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
                Spacer()
                if let fraction {
                    Text(NumberFormatting.percent(fraction))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
            if let fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .tint(tint)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .card()
    }
}

// MARK: - Bottom action bar

/// Sticky bar summarizing the selection with a primary action.
struct SelectionActionBar<Actions: View>: View {
    var selectedCount: Int
    var selectedBytes: Int64
    var noun: String = "item"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedCount == 0 ? "Nothing selected" : "\(NumberFormatting.count(selectedCount)) \(noun)\(selectedCount == 1 ? "" : "s") selected")
                    .font(.callout.weight(.medium))
                if selectedCount > 0 {
                    Text(ByteFormatting.string(selectedBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - File icons

/// Finder icon for a file or folder, cached.
struct FileIcon: View {
    var path: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 2_000
    }

    func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }

    /// Icon of the app with `bundleIdentifier`, if installed.
    func appIcon(bundleIdentifier: String) -> NSImage? {
        let key = "bundle:" + bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

// MARK: - Finder actions

/// Common file actions used in context menus.
@MainActor
enum FinderActions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func openTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }
}

/// Standard context menu items for a file path.
struct FileContextMenu: View {
    var path: String
    var onQuickLook: (() -> Void)?
    var onExclude: (() -> Void)?

    var body: some View {
        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(path) }
        if let onQuickLook {
            Button("Quick Look", systemImage: "eye", action: onQuickLook)
        }
        Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(path) }
        if let onExclude {
            Divider()
            Button("Always Exclude This Item", systemImage: "eye.slash", action: onExclude)
        }
    }
}

// MARK: - Empty states

/// Empty or initial state with an optional primary action.
struct EmptyStateView: View {
    var title: String
    var symbol: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Large call-to-action shown before the first scan of a feature.
struct ScanLaunchView: View {
    var section: AppSection
    var headline: String
    var message: String
    var buttonTitle: String = "Scan"
    var bullets: [String] = []
    var action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            IconTile(section: section, size: 84)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets, id: \.self) { bullet in
                        Label(bullet, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
            Button(action: action) {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(section.tint)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 380)
    }
}
