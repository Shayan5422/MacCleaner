import Foundation

/// Progress of a definitions update, for the interface.
struct AVUpdateProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case checking, downloading, patching, verifying, runningFreshclam, processingFeeds, compiling, loading
    }

    var phase: Phase
    var message: String
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64?
    /// 0…1 when known.
    var fraction: Double?
}

/// What updating the ClamAV databases did.
struct AVClamAVUpdateResult: Sendable, Equatable {
    /// A database file in `clamav/` changed.
    var changed = false
    /// Every database is at the published version.
    var upToDate = false
    var messages: [String] = []
    /// A problem to show (the previous databases stay in use).
    var problem: String?
}

/// Everything the ClamAV updaters need from the outside.
struct AVClamAVUpdateContext: Sendable {
    var paths: AVPaths
    var transport: any AVHTTPTransport
    var toolkit: any AVDatabaseToolkit
    var verifier: any AVCdiffVerifying = AVClamAVPSSVerifier.shared
    var userAgent: String
    var allowsConstrainedNetwork = true
    var mirror = URL(string: "https://database.clamav.net")!
    var now: @Sendable () -> Date = { Date() }
    var progress: @Sendable (AVUpdateProgress) -> Void = { _ in }
}

/// The User-Agent ClamAV's CDN requires (it answers 403 unless it starts with `ClamAV/`),
/// identifying Mac Cleaner at the end.
enum AVUserAgent {
    static func make(appVersion: String = AVUserAgent.appVersion) -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return "ClamAV/1.4.6 (OS: darwin, ARCH: \(architecture), CPU: \(architecture)) MacCleaner/\(appVersion)"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    }
}

/// Mac Cleaner's own ClamAV updater, used when freshclam isn't installed. It behaves like
/// freshclam: versions from DNS, signed CDIFF patches for small changes, and full `.cvd`
/// downloads only when patching isn't possible (at most once a day per file).
struct AVBuiltInClamAVUpdater: Sendable {
    let context: AVClamAVUpdateContext

    init(context: AVClamAVUpdateContext) {
        self.context = context
    }

    private var directory: URL { context.paths.clamav }

    /// Updates both databases toward `versions` (nil when the current versions are unknown).
    func update(state: inout AVDefinitionsState, versions: AVClamAVVersionInfo?) async -> AVClamAVUpdateResult {
        var result = AVClamAVUpdateResult()
        try? context.paths.prepare()
        promoteUnverifiedDownloads(state: &state)
        for database in AVClamAVDatabase.allCases {
            if Task.isCancelled { break }
            syncFromDisk(database, state: &state)
            let remote = versions?.version(of: database)
            var action = AVUpdatePolicy.plan(database, state: state[database], remoteVersion: remote, cdnRetryAfter: state.cdnRetryAfter, now: context.now())
            if case .applyPatches(let from, let to) = action {
                do {
                    try await applyPatches(database, from: from, to: to, state: &state)
                    result.changed = true
                    result.messages.append("\(database.title) patched to version \(to).")
                    action = .upToDate
                } catch let stop as AVCDNStop {
                    result.problem = stop.message
                    continue
                } catch {
                    var file = state[database]
                    file.cdiffFailedTarget = to
                    file.lastError = error.localizedDescription
                    state[database] = file
                    result.messages.append("Couldn't patch the \(database.rawValue) database (\(error.localizedDescription)); trying a full download.")
                    action = AVUpdatePolicy.plan(database, state: state[database], remoteVersion: remote, cdnRetryAfter: state.cdnRetryAfter, now: context.now())
                }
            }
            switch action {
            case .upToDate, .applyPatches:
                break
            case .wait(let until, let reason):
                result.messages.append("\(reason) Next try: \(DateFormatting.short(until)).")
                if state[database].version == nil && result.problem == nil { result.problem = reason }
            case .downloadFull:
                do {
                    if try await downloadFull(database, expectedVersion: remote, state: &state) {
                        result.changed = true
                        result.messages.append("Downloaded the \(database.rawValue) database.")
                    }
                } catch let stop as AVCDNStop {
                    result.problem = stop.message
                } catch is CancellationError {
                    break
                } catch {
                    result.problem = error.localizedDescription
                }
            }
        }
        let installed = AVClamAVDatabase.allCases.allSatisfy { database in
            guard let local = state[database].version else { return false }
            return versions.map { local >= $0.version(of: database) } ?? true
        }
        result.upToDate = installed && result.problem == nil
        return result
    }

