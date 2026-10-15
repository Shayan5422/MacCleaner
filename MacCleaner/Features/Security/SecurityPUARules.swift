import Foundation

/// A rule for a widely documented macOS adware or potentially-unwanted-program family.
/// The list is deliberately short: only identifiers and install paths that are
/// well established in public removal guides are included.
struct SecurityPUARule: Sendable, Hashable, Identifiable {
    enum Classification: String, Sendable, Hashable {
        case adware
        case potentiallyUnwanted
        case malware

        var title: String {
            switch self {
            case .adware: return "Adware"
            case .potentiallyUnwanted: return "Potentially unwanted program"
            case .malware: return "Malware"
            }
        }
    }

    var id: String
    var family: String
    var classification: Classification
    var summary: String
    /// Exact bundle identifiers or launchd labels (compared case-insensitively).
    var exactIdentifiers: Set<String>
    /// Vendor prefixes, ending with a dot ("com.genieo.").
    var identifierPrefixes: [String]
    /// Documented install locations; `~` is the home folder. Items inside them match too.
    var knownPaths: [String]

    init(id: String, family: String, classification: Classification, summary: String,
         exactIdentifiers: [String] = [], identifierPrefixes: [String] = [], knownPaths: [String] = []) {
        self.id = id
        self.family = family
        self.classification = classification
        self.summary = summary
        self.exactIdentifiers = Set(exactIdentifiers.map { $0.lowercased() })
        self.identifierPrefixes = identifierPrefixes.map { $0.lowercased() }
        self.knownPaths = knownPaths
    }
}

/// A rule match. Exact matches are reported as threats, prefix matches as suspicious.
struct SecurityPUAMatch: Sendable, Hashable {
    enum Strength: String, Sendable, Hashable {
        case exact, prefix
    }

    var rule: SecurityPUARule
    var strength: Strength
    var matchedValue: String

    var severity: FindingSeverity { strength == .exact ? .threat : .suspicious }

    /// Shown as the finding's rule label.
    var ruleTitle: String {
        strength == .exact
            ? "Known adware/PUP rule match: \(rule.family)"
            : "Matches the naming pattern of \(rule.family)"
    }

    var explanation: String {
        switch strength {
        case .exact:
            return "“\(matchedValue)” exactly matches a documented component of \(rule.family) (\(rule.classification.title.lowercased())). \(rule.summary)"
        case .prefix:
            return "“\(matchedValue)” uses the identifier prefix of \(rule.family) (\(rule.classification.title.lowercased())), but isn't a documented component. Check whether you installed it on purpose."
        }
    }
}

