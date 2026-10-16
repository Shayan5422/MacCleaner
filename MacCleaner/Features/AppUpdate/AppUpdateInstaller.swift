import Darwin
import Foundation
import Security

/// Downloads, verifies and installs a Mac Cleaner release.
///
/// Nothing is installed unless every check passes:
/// 1. the disk image matches the SHA-256 published with the release (and GitHub's own digest);
/// 2. it opens read-only and contains `Mac Cleaner.app`;
/// 3. the app's signature is valid (strict, all architectures, nested code) and satisfies
///    `identifier "com.maccleaner.MacCleaner" and anchor apple generic and certificate leaf[subject.OU] = "244735TY4Y"`;
/// 4. Gatekeeper accepts it as notarized by Apple;
/// 5. its version is the release's version and newer than the running one.
///
/// The installed app is then replaced atomically (`renamex_np` with `RENAME_SWAP`) and
/// put back if anything fails afterwards. The disk image is detached and temporary
/// files are removed on every path.
struct AppUpdateInstaller: Sendable {
    /// Who an update must come from.
    struct Policy: Sendable, Equatable {
        var bundleIdentifier: String
        var teamIdentifier: String
        var appName: String
        var requiresNotarization: Bool

        static let macCleaner = Policy(
            bundleIdentifier: "com.maccleaner.MacCleaner",
            teamIdentifier: "244735TY4Y",
            appName: "Mac Cleaner.app",
            requiresNotarization: true
        )

        /// The code requirement the new app's signature must satisfy.
        var codeRequirement: String {
            "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
    }

    enum Stage: Sendable, Equatable {
        case downloading(received: Int64, expected: Int64?)
        case verifyingChecksum
        case openingDiskImage
        case verifyingApp
        case installing
    }

    /// A downloaded disk image whose checksum matched, in its own temporary folder.
    struct VerifiedDownload: Sendable {
        var diskImage: URL
        var folder: URL
    }

    struct MountedImage: Sendable {
        var mountPoint: URL
    }

    /// The app inside the disk image, after every check passed.
    struct VerifiedApp: Sendable, Equatable {
        var url: URL
        var version: String
        var build: String?
    }

    static let maximumDownloadBytes: Int64 = 300_000_000
    static let maximumChecksumBytes = 64 * 1024

    var currentVersion: String
    var transport: AppUpdateTransport = .live
    var policy: Policy = .macCleaner

    // MARK: - Whole flows

    /// Downloads and verifies the release, then replaces `target` with it.
    func install(_ release: AppRelease, replacing target: URL, progress: @escaping @Sendable (Stage) -> Void) async throws -> VerifiedApp {
        let download = try await download(release, progress: progress)
        defer { Self.removeTemporaryFolder(download.folder) }
        return try await withVerifiedApp(in: download, release: release, progress: progress) { app in
            try Task.checkCancellation()
            progress(.installing)
            try await Self.replace(target, with: app.url, expectedVersion: app.version, policy: policy)
            return app
        }
    }

    /// Downloads and verifies the release without installing it, and moves the verified
    /// disk image to `folder` (for people who install it themselves).
    func downloadVerifiedDiskImage(_ release: AppRelease, to folder: URL, progress: @escaping @Sendable (Stage) -> Void) async throws -> URL {
        let download = try await download(release, progress: progress)
        defer { Self.removeTemporaryFolder(download.folder) }
        _ = try await withVerifiedApp(in: download, release: release, progress: progress) { $0 }
        let destination = Self.uniqueURL(in: folder, name: download.diskImage.lastPathComponent)
        try FileManager.default.moveItem(at: download.diskImage, to: destination)
        return destination
    }

    /// Mounts the disk image, verifies the app inside and runs `body` with it. The image
    /// is detached afterwards, whatever happens.
    private func withVerifiedApp<T: Sendable>(
        in download: VerifiedDownload,
        release: AppRelease,
        progress: @escaping @Sendable (Stage) -> Void,
        body: (VerifiedApp) async throws -> T
    ) async throws -> T {
        progress(.openingDiskImage)
        let mountRoot = download.folder.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let mounted = try await Self.attach(download.diskImage, mountRoot: mountRoot)
        do {
            progress(.verifyingApp)
            let app = try await Self.verifyApp(in: mounted.mountPoint, policy: policy, currentVersion: currentVersion, releaseVersion: release.version)
            let result = try await body(app)
            await Self.detach(mounted)
            return result
        } catch {
            await Self.detach(mounted)
            throw error
        }
    }

