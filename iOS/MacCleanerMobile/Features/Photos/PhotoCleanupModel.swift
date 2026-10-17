import Observation
import SwiftUI

/// The photo library cleanup (photos and videos). Placeholder until the Photos module lands.
@MainActor
@Observable
final class PhotoCleanupModel {
    /// What the last scan found that could be freed in photos, or nil before the first scan.
    var photoReclaimableBytes: Int64? { nil }
    /// The same for videos.
    var videoReclaimableBytes: Int64? { nil }
    /// One line for the Overview, e.g. "1,204 similar photos and 18 large videos".
    var summary: String? { nil }
    /// Items were deleted in this session: they wait in Recently Deleted for 30 days.
    var hasDeletedItems: Bool { false }
}

struct PhotosHomeView: View {
    var model: PhotoCleanupModel
    var body: some View { Text("Photos") }
}

struct VideosHomeView: View {
    var model: PhotoCleanupModel
    var body: some View { Text("Videos") }
}
