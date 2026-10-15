import Foundation

/// Why Mac Cleaner won't uninstall an app.
enum UninstallerProtection: Sendable, Hashable {
    case partOfMacOS
    case systemIntegrityProtection
    case macCleanerItself
    case linkedApp(target: String)
    case unsupportedLocation(String)

    var title: String {
        switch self {
        case .partOfMacOS: return "Part of macOS"
        case .systemIntegrityProtection: return "Protected by macOS"
        case .macCleanerItself: return "Mac Cleaner"
        case .linkedApp: return "Link to another location"
        case .unsupportedLocation: return "Unsupported location"
        }
    }

    var explanation: String {
        switch self {
        case .partOfMacOS:
            return "This app is part of macOS and is updated and managed by the system."
        case .systemIntegrityProtection:
            return "System Integrity Protection guards this app. It can't be removed, and that keeps your Mac secure."
        case .macCleanerItself:
            return "Mac Cleaner can't uninstall itself. Quit it and drag it to the Trash in Finder."
        case .linkedApp(let target):
            return "This item is a link to \(PathUtilities.abbreviate(target)). Uninstall the app from its real location."
        case .unsupportedLocation(let reason):
            return reason
        }
    }
}

/// Identifiers and names that decide which Library items belong to an app.
struct UninstallerAppIdentity: Sendable, Hashable {
    var path: String
    var bundleIdentifier: String?
    /// File name, `CFBundleName` and `CFBundleDisplayName` (deduplicated, original case).
    var names: [String]
    var executableName: String?
    var teamIdentifier: String?
    /// App groups declared in the app's entitlements (`$(TeamIdentifierPrefix)` expanded).
    var applicationGroups: [String] = []
    /// `true` once the entitlements were read, so empty groups really mean "none".
    var entitlementsKnown = false
    /// Bundle identifiers of helpers shipped inside the app (login items, XPC services, extensions).
    var helperIdentifiers: [String] = []
    /// Bundle identifiers inside embedded frameworks (shared code such as Sparkle).
    var frameworkIdentifiers: [String] = []
    /// Labels of launchd jobs shipped inside the app bundle.
    var embeddedJobLabels: [String] = []
    /// Lowercased vendor words: the second bundle identifier component and the developer's name.
    var vendorWords: [String] = []

