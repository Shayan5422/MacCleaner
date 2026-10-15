import Darwin
import Foundation

/// Cloud storage services recognized by their local folders.
enum CloudProviderKind: String, Sendable, CaseIterable, Hashable {
    case iCloudDrive, googleDrive, dropbox, oneDrive, box, other

    var title: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        case .box: return "Box"
        case .other: return "Cloud Storage"
        }
    }

    var symbolName: String {
        switch self {
        case .iCloudDrive: return "icloud.fill"
        case .googleDrive: return "triangle.fill"
        case .dropbox: return "shippingbox.fill"
        case .oneDrive: return "cloud.fill"
        case .box: return "cube.fill"
        case .other: return "externaldrive.fill.badge.icloud"
        }
    }
}

/// What a detected folder is to its provider.
enum CloudLocationRole: String, Sendable, Hashable {
    /// The provider's main synced folder (iCloud Drive, a File Provider domain).
    case drive
    /// Desktop or Documents, synced by iCloud Drive's "Desktop & Documents Folders".
    case desktopAndDocuments
    /// Apps' iCloud containers in ~/Library/Mobile Documents (other than iCloud Drive itself).
    case appData
    /// A folder kept in sync by an older sync app that doesn't use macOS File Provider.
    case legacyFolder
}

/// A locally accessible, cloud-synchronized folder.
struct CloudLocation: Identifiable, Sendable, Hashable {
    var path: String
    var provider: CloudProviderKind
    /// "Google Drive", "Proton Drive"…
    var providerName: String
    /// Account or domain shown by the provider (an email address, "Personal", a company).
    var account: String?
    var role: CloudLocationRole
    var title: String

    var id: String { path }

    /// macOS can remove the local copy of items here while keeping them in the cloud
    /// (iCloud Drive and File Provider domains). Older sync apps manage this themselves.
    var supportsRemoveDownload: Bool { role != .legacyFolder }

    /// Groups locations of the same provider account in the interface.
    var groupID: String { provider.rawValue + "|" + providerName + "|" + (account ?? "") }
}

/// Finds cloud-synchronized folders in a home folder. Only names and file types are read.
enum CloudProviderDetector {
    static let iCloudDriveContainer = "com~apple~CloudDocs"

