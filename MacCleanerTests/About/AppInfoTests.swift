import Foundation
import Testing
@testable import MacCleaner

struct AppInfoTests {
    @Test func creditsTheAuthorWithTheirPublicLinks() {
        #expect(AppInfo.author == "Shayan Hashemi")
        #expect(AppInfo.websiteURL.absoluteString == "https://www.shhshm.eu/")
        #expect(AppInfo.githubURL.absoluteString == "https://github.com/Shayan5422")
        #expect(AppInfo.linkedInURL.absoluteString == "https://www.linkedin.com/in/shhshm/")
        #expect(AppInfo.license == "MIT License")
        #expect(AppInfo.copyright == "© 2026 Shayan Hashemi")
        #expect(AppInfo.tagline == "The assistant that watches over your Mac.")
    }

    @Test func linksToTheProject() {
        #expect(AppInfo.repositoryURL.absoluteString == "https://github.com/Shayan5422/MacCleaner")
        #expect(AppInfo.issuesURL.absoluteString == "https://github.com/Shayan5422/MacCleaner/issues")
        #expect(AppInfo.releasesURL.absoluteString == "https://github.com/Shayan5422/MacCleaner/releases")
        #expect(AppInfo.licenseURL.absoluteString == "https://github.com/Shayan5422/MacCleaner/blob/main/LICENSE")
        for url in [AppInfo.websiteURL, AppInfo.githubURL, AppInfo.linkedInURL, AppInfo.repositoryURL] + AppInfo.acknowledgements.compactMap(\.url) {
            #expect(url.scheme == "https", "\(url) must use HTTPS")
        }
    }

    @Test func acknowledgesThirdPartyData() {
        let lines = AppInfo.acknowledgements.map { "\($0.title): \($0.detail)" }
        #expect(lines == [
            "Virus signatures: ClamAV® by Cisco Talos (GPL-2.0)",
            "Threat feeds: abuse.ch MalwareBazaar, URLhaus, ThreatFox (CC0)",
            "Port management: Based on PortPilot by Shayan Hashemi",
        ])
    }

    @Test func formatsTheVersionLine() {
        #expect(AppInfo.versionLine(version: "1.2.0", build: "45") == "Version 1.2.0 (45)")
        #expect(AppInfo.versionLine(version: "1.2.0", build: "") == "Version 1.2.0")
        #expect(AppInfo.versionLine(version: "1.2.0", build: "1.2.0") == "Version 1.2.0")
        #expect(!AppInfo.version.isEmpty)
    }
}
