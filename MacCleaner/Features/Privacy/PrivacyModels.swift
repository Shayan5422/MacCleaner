import Foundation

/// The kinds of browsing and usage traces the Privacy cleaner can remove.
enum PrivacyCategory: String, CaseIterable, Identifiable, Sendable, Hashable {
    case cache
    case history
    case downloads
    case cookies
    case websiteData
    case sessions
    case recentItems
    case appRecentDocuments

    var id: String { rawValue }

    /// Categories stored by browsers, in display order.
    static let browserCategories: [PrivacyCategory] = [.cache, .history, .downloads, .cookies, .websiteData, .sessions]

    var title: String {
        switch self {
        case .cache: return "Browser Cache"
        case .history: return "Browsing History"
        case .downloads: return "Download History"
        case .cookies: return "Cookies"
        case .websiteData: return "Website Data"
        case .sessions: return "Saved Tabs & Sessions"
        case .recentItems: return "Recent Items"
        case .appRecentDocuments: return "Apps’ Recent Documents"
        }
    }

    /// Compact label for summaries such as browser cards.
    var shortTitle: String {
        switch self {
        case .cache: return "Cache"
        case .history: return "History"
        case .downloads: return "Downloads list"
        case .cookies: return "Cookies"
        case .websiteData: return "Website data"
        case .sessions: return "Tabs & sessions"
        case .recentItems: return "Recent items"
        case .appRecentDocuments: return "App recents"
        }
    }

    var symbol: String {
        switch self {
        case .cache: return "shippingbox"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .cookies: return "person.badge.key"
        case .websiteData: return "globe"
        case .sessions: return "macwindow.on.rectangle"
        case .recentItems: return "clock"
        case .appRecentDocuments: return "doc.text"
        }
    }

    var safety: CleanupSafety {
        switch self {
        case .cache: return .safe
        case .history, .downloads, .sessions, .recentItems, .appRecentDocuments: return .review
        case .cookies, .websiteData: return .caution
        }
    }

    /// Removing this data signs people out of websites or resets site data.
    var signsOut: Bool { self == .cookies || self == .websiteData }

    /// Recreated automatically, so people may choose immediate deletion.
    var isRegenerable: Bool { self == .cache }

    var explanation: String {
        switch self {
        case .cache:
            return "Copies of images, scripts and pages that browsers keep so websites load faster."
        case .history:
            return "Websites you visited, typed addresses, frequently visited sites and address-bar suggestions."
        case .downloads:
            return "The list of files Safari downloaded. Chrome-based browsers and Firefox keep downloads inside browsing history."
        case .cookies:
            return "Small files websites use to keep you signed in and remember your choices."
        case .websiteData:
            return "Data websites store on your Mac: local storage, databases and offline content."
        case .sessions:
            return "Open and recently closed tabs that browsers save to restore your last session."
        case .recentItems:
            return "Recently used apps, documents and servers shown in the Apple menu."
        case .appRecentDocuments:
            return "Each app’s Open Recent list."
        }
    }

    var consequence: String {
        switch self {
        case .cache:
            return "Websites load a little slower the first time you visit them again. You stay signed in and nothing personal is lost. Browsers must be closed while their cache is cleaned."
        case .history:
            return "The browser forgets which sites you visited and stops suggesting them. Chrome-based browsers also forget their download list, which is stored with history. If history syncs with iCloud or a browser account, other devices keep their copy and it may sync back. Bookmarks and saved passwords are never touched."
        case .downloads:
            return "Only the list is cleared; downloaded files stay where they are. For Chrome-based browsers, clear Browsing History to remove their download list; for Firefox, use “Clear History” in the Firefox section."
        case .cookies:
            return "You’ll be signed out of websites, and some sites will ask for cookie consent again. Saved passwords are kept, so signing back in is quick."
        case .websiteData:
            return "Websites lose their stored settings and offline data, and you may be signed out. Web apps may download their data again. Extension settings are kept, but data an extension stored as website data may be reset."
        case .sessions:
            return "The browser can’t reopen your previous tabs or recently closed tabs."
        case .recentItems:
            return "The lists start empty. macOS may keep showing old entries until you log out or restart; your files are not affected."
        case .appRecentDocuments:
            return "Open Recent menus start empty. A running app may keep showing old entries until it quits; your documents are not affected."
        }
    }
}

