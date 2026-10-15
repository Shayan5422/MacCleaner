import AppKit
import Foundation

/// Identifiers in use on this Mac, for deciding what's left over from removed apps.
struct UninstallerInstalledSet: Sendable {
    /// Lowercased bundle identifiers of installed apps, their helpers, embedded frameworks,
    /// launchd labels and running apps.
    var identifiers: Set<String> = []
    /// Lowercased proper prefixes (three or more components) of those identifiers.
    var ancestors: Set<String> = []
    /// Lowercased app groups declared by installed apps.
    var applicationGroups: Set<String> = []
    /// Vendor prefix ("com.google") → name of an installed app from that vendor.
    var vendorApps: [String: String] = [:]

    init(apps: [UninstallerAppIdentity], additionalIdentifiers: [String] = []) {
        for app in apps {
            let name = app.names.first ?? (app.path as NSString).lastPathComponent
            for id in app.ownIdentifiers + app.frameworkIdentifiers + app.embeddedJobLabels { insert(id) }
            for id in app.ownIdentifiers {
                let parts = id.lowercased().split(separator: ".")
                guard parts.count >= 3 else { continue }
                let vendor = parts.prefix(2).joined(separator: ".")
                if vendorApps[vendor] == nil { vendorApps[vendor] = name }
            }
            for group in app.applicationGroups { applicationGroups.insert(group.lowercased()) }
        }
        for id in additionalIdentifiers { insert(id) }
    }

    private mutating func insert(_ identifier: String) {
        let key = identifier.lowercased()
        guard !key.isEmpty else { return }
        identifiers.insert(key)
        var parts = key.split(separator: ".")
        while parts.count > 3 {
            parts.removeLast()
            ancestors.insert(parts.joined(separator: "."))
        }
    }

    /// `true` when an installed identifier equals `key`, contains it as a prefix, or is under it.
    func owns(_ key: String) -> Bool {
        if identifiers.contains(key) || ancestors.contains(key) { return true }
        var parts = key.split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            if identifiers.contains(parts.joined(separator: ".")) { return true }
        }
        return false
    }
}

/// Finds Library items named after apps that are no longer installed.
///
/// Only reverse-DNS names (`com.vendor.app`, at least two dots) are considered, because
/// they identify one app unambiguously. Apple's items, well-known shared components,
/// anything an installed or registered app could own, and items changed in the last few
/// days (still in use by something) are skipped. Results are always `.review`.
struct UninstallerOrphanScanner: Sendable {
    var homeLibrary: String
    /// Searched for launch agents and daemons of removed apps; nil to skip.
    var systemLibrary: String?
    /// Items modified more recently than this are probably still in use.
    var recentActivityWindow: TimeInterval = 3 * 86_400
    /// Looking inside containers and group containers needs Full Disk Access; without it
    /// macOS would ask for permission for every app's data.
    var canReadProtectedAppData: Bool

