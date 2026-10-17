import SwiftUI

/// What the guides know about the device, to suggest the ones that help now.
struct GuideContext: Sendable, Equatable {
    var storage: DeviceStorage?
    var device: DeviceInfo
    var deletedPhotos: Bool
    var deletedFiles: Bool
    var safariProtectionEnabled: Bool?
}

/// A step-by-step guide for something iOS doesn't let an app do itself. Placeholder until the Guides module lands.
struct Guide: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var summary: String
    var symbol: String
}

enum GuideLibrary {
    static func suggestions(for context: GuideContext) -> [Guide] { [] }
}

struct GuidesHomeView: View {
    var context: GuideContext
    var body: some View { Text("Guides") }
}

struct GuideDetailView: View {
    var guide: Guide
    var context: GuideContext
    var body: some View { Text(guide.title) }
}
