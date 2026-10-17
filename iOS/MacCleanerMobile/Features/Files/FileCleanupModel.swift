import Observation
import SwiftUI

/// Large, old and duplicate files in folders the person picks. Placeholder until the Files module lands.
@MainActor
@Observable
final class FileCleanupModel {
    var reclaimableBytes: Int64? { nil }
    var summary: String? { nil }
    /// Files were moved to Recently Deleted in this session.
    var hasDeletedItems: Bool { false }
}

struct FilesHomeView: View {
    var model: FileCleanupModel
    var body: some View { Text("Files") }
}
