import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Thumbnails

/// Small in-memory cache of Quick Look thumbnails.
@MainActor
final class DuplicateThumbnailCache {
    static let shared = DuplicateThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 800
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

enum DuplicateThumbnailLoader {
    /// A Quick Look thumbnail of the file, or nil when there is none. Cloud-only files are
    /// skipped: generating their thumbnail would download them.
    static func load(path: String, side: CGFloat, scale: CGFloat) async -> CGImage? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_flags & FileFlags.dataless == 0 else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}

/// Quick Look thumbnail of a file, with its Finder icon as a placeholder. Size it with `.frame`.
struct DuplicateThumbnail: View {
    var path: String
    /// Longest side requested from Quick Look, in points.
    var side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                FileIcon(path: path, size: min(side, 72) * 0.8)
            }
        }
        .task(id: cacheKey) { await load() }
        .accessibilityHidden(true)
    }

    private var cacheKey: String { "\(path)#\(Int(side))@\(displayScale)" }

    private func load() async {
        let key = cacheKey
        if let cached = DuplicateThumbnailCache.shared.image(forKey: key) {
            image = cached
            return
        }
        image = nil
        let scale = displayScale
        guard let cgImage = await DuplicateThumbnailLoader.load(path: path, side: side, scale: scale), !Task.isCancelled else { return }
        let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        DuplicateThumbnailCache.shared.store(thumbnail, forKey: key)
        image = thumbnail
    }
}

// MARK: - Split layout

/// A list beside a detail view, separated by a draggable divider.
///
/// Pure SwiftUI on purpose: `HSplitView` hands its panes' ideal sizes (for example
/// the full height of a scroll view's content) to AppKit as minimum sizes, which
/// can force the window to grow far beyond the screen.
struct DuplicateSplitView<ListContent: View, DetailContent: View>: View {
    @Binding var listWidth: CGFloat
    var minimumListWidth: CGFloat = 240
    var maximumListWidth: CGFloat = 420
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> DetailContent

    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringDivider = false

    var body: some View {
        HStack(spacing: 0) {
            list()
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
            divider
            detail()
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != isHoveringDivider else { return }
                        isHoveringDivider = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? listWidth
                                dragStartWidth = start
                                listWidth = min(max(start + value.translation.width, minimumListWidth), maximumListWidth)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
            .onDisappear {
                if isHoveringDivider {
                    isHoveringDivider = false
                    NSCursor.pop()
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Progress

/// Horizontal list of pipeline stages with the current one highlighted.
struct DuplicateStageTracker: View {
    var titles: [String]
    var currentIndex: Int
    var tint: Color = AppSection.duplicates.tint

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 8) {
                        marker(index)
                        Text(title)
                            .font(.callout.weight(index == currentIndex ? .semibold : .regular))
                            .foregroundStyle(index <= currentIndex ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if index < titles.count - 1 {
                        Capsule()
                            .fill(index < currentIndex ? tint : Color.primary.opacity(0.12))
                            .frame(minWidth: 14, maxWidth: .infinity, minHeight: 2, maxHeight: 2)
                            .padding(.horizontal, 8)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { index in marker(index) }
                Text(titles[min(max(currentIndex, 0), titles.count - 1)])
                    .font(.callout.weight(.semibold))
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentIndex + 1) of \(titles.count): \(titles[min(max(currentIndex, 0), titles.count - 1)])")
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        ZStack {
            if index < currentIndex {
                Circle().fill(tint)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            } else if index == currentIndex {
                Circle().strokeBorder(tint, lineWidth: 2)
                Circle().fill(tint).padding(5)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Notes and notices

/// A compact, clickable note about the scan with details in a popover.
struct DuplicateNoteChip<Details: View>: View {
    var symbol: String
    var text: String
    var tint: Color
    @ViewBuilder var details: () -> Details
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).imageScale(.small)
                Text(text)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show details")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                details()
            }
            .font(.callout)
            .padding(16)
            .frame(width: 360, alignment: .leading)
        }
    }
}

/// Floating, dismissible message shown after an action.
struct DuplicateNoticeToast: View {
    var notice: DuplicateNotice
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.style.symbol)
                .foregroundStyle(notice.style.tint)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(notice.style.tint.opacity(0.25)))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Shows the model's current notice as a toast at the bottom of the view and
    /// announces it to VoiceOver.
    func duplicateNotices(_ model: DuplicatesViewModel) -> some View {
        overlay(alignment: .bottom) {
            if let notice = model.notice {
                DuplicateNoticeToast(notice: notice) { model.dismissNotice() }
                    .id(notice.id)
            }
        }
        .animation(.spring(duration: 0.3), value: model.notice)
        .onChange(of: model.notice) { _, notice in
            if let notice {
                AccessibilityNotification.Announcement(notice.message).post()
            }
        }
    }
}

// MARK: - File details

/// A labeled value in a file card ("Modified", "Created", …).
struct DuplicateMetadataItem: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Places views in rows, wrapping to a new row when the next view doesn't fit,
/// so rows of badges never force their container wider than the window.
struct DuplicateFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, maxWidth: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            let originX = x == 0 ? 0 : x + spacing
            frames.append(CGRect(x: originX, y: y, width: size.width, height: size.height))
            x = originX + size.width
            lineHeight = max(lineHeight, size.height)
            width = max(width, x)
        }
        return (frames, CGSize(width: width, height: y + lineHeight))
    }
}

