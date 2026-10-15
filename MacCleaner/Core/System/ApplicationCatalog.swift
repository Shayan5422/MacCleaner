import AppKit
import CoreServices
import Foundation

/// Facts about an application bundle, read from its Info.plist and file system.
struct AppBundleInfo: Identifiable, Sendable, Hashable {
    var path: String
    var name: String
    var bundleIdentifier: String?
    var shortVersion: String?
    var buildVersion: String?
    var executableName: String?
    var minimumSystemVersion: String?
    /// Sparkle update feed declared by the app, if any.
    var sparkleFeedURL: URL?
    /// Installed from the Mac App Store (has an App Store receipt).
    var isAppStoreApp: Bool
    /// Part of macOS (lives on the sealed system volume or is a protected Apple app).
    var isSystemApp: Bool
    var isAppleApp: Bool
    var installedDate: Date?
    var modificationDate: Date?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    var displayVersion: String {
        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (nil, build?): return build
        default: return "—"
        }
    }

    var executablePath: String? {
        executableName.map { path + "/Contents/MacOS/" + $0 }
    }
}

/// Finds installed applications and reads their metadata.
enum ApplicationCatalog {
    /// Folders searched for applications, most specific first.
    static func searchFolders() -> [(path: String, isSystem: Bool)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ("/Applications", false),
            (home + "/Applications", false),
            ("/System/Applications", true),
            ("/System/Applications/Utilities", true),
            ("/System/Library/CoreServices/Applications", true),
            ("/Library/Application Support", false), // some vendors ship helper apps here; only top-level .app bundles are read
        ]
    }

    /// Lists application bundles in the standard folders (and one level of subfolders).
    static func installedApplications(includeSystemApps: Bool = true) -> [AppBundleInfo] {
        var seen = Set<String>()
        var results: [AppBundleInfo] = []
        let manager = FileManager.default
        for folder in searchFolders() {
            if folder.isSystem && !includeSystemApps { continue }
            if folder.path == "/Library/Application Support" { continue }
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                let path = folder.path + "/" + name
                if name.hasSuffix(".app") {
                    if seen.insert(path).inserted, let info = read(path: path, isSystem: folder.isSystem) {
                        results.append(info)
                    }
                } else if !name.hasPrefix("."), folder.path != "/System/Applications" || name == "Utilities" {
                    // Vendor folders such as "/Applications/Adobe Photoshop 2025/".
                    var isDirectory: ObjCBool = false
                    guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                          !PackageDetector.isPackage(name: name),
                          let nested = try? manager.contentsOfDirectory(atPath: path) else { continue }
                    for child in nested where child.hasSuffix(".app") {
                        let childPath = path + "/" + child
                        if seen.insert(childPath).inserted, let info = read(path: childPath, isSystem: folder.isSystem) {
                            results.append(info)
                        }
                    }
                }
            }
        }
        return results
    }

    /// Reads one application bundle. Returns nil if it isn't a readable app bundle.
    static func read(path: String, isSystem: Bool? = nil) -> AppBundleInfo? {
        let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let bundleID = plist["CFBundleIdentifier"] as? String
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let displayName = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let systemApp = isSystem ?? (path.hasPrefix("/System/"))
        let receipt = path + "/Contents/_MASReceipt/receipt"

        return AppBundleInfo(
            path: path,
            name: fileName.isEmpty ? displayName : fileName,
            bundleIdentifier: bundleID,
            shortVersion: (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces),
            buildVersion: (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces),
            executableName: plist["CFBundleExecutable"] as? String,
            minimumSystemVersion: plist["LSMinimumSystemVersion"] as? String,
            sparkleFeedURL: (plist["SUFeedURL"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) },
            isAppStoreApp: FileManager.default.fileExists(atPath: receipt),
            isSystemApp: systemApp,
            isAppleApp: bundleID?.hasPrefix("com.apple.") == true,
            installedDate: attributes?[.creationDate] as? Date,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    /// Last time the app was opened, from Spotlight metadata (nil if Spotlight has no record).
    static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Number of times the app has been opened, from Spotlight metadata.
    static func useCount(path: String) -> Int? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
    }

    /// The app icon (main thread only).
    @MainActor
    static func icon(for path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}
