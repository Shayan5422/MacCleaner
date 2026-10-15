import Foundation
@testable import MacCleaner

/// A temporary folder for Developer tests, removed when the test ends.
final class DeveloperTestDirectory {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DeveloperTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = PathUtilities.resolvedPath(base.path) ?? base.path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> String {
        let full = path + "/" + relative
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func makeFile(_ relative: String, bytes: Int = 128) throws -> String {
        let full = path + "/" + relative
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x62, count: bytes).write(to: URL(fileURLWithPath: full))
        return full
    }

    func writePlist(_ object: [String: Any], to relative: String) throws {
        let full = path + "/" + relative
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: full))
    }
}
