import Foundation

/// One line of `docker system df --format '{{json .}}'`.
struct DeveloperDockerUsage: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case images, containers, volumes, buildCache, other
    }

    var type: String
    var totalCount: Int
    var activeCount: Int
    var sizeBytes: Int64
    var reclaimableBytes: Int64
    var reclaimablePercent: Int?

    var kind: Kind {
        switch type.lowercased() {
        case "images": return .images
        case "containers": return .containers
        case "local volumes", "volumes": return .volumes
        case "build cache": return .buildCache
        default: return .other
        }
    }

    var inactiveCount: Int { max(0, totalCount - activeCount) }
}

/// An image from `docker image ls --format '{{json .}}'`.
struct DeveloperDockerImage: Sendable, Hashable {
    var id: String
    var repository: String
    var tag: String
    var sizeBytes: Int64?
}

/// Parses Docker CLI output. Sizes use Docker's decimal units ("1.2GB", "512kB").
enum DeveloperDockerParser {
    static func parseSystemDF(_ output: String) -> [DeveloperDockerUsage] {
        jsonLines(output).compactMap { object in
            guard let type = string(object["Type"]) else { return nil }
            let reclaimable = string(object["Reclaimable"]) ?? "0B"
            let parsed = parseReclaimable(reclaimable)
            return DeveloperDockerUsage(
                type: type,
                totalCount: int(object["TotalCount"]) ?? 0,
                activeCount: int(object["Active"]) ?? 0,
                sizeBytes: string(object["Size"]).flatMap(parseSize) ?? 0,
                reclaimableBytes: parsed.bytes ?? 0,
                reclaimablePercent: parsed.percent
            )
        }
    }

    static func parseImages(_ output: String) -> [DeveloperDockerImage] {
        jsonLines(output).compactMap { object in
            guard let id = string(object["ID"]) else { return nil }
            return DeveloperDockerImage(
                id: id,
                repository: string(object["Repository"]) ?? "<none>",
                tag: string(object["Tag"]) ?? "<none>",
                sizeBytes: string(object["Size"]).flatMap(parseSize)
            )
        }
    }

    /// "1.234GB (45%)" → bytes and percent.
    static func parseReclaimable(_ text: String) -> (bytes: Int64?, percent: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "(") else { return (parseSize(trimmed), nil) }
        let size = parseSize(String(trimmed[..<open]))
        let percentText = trimmed[trimmed.index(after: open)...].filter { $0.isNumber }
        return (size, Int(percentText))
    }

    /// Parses "1.234GB", "12.3kB", "0B", "2 GB", "1.5GiB". Returns nil for "N/A" or unknown units.
    static func parseSize(_ text: String) -> Int64? {
        DeveloperSizeParser.parse(text, decimal: true)
    }

    /// `true` when the CLI couldn't reach the Docker engine.
    static func isEngineUnavailable(_ result: CommandResult) -> Bool {
        let output = result.combinedOutput.lowercased()
        return output.contains("cannot connect to the docker daemon")
            || output.contains("is the docker daemon running")
            || output.contains("error during connect")
            || output.contains("docker desktop is not running")
    }

    private static func jsonLines(_ output: String) -> [[String: Any]] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

/// Parses human-readable sizes printed by command-line tools.
enum DeveloperSizeParser {
    /// - Parameter decimal: `true` when "KB/MB/GB" mean powers of 1000 (Docker),
    ///   `false` when they mean powers of 1024 (Homebrew). "KiB/MiB/GiB" are always binary.
    static func parse(_ text: String, decimal: Bool) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var number = ""
        var unit = ""
        for character in trimmed {
            if character.isNumber || character == "." {
                guard unit.isEmpty else { return nil }
                number.append(character)
            } else if character == "," {
                continue
            } else if character.isWhitespace {
                continue
            } else {
                unit.append(character)
            }
        }
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let base: Double = decimal ? 1000 : 1024
        let multiplier: Double
        switch unit.lowercased() {
        case "", "b", "byte", "bytes": multiplier = 1
        case "k", "kb": multiplier = base
        case "m", "mb": multiplier = base * base
        case "g", "gb": multiplier = base * base * base
        case "t", "tb": multiplier = base * base * base * base
        case "p", "pb": multiplier = base * base * base * base * base
        case "kib": multiplier = 1024
        case "mib": multiplier = 1024 * 1024
        case "gib": multiplier = 1024 * 1024 * 1024
        case "tib": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }
}