    init(
        homeLibrary: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true),
        systemLibrary: URL? = URL(fileURLWithPath: "/Library", isDirectory: true),
        canReadProtectedAppData: Bool
    ) {
        self.homeLibrary = PathUtilities.normalize(homeLibrary.path)
        self.systemLibrary = systemLibrary.map { PathUtilities.normalize($0.path) }
        self.canReadProtectedAppData = canReadProtectedAppData
    }

    /// Shared frameworks, updaters, SDKs, toolchains and drivers that write reverse-DNS
    /// folders without being apps.
    static let sharedComponentPrefixes: [String] = [
        "com.google.keystone", "com.google.googleupdater", "com.google.softwareupdate", "com.google.gmp", "com.google.firebase",
        "com.microsoft.autoupdate", "com.microsoft.errorreporting", "com.microsoft.shared", "com.microsoft.office",
        "com.microsoft.oneauth", "com.microsoft.identity", "com.microsoft.appcenter", "com.microsoft.msal",
        "com.adobe.acc", "com.adobe.ccx", "com.adobe.crashreporter", "com.adobe.headlights", "com.adobe.hdinstall",
        "com.adobe.csxs", "com.adobe.cep", "com.adobe.ngl", "com.adobe.dunamis", "com.adobe.mediabrowser", "com.adobe.common",
        "com.plausiblelabs", "io.sentry", "com.crashlytics", "com.firebase", "io.fabric", "com.segment", "com.datadoghq",
        "com.onevcat.kingfisher", "org.sparkle-project", "com.github.electron", "com.squirrel", "com.bugsnag", "com.instabug",
        "com.amplitude", "com.mixpanel", "net.hockeyapp", "com.oracle.java", "org.cups", "com.openssh", "org.openssh",
        "org.python", "org.chromium", "org.swift", "org.llvm", "org.nodejs", "org.rust-lang", "io.flutter", "dev.flutter",
        "org.gradle", "org.jetbrains.kotlin", "com.sun.", "net.java.", "org.homebrew", "sh.brew", "homebrew.",
        "com.hp.", "com.epson.", "com.brother.", "jp.co.canon", "com.canon.", "com.xerox",
        "com.lexmark", "com.ricoh", "com.kyocera", "com.konicaminolta",
    ]

    /// Vendors whose apps share many components; their leftovers are skipped while any of their apps is installed.
    static let suiteVendors: Set<String> = [
        "com.microsoft", "com.adobe", "com.google", "com.jetbrains", "org.mozilla", "com.parallels", "com.vmware", "com.autodesk",
    ]

    /// Prefixes used by app frameworks rather than one developer, so "same developer" hints don't apply.
    static let genericVendors: Set<String> = [
        "com.electron", "com.github", "io.github", "com.todesktop", "org.cef", "org.electron", "com.example", "com.squirrel",
    ]

    private enum Style {
        case directories, plistFiles, hostPlistFiles, savedState, httpStorages, groups
    }

    private static let roots: [(relative: String, kind: UninstallerLeftoverKind, style: Style, protected: Bool)] = [
        ("Application Support", .applicationSupport, .directories, false),
        ("Caches", .caches, .directories, false),
        ("Preferences", .preferences, .plistFiles, false),
        ("Preferences/ByHost", .preferences, .hostPlistFiles, false),
        ("Containers", .containers, .directories, true),
        ("Group Containers", .groupContainers, .groups, true),
        ("Saved Application State", .savedState, .savedState, false),
        ("Logs", .logs, .directories, false),
        ("HTTPStorages", .webData, .httpStorages, false),
        ("WebKit", .webData, .directories, false),
    ]

    func scan(installed: UninstallerInstalledSet, isRegistered: (String) -> Bool, now: Date = Date()) -> [UninstallerOrphanItem] {
        let scanner = FileSystemScanner()
        var registeredCache: [String: Bool] = [:]
        func registered(_ key: String) -> Bool {
            var parts = key.split(separator: ".")
            while parts.count >= 2 {
                let candidate = parts.joined(separator: ".")
                if let cached = registeredCache[candidate] {
                    if cached { return true }
                } else {
                    let value = isRegistered(candidate)
                    registeredCache[candidate] = value
                    if value { return true }
                }
                parts.removeLast()
            }
            return false
        }

        /// Common checks; returns the installed app from the same vendor (for a hint) or nil,
        /// and whether the identifier may be reported at all.
        func evaluate(_ identifier: String) -> (allowed: Bool, sameVendorApp: String?) {
            let key = identifier.lowercased()
            guard UninstallerIdentifierRules.isReverseDNS(identifier, minimumDots: 2),
                  !UninstallerIdentifierRules.isAppleIdentifier(key),
                  !Self.sharedComponentPrefixes.contains(where: { key.hasPrefix($0) }),
                  !installed.owns(key) else { return (false, nil) }
            let vendor = key.split(separator: ".").prefix(2).joined(separator: ".")
            let sameVendorApp = Self.genericVendors.contains(vendor) ? nil : installed.vendorApps[vendor]
            if sameVendorApp != nil, Self.suiteVendors.contains(vendor) { return (false, nil) }
            if registered(key) { return (false, nil) }
            return (true, sameVendorApp)
        }

        var items: [UninstallerOrphanItem] = []
        for root in Self.roots {
            let directory = homeLibrary + "/" + root.relative
            guard let records = try? scanner.children(of: directory, includeHidden: false) else { continue }
            for record in records {
                guard let identifier = identifier(for: record, style: root.style),
                      !UninstallerIdentifierRules.isAppleIdentifier(record.name),
                      !(root.style == .groups && installed.applicationGroups.contains(record.name.lowercased())) else { continue }
                let verdict = evaluate(identifier)
                guard verdict.allowed else { continue }
                let activity = lastActivity(of: record, protected: root.protected, scanner: scanner)
                if now.timeIntervalSince(activity) < recentActivityWindow { continue }
                items.append(UninstallerOrphanItem(
                    path: record.path,
                    identifier: identifier,
                    kind: root.kind,
                    modificationDate: activity,
                    isProtectedAppData: root.protected,
                    usage: nil,
                    snapshot: record.snapshot,
                    sameDeveloperAs: verdict.sameVendorApp
                ))
            }
        }

        // Launch agents and daemons whose program was inside an app that no longer exists.
        var jobRoots: [(String, UninstallerLeftoverKind, Bool)] = [(homeLibrary + "/LaunchAgents", .launchAgents, false)]
        if let systemLibrary {
            jobRoots += [(systemLibrary + "/LaunchAgents", .launchAgents, true), (systemLibrary + "/LaunchDaemons", .launchDaemons, true)]
        }
        for (directory, kind, systemWide) in jobRoots {
            for record in (try? scanner.children(of: directory, includeHidden: false)) ?? []
            where (record.type == .regular || record.type == .symlink) && record.name.hasSuffix(".plist") {
                guard let job = orphanedJob(record), !UninstallerIdentifierRules.isAppleIdentifier(job.label),
                      !Self.sharedComponentPrefixes.contains(where: { job.label.lowercased().hasPrefix($0) }) else { continue }
                let verdict = evaluate(job.label)
                if job.missingBundle != nil {
                    // Strong evidence: the program's app is gone. Skip only if an installed app claims the label.
                    guard !installed.owns(job.label.lowercased()) else { continue }
                } else {
                    // Every app the job declares must be gone.
                    guard verdict.allowed, job.associated.allSatisfy({ evaluate($0).allowed }) else { continue }
                }
                items.append(UninstallerOrphanItem(
                    path: record.path,
                    identifier: job.label,
                    kind: kind,
                    modificationDate: record.modificationDate,
                    isProtectedAppData: false,
                    isSystemWide: systemWide,
                    usage: nil,
                    snapshot: record.snapshot,
                    sameDeveloperAs: verdict.sameVendorApp
                ))
                // The privileged helper tool the daemon ran, when it's still there.
                for helper in job.helperTools where FileManager.default.fileExists(atPath: helper) {
                    guard let snapshot = FileSnapshot.capture(path: helper), !items.contains(where: { $0.path == helper }) else { continue }
                    items.append(UninstallerOrphanItem(
                        path: helper, identifier: job.label, kind: .privilegedHelpers, modificationDate: nil,
                        isProtectedAppData: false, isSystemWide: true, usage: nil, snapshot: snapshot, sameDeveloperAs: verdict.sameVendorApp
                    ))
                }
            }
        }
        return items
    }

    private struct OrphanedJob {
        var label: String
        /// The app bundle the job's program lived in, which no longer exists.
        var missingBundle: String?
        /// Apps the job declares in `AssociatedBundleIdentifiers`.
        var associated: [String]
        var helperTools: [String]
    }

    /// A launch job is a candidate when its program lived inside an app bundle that's gone,
    /// or when it declares the apps it belongs to (`AssociatedBundleIdentifiers`). Jobs
    /// without any app reference are left alone: there's no reliable evidence.
    private func orphanedJob(_ record: FileRecord) -> OrphanedJob? {
        let stem = String(record.name.dropLast(".plist".count))
        guard let plist = UninstallerInventory.plistDictionary(at: record.path) else {
            // A dangling link into a removed app bundle.
            guard record.type == .symlink,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: record.path),
                  target.hasPrefix("/"), Self.isCheckableProgramPath(target),
                  let bundle = Self.enclosingAppBundle(target), !FileManager.default.fileExists(atPath: bundle) else { return nil }
            return OrphanedJob(label: stem, missingBundle: bundle, associated: [], helperTools: [])
        }
        let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        var programs: [String] = []
        if let program = plist["Program"] as? String { programs.append(program) }
        programs += plist["ProgramArguments"] as? [String] ?? []
        let executables = programs.filter { $0.hasPrefix("/") && Self.isCheckableProgramPath($0) }
        let helperTools = executables.filter { $0.hasPrefix("/Library/PrivilegedHelperTools/") }
        if let bundle = executables.lazy.compactMap(Self.enclosingAppBundle).first {
            return FileManager.default.fileExists(atPath: bundle) ? nil : OrphanedJob(label: label, missingBundle: bundle, associated: [], helperTools: helperTools)
        }
        var associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
        if let single = plist["AssociatedBundleIdentifiers"] as? String { associated.append(single) }
        guard !associated.isEmpty else { return nil }
        return OrphanedJob(label: label, missingBundle: nil, associated: associated, helperTools: helperTools)
    }

    /// Paths on other volumes, inside macOS or in App Translocation can't prove an app is gone.
    private static func isCheckableProgramPath(_ path: String) -> Bool {
        !path.hasPrefix("/Volumes/") && !path.hasPrefix("/System/") && !path.contains("/AppTranslocation/")
    }

    /// "/Applications/Foo.app/Contents/MacOS/Foo" → "/Applications/Foo.app" (the outermost app bundle).
    static func enclosingAppBundle(_ path: String) -> String? {
        var built = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            built += "/" + component
            if component.lowercased().hasSuffix(".app") { return built }
        }
        return nil
    }

    /// Groups items by the app they came from, largest first. Identifiers that extend
    /// another found identifier ("com.vendor.App.Helper" next to "com.vendor.App") join its group.
    static func group(_ items: [UninstallerOrphanItem]) -> [UninstallerOrphanGroup] {
        let identifiers = Set(items.map { $0.identifier.lowercased() })
        func root(of key: String) -> String {
            var parts = key.split(separator: ".")
            var best = key
            while parts.count > 3 {
                parts.removeLast()
                let candidate = parts.joined(separator: ".")
                if identifiers.contains(candidate) { best = candidate }
            }
            return best
        }
        let grouped = Dictionary(grouping: items) { root(of: $0.identifier.lowercased()) }
        return grouped.compactMap { key, members -> UninstallerOrphanGroup? in
            guard let first = members.first else { return nil }
            let identifier = members.first { $0.identifier.lowercased() == key }?.identifier ?? first.identifier
            let sorted = members.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : $0.path < $1.path }
            return UninstallerOrphanGroup(identifier: identifier, items: sorted)
        }
        .sorted { lhs, rhs in
            lhs.totalBytes != rhs.totalBytes ? lhs.totalBytes > rhs.totalBytes : lhs.identifier.lowercased() < rhs.identifier.lowercased()
        }
    }

    // MARK: Helpers

    private func identifier(for record: FileRecord, style: Style) -> String? {
        let name = record.name
        switch style {
        case .directories:
            return record.type == .directory ? name : nil
        case .plistFiles, .hostPlistFiles:
            guard record.type == .regular, name.hasSuffix(".plist") else { return nil }
            let domain = String(name.dropLast(".plist".count))
            return style == .hostPlistFiles ? UninstallerIdentifierRules.strippingHostSuffix(domain) : domain
        case .savedState:
            guard record.type == .directory, name.hasSuffix(".savedState") else { return nil }
            return String(name.dropLast(".savedState".count))
        case .httpStorages:
            if record.type == .regular, name.hasSuffix(".binarycookies") { return String(name.dropLast(".binarycookies".count)) }
            return record.type == .directory ? name : nil
        case .groups:
            guard record.type == .directory else { return nil }
            return UninstallerIdentifierRules.parseGroupIdentifier(name).identifier
        }
    }

    /// The newest modification of an item and its immediate children (where readable without prompts).
    private func lastActivity(of record: FileRecord, protected: Bool, scanner: FileSystemScanner) -> Date {
        var newest = record.modificationDate
        guard record.type == .directory else { return newest }
        // Group containers can't be listed without permission. An app container's top level
        // can (only the Data folder inside it is protected), so it's read without opening Data.
        if protected && !canReadProtectedAppData && record.path.contains("/Group Containers/") { return newest }
        for child in (try? scanner.children(of: record.path, includeHidden: true)) ?? [] {
            newest = max(newest, child.modificationDate)
        }
        return newest
    }
}

