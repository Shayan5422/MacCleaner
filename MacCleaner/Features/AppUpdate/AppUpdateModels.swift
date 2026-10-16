import Foundation

/// Dotted numeric versions ("1.10.0", "v2.0"), compared number by number.
///
/// Release tags must be plain numbers: anything else ("1.2.0-beta", "latest", "1..2")
/// is malformed and never offered as an update.
enum AppVersion {
    /// [1, 10, 0] for "1.10.0" or "v1.10.0"; nil for anything else.
    static func components(_ string: String) -> [Int]? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// "1.2.0" for "v1.2.0"; nil when malformed.
    static func normalized(_ string: String) -> String? {
        components(string).map { $0.map(String.init).joined(separator: ".") }
    }

    /// Compares numerically with missing components treated as 0 ("1.2" == "1.2.0"); nil if either is malformed.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = components(lhs), let b = components(rhs) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True only when both versions are well formed and `candidate` is strictly newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

/// A downloadable file of a release.
struct AppReleaseAsset: Codable, Hashable, Sendable {
    var name: String
    /// Always HTTPS.
    var url: URL
    var size: Int64?
    /// SHA-256 GitHub computed for the file (lowercase hex), when it reports one.
    var digest: String?
}

/// A published Mac Cleaner release on GitHub, reduced to what the app uses.
struct AppRelease: Codable, Hashable, Sendable {
    /// Normalized version from the tag, e.g. "1.2.0" for tag "v1.2.0".
    var version: String
    var tagName: String
    var name: String?
    /// Release notes (Markdown).
    var notes: String?
    /// The release page on GitHub.
    var pageURL: URL
    var publishedAt: Date?
    /// `Mac-Cleaner-<version>.dmg`
    var diskImage: AppReleaseAsset?
    /// `Mac-Cleaner-<version>.zip`
    var archive: AppReleaseAsset?
    /// `Mac-Cleaner-<version>.sha256`: `shasum -a 256` output for the other files.
    var checksums: AppReleaseAsset?

    /// The update can be installed from the app: a disk image with published checksums.
    var canInstall: Bool { diskImage != nil && checksums != nil }
}

/// Outcome of one check.
enum AppUpdateCheckResult: Equatable, Sendable {
    case updateAvailable(AppRelease)
    /// The latest release isn't newer than this build (or is a draft, a prerelease or has a malformed tag).
    case upToDate(latest: String?)
    /// The repository has no published release yet (GitHub answers 404).
    case noReleases
    case failed(String)

    /// True when GitHub gave a definite answer (worth remembering as "checked").
    var isConclusive: Bool {
        if case .failed = self { return false }
        return true
    }

    /// One line for a manual check, e.g. "Mac Cleaner 1.1.0 is available".
    func message(currentVersion: String) -> String {
        switch self {
        case .updateAvailable(let release): return "Mac Cleaner \(release.version) is available."
        case .upToDate: return "Mac Cleaner \(currentVersion) is the newest version."
        case .noReleases: return "Mac Cleaner \(currentVersion) is the newest version. No releases are published yet."
        case .failed(let reason): return "Couldn't check for updates: \(reason)"
        }
    }
}

/// Why an update couldn't be downloaded, verified or installed. Every message says
/// what happened and that nothing was changed when that's the case.
enum AppUpdateError: LocalizedError, Equatable, Sendable {
    case insecureURL
    case httpStatus(Int)
    case tooLarge
    case network(String)
    case noDiskImage
    case noChecksums
    case checksumNotListed(String)
    case checksumMismatch
    case checksumsDisagree
    case diskImageUnreadable(String)
    case appMissing
    case signatureInvalid(String)
    case wrongDeveloper
    case notNotarized(String)
    case notNewer(found: String, installed: String)
    case versionMismatch(found: String, release: String)
    case unreadableVersion
    case locationNotWritable(String)
    case copyFailed(String)
    case swapFailed(String)
    case simulatedVersion
    case cancelled

    var errorDescription: String? {
        switch self {
        case .insecureURL:
            return "The download link doesn't use a secure (HTTPS) connection, so it wasn't opened."
        case .httpStatus(let code):
            return code == 404 ? "GitHub couldn't find the file (HTTP 404)." : "GitHub answered with an error (HTTP \(code))."
        case .tooLarge:
            return "The download is much larger than a Mac Cleaner release, so it was stopped."
        case .network(let message):
            return message
        case .noDiskImage:
            return "This release doesn't include a Mac Cleaner disk image."
        case .noChecksums:
            return "This release doesn't publish checksums, so its download can't be verified."
        case .checksumNotListed(let name):
            return "The release's checksum file doesn't list \(name), so the download can't be verified."
        case .checksumMismatch:
            return "The downloaded disk image doesn't match the release's checksum. It may be damaged or altered, so it wasn't opened."
        case .checksumsDisagree:
            return "GitHub's checksum and the release's checksum file disagree, so the download wasn't trusted."
        case .diskImageUnreadable(let reason):
            return "The disk image couldn't be opened: \(reason)"
        case .appMissing:
            return "The disk image doesn't contain Mac Cleaner.app."
        case .signatureInvalid(let reason):
            return "The app in the update isn't validly signed (\(reason)), so it wasn't installed."
        case .wrongDeveloper:
            return "The app in the update isn't signed by Mac Cleaner's developer (Developer ID team 244735TY4Y), so it wasn't installed."
        case .notNotarized(let reason):
            return "Apple's notarization of the update couldn't be confirmed (\(reason)), so it wasn't installed."
        case .notNewer(let found, let installed):
            return "The update contains version \(found), which isn't newer than the installed version \(installed)."
        case .versionMismatch(let found, let release):
            return "The disk image contains version \(found), but the release is \(release), so it wasn't installed."
        case .unreadableVersion:
            return "The version of the app in the update couldn't be read."
        case .locationNotWritable(let folder):
            return "Mac Cleaner can't replace itself in \(folder) because it doesn't have permission to change that folder."
        case .copyFailed(let reason):
            return "The new version couldn't be copied next to the installed app: \(reason)"
        case .swapFailed(let reason):
            return "The installed app couldn't be replaced: \(reason). The installed version was kept."
        case .simulatedVersion:
            return "Installing is turned off while a test version is simulated."
        case .cancelled:
            return "The update was cancelled. Nothing was changed."
        }
    }
}
