import Foundation

/// One row of `docker ps --format '{{json .}}'`.
struct PortDockerPSEntry: Hashable, Sendable {
    /// Short container id as printed by `docker ps`.
    let id: String
    let name: String
    let image: String
    /// Published TCP host ports, in the order Docker lists them.
    let hostPorts: [UInt16]
}

/// Maps published host ports to Docker containers and stops / un-restarts containers through the `docker` CLI.
///
/// Fully inert when the `docker` CLI is not installed: no subprocess is ever started in that case.
final class PortDockerService: @unchecked Sendable {
    private let cacheMaxAge: TimeInterval = 5
    private let lock = NSLock()
    private var cache: (date: Date, containers: [UInt16: PortDockerContainer])?

    init() {}

    /// Process names that own published ports on macOS container runtimes (p_comm is cut at 16 chars, so prefixes
    /// of the long names also match).
    static let backendNames: [String] = [
        "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "Docker Desktop",
        "OrbStack Helper", "gvproxy",
    ]

    /// com.docker.backend, com.docker.vpnkit, vpnkit-bridge, "Docker Desktop", OrbStack Helper, colima/lima ssh mux, podman gvproxy.
    static func isDockerBackend(_ basic: PortProcessBasic, details: PortProcessDetails?) -> Bool {
        let names = [basic.comm, details?.executableName ?? ""]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for name in names where backendNames.contains(where: { nameMatches(name, $0) }) {
            return true
        }
        let arguments = details?.arguments ?? []
        // Lima / Colima forward ports through an ssh ControlMaster whose title is "ssh: <…/ssh.sock> [mux]",
        // or (lima ≥ 1.0) through `limactl hostagent`.
        if let title = arguments.first, title.hasPrefix("ssh: "), title.contains("[mux]"),
           title.contains("/.lima/") || title.contains("/.colima/") || title.contains("/_lima/") {
            return true
        }
        if names.contains("limactl"), arguments.contains("hostagent") { return true }
        return false
    }

    /// Exact match, or `name` is a 15–16 char truncated p_comm of `fullName`.
    private static func nameMatches(_ name: String, _ fullName: String) -> Bool {
        name == fullName || (name.count >= 15 && fullName.hasPrefix(name))
    }

    /// The `docker` CLI (Docker Desktop, OrbStack, Colima, Homebrew), nil when it isn't installed.
    var executable: String? { ToolLocator.shared.locate("docker") }

    /// `docker ps --format '{{json .}}'` → host port → container (parse Ports like "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp").
    /// Restart policy via `docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' <ids>`. Cached 5 s. [:] if docker missing.
    func containersByHostPort() async -> [UInt16: PortDockerContainer] {
        guard let executable else { return [:] }

        let cached = lock.withLock { () -> [UInt16: PortDockerContainer]? in
            guard let cache, Date().timeIntervalSince(cache.date) < cacheMaxAge else { return nil }
            return cache.containers
        }
        if let cached { return cached }

        var containers: [UInt16: PortDockerContainer] = [:]
        // A stopped Docker Desktop / Colima makes `docker ps` fail fast ("Cannot connect to the Docker daemon").
        if let ps = try? await ProcessRunner.run(executable, arguments: ["ps", "--format", "{{json .}}"], timeout: 5),
           ps.succeeded {
            let entries = Self.parsePSOutput(ps.standardOutput)
            var policies: [String: String] = [:]
            if !entries.isEmpty,
               let inspect = try? await ProcessRunner.run(
                   executable,
                   arguments: ["inspect", "--format", "{{.Id}} {{.HostConfig.RestartPolicy.Name}}"] + entries.map(\.id),
                   timeout: 5) {
                // Output is still useful if one container vanished in between (non-zero status).
                policies = Self.parseInspectRestartPolicies(inspect.standardOutput)
            }
            containers = Self.portMap(entries: entries, restartPolicies: policies)
        }

        lock.withLock { cache = (Date(), containers) }
        return containers
    }

    /// docker stop
    func stop(id: String) async throws {
        try await run(["stop", id], containerID: id, action: "stop", timeout: 30)
    }

    /// docker update --restart=no <id>
    func disableRestart(id: String) async throws {
        try await run(["update", "--restart=no", id], containerID: id, action: "turn off auto-restart for", timeout: 15)
    }

    func invalidateCache() {
        lock.withLock { cache = nil }
    }

