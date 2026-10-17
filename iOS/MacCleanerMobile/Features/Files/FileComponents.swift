import SwiftUI
import UniformTypeIdentifiers

/// An icon and a color for each kind of file, from its uniform type.
enum FileTypeStyle {
    static func symbol(for item: FileScanItem) -> String {
        if item.kind == .folder { return "folder.fill" }
        guard let type = item.contentType else { return item.kind == .package ? "shippingbox.fill" : "doc.fill" }
        if type.conforms(to: .image) { return "photo.fill" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film.fill" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext.fill" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .diskImage) { return "externaldrive.fill" }
        if type.conforms(to: .spreadsheet) { return "tablecells.fill" }
        if type.conforms(to: .presentation) { return "play.rectangle.fill" }
        if type.conforms(to: .applicationBundle) { return "app.fill" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return "doc.text.fill" }
        if type.conforms(to: .font) { return "textformat" }
        return item.kind == .package ? "shippingbox.fill" : "doc.fill"
    }

    static func tint(for item: FileScanItem) -> Color {
        if item.kind == .folder { return MobileSection.files.tint }
        guard let type = item.contentType else { return Color(.systemGray) }
        if type.conforms(to: .image) { return MobileSection.photos.tint }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return MobileSection.videos.tint }
        if type.conforms(to: .audio) { return .orange }
        if type.conforms(to: .pdf) { return .red }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .brown }
        if type.conforms(to: .spreadsheet) { return .green }
        if type.conforms(to: .presentation) { return .orange }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .blue }
        return Color(.systemGray)
    }
}

/// A file or folder in a result list: a selection circle, its icon, name, size, date and folder, and a Quick Look button.
struct FileItemRow: View {
    var item: FileScanItem
    var isSelected: Bool
    /// A capsule after the name, such as "Kept".
    var badge: String?
    var toggle: () -> Void
    /// Nil for folders, which Quick Look can't show.
    var preview: (() -> Void)?
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // With large text the details wrap instead of being cut off, and the icon stops growing.
        let isLarge = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.red : Color(.tertiaryLabel))
                        .contentTransition(.symbolEffect(.replace))
                    IconTile(symbol: FileTypeStyle.symbol(for: item), tint: FileTypeStyle.tint(for: item), size: min(iconSize, 48))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.body).foregroundStyle(.primary).lineLimit(isLarge ? 3 : 2).truncationMode(.middle)
                            if let badge { FileBadge(title: badge) }
                        }
                        Text(details).font(.subheadline).foregroundStyle(.secondary).lineLimit(isLarge ? nil : 1)
                        if !item.location.isEmpty {
                            Text(item.location).font(.caption).foregroundStyle(.tertiary).lineLimit(isLarge ? 2 : 1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let preview {
                Button(action: preview) {
                    Image(systemName: "eye").font(.body).frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preview \(item.name)")
            }
        }
        .contextMenu {
            Button(action: toggle) {
                Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "circle" : "checkmark.circle")
            }
            if let preview {
                Button(action: preview) { Label("Quick Look", systemImage: "eye") }
            }
        }
    }

    private var details: String {
        let date = item.modificationDate.map(DateFormatting.day)
        let size = item.kind == .folder ? "Empty folder" : ByteFormatting.string(item.size)
        return [size, date].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A small capsule such as "Kept".
struct FileBadge: View {
    var title: String
    var tint: Color = MobileSection.files.tint

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A done message at the top of a list, with a button to dismiss it.
struct FileNoticeView: View {
    var notice: FileNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.subheadline.weight(.semibold))
                Text(notice.message).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 2)
    }
}

/// The button at the bottom of a list that deletes the selection: "Delete 3 Files · 2.1 GB".
struct FileActionBar: View {
    var title: String
    var isBusy: Bool
    var action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(.white) }
                Text(title).font(.headline).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(isBusy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Asks before deleting items permanently that couldn't be moved to Recently Deleted.
struct FilePermanentDeletionPrompt: ViewModifier {
    var model: FileCleanupModel

    func body(content: Content) -> some View {
        let items = model.pendingPermanentDeletion
        let count = FileCleanupModel.count(items.count, of: items)
        // `presenting` hands the items to the button: dismissing the dialog clears the pending list first.
        content.confirmationDialog(
            "Delete \(count) permanently?",
            isPresented: Binding(get: { !model.pendingPermanentDeletion.isEmpty }, set: { if !$0 { model.keepPendingItems() } }),
            titleVisibility: .visible,
            presenting: items
        ) { items in
            Button("Delete Permanently", role: .destructive) {
                Task { await model.deletePermanently(items) }
            }
            Button("Keep", role: .cancel) {}
        } message: { items in
            let note = model.pendingNote.map { " \($0)" } ?? ""
            Text("\(items.count == 1 ? "It's" : "They're") in a location without Recently Deleted, so \(items.count == 1 ? "it" : "they") can't be moved there. Deleting permanently can't be undone.\(note)")
        }
    }
}

/// Shows the model's error message from whichever Files page is on screen, so it's never hidden behind another page.
struct FileErrorAlert: ViewModifier {
    var model: FileCleanupModel
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .alert("Couldn't Finish",
                   isPresented: Binding(get: { isOnScreen && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}
