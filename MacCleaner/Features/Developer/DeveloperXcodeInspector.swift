import Foundation

/// A folder inside Xcode's DerivedData.
struct DeveloperDerivedDataInfo: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case project
        case moduleCache
        case sharedCache(title: String)
    }

    enum ProjectStatus: Sendable, Hashable {
        case exists
        case missing
        /// The project is on a drive that isn't connected right now.
        case onDisconnectedVolume
        case unknown
    }

    var path: String
    var folderName: String
    var kind: Kind
    var projectName: String
    var workspacePath: String?
    var lastAccessed: Date?
    var projectStatus: ProjectStatus
}

/// An `.xcarchive` in Xcode's Archives folder.
struct DeveloperArchiveInfo: Sendable, Hashable {
    var path: String
    var name: String
    var version: String?
    var build: String?
    var bundleIdentifier: String?
    var creationDate: Date?

    var title: String {
        switch (version, build) {
        case let (version?, build?) where version != build: return "\(name) \(version) (\(build))"
        case let (version?, _): return "\(name) \(version)"
        case let (nil, build?): return "\(name) (\(build))"
        default: return name
        }
    }
}

/// A folder in `~/Library/Developer/Xcode/<platform> DeviceSupport`.
struct DeveloperDeviceSupportEntry: Sendable, Hashable {
    var path: String
    var name: String
    var platform: String
    var version: [Int]
    var versionString: String
    var build: String?
    var modificationDate: Date?
}

/// Reads metadata Xcode leaves next to its build products. Only small property
/// lists and folder names are read.
enum DeveloperXcodeInspector {
    static let deviceSupportPlatforms = ["iOS", "watchOS", "tvOS", "visionOS", "macOS"]

    private static let sharedCacheTitles: [String: String] = [
        "SDKStatCaches.noindex": "SDK stat cache",
        "CompilationCache.noindex": "Compilation cache",
        "SDKExplicitPrecompiledModules": "Precompiled SDK modules",
        "SymbolCache.noindex": "Symbol cache",
        "ExplicitPrecompiledModules": "Precompiled modules",
    ]

    // MARK: - DerivedData

