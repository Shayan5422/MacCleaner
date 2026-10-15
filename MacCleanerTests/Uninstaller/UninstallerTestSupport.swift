import Foundation
@testable import MacCleaner

/// A throwaway folder under the temporary directory, removed when the test finishes.
final class UninstallerTestSandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UninstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Normalized absolute path of `relative` inside the sandbox (matches what scanners report).
    func path(_ relative: String) -> String {
        PathUtilities.normalize(root.appendingPathComponent(relative).path)
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return path(relative)
    }

    @discardableResult
    func makeFile(_ relative: String, contents: String = "data") throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return path(relative)
    }

    @discardableResult
    func makePlist(_ relative: String, _ dictionary: [String: Any]) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
        return path(relative)
    }

    /// Sets the modification date of everything below `relative` (children first).
    func age(_ relative: String, days: Double) throws {
        let date = Date(timeIntervalSinceNow: -days * 86_400)
        let top = root.appendingPathComponent(relative)
        var paths: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: top.path) {
            while let child = enumerator.nextObject() as? String { paths.append(top.appendingPathComponent(child).path) }
        }
        for path in paths.sorted(by: { $0.count > $1.count }) + [top.path] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    /// Ages every item in the sandbox.
    func ageEverything(days: Double) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for name in names { try age(name, days: days) }
    }
}

enum UninstallerTestFixtures {
    static func identity(
        path: String,
        bundleID: String?,
        names: [String],
        executable: String? = nil,
        team: String? = nil,
        groups: [String] = [],
        entitlementsKnown: Bool = true,
        helpers: [String] = [],
        jobLabels: [String] = [],
        vendorWords: [String]? = nil
    ) -> UninstallerAppIdentity {
        UninstallerAppIdentity(
            path: path,
            bundleIdentifier: bundleID,
            names: names,
            executableName: executable,
            teamIdentifier: team,
            applicationGroups: groups,
            entitlementsKnown: entitlementsKnown,
            helperIdentifiers: helpers,
            embeddedJobLabels: jobLabels,
            vendorWords: vendorWords
        )
    }
}
