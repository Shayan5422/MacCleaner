import SwiftUI

/// The Clean tab: one row per kind of clutter the app can remove itself.
struct CleanHomeView: View {
    var model: AppModel
    /// A screen opened by `-debugOpen` (DEBUG builds only).
    @State private var opened: MobileSection? = DebugLaunch.openSection

    var body: some View {
        List {
            Section {
                NavigationLink { PhotosHomeView(model: model.photos) } label: {
                    CleanRow(section: .photos, summary: model.photos.summary ?? "Duplicates, similar photos, screenshots and bursts")
                }
                NavigationLink { VideosHomeView(model: model.photos) } label: {
                    CleanRow(section: .videos, summary: model.photos.videoReclaimableBytes.map { "\(ByteFormatting.string($0)) in large videos and screen recordings" }
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
        .navigationDestination(item: $opened) { section in
            switch section {
            case .photos: PhotosHomeView(model: model.photos)
            case .videos: VideosHomeView(model: model.photos)
            case .contacts: ContactsHomeView(model: model.contacts)
            default: FilesHomeView(model: model.files)
            }
        }
        .task {
            #if DEBUG
            switch DebugLaunch.openSection {
            case .photos?, .videos?: model.photos.startScan()
            case .contacts?:
                // Not tied to this view: it disappears (and its task is cancelled) when the screen opens.
                let contacts = model.contacts
                Task {
                    contacts.refreshAccess()
                    await contacts.scan()
                }
            case .files?:
                await model.files.prepare()
                model.files.scan()
            default: break
            }
            #endif
        }
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
