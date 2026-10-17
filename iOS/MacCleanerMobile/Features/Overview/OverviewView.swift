import SwiftUI

/// The first page: storage, what can be cleaned, protection and the guides that help now.
struct OverviewView: View {
    var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                storageCard
                cleanCard
                protectionCard
                suggestionsCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showsIntroduction = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("How Mac Cleaner works on \(model.device.deviceWord)")
            }
        }
        .refreshable {
            model.refreshStorage()
            await model.protection.refresh()
        }
    }

    // MARK: Storage

    private var storageCard: some View {
        Card {
            HStack(spacing: 18) {
                RingGauge(fraction: model.storage?.usedFraction ?? 0,
                          tint: (model.storage?.isLow ?? false) ? .orange : MobileSection.overview.tint) {
                    VStack(spacing: 0) {
                        Text(model.storage.map { NumberFormatting.percent($0.usedFraction) } ?? "—")
                            .font(.title3.weight(.bold)).monospacedDigit()
                        Text("used").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.device.deviceWord) storage").font(.headline)
                    if let storage = model.storage {
                        Text("\(ByteFormatting.string(storage.available)) available of \(ByteFormatting.string(storage.total))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if storage.isLow {
                            Label("Storage is almost full", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                        }
                    } else {
                        Text("Couldn't read the storage.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let reclaimable = model.reclaimableBytes, reclaimable > 0 {
                        Text("\(ByteFormatting.string(reclaimable)) can be freed")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                    }
                }
            }
        }
    }

    // MARK: Clean

    private var cleanCard: some View {
        Card {
            Text("Clean up").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink { PhotosHomeView(model: model.photos) } label: {
                    QuickAction(section: .photos, detail: model.photos.photoReclaimableBytes.map(ByteFormatting.string) ?? "Scan")
                }
                NavigationLink { VideosHomeView(model: model.photos) } label: {
                    QuickAction(section: .videos, detail: model.photos.videoReclaimableBytes.map(ByteFormatting.string) ?? "Scan")
                }
                NavigationLink { ContactsHomeView(model: model.contacts) } label: {
                    QuickAction(section: .contacts, detail: model.contacts.issueCount.map { NumberFormatting.count($0, "issue") } ?? "Scan")
                }
                NavigationLink { FilesHomeView(model: model.files) } label: {
                    QuickAction(section: .files, detail: model.files.reclaimableBytes.map(ByteFormatting.string) ?? "Choose folders")
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Protection

    private var protectionCard: some View {
        Button {
            model.selectedTab = .protect
        } label: {
            Card {
                HStack(spacing: 14) {
                    IconTile(section: .protection, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protection").font(.headline)
                        Text(protectionText).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var protectionText: String {
        switch model.protection.status {
        case .unknown: return "Check your passcode, iOS version and Safari protection."
        case .protected: return "Everything looks good."
        case .attention(let reason): return reason
        }
    }

    // MARK: Guides

    @ViewBuilder
    private var suggestionsCard: some View {
        let suggestions = Array(GuideLibrary.suggestions(for: model.guideContext).prefix(3))
        if !suggestions.isEmpty {
            Card {
                Text("Suggested for you").font(.headline)
                ForEach(suggestions) { guide in
                    NavigationLink { GuideDetailView(guide: guide, context: model.guideContext) } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: guide.symbol, tint: MobileSection.guides.tint, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(guide.title).font(.subheadline.weight(.semibold))
                                Text(guide.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct QuickAction: View {
    var section: MobileSection
    var detail: String

    var body: some View {
        HStack(spacing: 10) {
            IconTile(section: section, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}
