import AppKit
import Foundation
import Observation

/// Panes of System Settings › Privacy & Security that Mac Cleaner may point to.
enum SystemSettingsPane: String, CaseIterable, Sendable {
    case fullDiskAccess
    case appManagement
    case automation
    case filesAndFolders
    case loginItems
    case notifications
    case storage
    case softwareUpdate
    case firewall
    case fileVault
    case privacySecurity

    var url: URL {
        let string: String
        switch self {
        case .fullDiskAccess: string = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .appManagement: string = "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
        case .automation: string = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .filesAndFolders: string = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        case .loginItems: string = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case .notifications: string = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .storage: string = "x-apple.systempreferences:com.apple.settings.Storage"
        case .softwareUpdate: string = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        case .firewall: string = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
        case .fileVault: string = "x-apple.systempreferences:com.apple.preference.security?FileVault"
        case .privacySecurity: string = "x-apple.systempreferences:com.apple.preference.security"
        }
        return URL(string: string)!
    }

    var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .appManagement: return "App Management"
        case .automation: return "Automation"
        case .filesAndFolders: return "Files & Folders"
        case .loginItems: return "Login Items & Extensions"
        case .notifications: return "Notifications"
        case .storage: return "Storage"
        case .softwareUpdate: return "Software Update"
        case .firewall: return "Firewall"
        case .fileVault: return "FileVault"
        case .privacySecurity: return "Privacy & Security"
        }
    }
}

/// Status of a privacy permission.
enum PermissionStatus: String, Sendable {
    case granted, notGranted, unknown
}

/// A folder the person chose in an open panel, remembered with a bookmark so
/// it can be scanned again later (for example an external drive).
struct AuthorizedLocation: Identifiable, Sendable, Hashable, Codable {
    var id = UUID()
    var path: String
    var bookmark: Data
    var addedDate = Date()
}

/// Detects privacy permissions and guides people to grant them. Mac Cleaner
/// never tries to work around TCC: if access is missing, it says so and offers
/// the right System Settings pane.
@MainActor
@Observable
final class PermissionManager {
    private(set) var fullDiskAccess: PermissionStatus = .unknown
    private(set) var authorizedLocations: [AuthorizedLocation] = []
    private let defaultsKey = "authorizedLocations"

    init() {
        loadLocations()
        refresh()
    }

    func refresh() {
        fullDiskAccess = FullDiskAccessProbe.status()
    }

    func open(_ pane: SystemSettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }

    /// Shows an open panel and remembers the chosen folder.
    func chooseFolder(message: String, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = message
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    /// Shows an open panel for files or folders without remembering them.
    func chooseItems(message: String, allowFiles: Bool = true, allowMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowFiles
        panel.allowsMultipleSelection = allowMultiple
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    func remember(_ url: URL) {
        guard !authorizedLocations.contains(where: { $0.path == url.path }) else { return }
        // Security-scoped bookmarks keep access across launches when sandboxed;
        // outside the sandbox a regular bookmark tracks the folder if it moves.
        let options: URL.BookmarkCreationOptions = Self.isSandboxed ? [.withSecurityScope] : []
        guard let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        authorizedLocations.append(AuthorizedLocation(path: url.path, bookmark: data))
        saveLocations()
    }

    func forget(_ location: AuthorizedLocation) {
        authorizedLocations.removeAll { $0.id == location.id }
        saveLocations()
    }

    /// Resolves a remembered folder and starts security-scoped access if needed.
    /// Call `stopAccessing` when done.
    func resolve(_ location: AuthorizedLocation) -> URL? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = Self.isSandboxed ? [.withSecurityScope] : []
        guard let url = try? URL(resolvingBookmarkData: location.bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if Self.isSandboxed { _ = url.startAccessingSecurityScopedResource() }
        if stale { remember(url) }
        return url
    }

    func stopAccessing(_ url: URL) {
        if Self.isSandboxed { url.stopAccessingSecurityScopedResource() }
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private func loadLocations() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([AuthorizedLocation].self, from: data) else { return }
        authorizedLocations = decoded
    }

    private func saveLocations() {
        if let data = try? JSONEncoder().encode(authorizedLocations) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Determines whether Full Disk Access is granted by attempting to open
/// (never read) locations that macOS protects behind it.
enum FullDiskAccessProbe {
    static func status() -> PermissionStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedFiles = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Safari/CloudTabs.db",
        ]
        for path in protectedFiles {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { return .notGranted }
        }
        let protectedFolders = [home + "/Library/Safari", home + "/Library/Mail", home + "/Library/Messages"]
        for path in protectedFolders {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd >= 0 {
                defer { close(fd) }
                // Opening may succeed while listing is still denied.
                if let directory = fdopendir(dup(fd)) {
                    defer { closedir(directory) }
                    errno = 0
                    if readdir(directory) != nil { return .granted }
                    if errno == EPERM || errno == EACCES { return .notGranted }
                }
                continue
            }
            if errno == EPERM || errno == EACCES { return .notGranted }
        }
        return .unknown
    }
}