    static func derivedDataFolders(in derivedData: String) -> [DeveloperDerivedDataInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: derivedData) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = derivedData + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { return nil }
            return derivedDataInfo(folder: path)
        }
    }

    /// Describes one DerivedData folder using its `info.plist` ("WorkspacePath").
    static func derivedDataInfo(folder: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> DeveloperDerivedDataInfo {
        let name = (folder as NSString).lastPathComponent
        if name == "ModuleCache.noindex" || name == "ModuleCache" {
            return DeveloperDerivedDataInfo(path: folder, folderName: name, kind: .moduleCache, projectName: "Module cache", projectStatus: .unknown)
        }
        if let title = sharedCacheTitles[name] {
            return DeveloperDerivedDataInfo(path: folder, folderName: name, kind: .sharedCache(title: title), projectName: title, projectStatus: .unknown)
        }

        var info = DeveloperDerivedDataInfo(
            path: folder, folderName: name, kind: .project,
            projectName: projectName(fromFolderName: name), projectStatus: .unknown
        )
        guard let data = FileManager.default.contents(atPath: folder + "/info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return info
        }
        info.lastAccessed = plist["LastAccessedDate"] as? Date
        if let workspace = plist["WorkspacePath"] as? String, workspace.hasPrefix("/") {
            info.workspacePath = workspace
            info.projectName = projectName(fromWorkspacePath: workspace)
            info.projectStatus = projectStatus(workspacePath: workspace, fileExists: fileExists)
        }
        return info
    }

    static func projectStatus(workspacePath: String, fileExists: (String) -> Bool) -> DeveloperDerivedDataInfo.ProjectStatus {
        if fileExists(workspacePath) { return .exists }
        let components = workspacePath.split(separator: "/")
        if components.first == "Volumes", components.count > 1, !fileExists("/Volumes/" + components[1]) {
            return .onDisconnectedVolume
        }
        return .missing
    }

    /// "MyApp" for ".../MyApp.xcodeproj", ".../MyApp.xcworkspace" or a package folder.
    static func projectName(fromWorkspacePath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        if ["xcodeproj", "xcworkspace", "playground", "swiftpm"].contains(ext) {
            return (last as NSString).deletingPathExtension
        }
        if last == "Package.swift" {
            return ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        return last
    }

    /// "MyApp" for "MyApp-abcdefghijklmnopqrstuvwxyzab" (Xcode appends a hash).
    static func projectName(fromFolderName name: String) -> String {
        guard let dash = name.range(of: "-", options: .backwards) else { return name }
        let suffix = name[dash.upperBound...]
        guard suffix.count >= 20, suffix.allSatisfy({ $0.isLowercase && $0.isLetter }) else { return name }
        return String(name[..<dash.lowerBound])
    }

    // MARK: - Archives

    static func archives(in folder: String) -> [DeveloperArchiveInfo] {
        let manager = FileManager.default
        guard let days = try? manager.contentsOfDirectory(atPath: folder) else { return [] }
        var archives: [DeveloperArchiveInfo] = []
        for day in days.sorted() where !day.hasPrefix(".") {
            let dayPath = folder + "/" + day
            guard let names = try? manager.contentsOfDirectory(atPath: dayPath) else { continue }
            for name in names.sorted() where name.hasSuffix(".xcarchive") {
                archives.append(archiveInfo(path: dayPath + "/" + name))
            }
        }
        return archives
    }

    static func archiveInfo(path: String) -> DeveloperArchiveInfo {
        let fallbackName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var info = DeveloperArchiveInfo(path: path, name: fallbackName)
        info.creationDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard let data = FileManager.default.contents(atPath: path + "/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return info
        }
        if let name = plist["Name"] as? String, !name.isEmpty { info.name = name }
        if let date = plist["CreationDate"] as? Date { info.creationDate = date }
        if let properties = plist["ApplicationProperties"] as? [String: Any] {
            info.version = properties["CFBundleShortVersionString"] as? String
            info.build = properties["CFBundleVersion"] as? String
            info.bundleIdentifier = properties["CFBundleIdentifier"] as? String
        }
        return info
    }

    // MARK: - Device support

    /// Entries for one platform, newest version first.
    static func deviceSupportEntries(in folder: String, platform: String) -> [DeveloperDeviceSupportEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let entries = names.compactMap { name -> DeveloperDeviceSupportEntry? in
            guard !name.hasPrefix("."), let parsed = parseDeviceSupportName(name) else { return nil }
            let path = folder + "/" + name
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return DeveloperDeviceSupportEntry(
                path: path, name: name, platform: platform, version: parsed.version,
                versionString: parsed.versionString, build: parsed.build, modificationDate: date
            )
        }
        return entries.sorted { lhs, rhs in
            let order = compareVersions(lhs.version, rhs.version)
            if order != .orderedSame { return order == .orderedDescending }
            return (lhs.build ?? "") > (rhs.build ?? "")
        }
    }

    /// Parses "17.0 (21A329)", "iPhone15,2 17.0 (21A329)" or "16.4.1 (20E252) arm64e".
    static func parseDeviceSupportName(_ name: String) -> (version: [Int], versionString: String, build: String?)? {
        let tokens = name.split(separator: " ").map(String.init)
        guard let versionToken = tokens.first(where: { token in
            token.contains(".") && token.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }) ?? tokens.first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let version = versionToken.split(separator: ".").compactMap { Int($0) }
        let build = tokens.first { $0.hasPrefix("(") && $0.hasSuffix(")") }.map { String($0.dropFirst().dropLast()) }
        return (version, versionToken, build)
    }

    static func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Version numbers in a Gradle distribution folder name ("gradle-8.10.2-bin").
    static func gradleDistributionVersion(_ name: String) -> [Int]? {
        guard name.hasPrefix("gradle-") else { return nil }
        let parts = name.dropFirst("gradle-".count).split(separator: "-")
        guard let first = parts.first else { return nil }
        let numbers = first.split(separator: ".").compactMap { Int($0) }
        return numbers.isEmpty ? nil : numbers
    }
}
