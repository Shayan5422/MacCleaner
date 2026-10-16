import Darwin
import Foundation
@testable import MacCleaner

/// A temporary folder for one antivirus test, removed afterwards. Paths are resolved
/// (`/private/var/...`) so they match what the scanners see.
final class AVTestFolder: @unchecked Sendable {
    let url: URL
    var path: String { url.path }

    init(_ name: String = "AVTests") throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: PathUtilities.resolvedPath(base.path) ?? base.path, isDirectory: true)
    }

    deinit {
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                let item = url.path + "/" + relative
                chflags(item, 0)
                chmod(item, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func child(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func makeFile(_ relative: String, contents: Data = Data("hello".utf8), mode: mode_t? = nil) throws -> String {
        let file = child(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file)
        if let mode { chmod(file.path, mode) }
        return file.path
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> String {
        let directory = child(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    var paths: AVPaths { AVPaths(root: child("Antivirus")) }
}

/// Real files downloaded during development (ClamAV databases, abuse.ch exports). Tests that
/// need them are skipped when they aren't present (CI).
enum AVRealFiles {
    static let defaultRoot = "/private/tmp/claude-501/-Users-shayanhashemi-Downloads-Mac-cleaner/d5bdd58a-7de9-4905-b694-4f4dc0b3c27b/scratchpad/avdb"

    static var root: URL? {
        let path = ProcessInfo.processInfo.environment["MACCLEANER_AV_FIXTURES"] ?? defaultRoot
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    static func url(_ relative: String) -> URL? {
        guard let file = root?.appendingPathComponent(relative), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    static var hasClamAV: Bool { url("clamav/main.cvd") != nil && url("clamav/daily.cvd") != nil }
    static var hasFeeds: Bool { url("abusech/mb-recent.txt") != nil && url("abusech/threatfox-recent.json") != nil }
}

/// Serves HTTP responses from memory or files and records every request.
final class AVFakeTransport: AVHTTPTransport, @unchecked Sendable {
    struct Route {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data?
        var file: URL?
    }

    private let lock = NSLock()
    private var routes: [String: [Route]] = [:]
    private var recorded: [AVHTTPRequest] = []
    var error: Error?

    /// Adds a response for `url`. Several responses for one URL are served in order; the last repeats.
    func serve(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data? = nil, file: URL? = nil) {
        lock.withLock { routes[url, default: []].append(Route(status: status, headers: headers, body: body, file: file)) }
    }

    func reset(_ url: String) { lock.withLock { routes[url] = nil } }

    var requests: [AVHTTPRequest] { lock.withLock { recorded } }

    func count(_ substring: String) -> Int { requests.filter { $0.url.absoluteString.contains(substring) }.count }

    private func route(for request: AVHTTPRequest) throws -> Route {
        try lock.withLock {
            recorded.append(request)
            if let error { throw error }
            guard var queue = routes[request.url.absoluteString], let first = queue.first else { return Route(status: 404) }
            if queue.count > 1 {
                queue.removeFirst()
                routes[request.url.absoluteString] = queue
            }
            return first
        }
    }

    private func body(of route: Route) throws -> Data {
        if let body = route.body { return body }
        if let file = route.file { return try Data(contentsOf: file, options: [.alwaysMapped]) }
        return Data()
    }

    func download(_ request: AVHTTPRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> AVHTTPResponse {
        let route = try route(for: request)
        guard (200..<300).contains(route.status) else { return AVHTTPResponse(statusCode: route.status, headers: route.headers) }
        try? FileManager.default.removeItem(at: destination)
        if let file = route.file {
            let size = ((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= request.maxBytes else { throw AVTransportError.tooLarge(request.maxBytes) }
            try FileManager.default.copyItem(at: file, to: destination) // a clone on APFS
            progress(size, size)
            return AVHTTPResponse(statusCode: route.status, headers: route.headers, bytesReceived: size)
        }
        let data = route.body ?? Data()
        guard Int64(data.count) <= request.maxBytes else { throw AVTransportError.tooLarge(request.maxBytes) }
        try data.write(to: destination)
        progress(Int64(data.count), Int64(data.count))
        return AVHTTPResponse(statusCode: route.status, headers: route.headers, bytesReceived: Int64(data.count))
    }

    func fetch(_ request: AVHTTPRequest) async throws -> (AVHTTPResponse, Data) {
        let route = try route(for: request)
        guard (200..<300).contains(route.status) else { return (AVHTTPResponse(statusCode: route.status, headers: route.headers), Data()) }
        var data = try body(of: route)
        var status = route.status
        if request.headers["Range"] != nil || request.truncatesAtLimit {
            data = data.prefix(Int(request.maxBytes))
            status = request.headers["Range"] != nil ? 206 : status
        } else if Int64(data.count) > request.maxBytes {
            throw AVTransportError.tooLarge(request.maxBytes)
        }
        return (AVHTTPResponse(statusCode: status, headers: route.headers, bytesReceived: Int64(data.count)), Data(data))
    }
}

struct AVFakeVersionLookup: AVVersionLookup {
    var info: AVClamAVVersionInfo?

    func currentVersions() async -> AVClamAVVersionInfo? { info }

    static func versions(main: Int, daily: Int) -> AVFakeVersionLookup {
        AVFakeVersionLookup(info: AVClamAVVersionInfo(clamavVersion: "1.4.6", main: main, daily: daily, bytecode: nil, publishedAt: Date(), source: .dns))
    }
}

/// Stands in for the engine: "verifies" by reading the header, "compiles" by recording the inputs.
final class AVFakeToolkit: AVDatabaseToolkit, @unchecked Sendable {
    private let lock = NSLock()
    var compileError: Error?
    var loadError: Error?
    var verifyError: Error?
    private var inputs: [AVDatabaseInputs] = []

    var compileCount: Int { lock.withLock { inputs.count } }
    var lastInputs: AVDatabaseInputs? { lock.withLock { inputs.last } }

    func verify(_ url: URL) throws -> ClamAVDatabaseHeader {
        if let verifyError = lock.withLock({ self.verifyError }) { throw verifyError }
        guard let header = AVClamAVHeaderLine.read(at: url) else { throw AVEngineError.invalidDatabase("no header") }
        let name = url.lastPathComponent.components(separatedBy: ".").first ?? "?"
        return ClamAVDatabaseHeader(name: name, buildTime: header.buildTime ?? Date(), version: header.version,
                                    signatureCount: header.signatureCount ?? 0, functionalityLevel: header.functionalityLevel ?? 0, builder: header.builder ?? "")
    }

    func compile(_ inputs: AVDatabaseInputs, into directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> AVDatabaseSummary {
        if let compileError = lock.withLock({ self.compileError }) { throw compileError }
        lock.withLock { self.inputs.append(inputs) }
        var versions: [String: Int] = [:]
        for file in inputs.clamavFiles {
            if let header = AVClamAVHeaderLine.read(at: file) { versions[file.lastPathComponent.components(separatedBy: ".").first ?? "?"] = header.version }
        }
        let names = (inputs.clamavFiles.map(\.lastPathComponent) + inputs.sha256Lists.map(\.url.lastPathComponent)).joined(separator: "\n")
        try Data((names + "\nbuild \(UUID().uuidString)").utf8).write(to: directory.appendingPathComponent("compiled.txt"))
        progress(1, "done")
        return AVDatabaseSummary(builtAt: Date(), clamavVersions: versions, clamavBuildDates: [:], signatureCount: 1_000, unsupportedSignatureCount: 0,
                                 hashSignatureCount: 10, bodySignatureCount: 10, logicalSignatureCount: 10, hashListCount: inputs.sha256Lists.count)
    }

    func load(from directory: URL) throws -> AVLoadedEngine {
        if let loadError = lock.withLock({ self.loadError }) { throw loadError }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("compiled.txt").path) else { throw AVEngineError.notInstalled }
        let summary = AVDatabaseSummary(builtAt: Date(), clamavVersions: ["main": 1], clamavBuildDates: [:], signatureCount: 1_000, unsupportedSignatureCount: 0,
                                        hashSignatureCount: 10, bodySignatureCount: 10, logicalSignatureCount: 10, hashListCount: 0)
        return AVLoadedEngine(scanner: AVFakeScanner(), summary: summary)
    }
}

/// Reports files containing a marker as malware (or PUA), so scans can be tested without the engine.
struct AVFakeScanner: AVFileScanning {
    static let malwareMarker = Data("MACCLEANER-FAKE-MALWARE".utf8)
    static let puaMarker = Data("MACCLEANER-FAKE-PUA".utf8)

    var delay: TimeInterval = 0

    func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return AVFileScanResult(path: path, skipped: .notRegularFile) }
        if info.st_flags & FileFlags.dataless != 0 { return AVFileScanResult(path: path, skipped: .dataless) }
        if Int64(info.st_size) > options.maxFileSize { return AVFileScanResult(path: path, skipped: .tooLarge) }
        guard let data = FileManager.default.contents(atPath: path) else { return AVFileScanResult(path: path, skipped: .unreadable("unreadable")) }
        if data.range(of: Self.malwareMarker) != nil {
            return AVFileScanResult(path: path, detections: [AVDetection(signatureName: "Osx.Test.FakeMalware", kind: .malware, source: .clamav, memberPath: nil)],
                                    bytesScanned: Int64(data.count), sha256: AVFileHasher.sha256(data: data))
        }
        if data.range(of: Self.puaMarker) != nil, options.detectPUA {
            return AVFileScanResult(path: path, detections: [AVDetection(signatureName: "PUA.Osx.Test.Fake", kind: .pua, source: .clamav, memberPath: nil)],
                                    bytesScanned: Int64(data.count), sha256: AVFileHasher.sha256(data: data))
        }
        return AVBuiltInScanner().scanFile(atPath: path, options: options).isInfected
            ? AVBuiltInScanner().scanFile(atPath: path, options: options)
            : AVFileScanResult(path: path, bytesScanned: Int64(data.count))
    }
}

/// Lets tests push file events.
final class AVFakeEventSource: AVFileEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([AVFileEvent]) -> Void)?
    private(set) var watchedPaths: [String] = []

    func start(paths: [String], handler: @escaping @Sendable ([AVFileEvent]) -> Void) -> Bool {
        lock.withLock {
            watchedPaths = paths
            self.handler = handler
        }
        return true
    }

    func stop() { lock.withLock { handler = nil } }

    func push(_ events: [AVFileEvent]) {
        let handler = lock.withLock { self.handler }
        handler?(events)
    }
}

/// A clock tests move forward by hand.
final class AVTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
