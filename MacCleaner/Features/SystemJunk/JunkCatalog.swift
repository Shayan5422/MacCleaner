import Foundation

/// A kind of junk the System Junk scanner looks for, with plain-language
/// explanations shown next to the results.
struct JunkCategory: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let symbol: String
    /// What the data is.
    let explanation: String
    /// What happens when it's removed.
    let consequence: String
    /// Whether automatic cleaning may include this category (only regenerable data).
    let allowsAutomaticCleaning: Bool

    static let applicationCaches = JunkCategory(
        id: "junk.appCaches", title: "Application Caches", symbol: "shippingbox",
        explanation: "Temporary data apps store to speed things up, such as downloaded images and compiled resources.",
        consequence: "Apps rebuild their caches when needed. The first launch afterwards can be a little slower.",
        allowsAutomaticCleaning: true
    )
    static let systemCaches = JunkCategory(
        id: "junk.systemCaches", title: "macOS Caches", symbol: "apple.logo",
        explanation: "Caches created by Apple apps and macOS services in your user account.",
        consequence: "macOS recreates them, but some features (Maps, Music artwork, Help) may reload data. Not selected by default.",
        allowsAutomaticCleaning: false
    )
    static let temporaryFiles = JunkCategory(
        id: "junk.temporary", title: "Temporary Files", symbol: "clock.badge.xmark",
        explanation: "Files apps left in your temporary folders that haven't changed for several days.",
        consequence: "Recently used temporary files are never included, so running apps aren't affected.",
        allowsAutomaticCleaning: true
    )
    static let logs = JunkCategory(
        id: "junk.logs", title: "Application Logs", symbol: "doc.plaintext",
        explanation: "Diagnostic text files written by apps. They are only useful when troubleshooting.",
        consequence: "Apps start new log files automatically. Logs updated recently are listed but not selected.",
        allowsAutomaticCleaning: true
    )
    static let crashReports = JunkCategory(
        id: "junk.crashReports", title: "Crash & Diagnostic Reports", symbol: "exclamationmark.bubble",
        explanation: "Reports macOS writes when an app crashes, hangs or uses too many resources.",
        consequence: "You won't be able to send these reports to a developer afterwards. They aren't needed for anything else.",
        allowsAutomaticCleaning: true
    )
    static let xcodeBuildData = JunkCategory(
        id: "junk.xcode", title: "Xcode Build Data", symbol: "hammer",
        explanation: "DerivedData: intermediate build products and indexes Xcode creates for each project.",
        consequence: "Xcode rebuilds it on the next build, which will take longer than usual once.",
        allowsAutomaticCleaning: true
    )
    static let savedState = JunkCategory(
        id: "junk.savedState", title: "Saved Window States", symbol: "macwindow.on.rectangle",
        explanation: "Snapshots apps use to reopen their windows where you left them.",
        consequence: "Apps open with fresh windows the next time instead of restoring the previous session.",
        allowsAutomaticCleaning: false
    )
    static let deviceUpdates = JunkCategory(
        id: "junk.deviceUpdates", title: "iPhone & iPad Software Updates", symbol: "iphone.gen3",
        explanation: "Firmware files downloaded by Finder to update or restore iOS and iPadOS devices.",
        consequence: "They're downloaded again automatically if you update or restore a device.",
        allowsAutomaticCleaning: true
    )
    static let mailDownloads = JunkCategory(
        id: "junk.mailDownloads", title: "Mail Attachment Copies", symbol: "paperclip",
        explanation: "Copies of attachments created when you opened or Quick Looked them in Mail.",
        consequence: "The original attachments stay in Mail. Only these temporary copies are removed.",
        allowsAutomaticCleaning: false
    )
    static let installers = JunkCategory(
        id: "junk.installers", title: "Installers in Downloads", symbol: "shippingbox.and.arrow.backward",
        explanation: "Disk images and installer packages in your Downloads folder, usually no longer needed after installing.",
        consequence: "These are your files: they go to the Trash, and you'd need to download them again to reinstall.",
        allowsAutomaticCleaning: false
    )
    static let oldDownloads = JunkCategory(
        id: "junk.oldDownloads", title: "Old Downloads", symbol: "arrow.down.circle",
        explanation: "Items in your Downloads folder you haven't modified or opened for a long time.",
        consequence: "These are your files. Review them carefully; they go to the Trash so you can restore them.",
        allowsAutomaticCleaning: false
    )

    static let all: [JunkCategory] = [
        .applicationCaches, .systemCaches, .temporaryFiles, .logs, .crashReports, .xcodeBuildData,
        .savedState, .deviceUpdates, .mailDownloads, .installers, .oldDownloads,
    ]

    static func category(id: String) -> JunkCategory? {
        all.first { $0.id == id }
    }
}

/// Folders inside ~/Library/Caches that other Mac Cleaner features own or that
/// hold state rather than throwaway data. They are never offered as junk.
enum JunkExclusions {
    /// Browser caches are handled by the Privacy cleaner so the two lists don't overlap.
    static let browserCacheFolders: Set<String> = [
        "Google", "com.google.Chrome", "Chromium", "Firefox", "Mozilla", "com.apple.Safari",
        "Microsoft Edge", "com.microsoft.edgemac", "BraveSoftware", "com.brave.Browser",
        "Arc", "company.thebrowser.Browser", "Vivaldi", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "org.mozilla.firefox",
    ]

    /// Developer tool caches are handled by Developer Tools with their official commands.
    static let developerCacheFolders: Set<String> = [
        "Homebrew", "org.swift.swiftpm", "CocoaPods", "org.carthage.CarthageKit", "pip", "pypoetry",
        "Yarn", "pnpm", "go-build", "JetBrains", "node-gyp", "ms-playwright", "deno", "typescript",
    ]

    /// Caches that hold sync or account state, or that macOS manages itself.
    static let stateful: Set<String> = [
        "com.apple.bird", "com.apple.cloudd", "CloudKit", "com.apple.CloudDocs", "com.apple.findmy.fmipcore",
        "com.apple.findmy.fmfcore", "com.apple.homed", "com.apple.HomeKit", "FamilyCircle",
        "com.apple.akd", "com.apple.containermanagerd", "com.apple.nsurlsessiond", "com.apple.passd",
        "com.apple.iCloudHelper", "com.apple.ap.adprivacyd", "com.apple.amsengagementd",
        "com.apple.private.translation", "com.apple.icloud.searchpartyd", "com.apple.Messages",
        "com.apple.mobileassetd", "com.apple.coreservices.useractivityd",
    ]

    static func isExcludedCacheFolder(_ name: String, ownBundleIdentifier: String?) -> Bool {
        if let ownBundleIdentifier, name == ownBundleIdentifier { return true }
        return browserCacheFolders.contains(name) || developerCacheFolders.contains(name) || stateful.contains(name)
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
}
