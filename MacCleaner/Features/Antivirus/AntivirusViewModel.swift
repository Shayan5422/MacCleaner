import Foundation
import Observation

/// State of the Antivirus page. (Placeholder until the feature is implemented.)
@MainActor
@Observable
final class AntivirusViewModel {
    let services: AppServices
    /// Opens another section (set by `AppEnvironment.connectNavigation`).
    var navigate: ((AppSection) -> Void)?

    init(services: AppServices) {
        self.services = services
    }
}