/// Result of looking for leftovers of removed apps.
struct UninstallerOrphanScanResult: Sendable {
    var groups: [UninstallerOrphanGroup] = []
    /// Containers of removed apps that couldn't be measured without Full Disk Access.
    var unmeasuredProtected: [UninstallerOrphanItem] = []
    var scannedAt = Date()

    var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }
    var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

/// Runs the orphan scan end to end: installed identifiers, scan, safety check, sizes.
enum UninstallerOrphanService {
    static func scan(
        apps: [UninstallerApp],
        canReadProtectedAppData: Bool,
        exclusions: ExclusionList,
        policy: SafetyPolicy,
        scanner: FileSystemScanner = FileSystemScanner(),
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> UninstallerOrphanScanResult {
        progress?(0.1, "Checking which apps are installed…")
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let installed = UninstallerInstalledSet(apps: apps.map(\.identity), additionalIdentifiers: running)
        try Task.checkCancellation()

        progress?(0.25, "Looking for leftovers of removed apps…")
        let scanner = UninstallerOrphanScanner(canReadProtectedAppData: canReadProtectedAppData)
        let found = await BackgroundWork.run(qos: .userInitiated) {
            scanner.scan(installed: installed) { identifier in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
            }
            .filter { !exclusions.isExcluded($0.path) && policy.evaluate(path: $0.path, purpose: .applicationData).isAllowed }
        }
        try Task.checkCancellation()

        var result = UninstallerOrphanScanResult()
        let measurable = found.filter { !$0.isProtectedAppData || canReadProtectedAppData }
        result.unmeasuredProtected = found.filter { $0.isProtectedAppData && !canReadProtectedAppData }

        progress?(0.4, "Measuring \(measurable.count) item\(measurable.count == 1 ? "" : "s")…")
        let usages = await measure(measurable.map(\.path), scanner: FileSystemScanner()) { fraction in
            progress?(0.4 + 0.55 * fraction, "Measuring leftovers…")
        }
        try Task.checkCancellation()
        // Items that vanished, or whose folder can't be read at all (it then can't be removed either), are left out.
        let measured = measurable.compactMap { item -> UninstallerOrphanItem? in
            guard let usage = usages[item.path].flatMap(UninstallerLeftoverService.knownUsage) else { return nil }
            var copy = item
            copy.usage = usage
            return copy
        }
        result.groups = UninstallerOrphanScanner.group(measured)
        result.scannedAt = Date()
        progress?(1, "Done")
        return result
    }

    /// Measures paths a few at a time, reporting progress.
    static func measure(_ paths: [String], scanner: FileSystemScanner, concurrency: Int = 4, progress: (@Sendable (Double) -> Void)? = nil) async -> [String: DiskUsage] {
        var results: [String: DiskUsage] = [:]
        guard !paths.isEmpty else { return results }
        var options = WalkOptions()
        options.maxConcurrency = max(2, WalkOptions.defaultConcurrency / max(1, concurrency))
        let perItem = options
        await withTaskGroup(of: (String, DiskUsage?).self) { group in
            var iterator = paths.makeIterator()
            var completed = 0
            func addNext() -> Bool {
                guard let path = iterator.next() else { return false }
                group.addTask { (path, try? await scanner.measure(path: path, options: perItem)) }
                return true
            }
            for _ in 0..<max(1, concurrency) where !addNext() { break }
            while let (path, usage) = await group.next() {
                completed += 1
                if let usage { results[path] = usage }
                progress?(Double(completed) / Double(paths.count))
                if Task.isCancelled { group.cancelAll(); continue }
                _ = addNext()
            }
        }
        return results
    }
}
