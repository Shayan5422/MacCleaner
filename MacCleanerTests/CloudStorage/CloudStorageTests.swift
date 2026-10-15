import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacCleaner

/// Temporary folders for Cloud Storage tests. Everything lives under the system temporary directory.
enum CloudFixture {
    static func makeTemporaryDirectory(_ label: String) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return PathUtilities.resolvedPath(base.path) ?? base.path
    }

    static func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func writeFile(_ path: String, data: Data) throws {
        try makeDirectory((path as NSString).deletingLastPathComponent)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, count) }
        }
        return data
    }

    static func setDates(_ path: String, daysAgo: Double) {
        let seconds = Int(Date().timeIntervalSince1970 - daysAgo * 86_400)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        _ = utimes(path, &times)
    }

    static func item(_ path: String, locationID: String = "test") throws -> CloudFileItem {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return CloudFileItem(
            path: path, name: (path as NSString).lastPathComponent, locationID: locationID,
            logicalSize: Int64(info.st_size), localBytes: Int64(info.st_blocks) * 512,
            modificationDate: Date(), lastOpenedDate: nil, isPackage: false,
            identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
        )
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite("Cloud provider detection", .serialized)
struct CloudProviderDetectorTests {
    @Test func detectsProvidersInAFakeHome() throws {
        let home = try CloudFixture.makeTemporaryDirectory("CloudFakeHome")
        defer { CloudFixture.remove(home) }
        let mobile = home + "/Library/Mobile Documents"
        try CloudFixture.makeDirectory(mobile + "/com~apple~CloudDocs/Projects")
        try CloudFixture.makeDirectory(mobile + "/com~apple~Pages/Documents")
        try CloudFixture.makeDirectory(home + "/Library/CloudStorage/GoogleDrive-me@example.com/My Drive")
        try CloudFixture.makeDirectory(home + "/Library/CloudStorage/OneDrive-Personal")
        try CloudFixture.makeDirectory(home + "/Library/CloudStorage/Dropbox")
        try CloudFixture.makeDirectory(home + "/Library/CloudStorage/ProtonDrive-me@proton.me")
        try CloudFixture.makeDirectory(home + "/Library/CloudStorage/.hidden-domain")
        try CloudFixture.makeDirectory(home + "/Box Sync")
        try CloudFixture.makeDirectory(home + "/Desktop")
        try CloudFixture.makeDirectory(home + "/Documents")
        // Modern Dropbox links ~/Dropbox to its File Provider domain; it must not be counted twice.
        try FileManager.default.createSymbolicLink(atPath: home + "/Dropbox", withDestinationPath: home + "/Library/CloudStorage/Dropbox")
        // "Desktop & Documents Folders": iCloud Drive links to ~/Desktop (Documents isn't synced here).
        try FileManager.default.createSymbolicLink(atPath: mobile + "/com~apple~CloudDocs/Desktop", withDestinationPath: home + "/Desktop")

        let locations = CloudProviderDetector.detect(home: home)
        func location(_ path: String) -> CloudLocation? { locations.first { $0.path == path } }

        let iCloud = try #require(location(mobile + "/com~apple~CloudDocs"))
        #expect(iCloud.provider == .iCloudDrive && iCloud.role == .drive && iCloud.supportsRemoveDownload)
        let desktop = try #require(location(home + "/Desktop"))
        #expect(desktop.role == .desktopAndDocuments && desktop.provider == .iCloudDrive)
        #expect(location(home + "/Documents") == nil)
        let appData = try #require(location(mobile))
        #expect(appData.role == .appData)

        let google = try #require(location(home + "/Library/CloudStorage/GoogleDrive-me@example.com"))
        #expect(google.provider == .googleDrive && google.account == "me@example.com" && google.providerName == "Google Drive")
        let oneDrive = try #require(location(home + "/Library/CloudStorage/OneDrive-Personal"))
        #expect(oneDrive.provider == .oneDrive && oneDrive.account == "Personal")
        let dropbox = try #require(location(home + "/Library/CloudStorage/Dropbox"))
        #expect(dropbox.provider == .dropbox && dropbox.account == nil)
        let proton = try #require(location(home + "/Library/CloudStorage/ProtonDrive-me@proton.me"))
        #expect(proton.provider == .other && proton.providerName == "Proton Drive")
        let box = try #require(location(home + "/Box Sync"))
        #expect(box.provider == .box && box.role == .legacyFolder && !box.supportsRemoveDownload)

        #expect(location(home + "/Dropbox") == nil, "Symlinks to File Provider domains aren't separate locations")
        #expect(!locations.contains { $0.path.contains(".hidden-domain") })
        #expect(locations.count == 8)

        let legacy = Set(CloudProviderDetector.legacyFolderPaths(home: home))
        #expect(legacy == [home + "/Box Sync", home + "/Dropbox"])
    }

    @Test func emptyHomeHasNoProviders() throws {
        let home = try CloudFixture.makeTemporaryDirectory("CloudEmptyHome")
        defer { CloudFixture.remove(home) }
        #expect(CloudProviderDetector.detect(home: home).isEmpty)
    }

    @Test(arguments: [
        ("GoogleDrive-someone@gmail.com", CloudProviderKind.googleDrive, "Google Drive", "someone@gmail.com" as String?),
        ("OneDrive-Contoso", .oneDrive, "OneDrive", "Contoso"),
        ("Dropbox", .dropbox, "Dropbox", nil),
        ("Dropbox (Team)", .dropbox, "Dropbox", "Team"),
        ("Box-Box", .box, "Box", nil),
        ("SynologyDrive-office", .other, "Synology Drive", "office"),
    ])
    func fileProviderFolderNamesAreParsed(name: String, kind: CloudProviderKind, provider: String, account: String?) throws {
        let parsed = try #require(CloudProviderDetector.parseFileProviderFolder(name: name))
        #expect(parsed.kind == kind)
        #expect(parsed.providerName == provider)
        #expect(parsed.account == account)
    }

    @Test func appContainersGetReadableTitles() {
        #expect(CloudProviderDetector.appContainerTitle("com~apple~Pages") == "Pages")
        #expect(CloudProviderDetector.appContainerTitle("57T9237FN3~net~whatsapp~WhatsApp") == "WhatsApp")
        #expect(CloudProviderDetector.appContainerTitle("iCloud~com~example~Notes") == "Notes")
        #expect(CloudProviderDetector.appContainerTitle("KC697SNQ2X~AudioViz") == "AudioViz")
        #expect(CloudProviderDetector.appContainerTitle("iCloud~Uniswap") == "Uniswap")
    }
}

@Suite("Cloud storage scanner", .serialized)
struct CloudStorageScannerTests {
    @Test func measuresLocalFilesPackagesAndUnusedDownloads() async throws {
        let root = try CloudFixture.makeTemporaryDirectory("CloudScanner")
        defer { CloudFixture.remove(root) }
        try CloudFixture.writeFile(root + "/Photos/large.mov", data: CloudFixture.randomData(2_500_000))
        try CloudFixture.writeFile(root + "/Photos/old.jpg", data: CloudFixture.randomData(1_400_000))
        CloudFixture.setDates(root + "/Photos/old.jpg", daysAgo: 400)
        try CloudFixture.writeFile(root + "/Docs/Report.pages/Index.zip", data: CloudFixture.randomData(1_200_000))
        try CloudFixture.writeFile(root + "/Docs/Report.pages/Data/image.png", data: CloudFixture.randomData(300_000))
        try CloudFixture.writeFile(root + "/Docs/small.txt", data: Data("hello".utf8))
        try CloudFixture.writeFile(root + "/loose.bin", data: CloudFixture.randomData(1_100_000))

        let location = CloudLocation(path: root, provider: .googleDrive, providerName: "Google Drive", account: "test", role: .drive, title: "Google Drive")
        var scanner = CloudStorageScanner()
        scanner.notOpenedDays = 180
        let result = try await scanner.scan(locations: [location], progress: CloudScanProgress())
        let summary = try #require(result.summaries.first)
        let usage = try await FileSystemScanner().measure(path: root)

        #expect(summary.errorMessage == nil)
        #expect(summary.fileCount == usage.fileCount)
        #expect(summary.localBytes == usage.allocatedBytes)
        #expect(summary.logicalBytes == usage.logicalBytes)
        #expect(summary.cloudOnlyCount == 0)
        #expect(summary.cloudOnlyBytes == 0)

        let names = summary.largestLocal.map(\.name)
        #expect(names.first == "large.mov")
        #expect(names.contains("Report.pages"), "Packages are listed as one item")
        #expect(!names.contains("Index.zip"), "Files inside packages aren't listed on their own")
        #expect(!names.contains("small.txt"))
        let package = try #require(summary.largestLocal.first { $0.name == "Report.pages" })
        #expect(package.isPackage)
        #expect(package.logicalSize == 1_500_000)

        #expect(summary.notOpened.map(\.name) == ["old.jpg"])
        #expect(Array(summary.topFolders.map(\.name).prefix(2)) == ["Photos", "Docs"])
        #expect(summary.topFolders.contains { $0.name == "Items at the top level" })
        // Duplicate candidates come from metadata only; packages' contents aren't candidates.
        #expect(Set(result.duplicateCandidates.map(\.name)) == ["large.mov", "old.jpg", "loose.bin"])
    }

    @Test func appDataSkipsTheICloudDriveContainer() async throws {
        let mobile = try CloudFixture.makeTemporaryDirectory("CloudMobileDocuments")
        defer { CloudFixture.remove(mobile) }
        try CloudFixture.writeFile(mobile + "/com~apple~CloudDocs/drive.bin", data: CloudFixture.randomData(1_200_000))
        try CloudFixture.writeFile(mobile + "/com~apple~Pages/Documents/doc.bin", data: CloudFixture.randomData(1_100_000))
        let appData = CloudLocation(path: mobile, provider: .iCloudDrive, providerName: "iCloud Drive", account: nil, role: .appData, title: "App Data in iCloud")
        let result = try await CloudStorageScanner().scan(locations: [appData], progress: CloudScanProgress())
        let summary = try #require(result.summaries.first)
        #expect(summary.largestLocal.map(\.name) == ["doc.bin"])
        #expect(summary.topFolders.map(\.name) == ["Pages"])
    }
}

@Suite("Cloud file hashing and duplicates", .serialized)
struct CloudDuplicateTests {
    @Test func sha256MatchesKnownVectors() throws {
        let root = try CloudFixture.makeTemporaryDirectory("CloudHash")
        defer { CloudFixture.remove(root) }
        try CloudFixture.writeFile(root + "/abc.txt", data: Data("abc".utf8))
        try CloudFixture.writeFile(root + "/empty.txt", data: Data())
        #expect(try CloudFileHasher.sha256(path: root + "/abc.txt") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try CloudFileHasher.sha256(path: root + "/empty.txt") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Prefix hashing reads only the first bytes.
        #expect(try CloudFileHasher.sha256(path: root + "/abc.txt", prefixBytes: 1) == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
    }

    @Test func streamingHashMatchesAcrossChunkBoundaries() throws {
        let root = try CloudFixture.makeTemporaryDirectory("CloudHash")
        defer { CloudFixture.remove(root) }
        let data = CloudFixture.randomData(CloudFileHasher.chunkSize * 2 + 12_345)
        try CloudFixture.writeFile(root + "/big.bin", data: data)
        var hashedBytes: Int64 = 0
        let streamed = try CloudFileHasher.sha256(path: root + "/big.bin", onBytes: { hashedBytes += $0 })
        #expect(hashedBytes == Int64(data.count))
        #expect(streamed == CloudFileHasher.hex(Array(SHA256.hash(data: data))))
    }

    @Test func refusesFilesThatChangedOrAreNotFiles() throws {
        let root = try CloudFixture.makeTemporaryDirectory("CloudHash")
        defer { CloudFixture.remove(root) }
        try CloudFixture.writeFile(root + "/file.bin", data: Data("x".utf8))
        #expect(throws: CloudFileHasher.HashError.self) {
            try CloudFileHasher.sha256(path: root + "/file.bin", expected: FileIdentity(device: 0, inode: 42))
        }
        #expect(throws: CloudFileHasher.HashError.self) {
            try CloudFileHasher.sha256(path: root)
        }
    }

    @Test func findsIdenticalFilesButNotHardLinksOrLookalikes() async throws {
        let root = try CloudFixture.makeTemporaryDirectory("CloudDuplicates")
        defer { CloudFixture.remove(root) }
        let content = CloudFixture.randomData(1_300_000)
        var lookalike = content
        lookalike[lookalike.count - 1] ^= 0xFF // Same size and prefix, different ending.
        try CloudFixture.writeFile(root + "/a/original.bin", data: content)
        try CloudFixture.writeFile(root + "/b/copy.bin", data: content)
        try CloudFixture.writeFile(root + "/c/lookalike.bin", data: lookalike)
        try CloudFixture.makeDirectory(root + "/d")
        try #require(link(root + "/a/original.bin", root + "/d/hardlink.bin") == 0)
        try CloudFixture.writeFile(root + "/e/tiny1.txt", data: Data("same".utf8))
        try CloudFixture.writeFile(root + "/e/tiny2.txt", data: Data("same".utf8))

        let items = try ["/a/original.bin", "/b/copy.bin", "/c/lookalike.bin", "/d/hardlink.bin", "/e/tiny1.txt", "/e/tiny2.txt"]
            .map { try CloudFixture.item(root + $0) }
        let progress = CloudScanProgress()
        let groups = try await CloudDuplicateFinder(minimumBytes: 1_000_000).findDuplicates(in: items, progress: progress)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.items.map(\.name)).count == 2)
        #expect(group.items.contains { $0.name == "copy.bin" })
        #expect(!group.items.contains { $0.name == "lookalike.bin" })
        #expect(group.size == 1_300_000)
        #expect(group.redundantLocalBytes > 0)
        #expect(progress.snapshot.bytesCompared == progress.snapshot.bytesToCompare)
    }
}

