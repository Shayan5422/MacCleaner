import Foundation

/// Code-signature summaries of the executables behind connections, read with Mac Cleaner's
/// `CodeSignatureInspector` (offline: it never contacts Apple) and cached per path and modification date.
actor NetSignatureCache {
    static let shared = NetSignatureCache()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
    }

    private var cache: [Key: CodeSignatureInfo] = [:]
    private var inFlight: [Key: Task<CodeSignatureInfo, Never>] = [:]
    /// Signature checks hash code pages: two at a time keeps them from competing with the rest of the app.
    private let limiter = AsyncLimiter(limit: 2)

    func signature(for path: String) async -> CodeSignatureInfo {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let key = Key(path: path, modified: modified)
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }
        let limiter = self.limiter
        let task = Task.detached(priority: .utility) {
            await limiter.run {
                await BackgroundWork.run(qos: .utility) { CodeSignatureInspector.inspect(path: Self.inspectablePath(path)) }
            }
        }
        inFlight[key] = task
        let info = await task.value
        inFlight[key] = nil
        if cache.count > 2048 { cache.removeAll() }
        cache[key] = info
        return info
    }

    /// Signatures of every path, in parallel (bounded), as they are known.
    func signatures(for paths: [String]) async -> [String: CodeSignatureInfo] {
        await withTaskGroup(of: (String, CodeSignatureInfo).self) { group in
            for path in Set(paths) {
                group.addTask { (path, await self.signature(for: path)) }
            }
            var result: [String: CodeSignatureInfo] = [:]
            for await (path, info) in group { result[path] = info }
            return result
        }
    }

    /// The app bundle for an app's main executable (its signature covers the bundle), else the file itself.
    nonisolated static func inspectablePath(_ executable: String) -> String {
        if let range = executable.range(of: ".app/Contents/MacOS/") {
            let bundle = String(executable[..<range.lowerBound]) + ".app"
            // Only the main executable: a helper deeper inside is checked on its own.
            if !executable[range.upperBound...].contains("/") { return bundle }
        }
        return executable
    }
}

extension CodeSignatureInfo {
    /// Short label for connection rows: "Apple", "Developer ID · Example Inc", "Not signed"…
    var connectionSummary: String {
        switch status {
        case .valid:
            if isAppleSigned { return "Apple" }
            if isAppStoreSigned { return "Mac App Store" }
            if isDeveloperIDSigned {
                let name = developerName.map { " · \($0)" } ?? ""
                return (isNotarized == true ? "Notarized" : "Developer ID") + name
            }
            if isAdHocSigned { return "Ad-hoc signed" }
            return developerName.map { "Signed · \($0)" } ?? "Signed"
        case .unsigned: return "Not signed"
        case .invalid: return "Invalid signature"
        case .revoked: return "Certificate revoked"
        case .unknown: return "Signature unknown"
        }
    }

    /// Worth a second look: unsigned, broken or revoked code.
    var isConcerning: Bool {
        status == .unsigned || status == .invalid || status == .revoked
    }
}
