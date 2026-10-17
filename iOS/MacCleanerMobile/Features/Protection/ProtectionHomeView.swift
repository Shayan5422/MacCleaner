import SwiftUI

/// The Protect tab: a security checkup, Safari protection and the link check.
struct ProtectionHomeView: View {
    var model: ProtectionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProtectionSummaryCard(model: model)
                checkupCard
                SafariProtectionCard(model: model, guideContext: guideContext)
                linkCheckCard
                manualChecksCard
                Text("iOS doesn't let apps scan other apps or files for malware. Mac Cleaner checks what iOS lets it see, and Safari protection blocks sites on known malware lists.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(16)
            .readableColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Protection")
        .refreshable { await model.refresh() }
    }

    /// For the guides the rows link to.
    private var guideContext: GuideContext {
        GuideContext(storage: nil, device: model.device, deletedPhotos: false, deletedFiles: false,
                     safariProtectionEnabled: model.safariProtectionEnabled, systemUpToDate: model.systemUpToDate,
                     passcodeSet: model.passcodeSet, availableSystemVersion: model.availableSystemVersion)
    }

    private var checkupCard: some View {
        Card {
            Text("Security checkup").font(.headline)
            let items = model.checkupItems
            ForEach(items) { item in
                CheckupRow(item: item, guideContext: guideContext)
                if item.id != items.last?.id { Divider().padding(.leading, 44) }
            }
        }
    }

    private var linkCheckCard: some View {
        NavigationLink {
            LinkCheckView(model: model)
        } label: {
            Card {
                HStack(spacing: 14) {
                    IconTile(symbol: "link", tint: Color.brand, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check a link").font(.headline)
                        Text("See whether a link or site is on the malware lists.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var manualChecksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check these yourself").font(.headline)
                Text("iOS doesn't let apps see these settings.").font(.subheadline).foregroundStyle(.secondary)
            }
            let guides = [GuideKey.stolenDeviceProtection, .lockdownMode, .profiles].map(GuideLibrary.guide)
                .filter { $0.isAvailable(on: model.device) }
            ForEach(guides) { guide in
                NavigationLink {
                    GuideDetailView(guide: guide, context: guideContext)
                } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: guide.symbol, tint: guide.tint, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guide.title).font(.subheadline.weight(.semibold))
                            Text(guide.summary).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The checkup at a glance: a ring for the checks passed and the most important thing to do.
struct ProtectionSummaryCard: View {
    var model: ProtectionModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let tally = model.checkTally
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        Card {
            layout {
                RingGauge(fraction: tally.total > 0 ? Double(tally.passed) / Double(tally.total) : 0, tint: tint, lineWidth: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.status != .unknown {
                        Text("\(tally.passed) of \(NumberFormatting.count(tally.total, "check")) passed")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch model.status {
        case .unknown: return "Checking…"
        case .protected: return "Looking good"
        case .attention: return "Needs attention"
        }
    }

    private var detail: String {
        switch model.status {
        case .unknown: return "Looking at your passcode, \(model.systemName) version and Safari protection."
        case .protected: return "Your passcode, \(model.systemName) version and Safari protection are all set."
        case .attention(let reason): return reason + "."
        }
    }

    private var symbol: String {
        switch model.status {
        case .unknown: return "shield"
        case .protected: return "checkmark.shield.fill"
        case .attention: return "exclamationmark.shield.fill"
        }
    }

    private var tint: Color {
        switch model.status {
        case .unknown: return .secondary
        case .protected: return MobileSection.protection.tint
        case .attention: return .orange
        }
    }
}

#if DEBUG
#Preview("Looking good") {
    NavigationStack { ProtectionHomeView(model: .preview()) }
}

#Preview("Needs attention") {
    NavigationStack {
        ProtectionHomeView(model: .preview(passcode: .notSet, biometrics: .notEnrolled(.faceID), network: .vpn, safari: .off,
                                           software: .updateAvailable(SystemVersion([27, 0, 2]), postingDate: .now), blocklist: nil))
    }
}
#endif
