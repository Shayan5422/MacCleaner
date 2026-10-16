import SwiftUI

/// Code-signature badge: who signed it, or why nobody identifiable did.
struct GuardianSignatureBadge: View {
    let signature: GuardianSignatureSummary?

    var body: some View {
        if let signature {
            Badge(text: text(signature), symbol: signature.category.symbolName, tint: tint(signature.category))
                .help(signature.summary)
        } else {
            Badge(text: "Not checked", symbol: "questionmark.circle", tint: .gray)
                .help("The code signature couldn't be checked.")
        }
    }

    private func text(_ signature: GuardianSignatureSummary) -> String {
        switch signature.category {
        case .developerIDNotarized, .developerID, .appleDevelopment:
            return signature.developer ?? signature.category.title
        case .packageManager:
            return signature.developer ?? "Package manager"
        default:
            return signature.category.title
        }
    }

    private func tint(_ category: SecurityTrustCategory) -> Color {
        switch category {
        case .apple, .appStore, .developerIDNotarized: return .green
        case .developerID, .appleDevelopment: return .teal
        case .packageManager, .script, .unknown: return .gray
        case .adHoc, .unsigned, .untrustedCertificate: return .orange
        case .invalid, .revoked, .missing: return .red
        }
    }
}

/// The antivirus verdict for a new item's program.
struct GuardianVerdictBadge: View {
    let verdict: GuardianScanVerdict?
    let isScanning: Bool

    var body: some View {
        if isScanning {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Scanning…").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        } else if let verdict {
            if verdict.isClean {
                Badge(text: "No threats found", symbol: "checkmark.shield.fill", tint: .green)
                    .help("Scanned \(DateFormatting.relative(verdict.scannedAt))\(verdict.engine.map { " with \($0)" } ?? "").")
            } else {
                Badge(text: verdict.detections.first ?? "Threat", symbol: "ladybug.fill", tint: .red)
                    .help(verdict.detections.joined(separator: "\n"))
            }
        }
    }
}

/// App icon for items that belong to an app, otherwise a tinted symbol tile.
struct GuardianItemIcon: View {
    var path: String?
    var symbol: String
    var tint: Color = AppSection.startup.tint
    var size: CGFloat = 28

    var body: some View {
        if let path, FileManager.default.fileExists(atPath: path) {
            FileIcon(path: path, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(tint)
                )
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

extension GuardianStartupChange.Kind {
    var tint: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .changed: return .blue
        }
    }
}

/// An item icon with a small added/removed/changed mark in its corner.
struct GuardianChangeIcon: View {
    let change: GuardianStartupChange
    var size: CGFloat = 30

    var body: some View {
        GuardianItemIcon(path: change.record.iconPath, symbol: change.record.kind.symbolName, size: size)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: change.kind.symbolName)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, change.kind.tint)
                    .background(Circle().fill(Color.cardBackground).padding(-1.5))
                    .offset(x: 4, y: 4)
            }
            .padding(.trailing, 4)
            .padding(.bottom, 4)
            .accessibilityLabel(change.kind.title)
    }
}

/// Header used by Guardian cards: title, optional count, subtitle and trailing accessory.
struct GuardianCardHeader<Accessory: View>: View {
    var title: String
    var symbol: String
    var tint: Color = AppSection.startup.tint
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, symbol: String, tint: Color = AppSection.startup.tint, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(14)
    }
}

/// Small grey footnote line with an icon.
struct GuardianFootnote: View {
    var symbol: String = "info.circle"
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Confirmation dialog, error alert and Move to Trash flow for the actions started from one card.
struct StartupGuardActionsModifier: ViewModifier {
    @Bindable var model: StartupGuardModel
    let presenter: GuardianPresenter

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                model.pendingAction?.title ?? "",
                isPresented: Binding(get: { model.pendingAction != nil && model.presenter == presenter },
                                     set: { if !$0 { model.pendingAction = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingAction
            ) { action in
                Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) {
                    Task { await model.perform(action) }
                }
                Button("Cancel", role: .cancel) { model.pendingAction = nil }
            } message: { action in
                Text(action.message)
            }
            .alert("Couldn't Make the Change",
                   isPresented: Binding(get: { model.alertMessage != nil && model.presenter == presenter },
                                        set: { if !$0 { model.alertMessage = nil } }),
                   presenting: model.alertMessage) { _ in
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: { message in
                Text(message)
            }
            .cleanupFlow(model.cleanupFlow(for: presenter), services: model.services)
    }
}

/// "“X” is turned off and won't start at login." after an action from this card; hides itself after a few seconds.
struct StartupGuardStatusBanner: View {
    var model: StartupGuardModel
    let presenter: GuardianPresenter

    var body: some View {
        if let message = model.statusMessage, model.presenter == presenter {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    model.statusMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.green.opacity(0.08))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(6))
                if model.statusMessage == message { model.statusMessage = nil }
            }
        }
    }
}

extension View {
    /// Presents the confirmations, errors and Move to Trash flow of actions started from this card.
    func startupGuardActions(_ model: StartupGuardModel, presenter: GuardianPresenter) -> some View {
        modifier(StartupGuardActionsModifier(model: model, presenter: presenter))
    }
}

/// Relative time with the exact date on hover.
struct GuardianTimeText: View {
    let date: Date
    var prefix: String = ""
    var style: Font = .caption
    /// "now", "5 min", "3 h", "2 d", then the date: for narrow places like the menu bar.
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(prefix + (compact ? Self.compactText(date, now: context.date) : DateFormatting.relative(date, to: context.date)))
                .font(style)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .help(DateFormatting.short(date))
        }
    }

    nonisolated static func compactText(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Groups dated items into "Today", "Yesterday" and calendar days, newest first.
enum GuardianDayGrouping {
    static func groups<Item>(_ items: [Item], date: (Item) -> Date, now: Date = Date()) -> [(title: String, items: [Item])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Item]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.sorted(by: >).map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else {
                title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            return (title, buckets[day] ?? [])
        }
    }
}