    private func run(_ arguments: [String], containerID: String, action: String, timeout: TimeInterval) async throws {
        guard Self.isValidContainerReference(containerID) else {
            throw PortControlError("Invalid container id: \(containerID)")
        }
        guard let executable else { throw PortControlError("The docker command was not found.") }
        defer { invalidateCache() }
        let result: CommandResult
        do {
            result = try await ProcessRunner.run(executable, arguments: arguments, timeout: timeout)
        } catch {
            throw PortControlError("Docker couldn't \(action) container \(containerID): \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let detail = result.combinedOutput.split(separator: "\n").suffix(2).joined(separator: " ")
            throw PortControlError("Docker couldn't \(action) container \(containerID): "
                                   + (detail.isEmpty ? "exit code \(result.exitCode)" : detail))
        }
    }

    /// Container ids/names: `[a-zA-Z0-9][a-zA-Z0-9_.-]*` (also guarantees it can't be parsed as a CLI flag).
    static func isValidContainerReference(_ reference: String) -> Bool {
        guard let first = reference.unicodeScalars.first, isASCIIAlphanumeric(first) else { return false }
        return reference.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    // MARK: - Parsing (pure, tested)

    /// Parses one JSON object per line. Lines that are not valid JSON objects or have no ID are skipped.
    static func parsePSOutput(_ output: String) -> [PortDockerPSEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> PortDockerPSEntry? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
                  let row = object as? [String: Any],
                  let id = row["ID"] as? String, !id.isEmpty else { return nil }
            // "Names" can list several comma-separated names (legacy links); the first is the container's own.
            let names = (row["Names"] as? String) ?? ""
            let name = names.split(separator: ",").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? id
            return PortDockerPSEntry(id: id, name: name.isEmpty ? id : name, image: (row["Image"] as? String) ?? "",
                                 hostPorts: parseHostPorts((row["Ports"] as? String) ?? ""))
        }
    }

    /// Largest port range expanded from a single mapping ("8000-9000->…"); larger ranges are ignored.
    static let maxRangeLength = 1024

    /// Published TCP host ports from a `docker ps` Ports column, e.g.
    /// "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp", "[::]:8080->80/tcp", "127.0.0.1:8000-8002->8000-8002/tcp".
    /// Exposed-only ports ("6379/tcp") and UDP mappings are skipped. Order kept, duplicates removed.
    static func parseHostPorts(_ ports: String) -> [UInt16] {
        var result: [UInt16] = []
        var seen = Set<UInt16>()
        func add(_ port: UInt16) {
            if port > 0, seen.insert(port).inserted { result.append(port) }
        }
        for rawMapping in ports.split(separator: ",") {
            let mapping = rawMapping.trimmingCharacters(in: .whitespaces)
            guard let arrow = mapping.range(of: "->") else { continue }
            let host = mapping[..<arrow.lowerBound]
            let container = mapping[arrow.upperBound...]
            if let slash = container.lastIndex(of: "/"),
               container[container.index(after: slash)...].lowercased() != "tcp" { continue }

            let portText = host.lastIndex(of: ":").map { host[host.index(after: $0)...] } ?? host
            let bounds = portText.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 1, let port = UInt16(bounds[0]) {
                add(port)
            } else if bounds.count == 2, let low = UInt16(bounds[0]), let high = UInt16(bounds[1]),
                      low <= high, Int(high) - Int(low) < maxRangeLength {
                for port in low...high { add(port) }
            }
        }
        return result
    }

    /// Parses lines of `docker inspect --format '{{.Id}} {{.HostConfig.RestartPolicy.Name}}'` into full id →
    /// policy. An empty policy name is Docker's default, "no".
    static func parseInspectRestartPolicies(_ output: String) -> [String: String] {
        var policies: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let id = parts.first.map(String.init), !id.isEmpty,
                  id.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else { continue }
            let policy = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            policies[id] = policy.isEmpty ? "no" : policy
        }
        return policies
    }

    /// Joins `docker ps` rows with restart policies (matched by id prefix: ps prints short ids, inspect full ones).
    /// When two containers claim the same host port (IPv4/IPv6 bindings of different containers) the first wins.
    static func portMap(entries: [PortDockerPSEntry], restartPolicies: [String: String]) -> [UInt16: PortDockerContainer] {
        var map: [UInt16: PortDockerContainer] = [:]
        for entry in entries {
            let policy = restartPolicies[entry.id]
                ?? restartPolicies.first(where: { $0.key.hasPrefix(entry.id) || entry.id.hasPrefix($0.key) })?.value
            let container = PortDockerContainer(id: entry.id, name: entry.name, image: entry.image, restartPolicy: policy)
            for port in entry.hostPorts where map[port] == nil {
                map[port] = container
            }
        }
        return map
    }
}
