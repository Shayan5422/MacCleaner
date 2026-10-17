import Observation
import SwiftUI

/// Security checkup, Safari protection and link check. Placeholder until the Protection module lands.
@MainActor
@Observable
final class ProtectionModel {
    enum Status: Equatable, Sendable {
        case unknown
        case protected
        case attention(String)
    }

    var status: Status { .unknown }
    /// Whether the Safari content blocker is turned on in Settings, nil if not known yet.
    var safariProtectionEnabled: Bool? { nil }

    func refresh() async {}
}

struct ProtectionHomeView: View {
    var model: ProtectionModel
    var body: some View { Text("Protection") }
}
