import Foundation

/// Capacity and characteristics of a mounted volume.
struct VolumeInfo: Identifiable, Sendable, Hashable {
    var path: String
    var name: String
    var totalCapacity: Int64
    /// Free space right now.
    var availableCapacity: Int64
    /// Free space including purgeable data macOS can remove on demand (caches, iCloud downloads, snapshots).
    var availableForImportantUsage: Int64?
    var isInternal: Bool
    var isRemovable: Bool
    var isEjectable: Bool
    var isLocal: Bool
    var isReadOnly: Bool
    var isRootFileSystem: Bool
    var formatDescription: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    var usedCapacity: Int64 { max(0, totalCapacity - (availableForImportantUsage ?? availableCapacity)) }
    var purgeableCapacity: Int64 { max(0, (availableForImportantUsage ?? availableCapacity) - availableCapacity) }
    var usedFraction: Double { totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0 }
    var effectiveAvailable: Int64 { availableForImportantUsage ?? availableCapacity }

    /// The folder to scan for this volume. On the startup disk this is the data
    /// volume, because the system volume is sealed and firmlinked into it.
    var scanRootPath: String {
        isRootFileSystem ? "/System/Volumes/Data" : path
    }

    var symbolName: String {
        if isRootFileSystem { return "internaldrive.fill" }
        if !isLocal { return "server.rack" }
        if isRemovable || isEjectable { return "externaldrive.fill" }
        return "internaldrive"
    }
}

enum VolumeService {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey,
    ]

    /// Volumes people can browse (startup disk, external drives, disk images, network shares).
    static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(for:)).sorted { lhs, rhs in
            if lhs.isRootFileSystem != rhs.isRootFileSystem { return lhs.isRootFileSystem }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func startupVolume() -> VolumeInfo? {
        info(for: URL(fileURLWithPath: "/"))
    }

    static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        if values.volumeIsBrowsable == false { return nil }
        return VolumeInfo(
            path: url.path,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            totalCapacity: Int64(total),
            availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
            isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isLocal: values.volumeIsLocal ?? true,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? (url.path == "/"),
            formatDescription: values.volumeLocalizedFormatDescription
        )
    }

    /// The volume containing `path`.
    static func volume(containing path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return info(for: volumeURL)
    }
}