/// Status and characteristics of one copy, as badges that wrap when space is short.
struct DuplicateFileBadges: View {
    var file: DuplicateFile
    var isMarked: Bool
    var isSuggestedKeeper: Bool
    var keepRuleTitle: String?

    var body: some View {
        DuplicateFlowLayout {
            if isMarked {
                Badge(text: "Moving to Trash", symbol: "trash.fill", tint: .red)
            } else if file.isProtected {
                Badge(text: "Protected", symbol: "lock.fill", tint: .orange)
                    .help(file.protectionReason ?? "")
            } else {
                Badge(text: "Keeping", symbol: "checkmark.circle.fill", tint: .green)
            }
            if isSuggestedKeeper, let keepRuleTitle {
                Badge(text: "Suggested: \(keepRuleTitle)", symbol: "star.fill", tint: AppSection.duplicates.tint)
                    .help("The copy your keep rule selects to keep.")
            }
            if let library = file.managedLibraryName {
                Badge(text: "In \(library) library", symbol: "music.note.house.fill", tint: .purple)
                    .help("Removing it leaves a missing item in \(library). It's never selected automatically.")
            }
            if file.isHardLinked {
                Badge(text: "Hard link", symbol: "link", tint: .blue)
                    .help("This file has \(file.linkCount) names. Removing one name frees no space while the others remain.")
            }
            if file.sharedCloneBytes > 0 {
                Badge(text: "APFS clone", symbol: "square.on.square.dashed", tint: .teal)
                    .help("Shares storage with a copy made by the Finder. Removing it frees little space.")
            }
            if let volume = file.volumeName {
                Badge(text: volume, symbol: "externaldrive.fill", tint: .gray)
            }
        }
    }
}

extension DuplicateFile {
    /// What removing this copy alone frees, for display.
    var freedSpaceDescription: String {
        if isHardLinked { return "Nothing (hard link)" }
        if isMostlySharedClone {
            return exclusiveSize > 0 ? "\(ByteFormatting.string(exclusiveSize)) (APFS clone)" : "Little (APFS clone)"
        }
        return ByteFormatting.string(exclusiveSize)
    }

    /// Longer explanation of `freedSpaceDescription`, for help tags and accessibility.
    var freedSpaceExplanation: String {
        if isHardLinked {
            return "This file has other names (hard links). Removing this name frees no space while another name still points to the data."
        }
        if isMostlySharedClone {
            return "APFS clone — removing frees little space, because its data is shared with another copy until every clone is removed."
        }
        return "Moving this copy to the Trash frees \(ByteFormatting.string(exclusiveSize)) once the Trash is emptied."
    }
}

/// Modified, created, size and freed space of a copy: one row when there is room, two otherwise.
struct DuplicateFileMetadata: View {
    var file: DuplicateFile

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                modified
                created
                size
                frees
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    modified
                    created
                }
                GridRow {
                    size
                    frees
                }
            }
        }
    }

    private var modified: some View {
        DuplicateMetadataItem(label: "Modified", value: DateFormatting.short(file.modificationDate))
    }

    @ViewBuilder
    private var created: some View {
        if let created = file.creationDate {
            DuplicateMetadataItem(label: "Created", value: DateFormatting.short(created))
        } else {
            DuplicateMetadataItem(label: "Created", value: "Unknown")
        }
    }

    private var size: some View {
        DuplicateMetadataItem(label: "Size", value: ByteFormatting.string(file.logicalSize))
            .help("\(ByteFormatting.string(file.allocatedSize)) on disk")
    }

    private var frees: some View {
        DuplicateMetadataItem(label: "Frees", value: file.freedSpaceDescription)
            .help(file.freedSpaceExplanation)
    }
}
