import SwiftUI

/// The Clean tab: one row per kind of clutter the app can remove itself.
struct CleanHomeView: View {
    var model: AppModel

    var body: some View {
        List {
            Section {
                NavigationLink { PhotosHomeView(model: model.photos) } label: {
                    CleanRow(section: .photos, summary: model.photos.summary ?? "Duplicates, similar photos, screenshots and bursts")
                }
                NavigationLink { VideosHomeView(model: model.photos) } label: {
                    CleanRow(section: .videos, summary: model.photos.videoReclaimableBytes.map { "\(ByteFormatting.string($0)) in large videos" }
                             ?? "Large videos and screen recordings")
                }
                NavigationLink { ContactsHomeView(model: model.contacts) } label: {
                    CleanRow(section: .contacts, summary: model.contacts.summary ?? "Duplicate and incomplete contacts")
                }
                NavigationLink { FilesHomeView(model: model.files) } label: {
                    CleanRow(section: .files, summary: model.files.summary ?? "Large, old and duplicate files in folders you choose")
                }
            } footer: {
                Text("iOS keeps every app in its own sandbox, so no app can clear system data or other apps' caches. For those, the Guides tab shows you the fastest way in Settings.")
            }
        }
        .navigationTitle("Clean")
    }
}

struct CleanRow: View {
    var section: MobileSection
    var summary: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(section: section, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
