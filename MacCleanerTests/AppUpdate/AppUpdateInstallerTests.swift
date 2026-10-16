import Foundation
import Testing
@testable import MacCleaner

/// The real, signed and notarized v1.0.0 release (`build/release/Mac-Cleaner-1.0.0.dmg`
/// and `.sha256`, made by `scripts/release.sh`). Set `MACCLEANER_RELEASE_DIR` (or
/// `TEST_RUNNER_MACCLEANER_RELEASE_DIR` with xcodebuild) to use another folder. Tests that
/// need it are skipped when it isn't there.
enum ReleaseFixture {
    static var folder: URL {
        if let custom = ProcessInfo.processInfo.environment["MACCLEANER_RELEASE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        // MacCleanerTests/AppUpdate/<this file> → repository root.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/release", isDirectory: true)
    }

    static var diskImage: URL { folder.appendingPathComponent("Mac-Cleaner-1.0.0.dmg") }
    static var checksums: URL { folder.appendingPathComponent("Mac-Cleaner-1.0.0.sha256") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: diskImage.path) && FileManager.default.fileExists(atPath: checksums.path)
    }

    /// The release as GitHub describes it, with the given asset names.
    static func release(version: String = "1.0.0", digest: String? = nil) throws -> AppRelease {
        var json = AppUpdateFixtures.releaseJSON(tag: "v\(version)", assetVersion: version, dmgDigest: digest.map { "sha256:\($0)" } ?? "none")
        json = json.replacingOccurrences(of: "\"digest\": \"none\"", with: "\"digest\": null")
        return try #require(AppUpdateChecker.parseLatestRelease(Data(json.utf8)))
    }
}

/// Serves release files from disk by name, the way GitHub serves them over HTTPS.
enum AppUpdateFileTransport {
    static func serving(_ files: [String: URL]) -> AppUpdateTransport {
        AppUpdateTransport(
            fetch: { request, maxBytes in
                let url = request.url!
                guard let file = files[url.lastPathComponent] else {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
                }
                let data = try Data(contentsOf: file)
                guard data.count <= maxBytes else { throw AppUpdateError.tooLarge }
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            },
            download: { url, destination, maxBytes, progress in
                guard let file = files[url.lastPathComponent] else { throw AppUpdateError.httpStatus(404) }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= maxBytes else { throw AppUpdateError.tooLarge }
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let input = try FileHandle(forReadingFrom: file)
                let output = try FileHandle(forWritingTo: destination)
                defer {
                    try? input.close()
                    try? output.close()
                }
                var written: Int64 = 0
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    progress(written, size)
                }
            }
        )
    }
}

/// Records installer progress.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AppUpdateInstaller.Stage] = []

    func add(_ stage: AppUpdateInstaller.Stage) { lock.withLock { stored.append(stage) } }
    var stages: [AppUpdateInstaller.Stage] { lock.withLock { stored } }
}

@Suite("Mac Cleaner update installer", .serialized, .enabled(if: ReleaseFixture.isAvailable, "Needs build/release/Mac-Cleaner-1.0.0.dmg and .sha256"))
struct AppUpdateInstallerTests {
    private func installer(currentVersion: String, files: [String: URL]) -> AppUpdateInstaller {
        AppUpdateInstaller(currentVersion: currentVersion, transport: AppUpdateFileTransport.serving(files))
    }

    private var realFiles: [String: URL] {
        ["Mac-Cleaner-1.0.0.dmg": ReleaseFixture.diskImage, "Mac-Cleaner-1.0.0.sha256": ReleaseFixture.checksums]
    }

    // MARK: The real release

    @Test func acceptsTheSignedNotarizedReleaseWhenItIsNewer() async throws {
        let folder = try TemporaryTree("UpdateAccept")
        let recorder = StageRecorder()
        let release = try ReleaseFixture.release(digest: "6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157")
        let saved = try await installer(currentVersion: "0.9.0", files: realFiles)
            .downloadVerifiedDiskImage(release, to: URL(fileURLWithPath: folder.root)) { recorder.add($0) }

        #expect(saved.lastPathComponent == "Mac-Cleaner-1.0.0.dmg")
        #expect(try AppUpdateChecksums.sha256(of: saved) == "6b7778cce550ab6a87ea9a56770165cdc629a74905cf41c385d26dee2c29a157")
        let stages = recorder.stages
        #expect(stages.contains(.verifyingChecksum))
        #expect(stages.contains(.openingDiskImage))
        #expect(stages.contains(.verifyingApp))
        #expect(stages.contains { if case .downloading(let received, _) = $0 { return received == 9_346_057 } else { return false } })
    }

