import Foundation
import Testing
@testable import MacCleaner

@Suite("Developer – Xcode data")
struct DeveloperXcodeInspectorTests {
    @Test func readsDerivedDataInfoPlists() throws {
        let directory = try DeveloperTestDirectory()
        let derivedData = try directory.makeDirectory("Xcode/DerivedData")
        let project = try directory.makeFile("Projects/MyApp/MyApp.xcodeproj/project.pbxproj")
        let workspace = (project as NSString).deletingLastPathComponent
        let lastAccess = Date(timeIntervalSince1970: 1_790_000_000)

        try directory.writePlist(["WorkspacePath": workspace, "LastAccessedDate": lastAccess], to: "Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyzab/info.plist")
        try directory.writePlist(["WorkspacePath": directory.path + "/Projects/Gone/Gone.xcworkspace"], to: "Xcode/DerivedData/Gone-bcdefghijklmnopqrstuvwxyzabc/info.plist")
        try directory.makeDirectory("Xcode/DerivedData/Orphan-cdefghijklmnopqrstuvwxyzabcd/Build")
        try directory.makeDirectory("Xcode/DerivedData/ModuleCache.noindex")
        try directory.makeDirectory("Xcode/DerivedData/SDKStatCaches.noindex")
        try directory.makeFile("Xcode/DerivedData/.DS_Store")

        let folders = DeveloperXcodeInspector.derivedDataFolders(in: derivedData)
        #expect(folders.count == 5)

        let myApp = try #require(folders.first { $0.folderName.hasPrefix("MyApp-") })
        #expect(myApp.kind == .project)
        #expect(myApp.projectName == "MyApp")
        #expect(myApp.workspacePath == workspace)
        #expect(myApp.projectStatus == .exists)
        #expect(myApp.lastAccessed == lastAccess)

        let gone = try #require(folders.first { $0.folderName.hasPrefix("Gone-") })
        #expect(gone.projectName == "Gone")
        #expect(gone.projectStatus == .missing)

        let orphan = try #require(folders.first { $0.folderName.hasPrefix("Orphan-") })
        #expect(orphan.projectName == "Orphan")
        #expect(orphan.workspacePath == nil)
        #expect(orphan.projectStatus == .unknown)

        #expect(folders.first { $0.folderName == "ModuleCache.noindex" }?.kind == .moduleCache)
        #expect(folders.first { $0.folderName == "SDKStatCaches.noindex" }?.kind == .sharedCache(title: "SDK stat cache"))
    }

    @Test func recognizesProjectsOnDisconnectedDrives() {
        let status = DeveloperXcodeInspector.projectStatus(workspacePath: "/Volumes/Work SSD/Code/App/App.xcodeproj") { _ in false }
        #expect(status == .onDisconnectedVolume)
        let mounted = DeveloperXcodeInspector.projectStatus(workspacePath: "/Volumes/Work SSD/Code/App/App.xcodeproj") { $0 == "/Volumes/Work SSD" }
        #expect(mounted == .missing)
    }

    @Test func derivesProjectNames() {
        #expect(DeveloperXcodeInspector.projectName(fromWorkspacePath: "/Users/me/App/App.xcworkspace") == "App")
        #expect(DeveloperXcodeInspector.projectName(fromWorkspacePath: "/Users/me/Kit/Package.swift") == "Kit")
        #expect(DeveloperXcodeInspector.projectName(fromWorkspacePath: "/Users/me/Packages/Networking") == "Networking")
        #expect(DeveloperXcodeInspector.projectName(fromFolderName: "My-App-abcdefghijklmnopqrstuvwxyzab") == "My-App")
        #expect(DeveloperXcodeInspector.projectName(fromFolderName: "NoHash") == "NoHash")
        #expect(DeveloperXcodeInspector.projectName(fromFolderName: "Short-abc") == "Short-abc")
    }