    // MARK: - Versions

    /// Fallback when DNS fails: reads the first 512 bytes (the header) of each published database.
    func versionsFromHeaders(state: inout AVDefinitionsState) async -> AVClamAVVersionInfo? {
        if let retry = state.cdnRetryAfter, retry > context.now() { return nil }
        var found: [AVClamAVDatabase: Int] = [:]
        for database in AVClamAVDatabase.allCases {
            var request = cdnRequest(database.cvdName, maxBytes: 512)
            request.truncatesAtLimit = true
            request.headers["Range"] = "bytes=0-511"
            guard let (response, data) = try? await context.transport.fetch(request) else { return nil }
            if !response.isSuccess {
                recordCDNRefusal(response, state: &state)
                return nil
            }
            guard let header = AVClamAVHeaderLine.parse(data) else { return nil }
            found[database] = header.version
        }
        guard let main = found[.main], let daily = found[.daily] else { return nil }
        return AVClamAVVersionInfo(clamavVersion: nil, main: main, daily: daily, bytecode: nil, publishedAt: nil, source: .databaseHeaders)
    }

    // MARK: - Patches

    private func applyPatches(_ database: AVClamAVDatabase, from: Int, to: Int, state: inout AVDefinitionsState) async throws {
        guard let local = AVClamAVLocalDatabase.current(database, in: directory) else { throw AVClamAVLocalDatabase.Failure.missing(database.cvdName) }
        let work = try context.paths.makeWorkDirectory("patch-\(database.rawValue)")
        defer { try? FileManager.default.removeItem(at: work) }
        let unpacked = work.appendingPathComponent(database.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)

        context.progress(AVUpdateProgress(phase: .patching, message: "Preparing the \(database.rawValue) database…"))
        let source = local.url
        try await BackgroundWork.run(qos: .utility) {
            _ = try AVClamAVLocalDatabase.unpack(source, to: unpacked)
            try AVClamAVLocalDatabase.verifyUnpacked(database, in: unpacked, expectedVersion: local.header.version)
        }

        let total = to - from + 1
        for (index, version) in (from...to).enumerated() {
            try Task.checkCancellation()
            context.progress(AVUpdateProgress(phase: .patching, message: "Applying update \(index + 1) of \(total) (version \(version))…",
                                              fraction: Double(index) / Double(total)))
            let (response, data) = try await context.transport.fetch(cdnRequest(database.cdiffName(version: version), maxBytes: 16_000_000))
            guard response.isSuccess else {
                if response.statusCode == 429 || response.statusCode == 403 {
                    let message = recordCDNRefusal(response, state: &state)
                    throw AVCDNStop(message: message)
                }
                throw AVCdiff.Failure.malformed("patch \(version) unavailable (HTTP \(response.statusCode))")
            }
            let verifier = context.verifier
            try await BackgroundWork.run(qos: .utility) {
                let patch = try AVCdiff.open(data, verifier: verifier)
                guard patch.version == version else { throw AVCdiff.Failure.malformed("patch for version \(patch.version), expected \(version)") }
                try AVCdiff.apply(patch.script, in: unpacked)
            }
        }

        context.progress(AVUpdateProgress(phase: .verifying, message: "Checking the patched \(database.rawValue) database…"))
        let packed = work.appendingPathComponent(database.cldName)
        let header = try await BackgroundWork.run(qos: .utility) { () throws -> AVClamAVHeaderLine in
            let header = try AVClamAVLocalDatabase.verifyUnpacked(database, in: unpacked, expectedVersion: to)
            try AVClamAVLocalDatabase.pack(database, from: unpacked, to: packed)
            return header
        }
        let destination = directory.appendingPathComponent(database.cldName)
        try AVFileOps.replace(destination, with: packed)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(database.cvdName))

