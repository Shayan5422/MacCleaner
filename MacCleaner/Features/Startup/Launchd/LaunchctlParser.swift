import Foundation

/// Status of one launchd service, read from `launchctl print <domain>/<label>`.
struct LaunchctlServiceInfo: Sendable, Hashable {
    var label: String
    /// "running", "not running", "waiting", "spawn scheduled"...
    var state: String?
    var pid: Int32?
    /// Raw "last exit code" text, such as "0", "(never exited)" or "78: EX_CONFIG".
    var lastExitDescription: String?
    var lastExitCode: Int?
    var lastTerminatingSignal: String?
    var runs: Int?
    var path: String?
    var program: String?
    var type: String?
    /// Every top-level `key = value` pair, in output order, for the detail view.
    var properties: [LaunchdPlistEntry] = []

    var isRunning: Bool { pid != nil || state == "running" }

    /// "Exited normally", "Exited with code 78", "Never exited".
    var lastExitSummary: String? {
        guard let lastExitDescription else { return nil }
        if lastExitDescription.contains("never exited") { return "Hasn't exited since it started" }
        guard let code = lastExitCode else { return lastExitDescription }
        if code == 0 { return "Last exit: normal (0)" }
        return "Last exit: error \(lastExitDescription)"
    }
}

/// One row of the `services` table in `launchctl print <domain>`.
struct LaunchctlListedService: Sendable, Hashable {
    var label: String
    /// nil when the service isn't running.
    var pid: Int32?
    /// Last exit status, when the service has exited before.
    var lastExitStatus: Int?
}

/// Parses `launchctl` output. The format isn't a stable API, so every field is optional
/// and unknown lines are ignored.
enum LaunchctlParser {
    /// Parses `launchctl print gui/<uid>/<label>` (or `system/<label>`).
    static func parseService(_ output: String, label: String) -> LaunchctlServiceInfo {
        var info = LaunchctlServiceInfo(label: label)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // Top-level properties are indented by exactly one tab: "\tkey = value".
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            guard let separator = body.range(of: " = ") else { continue }
            let key = body[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = body[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, value != "{", !value.hasSuffix("{") else { continue }
            info.properties.append(LaunchdPlistEntry(key: key, value: .string(value)))

            switch key {
            case "state": info.state = value
            case "pid": info.pid = Int32(value).flatMap { $0 > 0 ? $0 : nil }
            case "last exit code":
                info.lastExitDescription = value
                info.lastExitCode = leadingInteger(value)
            case "last terminating signal": info.lastTerminatingSignal = value
            case "runs": info.runs = Int(value)
            case "path": info.path = value
            case "program": info.program = value
            case "type": info.type = value
            default: break
            }
        }
        return info
    }

    /// Parses `launchctl print-disabled <domain>` into label → disabled.
    /// Handles both the current (`=> enabled/disabled`) and older (`=> true/false`) formats.
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let arrow = trimmed.range(of: "=>") else { continue }
            let quoted = trimmed[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            guard quoted.count >= 2, quoted.hasSuffix("\"") else { continue }
            let label = String(quoted.dropFirst().dropLast())
            let value = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// Parses the `services = { ... }` table of `launchctl print <domain>`.
    static func parseServiceList(_ output: String) -> [String: LaunchctlListedService] {
        var result: [String: LaunchctlListedService] = [:]
        var inServices = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if !inServices {
                if line.hasPrefix("\t"), !line.hasPrefix("\t\t"), line.trimmingCharacters(in: .whitespaces) == "services = {" {
                    inServices = true
                }
                continue
            }
            if line.hasPrefix("\t"), !line.hasPrefix("\t\t"), line.trimmingCharacters(in: .whitespaces) == "}" { break }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let pid = Int32(fields[0]) else { continue }
            let status = fields[1] == "-" ? nil : Int(fields[1])
            let label = fields[2...].joined(separator: " ")
            result[label] = LaunchctlListedService(label: label, pid: pid > 0 ? pid : nil, lastExitStatus: status)
        }
        return result
    }

    private static func leadingInteger(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber || $0 == "-" }
        return digits.isEmpty || digits == "-" ? nil : Int(digits)
    }
}