    // MARK: - Download

    /// Downloads the disk image and the checksum file into a new temporary folder and
    /// verifies the checksum. The caller removes `folder`.
    func download(_ release: AppRelease, into parent: URL = FileManager.default.temporaryDirectory, progress: @escaping @Sendable (Stage) -> Void) async throws -> VerifiedDownload {
        guard let image = release.diskImage else { throw AppUpdateError.noDiskImage }
        guard let checksums = release.checksums else { throw AppUpdateError.noChecksums }
        let folder = parent.appendingPathComponent("MacCleanerUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var request = URLRequest(url: checksums.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpShouldHandleCookies = false
            request.setValue(AppUpdateChecker.userAgent(version: currentVersion), forHTTPHeaderField: "User-Agent")
            let (data, response) = try await transport.fetch(request, Self.maximumChecksumBytes)
            guard (200..<300).contains(response.statusCode) else { throw AppUpdateError.httpStatus(response.statusCode) }
            let checksumText = String(decoding: data, as: UTF8.self)

            progress(.downloading(received: 0, expected: image.size))
            let destination = folder.appendingPathComponent(image.name)
            try await transport.download(image.url, destination, Self.maximumDownloadBytes) { received, expected in
                progress(.downloading(received: received, expected: expected ?? image.size))
            }
            try Task.checkCancellation()

            progress(.verifyingChecksum)
            try AppUpdateChecksums.verify(file: destination, fileName: image.name, checksumFile: checksumText, githubDigest: image.digest)
            return VerifiedDownload(diskImage: destination, folder: folder)
        } catch {
            Self.removeTemporaryFolder(folder)
            if error is CancellationError { throw AppUpdateError.cancelled }
            throw error
        }
    }

    // MARK: - Disk image

    /// `hdiutil attach -nobrowse -readonly -noautoopen -mountrandom <root>`: read-only,
    /// hidden from Finder, at a random folder inside `mountRoot`.
    static func attach(_ image: URL, mountRoot: URL) async throws -> MountedImage {
        let result: CommandResult
        do {
            result = try await ProcessRunner.run(
                "/usr/bin/hdiutil",
                arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, "-plist", image.path],
                timeout: 180
            )
        } catch {
            throw AppUpdateError.diskImageUnreadable(error.localizedDescription)
        }
        guard result.succeeded else {
            let reason = result.standardError.split(separator: "\n").map(String.init)
                .last { !$0.contains("deprecated") && !$0.isEmpty } ?? "hdiutil exited with code \(result.exitCode)"
            throw AppUpdateError.diskImageUnreadable(reason.replacingOccurrences(of: "hdiutil: attach failed - ", with: ""))
        }
        guard let mountPoint = mountPoint(fromAttachOutput: Data(result.standardOutput.utf8), under: mountRoot) else {
            throw AppUpdateError.diskImageUnreadable("it has no readable volume")
        }
        return MountedImage(mountPoint: mountPoint)
    }

    /// The mount point `hdiutil attach -plist` reported inside `root`.
    static func mountPoint(fromAttachOutput data: Data, under root: URL) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let rootPath = root.resolvingSymlinksInPath().path
        let points = entities.compactMap { $0["mount-point"] as? String }
        let inside = points.first { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(rootPath + "/") }
        return (inside ?? points.first).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func detach(_ image: MountedImage) async {
        for arguments in [["detach", image.mountPoint.path], ["detach", "-force", image.mountPoint.path]] {
            if let result = try? await ProcessRunner.run("/usr/bin/hdiutil", arguments: arguments, timeout: 60), result.succeeded {
                return
            }
        }
    }

    // MARK: - Verifying the app

