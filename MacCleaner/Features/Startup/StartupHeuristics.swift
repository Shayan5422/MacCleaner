import Foundation

/// Rules that point out startup items that are probably unnecessary. They only
/// explain; nothing is changed without the person's confirmation.
enum StartupHeuristics {
    /// An owner app not opened for this long makes its background items "unused".
    static let unusedAppDays = 90
    /// KeepAlive items of apps not opened for this long are called out for their constant resource use.
    static let rarelyUsedDays = 30
    /// More login items than this slows down login noticeably.
    static let manyLoginItemsThreshold = 8

    /// Bundle-identifier prefixes shared by unrelated developers, which can't identify a vendor.
    static let sharedVendorPrefixes: Set<String> = [
        "com.github", "io.github", "org.github", "com.example", "org.example", "net.sourceforge", "org.sourceforge",
        "com.googlecode", "homebrew.mxcl", "org.homebrew", "sh.brew", "com.company", "com.mycompany", "local.user",
    ]

    /// Words that mark background helpers rather than apps people use directly.
    static let helperKeywords = [
        "update", "keystone", "helper", "agent", "launcher", "daemon", "service", "autorun", "startup", "notifier", "check",
    ]

    /// Fills in `concerns` for every item. Duplicates are found across all items.
    static func applyConcerns(to items: [StartupItem], installedVendorPrefixes: Set<String>, now: Date = Date()) -> [StartupItem] {
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            if let key = duplicateKey(for: item) { groups[key, default: []].append(index) }
        }
        return items.enumerated().map { index, item in
            var copy = item
            let others = duplicateKey(for: item).flatMap { groups[$0] }?.filter { $0 != index }.map { items[$0] } ?? []
            copy.concerns = concerns(for: item, duplicates: others, installedVendorPrefixes: installedVendorPrefixes, now: now)
            return copy
        }
    }

    static func concerns(for item: StartupItem, duplicates: [StartupItem], installedVendorPrefixes: Set<String>, now: Date) -> [StartupConcern] {
        // A damaged or empty property list: nothing else applies.
        if item.parseError != nil {
            return [StartupConcern(kind: .empty, title: "Damaged property list",
                                   explanation: "launchd can't read this property list, so it never starts anything. It's safe to remove.")]
        }
        if let definition = item.definition, definition.isEmpty {
            return [StartupConcern(kind: .empty, title: "Empty property list",
                                   explanation: "It doesn't define a program to run, so launchd ignores it. It's safe to remove.")]
        }

        if isBroken(item) {
            let missing = item.targetPath ?? item.analysis?.executable ?? item.analysis?.openTarget
            let what = missing.map { "“\(PathUtilities.abbreviate($0))”" } ?? "The program it starts"
            return [StartupConcern(kind: .broken, title: "Program is missing",
                                   explanation: "\(what) no longer exists, so this item does nothing at login. It can be removed.")]
        }

        var result: [StartupConcern] = []
        if let owner = item.owner, let lastUsed = owner.lastUsedDate {
            let days = Int(now.timeIntervalSince(lastUsed) / 86_400)
            if days >= unusedAppDays {
                let when = DateFormatting.relative(lastUsed, to: now)
                let explanation = item.kind == .loginItem
                    ? "\(owner.name) was last opened \(when). If you no longer use it, it doesn't need to open at login."
                    : "Belongs to \(owner.name), which you last opened \(when). If you no longer use it, its background items aren't needed."
                result.append(StartupConcern(kind: .unusedApp, title: "App not used recently", explanation: explanation))
            }
            if item.kind != .loginItem, item.definition?.keepAlive == .always, days >= rarelyUsedDays {
                result.append(StartupConcern(kind: .keepAliveRarelyUsed, title: "Always running for a rarely used app",
                                             explanation: "launchd keeps it running all the time, but \(owner.name) was last opened \(DateFormatting.relative(lastUsed, to: now))."))
            }
        }

        let activeDuplicates = duplicates.filter { $0.isEnabled != false && !isBroken($0) }
        if item.isEnabled != false, let other = activeDuplicates.first {
            let subject = item.analysis?.targetKind == .application || item.kind == .loginItem
                ? (item.targetPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? item.name)
                : item.name
            let more = activeDuplicates.count > 1 ? " and \(activeDuplicates.count - 1) more" : ""
            result.append(StartupConcern(kind: .duplicate, title: "Starts more than once",
                                         explanation: "\(subject) also starts through “\(other.name)” (\(other.kind.title.lowercased()))\(more). One of them is usually enough."))
        }

        if let leftover = leftoverConcern(for: item, installedVendorPrefixes: installedVendorPrefixes) {
            result.append(leftover)
        }
        return result
    }

    static func isBroken(_ item: StartupItem) -> Bool {
        switch item.kind {
        case .loginItem:
            return item.targetPath == nil || item.code?.exists == false
        case .appBackgroundItem where item.definition == nil:
            return false
        default:
            return item.analysis?.isBroken ?? false
        }
    }

    /// Two items are duplicates when they start the same app, or the same command line.
    static func duplicateKey(for item: StartupItem) -> String? {
        if item.kind == .loginItem {
            return item.targetPath.map { "app:" + $0 + "|Aqua" }
        }
        guard let analysis = item.analysis else { return nil }
        // Jobs limited to different sessions (login window vs. your session) don't overlap.
        // Agents default to the "Aqua" (logged-in) session, daemons to "System".
        let isDaemon = item.kind == .systemDaemon || item.plistPath?.contains("/LaunchDaemons/") == true
        let declared = item.definition?.limitLoadToSessionTypes ?? []
        let sessions = (declared.isEmpty ? [isDaemon ? "System" : "Aqua"] : declared).sorted().joined(separator: ",")
        switch analysis.targetKind {
        case .application:
            return analysis.targetPath.map { "app:" + $0 + "|" + sessions }
        case .program, .script, .inlineCode:
            guard let executable = analysis.executable else { return nil }
            return "cmd:" + ([executable] + analysis.arguments.dropFirst()).joined(separator: "\u{1F}") + "|" + sessions
        case .url, .unknown:
            return nil
        }
    }

    /// Updaters and helpers of a developer none of whose apps are installed any more.
    /// Only programs in vendor locations count (app bundles, plug-ins, Application Support,
    /// privileged helpers); command-line tools and scripts don't come with apps.
    static func leftoverConcern(for item: StartupItem, installedVendorPrefixes: Set<String>, home: String = LaunchdLocations.home) -> StartupConcern? {
        guard item.kind == .userAgent || item.kind == .systemAgent || item.kind == .systemDaemon,
              item.owner == nil, !item.isProtected, let label = item.label,
              let vendor = vendorPrefix(of: label), !sharedVendorPrefixes.contains(vendor),
              label.split(separator: ".").count >= 3, !installedVendorPrefixes.contains(vendor),
              let target = item.targetPath, isVendorLocation(target, home: home) else { return nil }
        let haystack = (label + " " + (target as NSString).lastPathComponent).lowercased()
        guard helperKeywords.contains(where: { haystack.contains($0) }) else { return nil }
        return StartupConcern(kind: .leftover, title: "Possibly left behind",
                              explanation: "No app with the identifier prefix “\(vendor)” is installed in your Applications folders. If you removed that developer's apps, this helper is probably left over.")
    }

    /// Places where vendors install helpers that belong to their apps.
    static func isVendorLocation(_ path: String, home: String) -> Bool {
        let lowered = path.lowercased()
        if [".app/", ".plugin/", ".bundle/", ".framework/"].contains(where: { lowered.contains($0) }) || lowered.hasSuffix(".app") { return true }
        let prefixes = ["/Library/PrivilegedHelperTools/", "/Library/Application Support/", home + "/Library/Application Support/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// "com.vendor.product.helper" → "com.vendor".
    static func vendorPrefix(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts[0] + "." + parts[1]
    }
}