    @Test func checksTheAppInsideTheDiskImage() async throws {
        let folder = try TemporaryTree("UpdateInspect")
        let mounted = try await AppUpdateInstaller.attach(ReleaseFixture.diskImage, mountRoot: URL(fileURLWithPath: try folder.makeDirectory("mount")))
        do {
            let app = try await AppUpdateInstaller.verifyApp(in: mounted.mountPoint, policy: .macCleaner, currentVersion: "0.9.0", releaseVersion: "1.0.0")
            #expect(app.version == "1.0.0")
            #expect(app.build == "1")
            #expect(app.url.lastPathComponent == "Mac Cleaner.app")
            try AppUpdateInstaller.checkSignature(of: app.url, policy: .macCleaner)
            // Another developer's requirement rejects the same, valid signature.
            var other = AppUpdateInstaller.Policy.macCleaner
            other.teamIdentifier = "ABCDE12345"
            #expect(throws: AppUpdateError.wrongDeveloper) { try AppUpdateInstaller.checkSignature(of: app.url, policy: other) }
            var renamed = AppUpdateInstaller.Policy.macCleaner
            renamed.bundleIdentifier = "com.example.Other"
            #expect(throws: AppUpdateError.wrongDeveloper) { try AppUpdateInstaller.checkSignature(of: app.url, policy: renamed) }
        } catch {
            await AppUpdateInstaller.detach(mounted)
            throw error
        }
        await AppUpdateInstaller.detach(mounted)
        #expect(!FileManager.default.fileExists(atPath: mounted.mountPoint.path))
    }

