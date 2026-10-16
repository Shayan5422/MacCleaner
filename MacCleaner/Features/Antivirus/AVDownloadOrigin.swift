import Darwin
import Foundation

/// Reads where a downloaded file came from, without following symbolic links:
/// `com.apple.metadata:kMDItemWhereFroms` (a property list array of URLs written by browsers:
/// the file's address, then usually the page it was downloaded from) and `com.apple.quarantine`
/// (the app and the date). Read-only; nothing is changed.
enum AVDownloadOriginReader {
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    static func read(path: String, intel: (any ThreatIntelLookup)?) -> AVDownloadOrigin? {
        let urls = whereFroms(path: path)
        let quarantine = SecurityQuarantineInfo.read(path: path)
        guard !urls.isEmpty || quarantine != nil else { return nil }
        var origin = AVDownloadOrigin(urls: urls, agent: quarantine?.agent, downloadedAt: quarantine?.date)
        if let intel { check(&origin, intel: intel) }
        return origin
    }

    /// Looks the addresses up in URLhaus/ThreatFox: the exact URL first, then listed malware hosts.
    static func check(_ origin: inout AVDownloadOrigin, intel: any ThreatIntelLookup) {
        for url in origin.urls {
            if let match = intel.match(url: url) {
                origin.listedURL = url
                origin.intelMatch = match
                return
            }
        }
        for url in origin.urls {
            guard let host = URLComponents(string: url, encodingInvalidCharacters: true)?.host, let match = intel.match(host: host) else { continue }
            origin.listedURL = url
            origin.intelMatch = match
            return
        }
    }

    static func whereFroms(path: String) -> [String] {
        guard let data = attribute(whereFromsAttribute, path: path, limit: 256 * 1024) else { return [] }
        return parseWhereFroms(data)
    }

    /// The attribute is a binary (sometimes XML) property list: an array of strings.
    static func parseWhereFroms(_ data: Data) -> [String] {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [] }
        let values: [Any]
        if let array = object as? [Any] { values = array } else if let single = object as? String { values = [single] } else { return [] }
        // Mail stores the sender and subject here; only web addresses are kept.
        return values.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count < 8_192 && $0.contains("://") }
    }

    static func attribute(_ name: String, path: String, limit: Int) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= limit else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let count = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }
}
