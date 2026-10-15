import Foundation
import Testing
@testable import MacCleaner

@Suite("Privacy – browser profile discovery")
struct PrivacyProfileDiscoveryTests {
    @Test func recognizesChromiumProfileFolderNames() {
        #expect(PrivacyProfileDiscovery.isChromiumProfileFolderName("Default"))
        #expect(PrivacyProfileDiscovery.isChromiumProfileFolderName("Profile 1"))
        #expect(PrivacyProfileDiscovery.isChromiumProfileFolderName("Profile 12"))
        #expect(!PrivacyProfileDiscovery.isChromiumProfileFolderName("Profile"))
        #expect(!PrivacyProfileDiscovery.isChromiumProfileFolderName("Profile X"))
        #expect(!PrivacyProfileDiscovery.isChromiumProfileFolderName("Guest Profile"))
        #expect(!PrivacyProfileDiscovery.isChromiumProfileFolderName("System Profile"))
        #expect(!PrivacyProfileDiscovery.isChromiumProfileFolderName("Crashpad"))
    }

    @Test func findsChromiumProfilesInAFakeLibrary() throws {
        let sandbox = try PrivacyTestSandbox()
        let support = sandbox.library + "/Application Support/Google/Chrome"
        let cache = sandbox.library + "/Caches/Google/Chrome"
        try sandbox.makeFile(support + "/Default/Preferences")
        try sandbox.makeFile(support + "/Profile 1/Preferences")
        try sandbox.makeFile(support + "/Profile 3/History")
        try sandbox.makeFile(support + "/Renamed/Preferences")
        try sandbox.makeFile(support + "/Guest Profile/Preferences")
        try sandbox.makeFile(support + "/System Profile/Preferences")
        try sandbox.makeDirectory(support + "/Crashpad")
        try sandbox.makeDirectory(support + "/ShaderCache")
        try sandbox.writeJSON(
            ["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]]],
            to: support + "/Local State"
        )
        try sandbox.makeDirectory(cache + "/Default/Cache")
        try sandbox.makeDirectory(cache + "/Profile 1/Code Cache")

        let result = PrivacyProfileDiscovery.chromiumProfiles(supportRoot: support, cacheRoot: cache)

        #expect(!result.supportBlocked)
        #expect(result.profiles.map(\.directoryName) == ["Default", "Profile 1", "Profile 3", "Renamed"])
        #expect(result.profiles[0].displayName == "Personal")
        #expect(result.profiles[0].isDefault)
        #expect(result.profiles[1].displayName == "Work")
        #expect(result.profiles[0].cachePath == cache + "/Default")
        #expect(result.profiles[1].cachePath == cache + "/Profile 1")
        #expect(result.profiles[2].cachePath == nil)
        #expect(result.profiles[0].dataPath == support + "/Default")
    }

    @Test func findsProfilesInTheCacheFolderWhenTheDataFolderIsMissing() throws {
        let sandbox = try PrivacyTestSandbox()
        let support = sandbox.library + "/Application Support/BraveSoftware/Brave-Browser"
        let cache = sandbox.library + "/Caches/BraveSoftware/Brave-Browser"
        try sandbox.makeDirectory(cache + "/Default/Cache")
        try sandbox.makeDirectory(cache + "/Profile 2/Cache")
        try sandbox.makeDirectory(cache + "/System Profile/Cache")

        let result = PrivacyProfileDiscovery.chromiumProfiles(supportRoot: support, cacheRoot: cache)

        #expect(result.profiles.map(\.directoryName) == ["Default", "Profile 2"])
        #expect(result.profiles.allSatisfy { $0.dataPath == nil })
        #expect(result.profiles[1].cachePath == cache + "/Profile 2")
    }

    @Test func detectsASingleProfileStoredDirectlyInTheDataFolder() throws {
        let sandbox = try PrivacyTestSandbox()
        let support = sandbox.library + "/Application Support/com.operasoftware.Opera"
        try sandbox.makeFile(support + "/Preferences")
        try sandbox.makeFile(support + "/History")
        try sandbox.makeFile(support + "/Cookies")

        let result = PrivacyProfileDiscovery.chromiumProfiles(supportRoot: support, cacheRoot: nil)

        #expect(result.profiles.count == 1)
        #expect(result.profiles[0].directoryName.isEmpty)
        #expect(result.profiles[0].dataPath == support)
        #expect(result.profiles[0].displayName == "Default profile")
    }

    @Test func parsesFirefoxProfilesINI() {
        let ini = """
        [Install4F96D1932A9F858E]
        Default=Profiles/abcd1234.default-release
        Locked=1

        [Profile1]
        Name=default
        IsRelative=1
        Path=Profiles/wxyz9876.default
        Default=1

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abcd1234.default-release

        [Profile2]
        Name=Elsewhere
        IsRelative=0
        Path=/Volumes/External/Firefox Profile

        [General]
        StartWithLastProfile=1
        Version=2
        """
        let parsed = PrivacyProfileDiscovery.parseFirefoxProfilesINI(ini)
        #expect(parsed.profiles.count == 3)
        #expect(parsed.profiles[0].name == "default")
        #expect(parsed.profiles[0].isDefault)
        #expect(parsed.profiles[1].path == "Profiles/abcd1234.default-release")
        #expect(parsed.profiles[1].isRelative)
        #expect(!parsed.profiles[2].isRelative)
        #expect(parsed.installDefaults == ["Profiles/abcd1234.default-release"])
    }

    @Test func findsFirefoxProfilesFromProfilesINIAndUnlistedFolders() throws {
        let sandbox = try PrivacyTestSandbox()
        let support = sandbox.library + "/Application Support/Firefox"
        let cache = sandbox.library + "/Caches/Firefox"
        try sandbox.write("""
        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abcd1234.default-release

        [Profile1]
        Name=Outside
        IsRelative=0
        Path=\(sandbox.root)/outside-profile

        [Install1]
        Default=Profiles/abcd1234.default-release
        """, to: support + "/profiles.ini")
        try sandbox.makeFile(support + "/Profiles/abcd1234.default-release/places.sqlite")
        try sandbox.makeFile(support + "/Profiles/zzzz0000.unlisted/prefs.js")
        try sandbox.makeFile(sandbox.root + "/outside-profile/places.sqlite")
        try sandbox.makeDirectory(cache + "/Profiles/abcd1234.default-release/cache2")

        let result = PrivacyProfileDiscovery.firefoxProfiles(supportRoot: support, cacheRoot: cache, home: sandbox.home)

        #expect(!result.supportBlocked)
        #expect(result.profiles.map(\.directoryName) == ["abcd1234.default-release", "zzzz0000.unlisted"])
        #expect(result.profiles[0].isDefault)
        #expect(result.profiles[0].displayName == "default-release")
        #expect(result.profiles[0].cachePath == cache + "/Profiles/abcd1234.default-release")
        #expect(result.profiles[1].displayName == "unlisted")
        #expect(result.profiles[1].cachePath == nil)
    }
}
