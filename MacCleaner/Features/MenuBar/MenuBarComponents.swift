import AppKit
import SwiftUI

/// Building blocks of the menu bar hub. Sections other features add (protection,
/// ports, activity) use them so the popover looks like one piece.

/// A titled section of the hub: small uppercase title, optional accessory, content.
struct MenuBarCard<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: String, symbol: String, tint: Color = .secondary, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                accessory()
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// One row inside a hub section: leading icon, title and subtitle, trailing control.
struct MenuBarHubRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 9) {
            leading()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            trailing()
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

/// A tiny tile of the status strip.
struct MenuBarStatusTile: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color
    /// Draws a small usage bar (0…1) under the value.
    var fraction: Double?
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(tint.gradient)
                            .frame(width: max(3, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
                    }
                }
                .frame(height: 4)
            } else {
                Spacer(minLength: 4).frame(height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A short explanation with a button that opens a page of the main window.
struct MenuBarOpenSectionRow: View {
    var text: String
    var section: AppSection
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            IconTile(section: section, size: 24)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Open") {
                MenuBarHubActions.open(section, environment: environment, openWindow: openWindow)
            }
            .controlSize(.small)
            .help("Open \(section.title) in Mac Cleaner")
        }
    }
}

/// The newest protection events, each opening the page it's about.
struct MenuBarEventList: View {
    var log: ProtectionEventLog
    var limit: Int
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let events = Array(log.events.prefix(limit))
        if events.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("No activity yet. Threats, flagged downloads, new startup items, opened ports and updates appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 2) {
                ForEach(events) { event in
                    MenuBarEventRow(event: event) {
                        if let section = event.section {
                            MenuBarHubActions.open(section, environment: environment, openWindow: openWindow)
                        }
                    }
                }
            }
        }
    }
}

private struct MenuBarEventRow: View {
    var event: ProtectionEvent
    var onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            MenuBarHubRow(title: event.title, subtitle: event.detail ?? DateFormatting.relative(event.date)) {
                Image(systemName: event.kind.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(event.severity == .info ? Color.secondary : event.severity.tint)
            } trailing: {
                Text(Self.age(of: event.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(DateFormatting.relative(event.date))
            }
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? Color.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(event.section == nil)
        .onHover { isHovering = $0 }
        .help(event.section.map { "Open \($0.title)" } ?? event.title)
    }

    /// "now", "5 min", "2 h", "3 d": short enough to leave the title its room.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }
}

/// What the hub's buttons do.
@MainActor
enum MenuBarHubActions {
    /// Shows `section` in the main window, opening the window when needed.
    static func open(_ section: AppSection, environment: AppEnvironment, openWindow: OpenWindowAction) {
        environment.navigation.open(section)
        AppPresence.shared.open(windowID: AppWindowID.main, using: openWindow)
    }

    static func runSmartScan(environment: AppEnvironment, openWindow: OpenWindowAction) {
        open(.smartScan, environment: environment, openWindow: openWindow)
        if environment.smartScan.phase != .scanning { environment.smartScan.start() }
    }
}