    static func detect(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [CloudLocation] {
        let home = PathUtilities.normalize(home)
        var locations: [CloudLocation] = []
        var seen = Set<String>()
        func add(_ location: CloudLocation) {
            let key = PathUtilities.resolvedPath(location.path) ?? location.path
            guard seen.insert(key).inserted else { return }
            locations.append(location)
        }

        // iCloud Drive.
        let mobileDocuments = home + "/Library/Mobile Documents"
        let cloudDocs = mobileDocuments + "/" + iCloudDriveContainer
        if isDirectory(cloudDocs) {
            add(CloudLocation(path: cloudDocs, provider: .iCloudDrive, providerName: "iCloud Drive", account: nil, role: .drive, title: "iCloud Drive"))
            for name in ["Desktop", "Documents"] where isSyncedWithICloudDrive(folder: home + "/" + name, cloudDocs: cloudDocs) {
                add(CloudLocation(path: home + "/" + name, provider: .iCloudDrive, providerName: "iCloud Drive", account: nil, role: .desktopAndDocuments, title: name))
            }
        }
        if let containers = try? FileManager.default.contentsOfDirectory(atPath: mobileDocuments),
           containers.contains(where: { $0 != iCloudDriveContainer && !$0.hasPrefix(".") && isDirectory(mobileDocuments + "/" + $0) }) {
            add(CloudLocation(path: mobileDocuments, provider: .iCloudDrive, providerName: "iCloud Drive", account: nil, role: .appData, title: "App Data in iCloud"))
        }

        // File Provider domains (Google Drive, Dropbox, OneDrive, Box…).
        let cloudStorage = home + "/Library/CloudStorage"
        let domains = (try? FileManager.default.contentsOfDirectory(atPath: cloudStorage)) ?? []
        for name in domains.sorted() where !name.hasPrefix(".") {
            let path = cloudStorage + "/" + name
            guard isDirectory(path), let parsed = parseFileProviderFolder(name: name) else { continue }
            add(CloudLocation(path: path, provider: parsed.kind, providerName: parsed.providerName, account: parsed.account, role: .drive, title: parsed.providerName))
        }

        // Folders of older sync apps directly in the home folder. Symlinks to File Provider
        // domains (modern Dropbox creates ~/Dropbox → ~/Library/CloudStorage/Dropbox) are skipped.
        let homeItems = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        for name in homeItems.sorted() {
            guard let parsed = parseLegacyFolder(name: name) else { continue }
            let path = home + "/" + name
            guard isDirectory(path) else { continue }
            add(CloudLocation(path: path, provider: parsed.kind, providerName: parsed.providerName, account: parsed.account, role: .legacyFolder, title: name))
        }
        return locations
    }

    /// Paths in the home folder that belong to cloud sync apps (real folders or links), for
    /// features that must never treat their contents as ordinary local files.
    static func legacyFolderPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let home = PathUtilities.normalize(home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { parseLegacyFolder(name: $0) != nil || $0 == "pCloud Drive" }.map { home + "/" + $0 }
    }

    // MARK: - Name parsing

    /// `GoogleDrive-me@example.com`, `Dropbox`, `OneDrive-Personal`, `Box-Box`, `ProtonDrive-me@proton.me`…
    static func parseFileProviderFolder(name: String) -> (kind: CloudProviderKind, providerName: String, account: String?)? {
        guard !name.isEmpty else { return nil }
        let (token, account) = splitProviderToken(name)
        switch token.lowercased() {
        case "googledrive": return (.googleDrive, "Google Drive", account)
        case "dropbox": return (.dropbox, "Dropbox", account)
        case "onedrive": return (.oneDrive, "OneDrive", account)
        case "box": return (.box, "Box", account == "Box" ? nil : account)
        default:
            let providerName = prettify(token)
            return providerName.isEmpty ? nil : (.other, providerName, account)
        }
    }

    /// Recognized folders of sync apps in the home folder.
    static func parseLegacyFolder(name: String) -> (kind: CloudProviderKind, providerName: String, account: String?)? {
        func suffix(after prefix: String) -> String? {
            let rest = name.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: " -()"))
            return rest.isEmpty ? nil : rest
        }
        if name == "Dropbox" || name.hasPrefix("Dropbox (") { return (.dropbox, "Dropbox", suffix(after: "Dropbox")) }
        if name == "Google Drive" { return (.googleDrive, "Google Drive", nil) }
        if name == "OneDrive" || name.hasPrefix("OneDrive - ") { return (.oneDrive, "OneDrive", suffix(after: "OneDrive")) }
        if name == "Box" || name == "Box Sync" { return (.box, "Box", nil) }
        if name == "Creative Cloud Files" || name.hasPrefix("Creative Cloud Files (") {
            return (.other, "Adobe Creative Cloud", suffix(after: "Creative Cloud Files"))
        }
        if name == "MEGA" || name == "MEGAsync" { return (.other, "MEGA", nil) }
        if name == "Nextcloud" { return (.other, "Nextcloud", nil) }
        if name == "ownCloud" { return (.other, "ownCloud", nil) }
        return nil
    }

    /// Readable title for an app's iCloud container (`57T9237FN3~net~whatsapp~WhatsApp` → `WhatsApp`).
    static func appContainerTitle(_ name: String) -> String {
        var parts = name.split(separator: "~").map(String.init)
        if let first = parts.first, first == "iCloud" || isTeamIdentifier(first), parts.count > 1 {
            parts.removeFirst()
        }
        if parts.count > 2, ["com", "net", "org", "io", "co", "de", "fr", "uk", "jp", "cc"].contains(parts[0].lowercased()) {
            parts.removeFirst(2)
        }
        let title = parts.joined(separator: " ")
        return title.isEmpty ? name : title
    }

    // MARK: - Desktop & Documents

    /// iCloud Drive's "Desktop & Documents Folders" keeps ~/Desktop and ~/Documents in iCloud.
    /// They are then marked with iCloud Drive's File Provider domain, and iCloud Drive contains
    /// links to them.
    static func isSyncedWithICloudDrive(folder: String, cloudDocs: String) -> Bool {
        guard isDirectory(folder) else { return false }
        if let domain = extendedAttribute("com.apple.file-provider-domain-id", path: folder), domain.hasPrefix("com.apple.CloudDocs") {
            return true
        }
        let link = cloudDocs + "/" + (folder as NSString).lastPathComponent
        var info = stat()
        guard lstat(link, &info) == 0, FileObjectType(mode: info.st_mode) == .symlink,
              let resolved = PathUtilities.resolvedPath(link), let target = PathUtilities.resolvedPath(folder) else { return false }
        return resolved == target
    }

    // MARK: - Helpers

    private static func splitProviderToken(_ name: String) -> (String, String?) {
        if let dash = name.firstIndex(of: "-") {
            let token = String(name[..<dash])
            let rest = String(name[name.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            return (token, rest.isEmpty ? nil : rest)
        }
        if let paren = name.firstIndex(of: "(") {
            let token = String(name[..<paren]).trimmingCharacters(in: .whitespaces)
            let rest = name[paren...].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            return (token, rest.isEmpty ? nil : rest)
        }
        return (name, nil)
    }

    /// `ProtonDrive` → `Proton Drive`, `pCloud` → `pCloud`.
    static func prettify(_ token: String) -> String {
        var result = ""
        var previous: Character?
        for character in token {
            if let previous, character.isUppercase, previous.isLowercase {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// `lstat` without following links: a symlinked folder is not a synced folder itself.
    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && FileObjectType(mode: info.st_mode) == .directory
    }

    private static func extendedAttribute(_ name: String, path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let length = getxattr(path, name, &buffer, buffer.count - 1, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
