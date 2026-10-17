import Observation
import SwiftUI

/// Duplicate and incomplete contacts. Placeholder until the Contacts module lands.
@MainActor
@Observable
final class ContactCleanupModel {
    /// Contacts to review after the last scan, or nil before the first scan.
    var issueCount: Int? { nil }
    var summary: String? { nil }
}

struct ContactsHomeView: View {
    var model: ContactCleanupModel
    var body: some View { Text("Contacts") }
}
