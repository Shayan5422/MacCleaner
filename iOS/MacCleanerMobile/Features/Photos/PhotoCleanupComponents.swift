import SwiftUI
import UIKit

/// The round check of a selectable thumbnail or row.
struct MediaSelectionMark: View {
    enum Style {
        /// On top of a photo: white ring, darkened inside.
        case overlay
        /// On a plain background, like a list in edit mode.
        case plain
    }

    var isSelected: Bool
    var style: Style = .overlay
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.white)
            } else if style == .overlay {
                Circle().fill(Color.black.opacity(0.18))
            }
            if style == .overlay || !isSelected {
                Circle().strokeBorder(style == .overlay ? Color.white : Color(.tertiaryLabel), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: style == .overlay ? .black.opacity(0.3) : .clear, radius: 1.5, y: 0.5)
        .accessibilityHidden(true)
    }
}

/// Marks the photo of a group that stays.
struct MediaKeepBadge: View {
    var body: some View {
        Text("Keep")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(red: 0.16, green: 0.62, blue: 0.33), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .accessibilityLabel("Suggested to keep")
    }
}

/// A thumbnail in a grid: a tap opens the preview, the check in the corner selects it.
struct MediaGridCell: View {
    var item: MediaItem
    var isSelected: Bool
    var isKeeper = false
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            MediaSquareThumbnail(id: item.id)
                .overlay {
                    if isSelected { Color.black.opacity(0.2) }
                }
                .overlay(alignment: .topLeading) {
                    if isKeeper { MediaKeepBadge().padding(6) }
                }
                .overlay(alignment: .bottomLeading) { badges.padding(6) }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            Button(action: onToggle) {
                MediaSelectionMark(isSelected: isSelected)
                    .padding(6)
                    .frame(minWidth: 44, minHeight: 44, alignment: .bottomTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MediaDescription.label(for: item))
        .accessibilityValue(isSelected ? "Selected for deletion" : isKeeper ? "Kept" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens a larger preview.")
        .accessibilityAction(.default, onOpen)
        .accessibilityAction(named: isSelected ? "Deselect" : "Select for Deletion", onToggle)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if item.isFavorite {
                Image(systemName: "heart.fill").font(.caption2.weight(.bold))
            }
            if item.kind == .video {
                Text(MediaDescription.duration(item.duration)).font(.caption2.weight(.semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}

/// Words for an item: for VoiceOver, rows and the preview.
enum MediaDescription {
    static func label(for item: MediaItem) -> String {
        var parts = [item.kind == .video ? (item.isScreenRecording ? "Screen recording" : "Video")
                                         : (item.isScreenshot ? "Screenshot" : "Photo")]
        if let date = item.creationDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if item.kind == .video { parts.append(spokenDuration(item.duration)) }
        parts.append(item.size.text)
        if item.isFavorite { parts.append("Favorite") }
        if item.hasAdjustments { parts.append("Edited") }
        return parts.joined(separator: ", ")
    }

    /// "0:42", "1:05:09".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(1, seconds.rounded())) ?? duration(seconds)
    }

    /// "4032 × 3024".
    static func dimensions(of item: MediaItem) -> String? {
        item.pixelWidth > 0 && item.pixelHeight > 0 ? "\(item.pixelWidth) × \(item.pixelHeight)" : nil
    }

    /// A video's resolution the way the Camera settings name it: "4K", "1080p", "720p".
    static func resolution(of item: MediaItem) -> String? {
        let shortSide = min(item.pixelWidth, item.pixelHeight)
        switch shortSide {
        case ..<1: return nil
        case 2160...: return "4K"
        case 1080...: return "1080p"
        case 720...: return "720p"
        default: return "\(shortSide)p"
        }
    }

    /// "iPhone" or "iPad", for sentences.
    @MainActor
    static var deviceWord: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

/// The bar at the bottom of a screen that deletes what's selected there.
struct MediaDeleteBar: View {
    var count: Int
    var noun: String
    var size: MediaByteTotal
    var isDeleting: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(role: .destructive, action: action) {
                ZStack {
                    // Keeps the button's height while the spinner shows.
                    Text(title).opacity(isDeleting ? 0 : 1)
                    if isDeleting { ProgressView() }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(count == 0 || isDeleting)
            .accessibilityLabel(count == 0 ? "Delete" : "Delete \(NumberFormatting.count(count, noun)), \(size.text)")
            Text(count == 0 ? "Select what you want to delete." : "iOS asks you to confirm. Deleted items stay in Recently Deleted for \(PhotosRecentlyDeleted.days) days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        // Like the system's bars, it stops growing at the first accessibility size so it can't cover the photos.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var title: String {
        count == 0 ? "Delete" : "Delete \(NumberFormatting.count(count, noun)) · \(size.text)"
    }
}

/// Shown after a deletion: where the items went and how to free the space now.
struct MediaDeletionBanner: View {
    var report: PhotoCleanupModel.DeletionReport
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.title).font(.subheadline.weight(.semibold))
                Text(report.message).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Up to four thumbnails in a row, for a category's card.
struct MediaThumbnailStrip: View {
    var ids: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { index in
                if index < ids.count {
                    MediaSquareThumbnail(id: ids[index], points: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