/// App services whose history, log and settings stay in temporary locations.
@MainActor
enum CloudTestServices {
    static func make(supportDirectory: String) throws -> AppServices {
        try FileManager.default.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
        let support = URL(fileURLWithPath: supportDirectory, isDirectory: true)
        // A fresh suite that is only read: nothing is written unless a setting changes.
        let defaults = try #require(UserDefaults(suiteName: "CloudStorageTests-\(UUID().uuidString)"))
        return AppServices(
            settings: SettingsManager(defaults: defaults),
            permissions: PermissionManager(),
            history: HistoryStore(directory: support),
            logger: ActivityLogger(directory: support)
        )
    }

    /// Polls `condition` on the main actor for up to `seconds`.
    static func waitUntil(seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for a condition")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
@Suite("Cloud storage view model", .serialized)
struct CloudStorageViewModelTests {
    @Test func analyzesAFakeHomeAndNeverEvictsNonCloudFiles() async throws {
        let home = try CloudFixture.makeTemporaryDirectory("CloudViewModelHome")
        let support = home + "-support"
        defer {
            CloudFixture.remove(home)
            CloudFixture.remove(support)
        }
        let drive = home + "/Library/CloudStorage/GoogleDrive-me@example.com"
        try CloudFixture.writeFile(drive + "/My Drive/video.mov", data: CloudFixture.randomData(2_500_000))
        try CloudFixture.writeFile(drive + "/My Drive/old.zip", data: CloudFixture.randomData(1_200_000))
        CloudFixture.setDates(drive + "/My Drive/old.zip", daysAgo: 400)
        let copy = CloudFixture.randomData(1_100_000)
        try CloudFixture.writeFile(drive + "/My Drive/a/copy.bin", data: copy)
        try CloudFixture.writeFile(drive + "/My Drive/b/copy.bin", data: copy)

        let model = CloudStorageViewModel(services: try CloudTestServices.make(supportDirectory: support), home: home)
        model.detect()
        try await CloudTestServices.waitUntil { model.hasDetected }
        #expect(model.locations.count == 1)
        #expect(model.detectedProviderNames == ["Google Drive (me@example.com)"])
        #expect(!model.hasICloud)

        model.scan()
        try await CloudTestServices.waitUntil { model.phase == .ready }
        #expect(model.groups.count == 1)
        #expect(model.totalLocalBytes >= 5_900_000)
        #expect(model.totalCloudOnlyCount == 0)
        #expect(model.notOpenedItems.map(\.name) == ["old.zip"])
        #expect(model.suggestions.contains { $0.id == "not-opened" })
        #expect(!model.suggestions.contains { $0.id == "optimize" })

        // Analysis never reads contents: identical copies are only compared on request.
        #expect(model.duplicates == nil)
        #expect(model.possibleDuplicateSets == 1)
        #expect(model.suggestions.contains { $0.id == "compare" })
        model.perform(try #require(model.suggestions.first { $0.id == "compare" }))
        #expect(model.isComparing)
        try await CloudTestServices.waitUntil { !model.isComparing }
        #expect(model.duplicateGroups.count == 1)
        #expect(model.duplicateGroups.first?.items.count == 2)
        #expect(model.suggestions.contains { $0.id == "duplicates" })

        model.perform(try #require(model.suggestions.first { $0.id == "not-opened" }))
        #expect(model.selectedItems.map(\.name) == ["old.zip"])

        // The fake folder isn't managed by a cloud provider, so macOS refuses Remove Download:
        // nothing is evicted, nothing is deleted, and Finder is suggested instead.
        let video = try #require(model.groups.first?.summaries.first?.largestLocal.first { $0.name == "video.mov" })
        model.requestRemoveDownload([video])
        let request = try #require(model.removalRequest)
        #expect(request.problems.isEmpty)
        model.confirmRemoval()
        try await CloudTestServices.waitUntil { model.showsRemovalReport }
        #expect(model.removalOutcomes.count == 1)
        #expect(model.removalOutcomes.first?.succeeded == false)
        #expect(model.removalOutcomes.first?.canUseFinder == true)
        #expect(model.evictedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    @Test func itemsOutsideCloudFoldersAreRefusedBeforeAskingMacOS() throws {
        let root = try CloudFixture.makeTemporaryDirectory("CloudPreflight")
        defer { CloudFixture.remove(root) }
        try CloudFixture.writeFile(root + "/drive/file.bin", data: Data("x".utf8))
        try CloudFixture.writeFile(root + "/elsewhere/file.bin", data: Data("x".utf8))
        try CloudFixture.writeFile(root + "/legacy/file.bin", data: Data("x".utf8))
        let locations = [
            CloudLocation(path: root + "/drive", provider: .googleDrive, providerName: "Google Drive", account: nil, role: .drive, title: "Google Drive"),
            CloudLocation(path: root + "/legacy", provider: .dropbox, providerName: "Dropbox", account: nil, role: .legacyFolder, title: "Dropbox"),
        ]
        #expect(CloudDownloadRemover.preflightProblem(for: try CloudFixture.item(root + "/drive/file.bin"), locations: locations) == nil)
        #expect(CloudDownloadRemover.preflightProblem(for: try CloudFixture.item(root + "/elsewhere/file.bin"), locations: locations) != nil)
        #expect(CloudDownloadRemover.preflightProblem(for: try CloudFixture.item(root + "/legacy/file.bin"), locations: locations)?.contains("Dropbox") == true)
        var stale = try CloudFixture.item(root + "/drive/file.bin")
        stale.identity = FileIdentity(device: 0, inode: 7)
        #expect(CloudDownloadRemover.preflightProblem(for: stale, locations: locations) != nil)
    }
}
