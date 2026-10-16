import Foundation
import Observation

/// State of the Ports & Network page. (Placeholder until the feature is implemented.)
@MainActor
@Observable
final class NetworkViewModel {
    let services: AppServices
    /// Opens another section (set by `AppEnvironment.connectNavigation`).
    var navigate: ((AppSection) -> Void)?

    init(services: AppServices) {
        self.services = services
    }
}
