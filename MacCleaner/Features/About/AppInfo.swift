import AppKit
import Foundation

/// Version, credits and project links shown in About, Settings and the update check.
/// Everything here is public information; nothing identifies the person or the Mac.
enum AppInfo {
    static let name = "Mac Cleaner"
    /// The owner's slogan, used in About, the menu bar and onboarding.
    static let tagline = "The assistant that watches over your Mac."
    /// What the app is, in one line.
    static let summary = "A fast, honest, native cleaner and system manager for macOS."
    static let author = "Shayan Hashemi"
    static let license = "MIT License"
    static let copyright = "© 2026 Shayan Hashemi"

    static let websiteURL = URL(string: "https://www.shhshm.eu/")!
    static let githubURL = URL(string: "https://github.com/Shayan5422")!
    static let linkedInURL = URL(string: "https://www.linkedin.com/in/shhshm/")!
    static let repositoryURL = URL(string: "https://github.com/Shayan5422/MacCleaner")!
    static let issuesURL = URL(string: "https://github.com/Shayan5422/MacCleaner/issues")!
    static let releasesURL = URL(string: "https://github.com/Shayan5422/MacCleaner/releases")!
    static let licenseURL = URL(string: "https://github.com/Shayan5422/MacCleaner/blob/main/LICENSE")!

    /// Third-party data and code the app relies on.
    struct Acknowledgement: Identifiable, Hashable {
        var title: String
        var detail: String
        var url: URL?
        var id: String { title }
    }

    static let acknowledgements: [Acknowledgement] = [
        Acknowledgement(title: "Virus signatures", detail: "ClamAV® by Cisco Talos (GPL-2.0)", url: URL(string: "https://www.clamav.net/")),
        Acknowledgement(title: "Threat feeds", detail: "abuse.ch MalwareBazaar, URLhaus, ThreatFox (CC0)", url: URL(string: "https://abuse.ch/")),
        Acknowledgement(title: "Port management", detail: "Based on PortPilot by Shayan Hashemi", url: URL(string: "https://github.com/Shayan5422/PortPilot")),
    ]

    /// CFBundleShortVersionString (MARKETING_VERSION in project.yml), e.g. "1.0.0".
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0.0"
    }

    /// CFBundleVersion (CURRENT_PROJECT_VERSION in project.yml), e.g. "1".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// "Version 1.0.0 (1)"; the build is left out when it's missing or equal to the version.
    static func versionLine(version: String = version, build: String = build) -> String {
        guard !build.isEmpty, build != version else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    /// Opens a link in the default browser.
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
