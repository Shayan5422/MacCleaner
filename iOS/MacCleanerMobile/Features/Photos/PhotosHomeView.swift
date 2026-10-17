import SwiftUI

/// Photos: access, the scan and what it found, one card per category.
struct PhotosHomeView: View {
    var model: PhotoCleanupModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.errorMessage {
                    PhotoErrorCard(message: message) { model.errorMessage = nil }
                }
                if let result = model.result, model.access.canRead, !model.isScanning {
                    results(result)
                } else if let progress = model.progress {
                    PhotoScanningCard(progress: progress) { model.cancelScan() }
                } else {
                    PhotoAccessCard(model: model, section: .photos)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Photos")
        .onAppear { model.screenAppeared() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAccess() }
        }
    }

    @ViewBuilder
    private func results(_ result: PhotoScanResult) -> some View {
        PhotoSummaryCard(result: result) { model.startScan() }
        if result.isLimited { PhotoLimitedNotice(tint: MobileSection.photos.tint) }
        if let report = model.lastDeletion {
            MediaDeletionBanner(report: report) { model.dismissDeletionReport() }
        }
        ForEach(PhotoCategory.photoCategories) { category in
            if result.candidates(in: category).isEmpty {
                PhotoCategoryRow(category: category, result: result)
            } else {
                NavigationLink { PhotoCategoryView(model: model, category: category) } label: {
                    PhotoCategoryRow(category: category, result: result)
                }
                .buttonStyle(.plain)
            }
        }
        NavigationLink { VideosHomeView(model: model) } label: {
            PhotoVideosRow(result: result)
        }
        .buttonStyle(.plain)
        if result.uncomparedCount > 0 {
            Text(uncomparedText(result.uncomparedCount))
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func uncomparedText(_ count: Int) -> String {
        let device = MediaDescription.deviceWord
        return count == 1
            ? "1 photo couldn't be compared: there's no copy of it on this \(device), and nothing is downloaded from iCloud to check it."
            : "\(NumberFormatting.count(count, "photo")) couldn't be compared: there's no copy of them on this \(device), and nothing is downloaded from iCloud to check them."
    }
}

/// What the last scan found in photos, and a way to scan again.
struct PhotoSummaryCard: View {
    var result: PhotoScanResult
    var onScan: () -> Void

    var body: some View {
        let total = result.photoReclaimable
        Card {
            HStack(spacing: 14) {
                IconTile(section: .photos, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    if total.bytes > 0 {
                        Text(total.text).font(.title2.weight(.bold)).monospacedDigit()
                        Text("can be freed in your photos").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing to clean up").font(.title3.weight(.bold))
                        Text("No duplicates, similar shots, screenshots or extra burst frames.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Text("\(checkedText) · Scanned \(DateFormatting.relative(result.date))")
                .font(.footnote).foregroundStyle(.secondary)
            Button(action: onScan) {
                Label("Scan Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(MobileSection.photos.tint)
        }
    }

    private var checkedText: String {
        let photos = NumberFormatting.count(result.photoCount, "photo")
        let what = result.videoCount > 0 ? "\(photos) and \(NumberFormatting.count(result.videoCount, "video"))" : photos
        return result.isLimited ? "Checked the \(what) you shared" : "Checked \(what)"
    }
}

/// One category on the Photos screen: what it holds, the space it frees and a few thumbnails.
struct PhotoCategoryRow: View {
    var category: PhotoCategory
    var result: PhotoScanResult

    var body: some View {
        let candidates = result.candidates(in: category)
        Card {
            MediaRowLabel(icon: IconTile(symbol: category.symbol, tint: category.tint, size: 40), title: category.title,
                          detail: candidates.isEmpty ? "None found"
                                                     : category.detailText(candidates: candidates.count, groups: result.groups(in: category).count),
                          size: candidates.isEmpty ? nil : MediaByteTotal(candidates).text,
                          showsChevron: !candidates.isEmpty)
            if !candidates.isEmpty {
                MediaThumbnailStrip(ids: result.items(in: category).prefix(4).map(\.id))
            }
        }
        .contentShape(Rectangle())
    }
}

/// The way from Photos to Videos.
struct PhotoVideosRow: View {
    var result: PhotoScanResult

    var body: some View {
        let total = result.videoReclaimable
        Card {
            MediaRowLabel(icon: IconTile(section: .videos, size: 40), title: "Videos", detail: detail,
                          size: total.bytes > 0 ? total.text : nil, showsChevron: true)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        let large = result.largeVideos.count, recordings = result.screenRecordings.count
        switch (large, recordings) {
        case (0, 0): return "No large videos or screen recordings"
        case (_, 0): return NumberFormatting.count(large, "large video")
        case (0, _): return NumberFormatting.count(recordings, "screen recording")
        default: return "\(NumberFormatting.count(large, "large video")) and \(NumberFormatting.count(recordings, "screen recording"))"
        }
    }
}

/// Icon, title, detail and size side by side; stacked at accessibility text sizes, so a long word
/// like "Screenshots" isn't cut off.
struct MediaRowLabel: View {
    var icon: IconTile
    var title: String
    var detail: String
    var size: String?
    var showsChevron: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        if let size {
                            Text(size).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let size {
                        Text(size).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        // Button and link labels would center wrapped lines otherwise.
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }
}
