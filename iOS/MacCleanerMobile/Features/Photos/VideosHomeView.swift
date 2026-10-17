import SwiftUI

/// Videos: large videos and screen recordings, biggest first, to review and delete.
struct VideosHomeView: View {
    var model: PhotoCleanupModel
    @State private var preview: MediaPreviewContext?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let result = model.result, model.access.canRead, !model.isScanning {
                VideoResultsList(model: model, result: result) { items, item in
                    preview = MediaPreviewContext(items: items, startID: item.id)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let message = model.errorMessage {
                            PhotoErrorCard(message: message) { model.errorMessage = nil }
                        }
                        if let progress = model.progress {
                            PhotoScanningCard(progress: progress) { model.cancelScan() }
                        } else {
                            PhotoAccessCard(model: model, section: .videos)
                        }
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Videos")
        // The delete bar takes the bottom of the screen.
        .toolbar(.hidden, for: .tabBar)
        .onAppear { model.screenAppeared() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAccess() }
        }
        .sheet(item: $preview) { context in
            MediaPreviewView(model: model, context: context)
        }
    }
}

/// The scan's videos in sections, with the delete bar.
struct VideoResultsList: View {
    var model: PhotoCleanupModel
    var result: PhotoScanResult
    var onOpen: ([MediaItem], MediaItem) -> Void

    var body: some View {
        let shown = result.largeVideos + result.screenRecordings + result.otherVideos
        let selected = model.selected(in: shown)
        List {
            Section {
                VideoSummaryRow(result: result) { model.startScan() }
            }
            if let report = model.lastDeletion {
                Section {
                    MediaDeletionBanner(report: report) { model.dismissDeletionReport() }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if let message = model.errorMessage {
                Section {
                    PhotoErrorCard(message: message) { model.errorMessage = nil }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if result.isLimited {
                Section {
                    PhotoLimitedNotice(tint: MobileSection.videos.tint)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            section(title: "Large Videos", items: result.largeVideos,
                    footer: "Videos of 100 MB or more, biggest first.", empty: "No videos of 100 MB or more.")
            section(title: "Screen Recordings", items: result.screenRecordings,
                    footer: "Recordings of your screen, biggest first.", empty: "No screen recordings.")
            if !result.otherVideos.isEmpty {
                section(title: "Other Videos", items: result.otherVideos,
                        footer: "Your next-biggest videos, under 100 MB. They aren't counted in what can be freed.", empty: nil)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !shown.isEmpty {
                MediaDeleteBar(count: selected.count, noun: "video", size: MediaByteTotal(selected), isDeleting: model.isDeleting) {
                    Task { await model.delete(selected) }
                }
            }
        }
        .task { MediaImageLoader.shared.prefetch(shown.map(\.id)) }
    }

    @ViewBuilder
    private func section(title: String, items: [MediaItem], footer: String, empty: String?) -> some View {
        Section {
            if items.isEmpty, let empty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VideoRow(item: item, isSelected: model.isSelected(item),
                         onToggle: { model.toggle(item) }, onOpen: { onOpen(items, item) })
            }
        } header: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer()
                    selectionButton(items)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    selectionButton(items)
                }
            }
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private func selectionButton(_ items: [MediaItem]) -> some View {
        if !items.isEmpty {
            let allSelected = items.allSatisfy(model.isSelected)
            Button(allSelected ? "Deselect All" : "Select All") {
                model.setSelected(items, !allSelected)
            }
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
        }
    }
}

/// What the scan found in videos, and a way to scan again.
struct VideoSummaryRow: View {
    var result: PhotoScanResult
    var onScan: () -> Void

    var body: some View {
        let total = result.videoReclaimable
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(section: .videos, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    if total.bytes > 0 {
                        Text(total.text).font(.title3.weight(.bold)).monospacedDigit()
                        Text("in large videos and screen recordings").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("No large videos").font(.title3.weight(.bold))
                        Text("Nothing of 100 MB or more, and no screen recordings.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Text("Checked \(NumberFormatting.count(result.videoCount, "video")) · Scanned \(DateFormatting.relative(result.date))")
                .font(.footnote).foregroundStyle(.secondary)
            Button(action: onScan) {
                Label("Scan Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    // In a list the icon would take the app's accent instead of the button's tint.
                    .foregroundStyle(MobileSection.videos.tint)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(MobileSection.videos.tint)
        }
        .padding(.vertical, 6)
    }
}

/// A video: thumbnail with its length, size and date. A tap opens it, the circle selects it.
struct VideoRow: View {
    var item: MediaItem
    var isSelected: Bool
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                MediaSelectionMark(isSelected: isSelected, style: .plain)
                    .frame(minWidth: 28, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    MediaThumbnail(id: item.id, points: 72)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Text(MediaDescription.duration(item.duration))
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(4)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.size.text).font(.headline).monospacedDigit()
                        Text(details).font(.subheadline).foregroundStyle(.secondary)
                        if item.isFavorite {
                            Label("Favorite", systemImage: "heart.fill")
                                .font(.footnote).foregroundStyle(.pink)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // Button labels center wrapped lines otherwise.
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MediaDescription.label(for: item))
        .accessibilityValue(isSelected ? "Selected for deletion" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the video.")
        .accessibilityAction(.default, onOpen)
        .accessibilityAction(named: isSelected ? "Deselect" : "Select for Deletion", onToggle)
    }

    private var details: String {
        var parts: [String] = []
        if let date = item.creationDate { parts.append(DateFormatting.day(date)) }
        parts.append(MediaDescription.duration(item.duration))
        if let resolution = MediaDescription.resolution(of: item) { parts.append(resolution) }
        return parts.joined(separator: " · ")
    }
}
