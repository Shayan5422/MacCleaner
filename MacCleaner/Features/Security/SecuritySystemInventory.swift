import Foundation

/// Parsers for read-only system tools used by the security scan.
enum SecuritySystemInventoryParser {
    /// `crontab -l` for the current user. Comments and variable assignments are skipped.
    static func cronJobs(_ output: String) -> [SecurityCronJob] {
        var jobs: [SecurityCronJob] = []
        var lineNumber = 0
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) != nil { continue }
            let fields = line.split(maxSplits: line.hasPrefix("@") ? 1 : 5, whereSeparator: { $0 == " " || $0 == "\t" })
            if line.hasPrefix("@") {
                guard fields.count == 2 else { continue }
                jobs.append(SecurityCronJob(schedule: String(fields[0]), command: String(fields[1]).trimmingCharacters(in: .whitespaces), lineNumber: lineNumber))
            } else {
                guard fields.count == 6 else { continue }
                jobs.append(SecurityCronJob(schedule: fields[0..<5].joined(separator: " "),
                                            command: String(fields[5]).trimmingCharacters(in: .whitespaces), lineNumber: lineNumber))
            }
        }
        return jobs
    }

    /// `systemextensionsctl list`.
    static func systemExtensions(_ output: String) -> [SecuritySystemExtension] {
        var results: [SecuritySystemExtension] = []
        var category = ""
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("--- ") {
                category = line.dropFirst(4).split(separator: " ").first.map(String.init) ?? ""
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 6, fields[0] != "enabled" else { continue }
            let identity = fields[3].trimmingCharacters(in: .whitespaces)
            var bundleIdentifier = identity
            var version = ""
            if let open = identity.range(of: " ("), identity.hasSuffix(")") {
                bundleIdentifier = String(identity[..<open.lowerBound])
                version = String(identity[open.upperBound...].dropLast())
            }
            guard !bundleIdentifier.isEmpty else { continue }
            let state = fields[5].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            results.append(SecuritySystemExtension(
                category: category,
                isEnabled: fields[0].trimmingCharacters(in: .whitespaces) == "*",
                isActive: fields[1].trimmingCharacters(in: .whitespaces) == "*",
                teamIdentifier: fields[2].trimmingCharacters(in: .whitespaces),
                bundleIdentifier: bundleIdentifier,
                version: version,
                name: fields[4].trimmingCharacters(in: .whitespaces),
                state: state
            ))
        }
        return results
    }

    /// `profiles status -type configuration`: number of profiles installed on the Mac.
    static func systemProfileCount(_ output: String) -> Int? {
        let text = output.lowercased()
        if text.contains("there are no configuration profiles") { return 0 }
        if let range = text.range(of: #"(\d+)\s+(?:system\s+)?configuration profiles?"#, options: .regularExpression) {
            return Int(text[range].prefix { $0.isNumber })
        }
        return nil
    }

    /// `profiles list` (current user): identifiers of installed profiles.
    static func userProfileIdentifiers(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "profileIdentifier:") else { return nil }
            let identifier = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return identifier.isEmpty ? nil : identifier
        }
    }

    /// `profiles status -type enrollment`: ("Enrolled via DEP: No", "MDM enrollment: Yes (User Approved)").
    static func enrollment(_ output: String) -> (mdm: Bool?, dep: Bool?) {
        var mdm: Bool?
        var dep: Bool?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            let value: Bool? = parts[1].hasPrefix("yes") ? true : parts[1].hasPrefix("no") ? false : nil
            if parts[0].contains("mdm enrollment") { mdm = value }
            if parts[0].contains("dep") { dep = value }
        }
        return (mdm, dep)
    }
}

/// Reads system persistence and configuration that a regular user may inspect.
enum SecuritySystemInventory {
    static let shellStartupFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bash_profile", ".bashrc", ".bash_login", ".profile"]
    static let authorizationPluginsFolder = "/Library/Security/SecurityAgentPlugins"

    /// The current user's cron jobs; nil when crontab couldn't be read.
    static func cronJobs() async -> [SecurityCronJob]? {
        guard let result = try? await ProcessRunner.run("/usr/bin/crontab", arguments: ["-l"], timeout: 10), !result.timedOut else { return nil }
        if result.succeeded { return SecuritySystemInventoryParser.cronJobs(result.standardOutput) }
        // "crontab: no crontab for <user>" exits 1 and simply means there are none.
        if result.standardError.lowercased().contains("no crontab") { return [] }
        return nil
    }

    static func systemExtensions() async -> [SecuritySystemExtension]? {
        guard let result = try? await ProcessRunner.run("/usr/bin/systemextensionsctl", arguments: ["list"], timeout: 20),
              result.succeeded else { return nil }
        return SecuritySystemInventoryParser.systemExtensions(result.standardOutput)
    }

    /// Configuration profiles visible without administrator rights.
    static func profiles() async -> SecurityProfilesStatus? {
        let tool = "/usr/bin/profiles"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        async let systemStatus = try? ProcessRunner.run(tool, arguments: ["status", "-type", "configuration"], timeout: 15)
        async let userList = try? ProcessRunner.run(tool, arguments: ["list"], timeout: 15)
        async let enrollment = try? ProcessRunner.run(tool, arguments: ["status", "-type", "enrollment"], timeout: 15)
        var status = SecurityProfilesStatus()
        var anyResult = false
        if let result = await systemStatus, result.succeeded {
            status.systemProfileCount = SecuritySystemInventoryParser.systemProfileCount(result.combinedOutput)
            anyResult = anyResult || status.systemProfileCount != nil
        }
        if let result = await userList, result.succeeded {
            status.userProfileIdentifiers = SecuritySystemInventoryParser.userProfileIdentifiers(result.combinedOutput)
            anyResult = true
        }
        if let result = await enrollment, result.succeeded {
            let parsed = SecuritySystemInventoryParser.enrollment(result.combinedOutput)
            status.isMDMEnrolled = parsed.mdm
            status.isDEPEnrolled = parsed.dep
            anyResult = anyResult || parsed.mdm != nil
        }
        return anyResult ? status : nil
    }

    /// Third-party authorization plug-ins (Apple's live in /System and aren't listed here).
    static func authorizationPlugins() -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: authorizationPluginsFolder) else {
            return FileManager.default.fileExists(atPath: authorizationPluginsFolder) ? nil : []
        }
        return names.sorted().filter { $0.hasSuffix(".bundle") }.map { authorizationPluginsFolder + "/" + $0 }
    }

    /// Existing shell startup files in the home folder.
    static func existingShellStartupFiles(home: String = LaunchdLocations.home) -> [String] {
        shellStartupFiles.map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Reads a text file of at most `limit` bytes; nil for unreadable, binary or huge files.
    static func readText(_ path: String, limit: Int = 1_000_000) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= limit,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.prefix(4096).contains(0) { return nil } // binary
        return String(decoding: data, as: UTF8.self)
    }
}