        let now = context.now()
        var file = state[database]
        file.version = header.version
        file.buildTime = header.buildTime
        file.signatureCount = header.signatureCount
        file.fileName = database.cldName
        file.fileSize = Self.size(of: destination)
        file.lastUpdated = now
        file.lastPatched = now
        file.consecutiveFailures = 0
        file.lastError = nil
        file.cdiffFailedTarget = nil
        state[database] = file
    }

    // MARK: - Full downloads

    /// Downloads and verifies `<database>.cvd`. Returns true when the local file changed.
    private func downloadFull(_ database: AVClamAVDatabase, expectedVersion: Int?, state: inout AVDefinitionsState) async throws -> Bool {
        try context.paths.prepare()
        let temporary = context.paths.temporary.appendingPathComponent("\(database.cvdName).\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var request = cdnRequest(database.cvdName, maxBytes: database.maxDownloadBytes)
        let local = AVClamAVLocalDatabase.current(database, in: directory)
        if local != nil, let modified = state[database].lastModifiedHeader { request.headers["If-Modified-Since"] = modified }

        let previousDownload = state[database].lastFullDownload
        var file = state[database]
        file.lastFullDownload = context.now() // counts against the once-a-day rule unless nothing was transferred
        state[database] = file

        let name = database.cvdName
        let progress = context.progress
        let response: AVHTTPResponse
        do {
            response = try await context.transport.download(request, to: temporary) { received, expected in
                progress(AVUpdateProgress(phase: .downloading, message: "Downloading \(name)…", bytesReceived: received, bytesExpected: expected,
                                          fraction: expected.map { Double(received) / Double(max($0, 1)) }))
            }
        } catch let error as AVTransportError where error == .offline {
            state[database].lastFullDownload = previousDownload
            throw error
        } catch {
            recordFailure(database, status: nil, retryAfter: nil, error: error.localizedDescription, state: &state)
            throw error
        }

        if response.statusCode == 304 {
            state[database].lastFullDownload = previousDownload
            return false
        }
        guard response.statusCode == 200 else {
            state[database].lastFullDownload = previousDownload
            if response.statusCode == 429 || response.statusCode == 403 {
                throw AVCDNStop(message: recordCDNRefusal(response, state: &state))
            }
            let message = "ClamAV's server answered HTTP \(response.statusCode) for \(name)."
            recordFailure(database, status: response.statusCode, retryAfter: response.retryAfter(now: context.now()), error: message, state: &state)
            throw AVTransportError.failed(message)
        }

        context.progress(AVUpdateProgress(phase: .verifying, message: "Verifying \(name)…"))
        let toolkit = context.toolkit
        let header: ClamAVDatabaseHeader
        do {
            header = try await BackgroundWork.run(qos: .utility) { try toolkit.verify(temporary) }
        } catch let error as AVEngineError where error == .notImplemented {
            // Keep the download (it can't be fetched again today) and verify it once the engine is available.
            try? FileManager.default.removeItem(at: unverifiedURL(database))
            try FileManager.default.moveItem(at: temporary, to: unverifiedURL(database))
            throw AVEngineError.notImplemented
        } catch {
            let message = "\(name) failed verification and was discarded: \(error.localizedDescription)"
            recordFailure(database, status: nil, retryAfter: nil, error: message, state: &state)
            throw AVTransportError.failed(message)
        }
        if let expectedVersion, header.version < expectedVersion {
            let message = "ClamAV's server sent an older \(name) (version \(header.version), expected \(expectedVersion))."
            recordFailure(database, status: nil, retryAfter: nil, error: message, state: &state)
            throw AVTransportError.failed(message)
        }
        try install(database, from: temporary, header: header, lastModified: response.lastModified, state: &state)
        return true
    }

    private func install(_ database: AVClamAVDatabase, from source: URL, header: ClamAVDatabaseHeader, lastModified: String?, state: inout AVDefinitionsState) throws {
        let destination = directory.appendingPathComponent(database.cvdName)
        try AVFileOps.replace(destination, with: source)
        let patched = directory.appendingPathComponent(database.cldName)
        if let cld = AVClamAVHeaderLine.read(at: patched), cld.version <= header.version { try? FileManager.default.removeItem(at: patched) }
        var file = state[database]
        file.version = header.version
        file.buildTime = header.buildTime
        file.signatureCount = header.signatureCount
        file.fileName = database.cvdName
        file.fileSize = Self.size(of: destination)
        file.lastModifiedHeader = lastModified ?? file.lastModifiedHeader
        file.lastUpdated = context.now()
        file.consecutiveFailures = 0
        file.nextAllowedFullDownload = nil
        file.lastError = nil
        file.cdiffFailedTarget = nil
        state[database] = file
    }

    private func unverifiedURL(_ database: AVClamAVDatabase) -> URL {
        directory.appendingPathComponent(database.cvdName + ".unverified")
    }

    /// A full download kept while the engine couldn't verify it is checked again before anything else.
    private func promoteUnverifiedDownloads(state: inout AVDefinitionsState) {
        for database in AVClamAVDatabase.allCases {
            let url = unverifiedURL(database)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let header = try context.toolkit.verify(url)
                try install(database, from: url, header: header, lastModified: nil, state: &state)
            } catch let error as AVEngineError where error == .notImplemented {
                continue
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Keeps the state in line with the files (freshclam or a person may have changed them).
    private func syncFromDisk(_ database: AVClamAVDatabase, state: inout AVDefinitionsState) {
        var file = state[database]
        if let local = AVClamAVLocalDatabase.current(database, in: directory) {
            if file.version != local.header.version {
                file.version = local.header.version
                file.buildTime = local.header.buildTime
                file.signatureCount = local.header.signatureCount
                file.lastUpdated = file.lastUpdated ?? context.now()
            }
            file.fileName = local.url.lastPathComponent
            file.fileSize = Self.size(of: local.url)
        } else {
            file.version = nil
            file.fileName = nil
            file.fileSize = nil
        }
        state[database] = file
    }

    // MARK: - Errors

    private func cdnRequest(_ name: String, maxBytes: Int64) -> AVHTTPRequest {
        var request = AVHTTPRequest(url: context.mirror.appendingPathComponent(name), headers: ["User-Agent": context.userAgent], maxBytes: maxBytes)
        request.allowsConstrainedNetwork = context.allowsConstrainedNetwork
        return request
    }

    /// 429 and 403 mean "stop asking for a while" for every file on the CDN.
    @discardableResult
    private func recordCDNRefusal(_ response: AVHTTPResponse, state: inout AVDefinitionsState) -> String {
        let now = context.now()
        let until = AVUpdatePolicy.retryDate(status: response.statusCode, retryAfter: response.retryAfter(now: now), failures: 1, now: now)
        state.cdnRetryAfter = max(state.cdnRetryAfter ?? .distantPast, until)
        if response.statusCode == 429 {
            return "ClamAV's servers are limiting downloads from this network. Mac Cleaner will try again after \(DateFormatting.short(until))."
        }
        return "ClamAV's servers refused the request (HTTP 403). Mac Cleaner will try again after \(DateFormatting.short(until))."
    }

    private func recordFailure(_ database: AVClamAVDatabase, status: Int?, retryAfter: TimeInterval?, error: String, state: inout AVDefinitionsState) {
        var file = state[database]
        file.consecutiveFailures += 1
        file.nextAllowedFullDownload = AVUpdatePolicy.retryDate(status: status, retryAfter: retryAfter, failures: file.consecutiveFailures, now: context.now())
        file.lastError = error
        state[database] = file
    }

    static func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }
}

/// The CDN asked to stop (429/403): nothing else is requested from it in this run.
struct AVCDNStop: Error {
    var message: String
}
