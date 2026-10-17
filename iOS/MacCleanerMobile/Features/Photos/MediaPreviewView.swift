import AVKit
import os
import Photos
import SwiftUI

/// What the preview shows: the items of one set or section, starting at the one tapped.
struct MediaPreviewContext: Identifiable {
    var items: [MediaItem]
    var keeperIDs: Set<String> = []
    var startID: String

    var id: String { startID }
}

/// A larger look at photos and videos before deciding, swiping between the items of a set.
struct MediaPreviewView: View {
    var model: PhotoCleanupModel
    var context: MediaPreviewContext
    @State private var currentID: String
    @Environment(\.dismiss) private var dismiss

    init(model: PhotoCleanupModel, context: MediaPreviewContext) {
        self.model = model
        self.context = context
        _currentID = State(initialValue: context.startID)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $currentID) {
                ForEach(context.items) { item in
                    MediaPreviewPage(item: item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if let item = context.items.first(where: { $0.id == currentID }) {
                    MediaPreviewInfoBar(item: item, isKeeper: context.keeperIDs.contains(item.id), isSelected: model.isSelected(item)) {
                        model.toggle(item)
                    }
                }
            }
            .navigationTitle(positionText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var positionText: String {
        guard context.items.count > 1, let index = context.items.firstIndex(where: { $0.id == currentID }) else { return "" }
        return "\(NumberFormatting.count(index + 1)) of \(NumberFormatting.count(context.items.count))"
    }
}

/// One photo, or a video that plays when asked.
struct MediaPreviewPage: View {
    var item: MediaItem
    @State private var player: AVPlayer?
    @State private var isLoadingVideo = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    MediaThumbnail(id: item.id, points: max(proxy.size.width, proxy.size.height), contentMode: .fit, allowsNetwork: true)
                    if item.kind == .video {
                        Button {
                            Task { await play() }
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 64))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingVideo)
                        .opacity(isLoadingVideo ? 0 : 1)
                        .accessibilityLabel("Play")
                        if isLoadingVideo { ProgressView().controlSize(.large) }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MediaDescription.label(for: item))
        .onDisappear { player?.pause() }
    }

    private func play() async {
        isLoadingVideo = true
        defer { isLoadingVideo = false }
        guard let asset = MediaImageLoader.shared.asset(for: item.id),
              let playerItem = await MediaPreviewPage.playerItem(for: asset) else { return }
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        player.play()
    }

    /// The video for playback; may stream it from iCloud, since the person asked to watch it.
    private nonisolated static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: playerItem) }
            }
        }
    }
}

/// Date, size and the choice to delete, under the preview.
struct MediaPreviewInfoBar: View {
    var item: MediaItem
    var isKeeper: Bool
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No date")
                        .font(.headline)
                    Text(details).font(.subheadline).foregroundStyle(.secondary)
                    if !flags.isEmpty {
                        Text(flags).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if isKeeper { MediaKeepBadge() }
            }
            Button(action: onToggle) {
                Label(isSelected ? "Selected for Deletion" : "Select for Deletion",
                      systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(isSelected ? .red : .white)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var details: String {
        var parts = [item.size.text]
        if let dimensions = MediaDescription.dimensions(of: item) { parts.append(dimensions) }
        if item.kind == .video { parts.append(MediaDescription.duration(item.duration)) }
        return parts.joined(separator: " · ")
    }

    private var flags: String {
        var parts: [String] = []
        if item.isFavorite { parts.append("Favorite") }
        if item.hasAdjustments { parts.append("Edited") }
        if item.isLivePhoto { parts.append("Live Photo") }
        if item.isScreenshot { parts.append("Screenshot") }
        if item.isScreenRecording { parts.append("Screen recording") }
        return parts.joined(separator: " · ")
    }
}