    @Test func rejectsAnOlderOrEqualVersion() async throws {
        let folder = try TemporaryTree("UpdateOlder")
        for current in ["1.0.0", "1.0", "2.0.0"] {
            await #expect(throws: AppUpdateError.notNewer(found: "1.0.0", installed: current)) {
                _ = try await installer(currentVersion: current, files: realFiles)
                    .downloadVerifiedDiskImage(try ReleaseFixture.release(), to: URL(fileURLWithPath: folder.root)) { _ in }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.root).isEmpty)
    }

    @Test func rejectsADiskImageThatIsntTheAnnouncedVersion() async throws {
        let folder = try TemporaryTree("UpdateVersion")
        let files = ["Mac-Cleaner-1.1.0.dmg": ReleaseFixture.diskImage, "Mac-Cleaner-1.1.0.sha256": try renamedChecksums(in: folder, version: "1.1.0")]
        await #expect(throws: AppUpdateError.versionMismatch(found: "1.0.0", release: "1.1.0")) {
            _ = try await installer(currentVersion: "0.9.0", files: files)
                .downloadVerifiedDiskImage(try ReleaseFixture.release(version: "1.1.0"), to: URL(fileURLWithPath: folder.root)) { _ in }
        }
    }

    // MARK: Checksums

    @Test func rejectsAWrongChecksum() async throws {
        let folder = try TemporaryTree("UpdateWrongHash")
        let sums = try folder.makeFile("Mac-Cleaner-1.0.0.sha256", size: 0)
        try "\(String(repeating: "f", count: 64))  Mac-Cleaner-1.0.0.dmg\n".write(toFile: sums, atomically: true, encoding: .utf8)
        await #expect(throws: AppUpdateError.checksumMismatch) {
            _ = try await installer(currentVersion: "0.9.0", files: ["Mac-Cleaner-1.0.0.dmg": ReleaseFixture.diskImage, "Mac-Cleaner-1.0.0.sha256": URL(fileURLWithPath: sums)])
                .downloadVerifiedDiskImage(try ReleaseFixture.release(), to: URL(fileURLWithPath: try folder.makeDirectory("out"))) { _ in }
        }
    }

    @Test func rejectsAGitHubDigestThatDisagrees() async throws {
        let folder = try TemporaryTree("UpdateDigest")
        await #expect(throws: AppUpdateError.checksumsDisagree) {
            _ = try await installer(currentVersion: "0.9.0", files: realFiles)
                .downloadVerifiedDiskImage(try ReleaseFixture.release(digest: String(repeating: "0", count: 64)), to: URL(fileURLWithPath: folder.root)) { _ in }
        }
    }

    @Test func rejectsAReleaseWithoutChecksums() async throws {
        let folder = try TemporaryTree("UpdateNoSums")
        var release = try ReleaseFixture.release()
        release.checksums = nil
        await #expect(throws: AppUpdateError.noChecksums) {
            _ = try await installer(currentVersion: "0.9.0", files: realFiles)
                .downloadVerifiedDiskImage(release, to: URL(fileURLWithPath: folder.root)) { _ in }
        }
    }

    @Test func rejectsACorruptedDiskImage() async throws {
        let folder = try TemporaryTree("UpdateCorrupt")
        let corrupted = try corruptedCopy(in: folder)
        // With the release's checksum: the download doesn't match.
        await #expect(throws: AppUpdateError.checksumMismatch) {
            _ = try await installer(currentVersion: "0.9.0", files: ["Mac-Cleaner-1.0.0.dmg": corrupted, "Mac-Cleaner-1.0.0.sha256": ReleaseFixture.checksums])
                .downloadVerifiedDiskImage(try ReleaseFixture.release(), to: URL(fileURLWithPath: try folder.makeDirectory("out1"))) { _ in }
        }
        // Even with a checksum that matches the damage, the image or its app is refused.
        let sums = try folder.makeFile("damaged.sha256", size: 0)
        try "\(try AppUpdateChecksums.sha256(of: corrupted))  Mac-Cleaner-1.0.0.dmg\n".write(toFile: sums, atomically: true, encoding: .utf8)
        do {
            _ = try await installer(currentVersion: "0.9.0", files: ["Mac-Cleaner-1.0.0.dmg": corrupted, "Mac-Cleaner-1.0.0.sha256": URL(fileURLWithPath: sums)])
                .downloadVerifiedDiskImage(try ReleaseFixture.release(), to: URL(fileURLWithPath: try folder.makeDirectory("out2"))) { _ in }
            Issue.record("A damaged disk image must not pass")
        } catch let error as AppUpdateError {
            switch error {
            case .diskImageUnreadable, .signatureInvalid, .appMissing, .unreadableVersion: break
            default: Issue.record("Unexpected error: \(error)")
            }
        }
    }

    // MARK: Signatures

    @Test func rejectsAnAdHocSignedApp() async throws {
        let folder = try TemporaryTree("UpdateAdHoc")
        let (image, sums) = try await Self.makeDiskImage(in: folder, version: "1.0.0", signing: .adHoc)
        await #expect(throws: AppUpdateError.wrongDeveloper) {
            _ = try await installer(currentVersion: "0.9.0", files: ["Mac-Cleaner-1.0.0.dmg": image, "Mac-Cleaner-1.0.0.sha256": sums])
                .downloadVerifiedDiskImage(try ReleaseFixture.release(), to: URL(fileURLWithPath: try folder.makeDirectory("out"))) { _ in }
        }
    }

    @Test func rejectsAnUnsignedApp() async throws {
        let folder = try TemporaryTree("UpdateUnsigned")
        let (image, sums) = try await Self.makeDiskImage(in: folder, version: "1.0.0", signing: .none)
        await #expect(throws: AppUpdateError.signatureInvalid("it isn't signed")) {
            _ = try await installer(currentVersion: "0.9.0", files: ["Mac-Cleaner-1.0.0.dmg": image, "Mac-Cleaner-1.0.0.sha256": sums])
                .downloadVerifiedDiskImage(try ReleaseFixture.release(), to: URL(fileURLWithPath: try folder.makeDirectory("out"))) { _ in }
        }
    }

    // MARK: Replacing the app (temporary folders only)

    @Test func replacesTheAppAtomicallyAndKeepsThePreviousVersionInTheTrash() async throws {
        let folder = try TemporaryTree("UpdateSwap")
        let applications = URL(fileURLWithPath: try folder.makeDirectory("Applications"))
        let trash = URL(fileURLWithPath: try folder.makeDirectory("Trash"))
        let target = try Self.makeApp(in: applications, version: "0.9.0")
        let mounted = try await AppUpdateInstaller.attach(ReleaseFixture.diskImage, mountRoot: URL(fileURLWithPath: try folder.makeDirectory("mount")))
        do {
            let newApp = mounted.mountPoint.appendingPathComponent("Mac Cleaner.app")
            let trashed = try await AppUpdateInstaller.replace(target, with: newApp, expectedVersion: "1.0.0", policy: .macCleaner) { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
            #expect(try AppUpdateInstaller.bundleVersion(of: target, policy: .macCleaner).version == "1.0.0")
            try AppUpdateInstaller.checkSignature(of: target, policy: .macCleaner)
            #expect(trashed?.lastPathComponent == "Mac Cleaner 0.9.0.app")
            if let trashed { #expect(try AppUpdateInstaller.bundleVersion(of: trashed, policy: .macCleaner).version == "0.9.0") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Mac Cleaner.app"])
        } catch {
            await AppUpdateInstaller.detach(mounted)
            throw error
        }
        await AppUpdateInstaller.detach(mounted)
    }

    @Test func rollsBackWhenTheInstalledCopyIsWrong() async throws {
        let folder = try TemporaryTree("UpdateRollback")
        let applications = URL(fileURLWithPath: try folder.makeDirectory("Applications"))
        let target = try Self.makeApp(in: applications, version: "0.9.0")
        let mounted = try await AppUpdateInstaller.attach(ReleaseFixture.diskImage, mountRoot: URL(fileURLWithPath: try folder.makeDirectory("mount")))
        do {
            let newApp = mounted.mountPoint.appendingPathComponent("Mac Cleaner.app")
            await #expect(throws: AppUpdateError.swapFailed("simulated failure")) {
                try await AppUpdateInstaller.replace(target, with: newApp, expectedVersion: "1.0.0", policy: .macCleaner,
                                                     trash: { _ in Issue.record("Nothing may be trashed on rollback"); return nil },
                                                     verifyInstalled: { _ in throw AppUpdateError.swapFailed("simulated failure") })
            }
            // The previous app is back and nothing else was left behind.
            #expect(try AppUpdateInstaller.bundleVersion(of: target, policy: .macCleaner).version == "0.9.0")
            #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Mac Cleaner.app"])
        } catch {
            await AppUpdateInstaller.detach(mounted)
            throw error
        }
        await AppUpdateInstaller.detach(mounted)
    }

    @Test func refusesToInstallACopyThatIsntSigned() async throws {
        let folder = try TemporaryTree("UpdateUnsignedCopy")
        let applications = URL(fileURLWithPath: try folder.makeDirectory("Applications"))
        let target = try Self.makeApp(in: applications, version: "0.9.0")
        let impostor = try Self.makeApp(in: URL(fileURLWithPath: try folder.makeDirectory("Downloads")), version: "1.0.0")
        await #expect(throws: AppUpdateError.signatureInvalid("it isn't signed")) {
            try await AppUpdateInstaller.replace(target, with: impostor, expectedVersion: "1.0.0", policy: .macCleaner) { _ in nil }
        }
        #expect(try AppUpdateInstaller.bundleVersion(of: target, policy: .macCleaner).version == "0.9.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Mac Cleaner.app"])
    }

    // MARK: Helpers

    enum Signing { case none, adHoc }

    /// A minimal "Mac Cleaner.app" with the given version. Its program is a shell script,
    /// or a copy of `/usr/bin/true` when it's going to be signed (a Mach-O keeps its
    /// signature inside the file, so it survives being copied into a disk image).
    static func makeApp(in folder: URL, version: String, machO: Bool = false) throws -> URL {
        let app = folder.appendingPathComponent("Mac Cleaner.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Mac Cleaner")
        if machO {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        } else {
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.maccleaner.MacCleaner",
            "CFBundleExecutable": "Mac Cleaner",
            "CFBundleName": "Mac Cleaner",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// A disk image like a release's, holding a fake app, and its checksum file.
    static func makeDiskImage(in folder: TemporaryTree, version: String, signing: Signing) async throws -> (URL, URL) {
        let staging = URL(fileURLWithPath: try folder.makeDirectory("staging"))
        let app = try makeApp(in: staging, version: version, machO: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Mac Cleaner").path
        switch signing {
        case .adHoc:
            let result = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path], timeout: 60)
            #expect(result.succeeded, "codesign failed: \(result.combinedOutput)")
        case .none:
            // The copied program carries Apple's signature; remove it so nothing is signed.
            let result = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--remove-signature", executable], timeout: 60)
            #expect(result.succeeded, "codesign failed: \(result.combinedOutput)")
        }
        let image = URL(fileURLWithPath: folder.path("Mac-Cleaner-\(version).dmg"))
        let created = try await ProcessRunner.run("/usr/bin/hdiutil", arguments: ["create", "-volname", "Mac Cleaner", "-srcfolder", staging.path, "-format", "UDZO", "-ov", image.path], timeout: 120)
        #expect(created.succeeded, "hdiutil create failed: \(created.combinedOutput)")
        let sums = URL(fileURLWithPath: folder.path("Mac-Cleaner-\(version).sha256"))
        try "\(try AppUpdateChecksums.sha256(of: image))  Mac-Cleaner-\(version).dmg\n".write(to: sums, atomically: true, encoding: .utf8)
        return (image, sums)
    }

    /// A copy of the release with bytes changed in the middle of the image.
    private func corruptedCopy(in folder: TemporaryTree) throws -> URL {
        let copy = URL(fileURLWithPath: folder.path("Mac-Cleaner-1.0.0.dmg"))
        try FileManager.default.copyItem(at: ReleaseFixture.diskImage, to: copy)
        let handle = try FileHandle(forUpdating: copy)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        for offset in stride(from: size / 3, to: size / 3 + 4096 * 64, by: 4096) {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(repeating: 0xA5, count: 512))
        }
        return copy
    }

    /// The release's checksum file with the disk image listed under another version's name.
    private func renamedChecksums(in folder: TemporaryTree, version: String) throws -> URL {
        let text = try String(contentsOf: ReleaseFixture.checksums, encoding: .utf8).replacingOccurrences(of: "1.0.0", with: version)
        let url = URL(fileURLWithPath: folder.path("Mac-Cleaner-\(version).sha256"))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Where the running app may replace itself.
struct AppUpdateLocationTests {
    @Test func writableFoldersAreAcceptedReadOnlyAndTranslocatedOnesAreNot() throws {
        let folder = try TemporaryTree("UpdateLocation")
        let writable = try AppUpdateInstallerTests.makeApp(in: URL(fileURLWithPath: try folder.makeDirectory("Applications")), version: "1.0.0")
        #expect(try AppUpdateInstaller.replaceableLocation(of: writable) == writable)

        let lockedFolder = try folder.makeDirectory("Locked")
        let locked = try AppUpdateInstallerTests.makeApp(in: URL(fileURLWithPath: lockedFolder), version: "1.0.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedFolder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder) }
        #expect(throws: AppUpdateError.self) { try AppUpdateInstaller.replaceableLocation(of: locked) }

        let translocated = URL(fileURLWithPath: "/private/var/folders/zz/AppTranslocation/1234/d/Mac Cleaner.app")
        #expect(throws: AppUpdateError.self) { try AppUpdateInstaller.replaceableLocation(of: translocated) }
    }

    @Test func uniqueNamesNeverOverwrite() throws {
        let folder = try TemporaryTree("UpdateUnique")
        let root = URL(fileURLWithPath: folder.root)
        #expect(AppUpdateInstaller.uniqueURL(in: root, name: "Mac-Cleaner-1.0.0.dmg").lastPathComponent == "Mac-Cleaner-1.0.0.dmg")
        try folder.makeFile("Mac-Cleaner-1.0.0.dmg", size: 1)
        #expect(AppUpdateInstaller.uniqueURL(in: root, name: "Mac-Cleaner-1.0.0.dmg").lastPathComponent == "Mac-Cleaner-1.0.0 2.dmg")
    }

    @Test func readsTheMountPointFromHdiutil() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
          <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk12</string></dict>
          <dict><key>dev-entry</key><string>/dev/disk13s1</string><key>mount-point</key><string>/private/tmp/update/mount/dmg.G1ecQL</string></dict>
        </array></dict></plist>
        """
        let point = AppUpdateInstaller.mountPoint(fromAttachOutput: Data(plist.utf8), under: URL(fileURLWithPath: "/private/tmp/update/mount"))
        #expect(point?.path == "/private/tmp/update/mount/dmg.G1ecQL")
        #expect(AppUpdateInstaller.mountPoint(fromAttachOutput: Data("garbage".utf8), under: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func theRequirementNamesMacCleanersTeam() {
        #expect(AppUpdateInstaller.Policy.macCleaner.codeRequirement
                == "identifier \"com.maccleaner.MacCleaner\" and anchor apple generic and certificate leaf[subject.OU] = \"244735TY4Y\"")
        #expect(AppUpdateInstaller.Policy.macCleaner.requiresNotarization)
    }
}
