import Foundation

/// A `[ProfileN]` section of Firefox's profiles.ini.
struct PrivacyFirefoxINIProfile: Sendable, Hashable {
    var name: String?
    var path: String
    var isRelative: Bool
    var isDefault: Bool
}

/// Finds browser profiles on disk. Only folder names and the small profile
/// lists (`Local State`, `profiles.ini`) are read; no browsing data is opened.
enum PrivacyProfileDiscovery {
    /// Chromium profiles that don't hold a person's browsing data.
    static let ignoredChromiumFolders: Set<String> = ["Guest Profile", "System Profile"]

    struct ChromiumProfiles: Sendable {
        var profiles: [PrivacyBrowserProfile] = []
        var supportBlocked = false
        var cacheBlocked = false
    }

    struct FirefoxProfiles: Sendable {
        var profiles: [PrivacyBrowserProfile] = []
        var supportBlocked = false
    }

    /// "Default" or "Profile N".
    static func isChromiumProfileFolderName(_ name: String) -> Bool {
        if name == "Default" { return true }
        guard name.hasPrefix("Profile ") else { return false }
        let number = name.dropFirst("Profile ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    // MARK: - Chromium family

    /// Profiles of a Chromium-based browser. Profile folders are found in the
    /// data folder (folders named Default/Profile N or containing Preferences)
    /// and, when the data folder is protected, in the cache folder.
    static func chromiumProfiles(supportRoot: String, cacheRoot: String?) -> ChromiumProfiles {
        var result = ChromiumProfiles()
        var found: [String: PrivacyBrowserProfile] = [:]

        func cacheFolder(for name: String) -> String? {
            guard let cacheRoot else { return nil }
            let path = name.isEmpty ? cacheRoot : cacheRoot + "/" + name
            return PrivacyFileAccess.probe(path) == .directory ? path : nil
        }

        switch PrivacyFileAccess.list(supportRoot) {
        case .entries(let records):
            let names = Set(records.map(\.name))
            // Opera keeps its only profile directly in the data folder.
            if names.contains("Preferences"), names.contains("History") || names.contains("Cookies") || names.contains("Network") {
                found[""] = PrivacyBrowserProfile(directoryName: "", displayName: "Default profile", dataPath: supportRoot, cachePath: cacheFolder(for: ""), isDefault: true)
            }
            for record in records where record.type == .directory && !ignoredChromiumFolders.contains(record.name) {
                let looksLikeProfile = isChromiumProfileFolderName(record.name)
                    || PrivacyFileAccess.probe(record.path + "/Preferences") == .file
                guard looksLikeProfile else { continue }
                found[record.name] = PrivacyBrowserProfile(
                    directoryName: record.name, displayName: record.name, dataPath: record.path,
                    cachePath: cacheFolder(for: record.name), isDefault: record.name == "Default"
                )
            }
        case .blocked:
            result.supportBlocked = true
        case .missing:
            break
        }

        if let cacheRoot, found[""] == nil {
            switch PrivacyFileAccess.list(cacheRoot) {
            case .entries(let records):
                for record in records where record.type == .directory && isChromiumProfileFolderName(record.name) && found[record.name] == nil {
                    let dataPath = supportRoot + "/" + record.name
                    found[record.name] = PrivacyBrowserProfile(
                        directoryName: record.name, displayName: record.name,
                        dataPath: PrivacyFileAccess.probe(dataPath) == .directory ? dataPath : nil,
                        cachePath: record.path, isDefault: record.name == "Default"
                    )
                }
            case .blocked:
                result.cacheBlocked = true
            case .missing:
                break
            }
        }

        let displayNames = result.supportBlocked ? [:] : chromiumProfileNames(localStatePath: supportRoot + "/Local State")
        result.profiles = found.values.map { profile in
            var named = profile
            if let name = displayNames[profile.directoryName], !name.isEmpty {
                named.displayName = name
            } else if profile.directoryName == "Default" || profile.directoryName.isEmpty {
                named.displayName = "Default profile"
            }
            return named
        }
        .sorted(by: chromiumOrder)
        return result
    }

    /// Profile names people chose, read from the browser's `Local State` file.
    static func chromiumProfileNames(localStatePath: String) -> [String: String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localStatePath),
              let size = attributes[.size] as? NSNumber, size.intValue < 16 * 1024 * 1024,
              let data = FileManager.default.contents(atPath: localStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (folder, value) in cache {
            if let entry = value as? [String: Any], let name = entry["name"] as? String {
                names[folder] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return names
    }

    private static func chromiumOrder(_ lhs: PrivacyBrowserProfile, _ rhs: PrivacyBrowserProfile) -> Bool {
        func rank(_ profile: PrivacyBrowserProfile) -> (Int, Int, String) {
            if profile.directoryName.isEmpty || profile.directoryName == "Default" { return (0, 0, "") }
            if isChromiumProfileFolderName(profile.directoryName) {
                return (1, Int(profile.directoryName.dropFirst("Profile ".count)) ?? 0, "")
            }
            return (2, 0, profile.directoryName)
        }
        return rank(lhs) < rank(rhs)
    }

    // MARK: - Firefox

    /// Parses Firefox's `profiles.ini`.
    static func parseFirefoxProfilesINI(_ text: String) -> (profiles: [PrivacyFirefoxINIProfile], installDefaults: Set<String>) {
        var sections: [(name: String, values: [String: String])] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
                continue
            }
            guard let separator = line.firstIndex(of: "="), !sections.isEmpty else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            sections[sections.count - 1].values[key] = value
        }

        var profiles: [PrivacyFirefoxINIProfile] = []
        var installDefaults = Set<String>()
        for section in sections {
            if section.name.hasPrefix("Install"), let path = section.values["Default"], !path.isEmpty {
                installDefaults.insert(path)
            } else if section.name.hasPrefix("Profile"), let path = section.values["Path"], !path.isEmpty {
                profiles.append(PrivacyFirefoxINIProfile(
                    name: section.values["Name"],
                    path: path,
                    isRelative: section.values["IsRelative"] != "0",
                    isDefault: section.values["Default"] == "1"
                ))
            }
        }
        return (profiles, installDefaults)
    }

    /// Firefox profiles from profiles.ini plus any profile folders it doesn't list.
    /// Profiles stored outside the Library folder are skipped: the Privacy
    /// cleaner only removes data inside ~/Library.
    static func firefoxProfiles(supportRoot: String, cacheRoot: String?, home: String) -> FirefoxProfiles {
        var result = FirefoxProfiles()
        let library = home + "/Library"
        var seen = Set<String>()
        var profiles: [PrivacyBrowserProfile] = []

        if PrivacyFileAccess.isBlockedDirectory(supportRoot) {
            result.supportBlocked = true
            return result
        }

        func add(path: String, name: String?, isDefault: Bool) {
            guard let normalized = cleanAbsolutePath(path),
                  PathUtilities.isDescendant(normalized, of: library),
                  PrivacyFileAccess.probe(normalized) == .directory,
                  seen.insert(normalized).inserted else { return }
            let folder = (normalized as NSString).lastPathComponent
            var cachePath: String?
            if let cacheRoot {
                let candidate = cacheRoot + "/Profiles/" + folder
                if PrivacyFileAccess.probe(candidate) == .directory { cachePath = candidate }
            }
            let fallbackName = folder.split(separator: ".", maxSplits: 1).last.map(String.init) ?? folder
            profiles.append(PrivacyBrowserProfile(
                directoryName: folder,
                displayName: (name?.isEmpty == false ? name : nil) ?? fallbackName,
                dataPath: normalized,
                cachePath: cachePath,
                isDefault: isDefault
            ))
        }

        if let data = FileManager.default.contents(atPath: supportRoot + "/profiles.ini"),
           let text = String(data: data, encoding: .utf8) {
            let parsed = parseFirefoxProfilesINI(text)
            for profile in parsed.profiles {
                let absolute = profile.isRelative ? supportRoot + "/" + profile.path : profile.path
                add(path: absolute, name: profile.name, isDefault: profile.isDefault || parsed.installDefaults.contains(profile.path))
            }
        }

        if case .entries(let records) = PrivacyFileAccess.list(supportRoot + "/Profiles") {
            for record in records.sorted(by: { $0.name < $1.name }) where record.type == .directory {
                add(path: record.path, name: nil, isDefault: false)
            }
        }

        result.profiles = profiles.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return result
    }

    /// Collapses repeated and trailing slashes. Rejects relative paths and paths
    /// with `.` or `..` components. Unlike `PathUtilities.normalize`, it never
    /// rewrites `/private` prefixes, so paths stay comparable with their roots.
    static func cleanAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return "/" + components.joined(separator: "/")
    }
}
