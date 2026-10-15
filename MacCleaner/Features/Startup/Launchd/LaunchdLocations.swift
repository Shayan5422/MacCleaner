import Foundation

/// Where launchd property lists live, and how they are listed.
enum LaunchdLocations {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var userAgentsFolder: String { home + "/Library/LaunchAgents" }
    static let systemAgentsFolder = "/Library/LaunchAgents"
    static let systemDaemonsFolder = "/Library/LaunchDaemons"

    /// A property list found in a launchd folder.
    struct PlistFile: Sendable, Hashable {
        /// Path inside the launchd folder (may be a symbolic link).
        var path: String
        /// Where a symbolic link points, when the file is a link.
        var linkDestination: String?
    }

    /// Lists `*.plist` files directly inside `folder`. Unreadable folders return nil.
    static func plistFiles(in folder: String) -> [PlistFile]? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return nil }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".plist"), !name.hasPrefix("._") else { return nil }
            let path = folder + "/" + name
            var destination: String?
            if let attributes = try? manager.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                destination = PathUtilities.resolvedPath(path)
                    ?? (try? manager.destinationOfSymbolicLink(atPath: path))
            }
            return PlistFile(path: path, linkDestination: destination)
        }
    }

    /// Background items embedded in an app bundle (SMAppService / SMLoginItemSetEnabled style).
    struct EmbeddedItems: Sendable, Hashable {
        var loginItemApps: [String] = []
        var agentPlists: [String] = []
        var daemonPlists: [String] = []

        var isEmpty: Bool { loginItemApps.isEmpty && agentPlists.isEmpty && daemonPlists.isEmpty }
    }

    static func embeddedItems(inApp appPath: String) -> EmbeddedItems {
        let manager = FileManager.default
        func list(_ relative: String, suffix: String) -> [String] {
            let folder = appPath + "/Contents/Library/" + relative
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return [] }
            return names.sorted().filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }.map { folder + "/" + $0 }
        }
        return EmbeddedItems(
            loginItemApps: list("LoginItems", suffix: ".app"),
            agentPlists: list("LaunchAgents", suffix: ".plist"),
            daemonPlists: list("LaunchDaemons", suffix: ".plist")
        )
    }
}
