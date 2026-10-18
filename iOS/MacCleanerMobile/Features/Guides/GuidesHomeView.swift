import SwiftUI

/// The Guides tab: suggestions for this device, then every guide by category, with search.
struct GuidesHomeView: View {
    var context: GuideContext

    @State private var query = ""

    private var progress: GuideProgress { .shared }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchResults: [Guide] { GuideLibrary.search(trimmedQuery, for: context.device) }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                suggestionsSection
                ForEach(GuideCategory.allCases) { category in
                    Section {
                        ForEach(GuideLibrary.guides(in: category, for: context.device)) { guide in
                            link(to: guide) { GuideRow(guide: guide, isDone: progress.isDone(guide.id)) }
                        }
                    } header: {
                        Text(category.title)
                    } footer: {
                        Text(category.footer)
                    }
                }
            } else if !searchResults.isEmpty {
                Section {
                    ForEach(searchResults) { guide in
                        link(to: guide) { GuideRow(guide: guide, isDone: progress.isDone(guide.id)) }
                    }
                }
            }
        }
        .navigationTitle("Guides")
        .searchable(text: $query, prompt: "Search guides")
        .overlay {
            if !trimmedQuery.isEmpty && searchResults.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        let suggestions = Array(GuideLibrary.suggestions(for: context).prefix(3))
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { guide in
                    link(to: guide) {
                        GuideRow(guide: guide, isDone: false, reason: GuideLibrary.reason(for: guide, in: context), isProminent: true)
                    }
                }
            } header: {
                Text("Suggested for you")
            } footer: {
                Text("iOS keeps these settings out of reach of apps, so each guide shows the quickest way to do it yourself.")
            }
            .headerProminence(.increased)
        }
    }

    private func link(to guide: Guide, @ViewBuilder label: () -> GuideRow) -> some View {
        NavigationLink { GuideDetailView(guide: guide, context: context) } label: { label() }
    }
}

/// A guide in a list: its icon, title and summary, with a check when it's done.
struct GuideRow: View {
    var guide: Guide
    var isDone: Bool
    /// Why it's suggested now, e.g. "Safari protection is off".
    var reason: String? = nil
    var isProminent = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: guide.symbol, tint: guide.tint, size: isProminent ? 40 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(guide.title).font(isProminent ? .body.weight(.semibold) : .body)
                if let reason {
                    Text(reason).font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                }
                Text(guide.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
            }
            Spacer(minLength: 0)
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, isProminent ? 4 : 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "")
    }
}

#if DEBUG
#Preview("Guides") {
    NavigationStack {
        GuidesHomeView(context: GuideContext(storage: DeviceStorage(total: 128_000_000_000, available: 3_000_000_000),
                                             device: DeviceInfo(modelIdentifier: "iPhone18,3", systemVersion: [27, 0, 1], isPad: false),
                                             deletedPhotos: true, deletedFiles: false, safariProtectionEnabled: false))
    }
}
#endif
