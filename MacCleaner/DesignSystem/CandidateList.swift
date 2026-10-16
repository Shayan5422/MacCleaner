import QuickLook
import SwiftUI

/// A category of removable items with an explanation of what removing it means.
struct CandidateGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String
    /// What the data is.
    var explanation: String
    /// What happens if it's removed.
    var consequence: String
    var candidates: [CleanupCandidate]

    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.usage.reclaimableBytes } }
}

/// Selection state for scan results, keyed by candidate id.
@MainActor
@Observable
final class CandidateSelection {
    private(set) var selectedIDs: Set<String> = []

    init() {}

    func reset(to candidates: [CleanupCandidate]) {
        selectedIDs = Set(candidates.filter(\.isSelectedByDefault).map(\.id))
    }

    func isSelected(_ candidate: CleanupCandidate) -> Bool {
        selectedIDs.contains(candidate.id)
    }

    func toggle(_ candidate: CleanupCandidate) {
        if selectedIDs.contains(candidate.id) { selectedIDs.remove(candidate.id) } else { selectedIDs.insert(candidate.id) }
    }

    func set(_ candidates: [CleanupCandidate], selected: Bool) {
        for candidate in candidates {
            if selected { selectedIDs.insert(candidate.id) } else { selectedIDs.remove(candidate.id) }
        }
    }

    func clear() {
        selectedIDs.removeAll()
    }

    /// Tri-state for a group checkbox: true, false, or nil when mixed.
    func state(of candidates: [CleanupCandidate]) -> Bool? {
        let count = candidates.filter { selectedIDs.contains($0.id) }.count
        if count == 0 { return false }
        if count == candidates.count { return true }
        return nil
    }

    func selected(in candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    /// Selected bytes, without counting items nested in other selected items twice.
    func selectedBytes(in candidates: [CleanupCandidate]) -> Int64 {
        let chosen = selected(in: candidates)
        let topLevel = Set(PathUtilities.removingNestedPaths(chosen.map(\.path)))
        var seen = Set<String>()
        return chosen.reduce(0) { total, candidate in
            guard topLevel.contains(candidate.path), seen.insert(candidate.path).inserted else { return total }
            return total + candidate.usage.reclaimableBytes
        }
    }
}

/// Grouped, selectable list of cleanup candidates with explanations,
/// Quick Look, and Finder actions.
struct CandidateGroupsView: View {
    var groups: [CandidateGroup]
    @Bindable var selection: CandidateSelection
    var searchText: String = ""
    var onExclude: ((CleanupCandidate) -> Void)?

    @State private var expanded: Set<String> = []
    @State private var quickLookURL: URL?
    @State private var inspected: CleanupCandidate?

    private var filteredGroups: [CandidateGroup] {
        guard !searchText.isEmpty else { return groups }
        return groups.compactMap { group in
            var copy = group
            copy.candidates = group.candidates.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) || $0.path.localizedCaseInsensitiveContains(searchText)
                    || ($0.detail?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
            return copy.candidates.isEmpty ? nil : copy
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(filteredGroups) { group in
                groupCard(group)
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $inspected) { candidate in
            CandidateContentsSheet(candidate: candidate)
        }
    }

    private func groupCard(_ group: CandidateGroup) -> some View {
        let isExpanded = expanded.contains(group.id) || !searchText.isEmpty
        let state = selection.state(of: group.candidates)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state ?? false },
                    set: { selection.set(group.candidates, selected: $0) }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .overlay {
                    if state == nil {
                        Image(systemName: "minus").font(.system(size: 8, weight: .bold)).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Select all \(group.title)")

                Image(systemName: group.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.headline)
                    Text(group.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text("\(group.candidates.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                SizeText(bytes: group.totalBytes, font: .callout.weight(.semibold))
                    .frame(minWidth: 76, alignment: .trailing)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation { _ = expanded.insert(group.id) }
            }

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(group.consequence).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    LazyVStack(spacing: 0) {
                        ForEach(group.candidates.sorted { $0.usage.reclaimableBytes > $1.usage.reclaimableBytes }) { candidate in
                            CandidateRow(
                                candidate: candidate,
                                isSelected: Binding(get: { selection.isSelected(candidate) }, set: { _ in selection.toggle(candidate) }),
                                onQuickLook: { quickLookURL = candidate.url },
                                onInspect: { inspected = candidate },
                                onExclude: onExclude.map { handler in { handler(candidate) } }
                            )
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.subtleBorder))
    }
}

/// One selectable item in a candidate list.
struct CandidateRow: View {
    var candidate: CleanupCandidate
    @Binding var isSelected: Bool
    var onQuickLook: () -> Void
    var onInspect: () -> Void
    var onExclude: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(candidate.title)")
            if let bundleID = candidate.ownerBundleIdentifier, let icon = IconCache.shared.appIcon(bundleIdentifier: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                FileIcon(path: candidate.path, size: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(candidate.title).lineLimit(1)
                    if candidate.safety != .safe { SafetyBadge(safety: candidate.safety) }
                }
                if let detail = candidate.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                PathText(path: candidate.path, font: .caption2)
            }
            Spacer()
            if isHovering {
                Button(action: onInspect) { Image(systemName: "list.bullet.rectangle") }
                    .buttonStyle(.borderless)
                    .help("Show the largest files inside")
                Button(action: onQuickLook) { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help("Quick Look")
            }
            SizeText(bytes: candidate.usage.reclaimableBytes, font: .callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { isSelected.toggle() }
        .contextMenu {
            FileContextMenu(path: candidate.path, onQuickLook: onQuickLook, onExclude: onExclude)
            Button("Show Contents", systemImage: "list.bullet.rectangle", action: onInspect)
        }
    }
}

/// Lists the largest files inside a candidate folder so people can see exactly what would be removed.
struct CandidateContentsSheet: View {
    let candidate: CleanupCandidate
    @State private var files: [FileRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var quickLookURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                FileIcon(path: candidate.path, size: 32)
                VStack(alignment: .leading) {
                    Text(candidate.title).font(.headline)
                    PathText(path: candidate.path)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    SizeText(bytes: candidate.usage.allocatedBytes, font: .headline)
                    Text("\(NumberFormatting.count(candidate.usage.fileCount, "file"))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if isLoading {
                ProgressView("Listing files…").frame(maxWidth: .infinity, minHeight: 240)
            } else if let errorMessage {
                InfoCallout(style: .warning, message: errorMessage)
            } else if files.isEmpty {
                Text("No files inside.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Table(files) {
                    TableColumn("Name") { file in
                        HStack(spacing: 6) {
                            FileIcon(path: file.path, size: 16)
                            Text(file.name).lineLimit(1)
                        }
                        .contextMenu { FileContextMenu(path: file.path, onQuickLook: { quickLookURL = file.url }) }
                    }
                    TableColumn("Modified") { file in
                        Text(DateFormatting.day(file.modificationDate)).foregroundStyle(.secondary)
                    }
                    .width(110)
                    TableColumn("Size") { file in
                        SizeText(bytes: file.allocatedSize).foregroundStyle(.secondary)
                    }
                    .width(90)
                }
                .frame(minHeight: 300)
                Text(files.count == 200 ? "Showing the 200 largest files." : files.count == 1 ? "Showing 1 file." : "Showing all \(files.count) files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { FinderActions.reveal(candidate.path) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .quickLookPreview($quickLookURL)
        .task {
            do {
                files = try await FileSystemScanner().findFiles(in: [candidate.path], keepLargest: 200) { _, _ in true }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