    static func verifyApp(in mountPoint: URL, policy: Policy, currentVersion: String, releaseVersion: String) async throws -> VerifiedApp {
        let app = mountPoint.appendingPathComponent(policy.appName, isDirectory: true)
        var isDirectory: ObjCBool = false
        let isLink = (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        guard !isLink, FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppUpdateError.appMissing
        }
        try checkSignature(of: app, policy: policy)
        if policy.requiresNotarization {
            try await checkNotarization(of: app)
        }
        let (version, build) = try bundleVersion(of: app, policy: policy)
        guard AppVersion.compare(version, releaseVersion) == .orderedSame else {
            throw AppUpdateError.versionMismatch(found: version, release: releaseVersion)
        }
        guard AppVersion.isNewer(version, than: currentVersion) else {
            throw AppUpdateError.notNewer(found: version, installed: currentVersion)
        }
        return VerifiedApp(url: app, version: version, build: build)
    }

    /// Strict signature validation, then Mac Cleaner's code requirement.
    static func checkSignature(of app: URL, policy: Policy) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw AppUpdateError.signatureInvalid("it couldn't be read")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var errors: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &errors)
        let validityError = errors?.takeRetainedValue()
        switch validity {
        case errSecSuccess:
            break
        case errSecCSUnsigned:
            throw AppUpdateError.signatureInvalid("it isn't signed")
        default:
            throw AppUpdateError.signatureInvalid(describe(validity, validityError))
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(policy.codeRequirement as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw AppUpdateError.signatureInvalid("the code requirement couldn't be built")
        }
        var requirementErrors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &requirementErrors)
        let requirementError = requirementErrors?.takeRetainedValue()
        switch status {
        case errSecSuccess:
            return
        case errSecCSReqFailed:
            throw AppUpdateError.wrongDeveloper
        default:
            throw AppUpdateError.signatureInvalid(describe(status, requirementError))
        }
    }

    /// Gatekeeper's assessment (`spctl --assess --type execute`): accepted as notarized Developer ID software.
    static func checkNotarization(of app: URL) async throws {
        let result: CommandResult
        do {
            result = try await ProcessRunner.run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "-vv", app.path], timeout: 120)
        } catch {
            throw AppUpdateError.notNotarized("Gatekeeper couldn't assess it: \(error.localizedDescription)")
        }
        let output = result.combinedOutput
        let source = output.split(separator: "\n").first { $0.hasPrefix("source=") }.map { String($0.dropFirst("source=".count)) }
        guard result.exitCode == 0, !result.timedOut, source == "Notarized Developer ID" else {
            if let source { throw AppUpdateError.notNotarized("Gatekeeper rejected it: \(source)") }
            if result.timedOut { throw AppUpdateError.notNotarized("Gatekeeper didn't answer in time") }
            throw AppUpdateError.notNotarized("Gatekeeper rejected it")
        }
    }

    /// Short version and build of the app, after checking its bundle identifier.
    static func bundleVersion(of app: URL, policy: Policy) throws -> (version: String, build: String?) {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = (plist["CFBundleShortVersionString"] as? String).flatMap(AppVersion.normalized) else {
            throw AppUpdateError.unreadableVersion
        }
        guard plist["CFBundleIdentifier"] as? String == policy.bundleIdentifier else { throw AppUpdateError.wrongDeveloper }
        return (version, plist["CFBundleVersion"] as? String)
    }

    private static func describe(_ status: OSStatus, _ error: CFError?) -> String {
        if let error, let description = CFErrorCopyDescription(error) as String?, !description.isEmpty {
            return description
        }
        if let message = SecCopyErrorMessageString(status, nil) as String? { return message }
        return "code \(status)"
    }

    // MARK: - Replacing the installed app

    /// The running bundle, if Mac Cleaner may replace it there; otherwise the reason why not.
    static func replaceableLocation(of bundle: URL) throws -> URL {
        let path = bundle.standardizedFileURL.path
        let folder = bundle.deletingLastPathComponent()
        let folderName = PathUtilities.abbreviate(folder.path)
        if path.contains("/AppTranslocation/") {
            throw AppUpdateError.locationNotWritable("the temporary location macOS opened it from (move Mac Cleaner to Applications first)")
        }
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey, .isSymbolicLinkKey])
        if values?.volumeIsReadOnly == true { throw AppUpdateError.locationNotWritable(folderName) }
        if values?.isSymbolicLink == true { throw AppUpdateError.locationNotWritable(folderName) }
        guard access(folder.path, W_OK) == 0, access(bundle.path, W_OK) == 0 else {
            throw AppUpdateError.locationNotWritable(folderName)
        }
        return bundle
    }

    /// Replaces `target` with a copy of `newApp`, atomically:
    /// 1. copy the new app to a hidden sibling of `target` (same volume);
    /// 2. check the copy's signature again;
    /// 3. swap the two with `renamex_np(RENAME_SWAP)`;
    /// 4. check the installed version (swapping back if it's wrong);
    /// 5. move the previous app to the Trash.
    /// Returns where the previous app went in the Trash, if it could be moved there.
    ///
    /// - Parameters:
    ///   - trash: Moves the previous version away (tests use a folder of their own).
    ///   - verifyInstalled: Checks the app at `target` after the swap; by default that it's `expectedVersion`.
    @discardableResult
    static func replace(
        _ target: URL,
        with newApp: URL,
        expectedVersion: String,
        policy: Policy,
        trash: (URL) throws -> URL? = AppUpdateInstaller.moveToTrash,
        verifyInstalled: ((URL) throws -> Void)? = nil
    ) async throws -> URL? {
        let folder = target.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-update-\(UUID().uuidString.prefix(8)).app", isDirectory: true)
        let previousVersion = (try? bundleVersion(of: target, policy: policy).version) ?? ""

        // 1–2: copy and check the copy. Only the staged copy exists if this fails.
        do {
            let result = try await ProcessRunner.run("/usr/bin/ditto", arguments: [newApp.path, staged.path], timeout: 600)
            guard result.succeeded else {
                throw AppUpdateError.copyFailed(result.combinedOutput.split(separator: "\n").last.map(String.init) ?? "ditto exited with code \(result.exitCode)")
            }
            try checkSignature(of: staged, policy: policy)
            guard (try? bundleVersion(of: staged, policy: policy).version) == expectedVersion else {
                throw AppUpdateError.copyFailed("the copy doesn't contain version \(expectedVersion)")
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        // 3: swap. Afterwards `target` is the new app and `staged` the previous one.
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw AppUpdateError.swapFailed(reason)
        }

        // 4: the installed app must be the new version; otherwise put the previous one back.
        do {
            if let verifyInstalled {
                try verifyInstalled(target)
            } else if (try? bundleVersion(of: target, policy: policy).version) != expectedVersion {
                throw AppUpdateError.swapFailed("the new version couldn't be read after installing")
            }
        } catch {
            if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                try? FileManager.default.removeItem(at: staged)
            }
            throw (error as? AppUpdateError) ?? AppUpdateError.swapFailed(error.localizedDescription)
        }

        // 5: the previous version goes to the Trash with a readable name.
        let trashedURL: URL
        do {
            guard let moved = try trash(staged) else { return nil }
            trashedURL = moved
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return nil
        }
        let readableName = previousVersion.isEmpty ? policy.appName : "\(target.deletingPathExtension().lastPathComponent) \(previousVersion).app"
        let renamed = uniqueURL(in: trashedURL.deletingLastPathComponent(), name: readableName)
        if (try? FileManager.default.moveItem(at: trashedURL, to: renamed)) != nil { return renamed }
        return trashedURL
    }

    /// `FileManager.trashItem`, returning where the item went.
    static func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    // MARK: - Relaunching

    /// Starts a small detached shell that waits for this process to exit, then opens the
    /// app again. The caller terminates the app right after.
    static func relaunch(_ app: URL, afterExitOf pid: pid_t = getpid()) throws {
        // Paths are passed as arguments, never inserted into the script.
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 100 ]; do /bin/sleep 0.2; i=$((i+1)); done; /bin/sleep 1; /usr/bin/open -n \"$2\""
        let arguments = ["/bin/sh", "-c", script, "sh", String(pid), app.path]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())"]

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session, so the shell outlives this process.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, &argv, &envp)
        guard status == 0 else {
            throw AppUpdateError.swapFailed("Mac Cleaner couldn't be reopened (\(String(cString: strerror(status))))")
        }
    }

    // MARK: - Helpers

    /// `name`, or "name 2", "name 3"… if it's taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Removes a temporary folder unless a disk image is still mounted inside it.
    static func removeTemporaryFolder(_ folder: URL) {
        let mountRoot = folder.appendingPathComponent("mount", isDirectory: true)
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path), !leftovers.isEmpty {
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
