import Foundation

/// A folder or drive the duplicate finder searches.
struct DuplicateLocation: Identifiable, Hashable, Codable, Sendable {
    var path: String
    /// One of the standard personal folders. Default locations can be turned off but not removed.
    var isDefault: Bool
    var isEnabled: Bool

    var id: String { path }

    var displayName: String {
        let name = FileManager.default.displayName(atPath: path)
        return name.isEmpty ? (path as NSString).lastPathComponent : name
    }

    var isExternal: Bool { path.hasPrefix("/Volumes/") }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var symbolName: String {
        if isExternal {
            return path.split(separator: "/").count <= 2 ? "externaldrive.fill" : "folder.fill"
        }
        switch (path as NSString).lastPathComponent {
        case "Downloads": return "arrow.down.circle.fill"
        case "Documents": return "doc.fill"
        case "Desktop": return "menubar.dock.rectangle"
        case "Pictures": return "photo.fill"
        case "Movies": return "film.fill"
        case "Music": return "music.note"
        default: return "folder.fill"
        }
    }

    static let defaultFolderNames = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]

    /// ~/Downloads, ~/Documents, ~/Desktop, ~/Pictures, ~/Movies and ~/Music.
    static func defaultPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        defaultFolderNames.map { PathUtilities.join(home, $0) }
    }

    static func defaults(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [DuplicateLocation] {
        defaultPaths(home: home).map { DuplicateLocation(path: $0, isDefault: true, isEnabled: true) }
    }
}

/// Persists the duplicate finder's locations in `UserDefaults`.
struct DuplicateLocationStore {
    let defaults: UserDefaults
    var key = "duplicates.locations"

    /// Saved locations, with any missing default folder added back.
    func load() -> [DuplicateLocation] {
        var locations: [DuplicateLocation] = []
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([DuplicateLocation].self, from: data) {
            locations = saved
        }
        for location in DuplicateLocation.defaults() where !locations.contains(where: { $0.path == location.path }) {
            locations.append(location)
        }
        let order = Dictionary(uniqueKeysWithValues: DuplicateLocation.defaultPaths().enumerated().map { ($1, $0) })
        return locations.sorted { lhs, rhs in
            switch (order[lhs.path], order[rhs.path]) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        }
    }

    func save(_ locations: [DuplicateLocation]) {
        if let data = try? JSONEncoder().encode(locations) {
            defaults.set(data, forKey: key)
        }
    }
}