    init(
        path: String,
        bundleIdentifier: String?,
        names: [String],
        executableName: String? = nil,
        teamIdentifier: String? = nil,
        applicationGroups: [String] = [],
        entitlementsKnown: Bool = false,
        helperIdentifiers: [String] = [],
        frameworkIdentifiers: [String] = [],
        embeddedJobLabels: [String] = [],
        vendorWords: [String]? = nil
    ) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        var seen = Set<String>()
        self.names = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        self.executableName = executableName
        self.teamIdentifier = teamIdentifier
        self.applicationGroups = applicationGroups
        self.entitlementsKnown = entitlementsKnown
        self.helperIdentifiers = helperIdentifiers
        self.frameworkIdentifiers = frameworkIdentifiers
        self.embeddedJobLabels = embeddedJobLabels
        self.vendorWords = vendorWords ?? UninstallerAppIdentity.vendorWords(bundleIdentifier: bundleIdentifier, developer: nil)
    }

    /// Identifiers that make an item belong to this app (bundle ID first).
    var ownIdentifiers: [String] {
        ([bundleIdentifier].compactMap { $0 } + helperIdentifiers).filter { !$0.isEmpty }
    }

    /// Vendor words from a reverse-DNS bundle identifier ("com.google.Chrome" → "google")
    /// and from the code-signing developer name ("Google LLC" → "google llc", "google").
    static func vendorWords(bundleIdentifier: String?, developer: String?) -> [String] {
        var words: [String] = []
        if let parts = bundleIdentifier?.lowercased().split(separator: "."), parts.count >= 3 {
            words.append(String(parts[1]))
        }
        if let developer, !["mac app store", "apple"].contains(developer.lowercased()) {
            let lowered = developer.lowercased()
            words.append(lowered)
            if let first = lowered.split(whereSeparator: { $0 == " " || $0 == "," }).first, first.count >= 3 {
                words.append(String(first))
            }
        }
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// An installed application as shown by the Uninstaller and Updates.
struct UninstallerApp: Identifiable, Sendable, Hashable {
    var info: AppBundleInfo
    var identity: UninstallerAppIdentity
    var copyright: String?
    /// An iPhone or iPad app installed from the App Store (wrapped bundle).
    var isWrappediOSApp = false
    /// App Store item ID, when known (Spotlight or the wrapped app's metadata).
    var appStoreItemID: Int?
    /// App Store region recorded by a wrapped iPhone/iPad app.
    var storefront: String?
    var lastUsed: Date?
    var useCount: Int?
    /// Size of the app bundle; nil until measured.
    var usage: DiskUsage?
    /// Code-signing details; nil until inspected.
    var signature: CodeSignatureInfo?
    /// Why the app can't be uninstalled, or nil when it can.
    var protection: UninstallerProtection?
    /// `true` once signature, entitlements and embedded helpers were read.
    var isEnriched = false

    /// Apps not opened for this long count as unused.
    static let unusedInterval: TimeInterval = 90 * 86_400
    /// Apps at least this large count as large.
    static let largeAppBytes: Int64 = 1_000_000_000

    var id: String { info.path }
    var path: String { info.path }
    var name: String { info.name }
    var bundleIdentifier: String? { info.bundleIdentifier }
    var canUninstall: Bool { protection == nil }

    /// Hidden bundles (".Name.app") are components other apps install, not apps people
    /// use. They aren't listed, but still count as installed when deciding what's shared.
    var isHiddenComponent: Bool { (info.path as NSString).lastPathComponent.hasPrefix(".") }

    /// The developer, from the code signature. App Store apps are signed by Apple on the
    /// developer's behalf, so their copyright line names the developer instead.
    var developer: String? {
        guard let signature else { return nil }
        if let name = signature.developerName, name != "Mac App Store" { return name }
        if let holder = UninstallerApp.copyrightHolder(copyright) { return holder }
        return signature.developerName
    }

    var sortName: String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    var sortVersion: String { info.displayVersion }
    var sortSize: Int64 { usage?.allocatedBytes ?? -1 }
    var sortLastUsed: Date { lastUsed ?? .distantPast }
    var sortDeveloper: String { developer?.lowercased() ?? "~" }

    /// "Copyright © 2013–2024 Telegram Messenger Inc. All rights reserved." → "Telegram Messenger Inc."
    static func copyrightHolder(_ copyright: String?) -> String? {
        guard var text = copyright?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for marker in ["All rights reserved", "All Rights Reserved", "all rights reserved"] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        text = text.replacingOccurrences(of: "Copyright", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "©", with: "")
            .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
        // Drop leading years and ranges such as "2013-2024".
        let scalars = text.unicodeScalars.drop { scalar in
            CharacterSet.decimalDigits.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                || "-–—,.".unicodeScalars.contains(scalar)
        }
        let holder = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        guard holder.count >= 2, holder.count <= 60 else { return nil }
        return holder
    }
}

/// Kinds of files apps leave in Library folders.
enum UninstallerLeftoverKind: String, Sendable, CaseIterable, Hashable, Comparable {
    case applicationSupport, containers, groupContainers, preferences, caches, logs, crashReports
    case savedState, webData, applicationScripts, recentDocuments
    case launchAgents, launchDaemons, privilegedHelpers

    static func < (lhs: UninstallerLeftoverKind, rhs: UninstallerLeftoverKind) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    var title: String {
        switch self {
        case .applicationSupport: return "Application Support"
        case .containers: return "Sandbox Containers"
        case .groupContainers: return "Shared Group Containers"
        case .preferences: return "Preferences"
        case .caches: return "Caches"
        case .logs: return "Logs"
        case .crashReports: return "Crash Reports"
        case .savedState: return "Saved Window State"
        case .webData: return "Cookies & Web Data"
        case .applicationScripts: return "Application Scripts"
        case .recentDocuments: return "Recent Documents List"
        case .launchAgents: return "Launch Agents"
        case .launchDaemons: return "Launch Daemons"
        case .privilegedHelpers: return "Privileged Helper Tools"
        }
    }

    var symbol: String {
        switch self {
        case .applicationSupport: return "folder.fill"
        case .containers: return "shippingbox.fill"
        case .groupContainers: return "square.stack.3d.up.fill"
        case .preferences: return "slider.horizontal.3"
        case .caches: return "archivebox.fill"
        case .logs: return "doc.text.fill"
        case .crashReports: return "exclamationmark.bubble.fill"
        case .savedState: return "macwindow"
        case .webData: return "globe"
        case .applicationScripts: return "applescript.fill"
        case .recentDocuments: return "clock.fill"
        case .launchAgents: return "bolt.fill"
        case .launchDaemons: return "gearshape.2.fill"
        case .privilegedHelpers: return "lock.fill"
        }
    }

    /// What the data is.
    var explanation: String {
        switch self {
        case .applicationSupport: return "Settings, databases and other data the app keeps for you."
        case .containers: return "Everything a sandboxed app stores: its settings, caches and any documents saved inside the app."
        case .groupContainers: return "Data the app shares with its extensions, widgets or companion apps."
        case .preferences: return "The app's settings."
        case .caches: return "Temporary data the app recreates when needed."
        case .logs: return "Diagnostic logs written by the app."
        case .crashReports: return "Reports macOS saved when the app crashed."
        case .savedState: return "Window positions macOS restores when the app opens."
        case .webData: return "Cookies, website data and network caches used by the app."
        case .applicationScripts: return "Scripts and data used by the app's extensions."
        case .recentDocuments: return "The app's list of recently opened documents."
        case .launchAgents: return "Starts a helper of the app in the background, usually at login."
        case .launchDaemons: return "A system-wide background service installed by the app."
        case .privilegedHelpers: return "A helper tool installed with administrator rights."
        }
    }

    /// What removing it means.
    var consequence: String {
        switch self {
        case .applicationSupport, .containers, .groupContainers:
            return "May contain data you created in the app, such as libraries, projects or account data."
        case .preferences: return "The app's settings are lost."
        case .caches, .logs, .crashReports, .savedState, .recentDocuments: return "Nothing you need is lost."
        case .webData: return "You may need to sign in again."
        case .applicationScripts: return "Extensions of the app lose their settings."
        case .launchAgents: return "The helper no longer starts. It stops completely after you log out."
        case .launchDaemons, .privilegedHelpers: return "Requires an administrator. The service stops after a restart."
        }
    }

    /// Selected by default when resetting an app (data the app recreates or settings).
    var isResetDefault: Bool {
        switch self {
        case .preferences, .caches, .logs, .crashReports, .savedState, .webData, .recentDocuments: return true
        default: return false
        }
    }

    /// Background services keep an installed app working, so resetting never offers them.
    var isOfferedForReset: Bool {
        switch self {
        case .launchAgents, .launchDaemons, .privilegedHelpers: return false
        default: return true
        }
    }
}

/// Why an item was attributed to an app.
enum UninstallerMatchReason: Sendable, Hashable {
    case bundleIdentifier(String)
    case helperIdentifier(String)
    case appGroup(String)
    case appName(String)
    case vendorFolder(vendor: String, name: String)
    case launchJob(String)
    case executableName(String)
    case referencedByJob(String)

    var explanation: String {
        switch self {
        case .bundleIdentifier(let id): return "Named after the app's identifier (\(id))."
        case .helperIdentifier(let id): return "Belongs to a helper inside the app (\(id))."
        case .appGroup(let group): return "App group used by the app (\(group))."
        case .appName(let name): return "Named like the app (“\(name)”). Check before removing."
        case .vendorFolder(let vendor, let name): return "“\(name)” inside the \(vendor) folder. Check before removing."
        case .launchJob(let label): return "Starts the app or one of its helpers (\(label))."
        case .executableName(let name): return "Written by the app's program (\(name))."
        case .referencedByJob(let label): return "Used by the app's background service (\(label))."
        }
    }

    /// Matches on the app's name are less certain than identifier matches.
    var isNameBased: Bool {
        switch self {
        case .appName, .vendorFolder: return true
        default: return false
        }
    }
}

/// A file or folder that belongs to an app.
struct UninstallerLeftover: Identifiable, Sendable, Hashable {
    var path: String
    var kind: UninstallerLeftoverKind
    var reason: UninstallerMatchReason
    var safety: CleanupSafety
    /// In `/Library`: removing it needs an administrator.
    var isSystemWide: Bool
    /// A container or group container: macOS protects its contents (App Data / Full Disk Access).
    var isProtectedAppData: Bool
    /// launchd label, for launch agents and daemons.
    var launchLabel: String?
    var usage: DiskUsage?
    var snapshot: FileSnapshot?
    var modificationDate: Date?
    /// Extra caution shown to people, e.g. "Contains documents saved inside the app."
    var note: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    /// Size isn't known, or only partly (unreadable folders inside).
    var isSizeIncomplete: Bool { usage == nil || (usage?.unreadableDirectoryCount ?? 0) > 0 }
    var bytes: Int64 { usage?.reclaimableBytes ?? 0 }

    func cleanupItem() -> CleanupItem {
        CleanupItem(path: path, purpose: .applicationData, snapshot: snapshot, estimatedBytes: bytes, category: kind.title)
    }
}

/// An item that looked related but was left out, with the reason.
struct UninstallerExcludedItem: Identifiable, Sendable, Hashable {
    var path: String
    var kind: UninstallerLeftoverKind
    var reason: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Everything found for one app.
struct UninstallerLocateResult: Sendable, Hashable {
    var leftovers: [UninstallerLeftover] = []
    var excluded: [UninstallerExcludedItem] = []
    /// Installer package identifiers that appear related (information only).
    var receipts: [String] = []

    var totalBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }
}

/// One item left behind by an app that's no longer installed.
struct UninstallerOrphanItem: Identifiable, Sendable, Hashable {
    var path: String
    /// Reverse-DNS identifier the item is named after.
    var identifier: String
    var kind: UninstallerLeftoverKind
    var modificationDate: Date?
    var isProtectedAppData: Bool
    /// In `/Library`: removing it needs an administrator.
    var isSystemWide = false
    var usage: DiskUsage?
    var snapshot: FileSnapshot?
    /// An installed app from the same developer, if any (the item may be shared).
    var sameDeveloperAs: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var bytes: Int64 { usage?.reclaimableBytes ?? 0 }
}

extension UninstallerOrphanItem {
    static let candidateCategoryID = "uninstaller.leftovers"
    static let candidateCategoryTitle = "Leftovers of Removed Apps"

    /// A scan result row. Leftovers of removed apps always need review and are never preselected.
    func cleanupCandidate(identifier groupIdentifier: String) -> CleanupCandidate {
        CleanupCandidate(
            path: path,
            title: name,
            detail: "\(kind.title) · left by \(groupIdentifier)" + (isSystemWide ? " · needs an administrator" : ""),
            categoryID: Self.candidateCategoryID,
            categoryTitle: Self.candidateCategoryTitle,
            usage: usage ?? .zero,
            snapshot: snapshot,
            safety: .review,
            purpose: .applicationData,
            modificationDate: modificationDate
        )
    }
}

/// Items left behind by one removed app, grouped by identifier.
struct UninstallerOrphanGroup: Identifiable, Sendable, Hashable {
    var identifier: String
    var items: [UninstallerOrphanItem]

    var id: String { identifier.lowercased() }

    /// A readable name from the identifier: "com.vendor.CoolApp" → "CoolApp",
    /// "chat.atomic.app" → "Atomic", "com.vendor.Tool.Updater" → "Tool Updater".
    var displayName: String {
        UninstallerOrphanGroup.displayName(for: identifier)
    }

    static func displayName(for identifier: String) -> String {
        let parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 2, var name = parts.last, !name.isEmpty else { return identifier }
        let generic: Set<String> = ["app", "mac", "macos", "osx", "desktop", "client", "application", "electron", "main", "core"]
        let roles: Set<String> = ["helper", "agent", "updater", "launcher", "service", "daemon"]
        let lowered = name.lowercased()
        if generic.contains(lowered) || roles.contains(lowered), parts.count >= 3 {
            let previous = parts[parts.count - 2]
            name = roles.contains(lowered) ? previous + " " + name.prefix(1).uppercased() + name.dropFirst() : previous
        }
        // Generated identifiers ("230313mzl4w4u92") don't make a name.
        if name.filter(\.isNumber).count > name.filter(\.isLetter).count { return identifier }
        if name == name.lowercased() { name = name.prefix(1).uppercased() + name.dropFirst() }
        return name
    }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var newestModification: Date? { items.compactMap(\.modificationDate).max() }
    var sameDeveloperAs: String? { items.compactMap(\.sameDeveloperAs).first }
}
