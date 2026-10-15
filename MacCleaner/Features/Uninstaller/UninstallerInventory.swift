import CoreServices
import Darwin
import Foundation
import Security

/// Finds installed apps and gathers what the Uninstaller and Updates show about them.
///
/// Work happens in three phases so the list appears immediately:
/// 1. `loadApplications()` reads Info.plist files and Spotlight usage data (fast).
/// 2. `enrichmentUpdates(for:)` reads code signatures, entitlements and embedded helpers.
/// 3. `sizeUpdates(for:)` measures app bundles, a few at a time.
/// Results of phases 2 and 3 are cached per bundle version, so both features share them.
enum UninstallerInventory {
    // MARK: Phase 1

    /// Lists apps people can manage: everything in the Applications folders except
    /// apps that are part of macOS. Blocking; call from background work.
    static func loadApplications(
        policy: SafetyPolicy = .current,
        ownBundlePath: String = Bundle.main.bundlePath,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [UninstallerApp] {
        var apps: [UninstallerApp] = []
        var seen = Set<String>()
        for info in ApplicationCatalog.installedApplications(includeSystemApps: false) where seen.insert(info.path).inserted {
            if let app = makeApp(info: info, policy: policy, ownBundlePath: ownBundlePath, ownBundleIdentifier: ownBundleIdentifier) {
                apps.append(app)
            }
        }
        for (info, metadata) in wrappedApplications(excluding: seen) {
            guard var app = makeApp(info: info, policy: policy, ownBundlePath: ownBundlePath, ownBundleIdentifier: ownBundleIdentifier) else { continue }
            app.isWrappediOSApp = true
            app.appStoreItemID = metadata.itemID
            app.storefront = metadata.storefront
            if app.copyright == nil, let artist = metadata.artist { app.copyright = artist }
            apps.append(app)
        }
        return apps
    }

    /// Reads one app chosen by the person (for apps outside the Applications folders).
    static func loadApplication(at path: String, policy: SafetyPolicy = .current) -> UninstallerApp? {
        guard let info = ApplicationCatalog.read(path: PathUtilities.normalize(path)) else { return nil }
        return makeApp(info: info, policy: policy, ownBundlePath: Bundle.main.bundlePath, ownBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private static func makeApp(info: AppBundleInfo, policy: SafetyPolicy, ownBundlePath: String, ownBundleIdentifier: String?) -> UninstallerApp? {
        if info.isSystemApp || info.path.hasPrefix("/System/") { return nil }
        var status = stat()
        guard lstat(info.path, &status) == 0 else { return nil }

        var protection: UninstallerProtection?
        if FileObjectType(mode: status.st_mode) == .symlink {
            let target = PathUtilities.resolvedPath(info.path) ?? ""
            // Safari and other cryptex apps appear in /Applications as protected links into the system.
            if status.st_flags & FileFlags.restricted != 0 || target.hasPrefix("/System/") { return nil }
            protection = .linkedApp(target: target)
        } else if status.st_flags & (FileFlags.restricted | FileFlags.systemImmutable) != 0 {
            if info.isAppleApp { return nil }
            protection = .systemIntegrityProtection
        }
        if protection == nil {
            let resolved = PathUtilities.resolvedPath(info.path) ?? info.path
            let own = PathUtilities.resolvedPath(ownBundlePath) ?? ownBundlePath
            if resolved == own || (ownBundleIdentifier != nil && info.bundleIdentifier == ownBundleIdentifier) {
                protection = .macCleanerItself
            }
        }
        if protection == nil, case .denied(let reason) = policy.evaluate(path: info.path, purpose: .application) {
            protection = .unsupportedLocation(reason)
        }

        let plist = plistDictionary(at: info.path + "/Contents/Info.plist") ?? [:]
        let names = [info.name, plist["CFBundleName"] as? String, plist["CFBundleDisplayName"] as? String].compactMap { $0 }
        var app = UninstallerApp(
            info: info,
            identity: UninstallerAppIdentity(path: info.path, bundleIdentifier: info.bundleIdentifier, names: names, executableName: info.executableName),
            copyright: plist["NSHumanReadableCopyright"] as? String,
            lastUsed: ApplicationCatalog.lastUsedDate(path: info.path),
            useCount: ApplicationCatalog.useCount(path: info.path),
            protection: protection
        )
        if info.isAppStoreApp { app.appStoreItemID = appStoreItemID(path: info.path) }
        return app
    }

    struct WrappedMetadata: Sendable {
        var itemID: Int?
        var storefront: String?
        var artist: String?
    }

    /// iPhone and iPad apps installed from the App Store on Apple silicon: an outer `.app`
    /// with a `Wrapper` folder instead of `Contents`. `ApplicationCatalog` skips them.
    static func wrappedApplications(excluding known: Set<String>) -> [(AppBundleInfo, WrappedMetadata)] {
        let manager = FileManager.default
        let folders = ["/Applications", manager.homeDirectoryForCurrentUser.path + "/Applications"]
        var results: [(AppBundleInfo, WrappedMetadata)] = []
        for folder in folders {
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where name.hasSuffix(".app") {
                let path = folder + "/" + name
                guard !known.contains(path), !manager.fileExists(atPath: path + "/Contents/Info.plist"),
                      let inner = wrappedInnerBundle(path),
                      let plist = plistDictionary(at: inner + "/Info.plist") else { continue }
                let metadata = plistDictionary(at: path + "/Wrapper/iTunesMetadata.plist")
                let bundleID = plist["CFBundleIdentifier"] as? String
                let attributes = try? manager.attributesOfItem(atPath: path)
                let info = AppBundleInfo(
                    path: path,
                    name: (name as NSString).deletingPathExtension,
                    bundleIdentifier: bundleID,
                    shortVersion: (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces),
                    buildVersion: (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces),
                    executableName: plist["CFBundleExecutable"] as? String,
                    minimumSystemVersion: plist["LSMinimumSystemVersion"] as? String,
                    sparkleFeedURL: nil,
                    isAppStoreApp: metadata != nil,
                    isSystemApp: false,
                    isAppleApp: bundleID?.hasPrefix("com.apple.") == true,
                    installedDate: attributes?[.creationDate] as? Date,
                    modificationDate: attributes?[.modificationDate] as? Date
                )
                let extra = WrappedMetadata(
                    itemID: (metadata?["itemId"] as? NSNumber)?.intValue,
                    storefront: metadata?["storefrontCountryCode"] as? String,
                    artist: metadata?["artistName"] as? String
                )
                results.append((info, extra))
            }
        }
        return results
    }

    private static func wrappedInnerBundle(_ path: String) -> String? {
        if let resolved = PathUtilities.resolvedPath(path + "/WrappedBundle"),
           PathUtilities.isDescendant(resolved, of: PathUtilities.resolvedPath(path) ?? path) {
            return resolved
        }
        let wrapper = path + "/Wrapper"
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: wrapper) else { return nil }
        return children.sorted().first { $0.hasSuffix(".app") }.map { wrapper + "/" + $0 }
    }

    /// App Store item ID recorded by Spotlight for App Store apps.
    static func appStoreItemID(path: String) -> Int? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, "kMDItemAppStoreAdamID" as CFString) as? NSNumber)?.intValue
    }

    // MARK: Phase 2

    /// Reads the code signature, entitlements and embedded helpers. Blocking.
    static func enrich(_ app: UninstallerApp) -> UninstallerApp {
        var app = app
        let signature = CodeSignatureInspector.inspect(path: app.path)
        app.signature = signature
        let groups = UninstallerCodeSigning.applicationGroups(path: app.path, teamIdentifier: signature.teamIdentifier)
        let embedded = embeddedIdentifiers(bundlePath: app.path, isWrapped: app.isWrappediOSApp)
        app.identity.teamIdentifier = signature.teamIdentifier
        app.identity.applicationGroups = groups.groups
        app.identity.entitlementsKnown = groups.known
        app.identity.helperIdentifiers = embedded.helpers.filter { $0.caseInsensitiveCompare(app.bundleIdentifier ?? "") != .orderedSame }
        app.identity.frameworkIdentifiers = embedded.frameworks
        app.identity.embeddedJobLabels = embedded.jobLabels
        app.identity.vendorWords = UninstallerAppIdentity.vendorWords(bundleIdentifier: app.bundleIdentifier, developer: app.developer)
        app.isEnriched = true
        return app
    }

    struct EmbeddedIdentifiers: Sendable, Hashable {
        var helpers: [String] = []
        var frameworks: [String] = []
        var jobLabels: [String] = []
    }

    /// Bundle identifiers of helpers, extensions and services inside an app bundle.
    static func embeddedIdentifiers(bundlePath: String, isWrapped: Bool = false) -> EmbeddedIdentifiers {
        var result = EmbeddedIdentifiers()
        let manager = FileManager.default
        let helperExtensions: Set<String> = ["app", "appex", "xpc", "systemextension", "mdimporter", "qlgenerator"]

        func identifier(ofBundle path: String) -> String? {
            let plist = plistDictionary(at: path + "/Contents/Info.plist") ?? plistDictionary(at: path + "/Info.plist")
            return (plist?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func children(_ directory: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        }

        if isWrapped {
            guard let inner = wrappedInnerBundle(bundlePath) else { return result }
            for name in children(inner + "/PlugIns") where helperExtensions.contains((name as NSString).pathExtension) {
                if let id = identifier(ofBundle: inner + "/PlugIns/" + name) { result.helpers.append(id) }
            }
            return result
        }

        let contents = bundlePath + "/Contents"
        let helperFolders = ["Library/LoginItems", "Helpers", "Library/Helpers", "XPCServices", "PlugIns", "Library/SystemExtensions",
                             "Library/Spotlight", "Library/QuickLook", "Applications", "MacOS", "SharedSupport", "Resources", "Frameworks"]
        for folder in helperFolders {
            for name in children(contents + "/" + folder) {
                let ext = (name as NSString).pathExtension.lowercased()
                let path = contents + "/" + folder + "/" + name
                if helperExtensions.contains(ext) {
                    // Inside Frameworks only Electron-style helper apps are app-specific.
                    if folder == "Frameworks" && ext != "app" { continue }
                    guard let id = identifier(ofBundle: path) else { continue }
                    result.helpers.append(id)
                    if folder == "Library/LoginItems" { result.jobLabels.append(id) }
                } else if folder == "Frameworks", ext == "framework" {
                    if let id = identifier(ofBundle: path + "/Resources") ?? identifier(ofBundle: path + "/Versions/A/Resources") {
                        result.frameworks.append(id)
                    }
                    for sub in ["XPCServices", "Versions/A/XPCServices", "Resources", "Versions/A/Resources"] {
                        for nested in children(path + "/" + sub) where ["xpc", "app"].contains((nested as NSString).pathExtension.lowercased()) {
                            if let id = identifier(ofBundle: path + "/" + sub + "/" + nested) { result.frameworks.append(id) }
                        }
                    }
                }
            }
        }
        // Privileged helpers that SMJobBless installs are named after their label.
        for name in children(contents + "/Library/LaunchServices") where UninstallerIdentifierRules.isReverseDNS(name, minimumDots: 1) {
            result.helpers.append(name)
            result.jobLabels.append(name)
        }
        // Agents and daemons registered with SMAppService.
        for folder in ["Library/LaunchAgents", "Library/LaunchDaemons"] {
            for name in children(contents + "/" + folder) where name.hasSuffix(".plist") {
                if let label = plistDictionary(at: contents + "/" + folder + "/" + name)?["Label"] as? String, !label.isEmpty {
                    result.jobLabels.append(label)
                }
            }
        }
        result.helpers = unique(result.helpers)
        result.frameworks = unique(result.frameworks)
        result.jobLabels = unique(result.jobLabels)
        return result
    }

    // MARK: Streams for phases 2 and 3

    /// Enriches apps a few at a time and yields each as soon as it's ready.
    static func enrichmentUpdates(for apps: [UninstallerApp], concurrency: Int = 4) -> AsyncStream<UninstallerApp> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: UninstallerApp?.self) { group in
                    var iterator = apps.makeIterator()
                    func addNext() -> Bool {
                        guard let app = iterator.next() else { return false }
                        group.addTask {
                            if Task.isCancelled { return nil }
                            let fingerprint = UninstallerInventoryCache.fingerprint(path: app.path)
                            if let fingerprint, let cached = await UninstallerInventoryCache.shared.enriched(app, fingerprint: fingerprint) {
                                return cached
                            }
                            let enriched = await BackgroundWork.run(qos: .utility) { enrich(app) }
                            if let fingerprint { await UninstallerInventoryCache.shared.storeEnrichment(enriched, fingerprint: fingerprint) }
                            return enriched
                        }
                        return true
                    }
                    for _ in 0..<max(1, concurrency) where !addNext() { break }
                    while let result = await group.next() {
                        if let result { continuation.yield(result) }
                        if Task.isCancelled { group.cancelAll(); continue }
                        _ = addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Measures app bundles a few at a time; yields (path, usage) as each finishes.
    static func sizeUpdates(for apps: [UninstallerApp], scanner: FileSystemScanner, concurrency: Int = 3) -> AsyncStream<(String, DiskUsage)> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: (String, DiskUsage)?.self) { group in
                    var iterator = apps.makeIterator()
                    var options = WalkOptions()
                    options.maxConcurrency = max(2, WalkOptions.defaultConcurrency / max(1, concurrency))
                    let perItem = options
                    func addNext() -> Bool {
                        guard let app = iterator.next() else { return false }
                        group.addTask {
                            if Task.isCancelled { return nil }
                            let fingerprint = UninstallerInventoryCache.fingerprint(path: app.path)
                            if let fingerprint, let cached = await UninstallerInventoryCache.shared.size(for: fingerprint) {
                                return (app.path, cached)
                            }
                            guard let usage = try? await scanner.measure(path: app.path, options: perItem) else { return nil }
                            if let fingerprint { await UninstallerInventoryCache.shared.storeSize(usage, fingerprint: fingerprint) }
                            return (app.path, usage)
                        }
                        return true
                    }
                    for _ in 0..<max(1, concurrency) where !addNext() { break }
                    while let result = await group.next() {
                        if let result { continuation.yield(result) }
                        if Task.isCancelled { group.cancelAll(); continue }
                        _ = addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    static func plistDictionary(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Reads entitlements with the Security framework (no validation, no network).
enum UninstallerCodeSigning {
    static func entitlements(path: String) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }

    /// App groups from `com.apple.security.application-groups`, with Xcode's
    /// `$(TeamIdentifierPrefix)` placeholder expanded (some apps ship it unexpanded).
    static func applicationGroups(path: String, teamIdentifier: String?) -> (groups: [String], known: Bool) {
        guard let entitlements = entitlements(path: path) else { return ([], false) }
        let raw = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        let groups = raw.compactMap { group -> String? in
            var value = group
            for placeholder in ["$(TeamIdentifierPrefix)", "$(AppIdentifierPrefix)"] where value.contains(placeholder) {
                guard let teamIdentifier else { return nil }
                value = value.replacingOccurrences(of: placeholder, with: teamIdentifier + ".")
            }
            return value.isEmpty ? nil : value
        }
        return (groups, true)
    }
}

/// Caches enrichment and sizes per bundle version, shared by Uninstaller, Updates and Smart Scan.
actor UninstallerInventoryCache {
    static let shared = UninstallerInventoryCache()

    struct Fingerprint: Hashable, Sendable {
        var path: String
        var device: Int32
        var inode: UInt64
        var bundleModified: Double
        var infoModified: Double
    }

    private struct Enrichment: Sendable {
        var signature: CodeSignatureInfo?
        var identity: UninstallerAppIdentity
    }

    private var sizes: [Fingerprint: DiskUsage] = [:]
    private var enrichments: [Fingerprint: Enrichment] = [:]

    /// Identifies a bundle version: replacing or updating an app changes its inode or dates.
    nonisolated static func fingerprint(path: String) -> Fingerprint? {
        var bundle = stat()
        guard lstat(path, &bundle) == 0 else { return nil }
        var info = stat()
        let infoModified: Double
        if lstat(path + "/Contents/Info.plist", &info) == 0 {
            infoModified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        } else {
            infoModified = 0
        }
        return Fingerprint(
            path: path,
            device: bundle.st_dev,
            inode: UInt64(bundle.st_ino),
            bundleModified: Double(bundle.st_mtimespec.tv_sec) + Double(bundle.st_mtimespec.tv_nsec) / 1e9,
            infoModified: infoModified
        )
    }

    func size(for fingerprint: Fingerprint) -> DiskUsage? {
        sizes[fingerprint]
    }

    func storeSize(_ usage: DiskUsage, fingerprint: Fingerprint) {
        sizes[fingerprint] = usage
    }

    func enriched(_ app: UninstallerApp, fingerprint: Fingerprint) -> UninstallerApp? {
        guard let cached = enrichments[fingerprint] else { return nil }
        var copy = app
        copy.signature = cached.signature
        copy.identity = cached.identity
        copy.isEnriched = true
        return copy
    }

    func storeEnrichment(_ app: UninstallerApp, fingerprint: Fingerprint) {
        enrichments[fingerprint] = Enrichment(signature: app.signature, identity: app.identity)
    }

    func invalidate(path: String) {
        sizes = sizes.filter { $0.key.path != path }
        enrichments = enrichments.filter { $0.key.path != path }
    }
}
