import Foundation

/// Where an app's update information came from.
enum UpdatesSource: String, Sendable, Codable, Hashable, CaseIterable {
    case appStore
    case sparkle
    case homebrew
    case none

    var title: String {
        switch self {
        case .appStore: return "App Store"
        case .sparkle: return "Developer feed"
        case .homebrew: return "Homebrew"
        case .none: return "—"
        }
    }

    var symbol: String {
        switch self {
        case .appStore: return "bag"
        case .sparkle: return "dot.radiowaves.left.and.right"
        case .homebrew: return "mug"
        case .none: return "questionmark.circle"
        }
    }
}

/// How an app keeps itself up to date, detected offline from its bundle.
/// Only the App Store, Sparkle feeds and Homebrew can be checked; the others are
/// shown as hints so people know where updates come from.
enum UpdatesMechanism: Sendable, Hashable {
    case appStore
    /// A Sparkle feed declared in Info.plist (HTTPS).
    case sparkleFeed(URL)
    /// A Sparkle feed served over plain HTTP. Not checked: the response could be tampered with.
    case sparkleInsecureFeed(String)
    /// Sparkle is bundled but the feed is configured at run time.
    case sparkleInApp
    case squirrel
    case electronUpdater
    case microsoftAutoUpdate
    case googleSoftwareUpdate
    case adobeCreativeCloud
    case jetBrains
    case mozilla
    case none

    var hint: String? {
        switch self {
        case .appStore:
            return "Updates are delivered by the App Store."
        case .sparkleFeed:
            return "The app checks its developer's update feed. Use the app's “Check for Updates…” command to install updates."
        case .sparkleInsecureFeed:
            return "The app's update feed uses an unencrypted (HTTP) connection, so Mac Cleaner doesn't check it. Use the app's “Check for Updates…” command."
        case .sparkleInApp:
            return "The app has a built-in updater whose feed isn't published in the app bundle. Use the app's “Check for Updates…” command."
        case .squirrel, .electronUpdater:
            return "The app updates itself in the background. Open the app to get the latest version."
        case .microsoftAutoUpdate:
            return "Updated by Microsoft AutoUpdate (Help › Check for Updates in Microsoft apps)."
        case .googleSoftwareUpdate:
            return "Updated automatically by Google's updater. Check About in the app to update."
        case .adobeCreativeCloud:
            return "Updated through the Adobe Creative Cloud app."
        case .jetBrains:
            return "Updated from the app itself or JetBrains Toolbox."
        case .mozilla:
            return "The app updates itself. Check “About” in the app to update."
        case .none:
            return nil
        }
    }

    var updatesItself: Bool {
        switch self {
        case .none, .appStore: return false
        default: return true
        }
    }
}

enum UpdatesStatus: String, Sendable, Codable, Hashable {
    case notChecked
    case checking
    case updateAvailable
    case upToDate
    /// A newer version exists but needs a newer macOS than this Mac runs.
    case incompatible
    /// No reliable source of update information.
    case unknown
    /// A check was attempted but failed (network, server or parsing error).
    case failed

    var title: String {
        switch self {
        case .notChecked: return "Not checked"
        case .checking: return "Checking…"
        case .updateAvailable: return "Update available"
        case .upToDate: return "Up to date"
        case .incompatible: return "Needs newer macOS"
        case .unknown: return "Unknown"
        case .failed: return "Check failed"
        }
    }

    var symbol: String {
        switch self {
        case .notChecked: return "circle.dashed"
        case .checking: return "arrow.triangle.2.circlepath"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .upToDate: return "checkmark.circle.fill"
        case .incompatible: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        case .failed: return "xmark.circle"
        }
    }

    /// Lower ranks sort first ("updates first").
    var sortRank: Int {
        switch self {
        case .updateAvailable: return 0
        case .incompatible: return 1
        case .failed: return 2
        case .checking: return 3
        case .upToDate: return 4
        case .unknown: return 5
        case .notChecked: return 6
        }
    }
}

/// The outcome of checking one app.
struct UpdatesCheckResult: Sendable, Codable, Hashable {
    var status: UpdatesStatus
    var source: UpdatesSource
    var latestVersion: String?
    /// Plain-language explanation of the result.
    var detail: String
    var releaseNotesURL: URL?
    /// Release notes text from the App Store (plain text).
    var releaseNotesText: String?
    /// `macappstore://` link to the app's page.
    var storeURL: URL?
    var homebrewToken: String?
    var releaseDate: Date?
    var minimumSystemVersion: String?
    var isCritical = false
    var checkedAt: Date
    /// The installed version when the check ran; a different version invalidates the result.
    var installedVersionAtCheck: String
}

/// One row of the Updates list.
struct UpdatesAppRow: Identifiable, Sendable, Hashable {
    var app: UninstallerApp
    var mechanism: UpdatesMechanism
    var result: UpdatesCheckResult?
    var isChecking = false

    var id: String { app.path }
    var name: String { app.name }
    var installedVersion: String { app.info.displayVersion }
    var status: UpdatesStatus { isChecking ? .checking : (result?.status ?? .notChecked) }
    var latestVersion: String? { result?.latestVersion }

    /// The source that can actually be checked for this app.
    var checkableSource: UpdatesSource {
        switch mechanism {
        case .appStore: return .appStore
        case .sparkleFeed: return .sparkle
        default: return .none
        }
    }

    var displaySource: UpdatesSource {
        if let source = result?.source, source != .none { return source }
        return checkableSource
    }

    // Sort keys (Table columns sort with key paths to Comparable values).
    var sortName: String { app.sortName }
    var sortInstalled: String { installedVersion }
    var sortLatest: String { latestVersion ?? "" }
    var sortSource: String { displaySource == .none ? "~" : displaySource.title }
    var sortSize: Int64 { app.sortSize }
    var sortLastUsed: Date { app.sortLastUsed }
    var sortStatus: Int { status.sortRank }
}

/// Errors from update checks, with messages people can act on.
enum UpdatesCheckError: LocalizedError, Sendable {
    case insecureURL
    case httpStatus(Int)
    case tooLarge
    case invalidFeed(String)
    case rateLimited
    case offline
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: return "The update feed doesn't use a secure (HTTPS) connection, so it wasn't checked."
        case .httpStatus(let code):
            if code == 404 { return "The update feed wasn't found on the developer's server (HTTP 404)." }
            return "The server returned an error (HTTP \(code))."
        case .tooLarge: return "The server's response was unexpectedly large and was ignored."
        case .invalidFeed(let reason): return "The update feed couldn't be read: \(reason)"
        case .rateLimited: return "The server asked Mac Cleaner to slow down. Try again in a minute."
        case .offline: return "Your Mac appears to be offline."
        case .underlying(let message): return message
        }
    }

    static func wrap(_ error: Error) -> UpdatesCheckError {
        if let error = error as? UpdatesCheckError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .underlying("The server didn't respond in time.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return .underlying("The server's security certificate couldn't be verified, so the check was stopped.")
            case .cannotFindHost, .dnsLookupFailed:
                return .underlying("The update server couldn't be found.")
            default:
                return .underlying(urlError.localizedDescription)
            }
        }
        return .underlying(error.localizedDescription)
    }
}