    @Test func readsArchiveMetadata() throws {
        let directory = try DeveloperTestDirectory()
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        try directory.writePlist([
            "Name": "Cliquette",
            "CreationDate": created,
            "ApplicationProperties": ["CFBundleShortVersionString": "1.4", "CFBundleVersion": "52", "CFBundleIdentifier": "com.example.cliquette"],
        ], to: "Archives/2025-06-15/Cliquette 15-06-2025, 10.12.xcarchive/Info.plist")
        try directory.makeDirectory("Archives/2025-06-15/NotAnArchive")

        let archives = DeveloperXcodeInspector.archives(in: directory.path + "/Archives")
        #expect(archives.count == 1)
        let archive = try #require(archives.first)
        #expect(archive.title == "Cliquette 1.4 (52)")
        #expect(archive.bundleIdentifier == "com.example.cliquette")
        #expect(archive.creationDate == created)
    }

    @Test func ordersDeviceSupportNewestFirst() throws {
        let directory = try DeveloperTestDirectory()
        for name in ["16.4 (20E247)", "iPhone15,2 17.0 (21A329)", "17.0.3 (21A360)", "16.4.1 (20E252) arm64e", "Notes"] {
            try directory.makeDirectory("iOS DeviceSupport/" + name)
        }
        let entries = DeveloperXcodeInspector.deviceSupportEntries(in: directory.path + "/iOS DeviceSupport", platform: "iOS")
        #expect(entries.map(\.versionString) == ["17.0.3", "17.0", "16.4.1", "16.4"])
        #expect(entries.first?.build == "21A360")

        let parsed = try #require(DeveloperXcodeInspector.parseDeviceSupportName("Watch6,1 9.4 (20T250)"))
        #expect(parsed.version == [9, 4])
        #expect(parsed.build == "20T250")
        #expect(DeveloperXcodeInspector.compareVersions([17, 0], [17]) == .orderedSame)
        #expect(DeveloperXcodeInspector.compareVersions([16, 4, 1], [16, 10]) == .orderedAscending)
    }

    @Test func parsesGradleDistributionVersions() {
        #expect(DeveloperXcodeInspector.gradleDistributionVersion("gradle-8.10.2-bin") == [8, 10, 2])
        #expect(DeveloperXcodeInspector.gradleDistributionVersion("gradle-7.6-all") == [7, 6])
        #expect(DeveloperXcodeInspector.gradleDistributionVersion("wrapper") == nil)
    }

    @Test func measuresEachChildOfAFolderInOneWalk() async throws {
        let directory = try DeveloperTestDirectory()
        try directory.makeFile("cache/a/one.bin", bytes: 10_000)
        try directory.makeFile("cache/a/nested/two.bin", bytes: 20_000)
        try directory.makeFile("cache/b.zip", bytes: 5_000)
        try directory.makeDirectory("cache/empty")

        let usages = try await DeveloperFolderMeasurer.measureChildren(of: directory.path + "/cache")
        #expect(Set(usages.keys) == [directory.path + "/cache/a", directory.path + "/cache/b.zip", directory.path + "/cache/empty"])
        #expect(usages[directory.path + "/cache/a"]?.fileCount == 2)
        #expect(usages[directory.path + "/cache/a"]?.logicalBytes == 30_000)
        #expect(usages[directory.path + "/cache/b.zip"]?.logicalBytes == 5_000)
        #expect(usages[directory.path + "/cache/empty"]?.fileCount == 0)
    }

    @Test func quotesCommandsForDisplay() {
        let command = DeveloperCommand(executable: "/opt/homebrew/bin/docker", displayName: "docker", arguments: ["system", "df", "--format", "{{json .}}"], timeout: 30)
        #expect(command.commandLine == "docker system df --format '{{json .}}'")
        let simple = DeveloperCommand(executable: "/usr/bin/xcrun", displayName: "xcrun", arguments: ["simctl", "runtime", "delete", "99937711-6DB6-4A20-945A-05BDBFDA00B5"], timeout: 30)
        #expect(simple.commandLine == "xcrun simctl runtime delete 99937711-6DB6-4A20-945A-05BDBFDA00B5")
    }
}
