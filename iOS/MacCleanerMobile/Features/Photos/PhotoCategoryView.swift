import SwiftUI

/// The photos of one category, to review and delete.
struct PhotoCategoryView: View {
    var model: PhotoCleanupModel
    var category: PhotoCategory
    @State private var preview: MediaPreviewContext?

    var body: some View {
        let items = model.result?.items(in: category) ?? []
        let selected = model.selected(in: items)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(category.explanation)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let report = model.lastDeletion {
                        MediaDeletionBanner(report: report) { model.dismissDeletionReport() }
                    }
                    if let message = model.errorMessage {
                        PhotoErrorCard(message: message) { model.errorMessage = nil }
                    }
                }
                if items.isEmpty {
                    EmptyStateView(symbol: "checkmark.circle", title: "All clear", message: "Nothing is left in \(category.title).")
                } else if category.isGrouped {
                    ForEach(model.result?.groups(in: category) ?? []) { group in
                        MediaGroupSection(group: group, category: category, model: model) { item in
                            preview = MediaPreviewContext(items: group.items, keeperIDs: group.keeperIDs, startID: item.id)
                        }
                    }
                } else {
                    ForEach(MediaMonthSection.sections(of: items)) { section in
                        MediaMonthSectionView(section: section, model: model) { item in
                            preview = MediaPreviewContext(items: section.items, startID: item.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .navigationTitle(category.title)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { selectionButton(items) }
            }
        }
        // The delete bar takes the bottom of the screen.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty {
                MediaDeleteBar(count: selected.count, noun: category.itemNoun, size: MediaByteTotal(selected), isDeleting: model.isDeleting) {
                    Task { await model.delete(selected) }
                }
            }
        }
        .sheet(item: $preview) { context in
            MediaPreviewView(model: model, context: context)
        }
        .task { MediaImageLoader.shared.prefetch(items.map(\.id)) }
    }

    @ViewBuilder
    private func selectionButton(_ items: [MediaItem]) -> some View {
        if category.isGrouped {
            let anySelected = items.contains(where: model.isSelected)
            Button(anySelected ? "Deselect All" : "Select Suggested") {
                if anySelected {
                    model.setSelected(items, false)
                } else {
                    let groups = model.result?.groups(in: category) ?? []
                    model.setSelected(groups.flatMap(\.extras).filter { !$0.isFavorite }, true)
                }
            }
        } else {
            let allSelected = items.allSatisfy(model.isSelected)
            Button(allSelected ? "Deselect All" : "Select All") {
                model.setSelected(items, !allSelected)
            }
        }
    }
}

/// One set of duplicates, similar shots or burst frames, with the kept photo marked.
struct MediaGroupSection: View {
    var group: MediaGroup
    var category: PhotoCategory
    var model: PhotoCleanupModel
    var onOpen: (MediaItem) -> Void

    var body: some View {
        let anySelected = group.items.contains(where: model.isSelected)
        VStack(alignment: .leading, spacing: 10) {
            MediaSectionHeader(title: title, subtitle: group.date.map(DateFormatting.day),
                               actionTitle: anySelected ? "Keep All" : "Select Others") {
                if anySelected {
                    model.setSelected(group.items, false)
                } else {
                    // Favorites only when there's nothing else to select.
                    let others = group.extras.filter { !$0.isFavorite }
                    model.setSelected(others.isEmpty ? group.extras : others, true)
                }
            }
            MediaGrid(items: group.items, keeperIDs: group.keeperIDs, model: model, onOpen: onOpen)
        }
    }

    private var title: String {
        switch category {
        case .duplicates: return NumberFormatting.count(group.items.count, "copy", plural: "copies")
        case .bursts: return "Burst of \(NumberFormatting.count(group.items.count, "photo"))"
        default: return NumberFormatting.count(group.items.count, "similar shot")
        }
    }
}

/// Screenshots by month.
struct MediaMonthSection: Identifiable {
    var id: String
    var title: String
    var items: [MediaItem]

    /// Consecutive items of the same month; `items` should be sorted by date.
    static func sections(of items: [MediaItem], calendar: Calendar = .current) -> [MediaMonthSection] {
        var sections: [MediaMonthSection] = []
        for item in items {
            let start = item.creationDate.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
            let id = start.map { "\(Int($0.timeIntervalSince1970))" } ?? "undated"
            if sections.last?.id == id {
                sections[sections.count - 1].items.append(item)
            } else {
                let title = start?.formatted(.dateTime.month(.wide).year()) ?? "No Date"
                sections.append(MediaMonthSection(id: sections.contains { $0.id == id } ? "\(id)-\(sections.count)" : id,
                                                  title: title, items: [item]))
            }
        }
        return sections
    }
}

struct MediaMonthSectionView: View {
    var section: MediaMonthSection
    var model: PhotoCleanupModel
    var onOpen: (MediaItem) -> Void

    var body: some View {
        let allSelected = section.items.allSatisfy(model.isSelected)
        VStack(alignment: .leading, spacing: 10) {
            MediaSectionHeader(title: section.title, subtitle: NumberFormatting.count(section.items.count, "screenshot"),
                               actionTitle: allSelected ? "Deselect All" : "Select All") {
                model.setSelected(section.items, !allSelected)
            }
            MediaGrid(items: section.items, model: model, onOpen: onOpen)
        }
    }
}

/// A section's title and subtitle with a selection button: side by side when they fit, otherwise
/// (large text, long titles) the button goes under the title.
struct MediaSectionHeader: View {
    var title: String
    var subtitle: String?
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titles
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 6) {
                titles
                button
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var button: some View {
        Button(actionTitle, action: action)
            .font(.subheadline.weight(.semibold))
    }
}

/// Thumbnails in rows, as many columns as fit (three on an iPhone).
struct MediaGrid: View {
    var items: [MediaItem]
    var keeperIDs: Set<String> = []
    var model: PhotoCleanupModel
    var onOpen: (MediaItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 220), spacing: 3)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(items) { item in
                MediaGridCell(item: item, isSelected: model.isSelected(item), isKeeper: keeperIDs.contains(item.id),
                              onToggle: { model.toggle(item) }, onOpen: { onOpen(item) })
            }
        }
    }
}