/// One file or folder removed as part of a privacy item.
struct PrivacyCleanupTarget: Sendable, Hashable {
    var path: String
    /// What the file is ("Disk cache", "Cookies"…).
    var label: String?
    var snapshot: FileSnapshot?
    var usage: DiskUsage
}

/// A browser profile found on disk.
struct PrivacyBrowserProfile: Identifiable, Sendable, Hashable {
    /// Folder name ("Default", "Profile 1", "abcd.default-release"). Empty when the
    /// browser keeps a single profile directly in its data folder (Opera).
    var directoryName: String
    var displayName: String
    /// Profile folder in Application Support; nil when it doesn't exist or macOS blocks it.
    var dataPath: String?
    /// The profile's folder in ~/Library/Caches, if any.
    var cachePath: String?
    var isDefault: Bool

    var id: String { directoryName }
}

/// One row of results: related files of one category for one browser profile
/// (or one macOS list), removed together.
struct PrivacyDataItem: Identifiable, Sendable, Hashable {
    var id: String
    var category: PrivacyCategory
    /// nil for macOS items such as recent-items lists.
    var browserID: String?
    var ownerName: String
    var profileName: String?
    var targets: [PrivacyCleanupTarget]
    /// Display and selection model shared with the design system's candidate list.
    var candidate: CleanupCandidate
    /// The files sit in a folder macOS privacy protection doesn't let Mac Cleaner
    /// change (for example Safari's data without Full Disk Access). Sizes are
    /// shown, but the item is never offered for cleaning.
    var isProtected = false

    var usage: DiskUsage { targets.reduce(DiskUsage.zero) { $0 + $1.usage } }
    var bytes: Int64 { usage.reclaimableBytes }
    var safety: CleanupSafety { category.safety }

    var cleanupItems: [CleanupItem] {
        targets.map {
            CleanupItem(path: $0.path, purpose: .privacyData, snapshot: $0.snapshot, estimatedBytes: $0.usage.reclaimableBytes, category: category.title)
        }
    }
}

/// History details for one Firefox profile. Firefox history shares a database
/// with bookmarks, so it is cleared inside the database instead of deleting files.
struct PrivacyFirefoxHistoryStatus: Identifiable, Sendable, Hashable {
    var profile: PrivacyBrowserProfile
    var placesPath: String
    var databaseBytes: Int64
    /// nil when unknown (Firefox running, database unreadable).
    var visitCount: Int?
    var downloadCount: Int?
    var problem: String?

    var id: String { placesPath }
    var profileDirectory: String { (placesPath as NSString).deletingLastPathComponent }
}

/// The system-wide download history kept by macOS (Launch Services quarantine events).
struct PrivacyQuarantineStatus: Sendable, Hashable {
    var path: String
    var eventCount: Int?
    var isBlocked: Bool
    var problem: String?
}

/// Everything found for one browser.
struct PrivacyBrowserReport: Identifiable, Sendable {
    var browser: PrivacyBrowser
    var applicationPath: String?
    var profiles: [PrivacyBrowserProfile]
    var items: [PrivacyDataItem]
    /// Locations that exist but macOS didn't let Mac Cleaner read.
    var blockedLocations: [String]
    var firefoxHistory: [PrivacyFirefoxHistoryStatus]
    /// Main data folder, for "Reveal in Finder".
    var dataFolder: String?

    var id: String { browser.id }
    var isInstalled: Bool { applicationPath != nil }
    var isBlocked: Bool { !blockedLocations.isEmpty }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var hasData: Bool { !items.isEmpty || !firefoxHistory.isEmpty }

    func bytes(in category: PrivacyCategory) -> Int64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
    }

    /// Every item of the category is protected by macOS.
    func isProtected(_ category: PrivacyCategory) -> Bool {
        let matching = items.filter { $0.category == category }
        return !matching.isEmpty && matching.allSatisfy(\.isProtected)
    }

    var hasProtectedItems: Bool { items.contains(where: \.isProtected) }
}

/// Result of a privacy scan.
struct PrivacyScanResult: Sendable {
    var browsers: [PrivacyBrowserReport] = []
    /// Recent-items lists kept by macOS and apps.
    var systemItems: [PrivacyDataItem] = []
    var recentItemsBlocked = false
    var quarantine: PrivacyQuarantineStatus?
    var date = Date()
}
