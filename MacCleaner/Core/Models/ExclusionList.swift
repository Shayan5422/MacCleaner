import Foundation

/// Paths the person never wants scanned or cleaned. An excluded path also
/// excludes everything inside it.
struct ExclusionList: Sendable, Hashable, Codable {
    private(set) var paths: [String]

    init(paths: [String] = []) {
        self.paths = []
        for path in paths { add(path) }
    }

    var isEmpty: Bool { paths.isEmpty }

    mutating func add(_ path: String) {
        let normalized = PathUtilities.normalize(path)
        guard !normalized.isEmpty, !paths.contains(normalized) else { return }
        paths.append(normalized)
        paths.sort()
    }

    mutating func remove(_ path: String) {
        let normalized = PathUtilities.normalize(path)
        paths.removeAll { $0 == normalized }
    }

    /// `true` if `path` is an excluded path or lies inside one. Paths seen through
    /// the data volume (`/System/Volumes/Data/Users/…`) match exclusions stored
    /// in their usual form (`/Users/…`).
    func isExcluded(_ path: String) -> Bool {
        guard !paths.isEmpty else { return false }
        let canonical = PathUtilities.firmlinkCanonical(path)
        for excluded in paths where PathUtilities.isSameOrDescendant(canonical, of: excluded) {
            return true
        }
        return false
    }

    /// `true` if any exclusion lies at or below `directory`. Lets a walker skip
    /// per-entry checks for directories that contain no exclusions.
    func hasExclusions(inside directory: String) -> Bool {
        guard !paths.isEmpty else { return false }
        let canonical = PathUtilities.firmlinkCanonical(directory)
        if canonical == "/System/Volumes/Data" { return true }
        return paths.contains { PathUtilities.isSameOrDescendant($0, of: canonical) }
    }
}

/// Small, allocation-light helpers for absolute POSIX paths.
enum PathUtilities {
    /// Expands `~`, collapses `//`, drops `.` components and trailing slashes.
    /// Purely lexical: it never resolves symlinks and, unlike
    /// `NSString.standardizingPath`, never strips `/private` (which would make
    /// `/private/tmp/x` and `/tmp/x` look different from what's on disk).
    /// `..` components are kept so safety checks can reject them.
    static func normalize(_ path: String) -> String {
        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
        guard expanded.hasPrefix("/") else { return expanded }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// `true` when `path` equals `ancestor` or is inside it, comparing whole components.
    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        guard path.hasPrefix(ancestor) else { return false }
        if path.utf8.count == ancestor.utf8.count { return true }
        let index = path.utf8.index(path.utf8.startIndex, offsetBy: ancestor.utf8.count)
        return path.utf8[index] == UInt8(ascii: "/")
    }

    /// `true` when `path` is strictly inside `ancestor`.
    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        path != ancestor && isSameOrDescendant(path, of: ancestor)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Replaces the home directory prefix with `~` for display.
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if isSameOrDescendant(path, of: home) {
            return "~" + path.dropFirst(home.count)
        }
        if path.hasPrefix("/System/Volumes/Data/") {
            return String(path.dropFirst("/System/Volumes/Data".count))
        }
        return path
    }

    /// Removes paths that are inside another path of the same list, so nested
    /// selections are neither counted nor deleted twice.
    static func removingNestedPaths(_ paths: [String]) -> [String] {
        let sorted = Array(Set(paths)).sorted()
        var result: [String] = []
        for path in sorted {
            if let last = result.last, isSameOrDescendant(path, of: last) { continue }
            result.append(path)
        }
        return result
    }

    /// Resolves symlinks in every component (`realpath(3)`). Returns nil if the path doesn't exist.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