enum SecurityPUARules {
    static let all: [SecurityPUARule] = [
        SecurityPUARule(
            id: "mackeeper", family: "MacKeeper", classification: .potentiallyUnwanted,
            summary: "Aggressively marketed system utility that security vendors classify as a potentially unwanted program.",
            exactIdentifiers: ["com.mackeeper.MacKeeper", "com.zeobit.MacKeeper"],
            identifierPrefixes: ["com.mackeeper.", "com.zeobit."],
            knownPaths: ["/Applications/MacKeeper.app", "~/Library/Application Support/MacKeeper Helper"]
        ),
        SecurityPUARule(
            id: "genieo", family: "Genieo", classification: .adware,
            summary: "Adware that hijacks browser search and home pages.",
            exactIdentifiers: [
                "com.genieo.engine", "com.genieo.completer.update", "com.genieo.completer.download",
                "com.genieoinnovation.macextension", "com.genieoinnovation.macextension.client",
            ],
            identifierPrefixes: ["com.genieo.", "com.genieoinnovation."],
            knownPaths: [
                "/Applications/Genieo.app", "/Applications/Uninstall Genieo.app", "/Applications/Uninstall IM Completer.app",
                "/Library/Frameworks/GenieoExtra.framework", "/Library/PrivilegedHelperTools/com.genieoinnovation.macextension.client",
                "/usr/lib/libgenkit.dylib", "/usr/lib/libgenkitsa.dylib", "/usr/lib/libimckit.dylib", "/usr/lib/libimckitsa.dylib",
                "~/Library/Application Support/com.genieoinnovation.Installer", "~/Library/Application Support/Genieo",
            ]
        ),
        SecurityPUARule(
            id: "vsearch", family: "VSearch (Downlite)", classification: .adware,
            summary: "Adware that injects ads and redirects browser searches.",
            exactIdentifiers: ["com.vsearch.agent", "com.vsearch.daemon", "com.vsearch.helper"],
            identifierPrefixes: ["com.vsearch."],
            knownPaths: [
                "/Library/Frameworks/VSearch.framework", "/System/Library/Frameworks/VSearch.framework",
                "/Library/Application Support/VSearch", "/Library/PrivilegedHelperTools/Jack", "/Library/LaunchDaemons/Jack.plist",
            ]
        ),
        SecurityPUARule(
            id: "conduit", family: "Conduit (Trovi)", classification: .adware,
            summary: "Browser hijacker that changes the search engine and home page.",
            identifierPrefixes: ["com.conduit."],
            knownPaths: [
                "/Library/InputManagers/CTLoader", "/Library/Application Support/Conduit",
                "~/Library/Internet Plug-Ins/ConduitNPAPIPlugin.plugin", "~/Library/Internet Plug-Ins/TroviNPAPIPlugin.plugin",
            ]
        ),
        SecurityPUARule(
            id: "spigot", family: "Spigot", classification: .adware,
            summary: "Bundled browser extensions and search agents that change browser settings.",
            identifierPrefixes: ["com.spigot."]
        ),
        SecurityPUARule(
            id: "pcvark", family: "Advanced Mac Cleaner (PCVARK)", classification: .potentiallyUnwanted,
            summary: "\"Optimizer\" apps that report exaggerated problems to sell a license.",
            exactIdentifiers: ["com.pcv.hlpramc"],
            identifierPrefixes: ["com.pcv."],
            knownPaths: ["/Applications/Advanced Mac Cleaner.app", "/Applications/Mac Auto Fixer.app"]
        ),
        SecurityPUARule(
            id: "crossrider", family: "Crossrider", classification: .adware,
            summary: "Adware platform that installs ad-injecting browser extensions.",
            identifierPrefixes: ["com.crossrider."]
        ),
        SecurityPUARule(
            id: "macdefender", family: "Mac Defender", classification: .malware,
            summary: "Fake antivirus that scares people into paying for a license.",
            knownPaths: ["/Applications/MacDefender.app", "/Applications/MacProtector.app"]
        ),
    ]

    /// Matches a bundle identifier or launchd label. Exact identifiers win over prefixes.
    static func match(identifier rawIdentifier: String, rules: [SecurityPUARule] = all) -> SecurityPUAMatch? {
        let identifier = rawIdentifier.lowercased()
        guard !identifier.isEmpty else { return nil }
        if let rule = rules.first(where: { $0.exactIdentifiers.contains(identifier) }) {
            return SecurityPUAMatch(rule: rule, strength: .exact, matchedValue: rawIdentifier)
        }
        if let rule = rules.first(where: { $0.identifierPrefixes.contains { identifier.hasPrefix($0) } }) {
            return SecurityPUAMatch(rule: rule, strength: .prefix, matchedValue: rawIdentifier)
        }
        return nil
    }

    /// Matches a path that is a documented install location or lies inside one.
    static func match(path: String, home: String = LaunchdLocations.home, rules: [SecurityPUARule] = all) -> SecurityPUAMatch? {
        for rule in rules {
            for known in rule.knownPaths {
                let expanded = expand(known, home: home)
                if PathUtilities.isSameOrDescendant(path, of: expanded) {
                    return SecurityPUAMatch(rule: rule, strength: .exact, matchedValue: path)
                }
            }
        }
        return nil
    }

    /// Documented install paths that exist on this Mac.
    static func installedKnownPaths(
        home: String = LaunchdLocations.home,
        rules: [SecurityPUARule] = all,
        exists: (String) -> Bool = { path in var info = stat(); return lstat(path, &info) == 0 }
    ) -> [SecurityPUAMatch] {
        rules.flatMap { rule in
            rule.knownPaths.map { expand($0, home: home) }.filter(exists).map {
                SecurityPUAMatch(rule: rule, strength: .exact, matchedValue: $0)
            }
        }
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}
