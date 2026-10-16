import Foundation

/// A loaded engine with what its database contains.
struct AVLoadedEngine: Sendable {
    var scanner: any AVFileScanning
    var summary: AVDatabaseSummary
}

/// The engine operations the updater and the app use. `AVLiveToolkit` calls the real engine;
/// tests substitute fakes so the updater can be exercised without it.
protocol AVDatabaseToolkit: Sendable {
    /// Checks a ClamAV container (`.cvd`/`.cld`) before it is used.
    func verify(_ url: URL) throws -> ClamAVDatabaseHeader
    /// Builds the engine database into `directory`. Blocks.
    func compile(_ inputs: AVDatabaseInputs, into directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> AVDatabaseSummary
    /// Loads a compiled database. Blocks.
    func load(from directory: URL) throws -> AVLoadedEngine
    /// Signatures that work without downloaded definitions (the EICAR test file).
    func builtInScanner() -> any AVFileScanning
}

extension AVDatabaseToolkit {
    func builtInScanner() -> any AVFileScanning { AVBuiltInScanner() }
}

struct AVLiveToolkit: AVDatabaseToolkit {
    init() {}

    func verify(_ url: URL) throws -> ClamAVDatabaseHeader {
        try ClamAVDatabaseFile.verify(at: url)
    }

    func compile(_ inputs: AVDatabaseInputs, into directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> AVDatabaseSummary {
        try AVDatabaseCompiler.compile(inputs, into: directory, progress: progress)
    }

    func load(from directory: URL) throws -> AVLoadedEngine {
        let engine = try AVEngine.load(from: directory)
        return AVLoadedEngine(scanner: AVReportingPolicy.Scanner(base: engine), summary: engine.summary)
    }

    /// The engine's own built-in mode (EICAR, also inside archives).
    func builtInScanner() -> any AVFileScanning { AVEngine.builtIn() }
}

/// Which engine matches Mac Cleaner reports. Unwanted software (PUA) made for Windows or Linux,
/// such as "PUA.Win.Trojan.Xored-1", is dropped: it can't affect a Mac, and these signatures
/// are ClamAV's most common false alarms in Mac apps (on the development Mac one matched a
/// minified JavaScript library inside two code editors). Windows and Linux *malware* is still
/// reported while "Detect Windows and Linux threats" is on.
enum AVReportingPolicy {
    static func isReported(_ detection: AVDetection) -> Bool {
        !(detection.kind == .pua && isWindowsOrLinux(detection.signatureName))
    }

    /// The platform is the first part of a ClamAV name, or the second after "PUA."
    static func isWindowsOrLinux(_ signatureName: String) -> Bool {
        let parts = signatureName.split(separator: ".", maxSplits: 2)
        guard parts.count >= 2 else { return false }
        let platform = parts[0] == "PUA" ? parts[1] : parts[0]
        return platform == "Win" || platform == "Unix"
    }

    /// Applies the policy to every result of `base`.
    struct Scanner: AVFileScanning {
        let base: any AVFileScanning

        func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult {
            var result = base.scanFile(atPath: path, options: options)
            if !result.detections.allSatisfy(AVReportingPolicy.isReported) {
                result.detections.removeAll { !AVReportingPolicy.isReported($0) }
            }
            return result
        }
    }
}

/// Process-wide access to the loaded engine, shared by the Antivirus page, the shields,
/// Smart Scan and other features. Thread-safe.
///
/// Without downloaded definitions, `activeScanner` is `AVBuiltInScanner` (EICAR test file only).
final class AVEngineHolder: @unchecked Sendable {
    static let shared = AVEngineHolder()

    /// Posted (on any thread) when an engine is installed or removed.
    static let didChangeNotification = Notification.Name("AVEngineHolderDidChange")

    private let lock = NSLock()
    private var engine: AVLoadedEngine?
    private var loadedFrom: Date?
    private let builtIn: any AVFileScanning

    init(fallback: any AVFileScanning = AVLiveToolkit().builtInScanner()) {
        builtIn = fallback
    }

    var loadedEngine: AVLoadedEngine? { lock.withLock { engine } }
    var hasDefinitions: Bool { loadedEngine != nil }
    var summary: AVDatabaseSummary? { loadedEngine?.summary }

    /// The engine when definitions are loaded, otherwise the built-in test signatures.
    var activeScanner: any AVFileScanning { lock.withLock { engine?.scanner ?? builtIn } }

    /// When the loaded database was compiled (from `state.json`), to notice updates made by
    /// another process.
    var loadedDatabaseDate: Date? { lock.withLock { loadedFrom } }

    func install(_ engine: AVLoadedEngine?, compiledAt: Date?) {
        lock.withLock {
            self.engine = engine
            loadedFrom = engine == nil ? nil : compiledAt
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Loads the installed database if `state.json` says one was compiled. Blocks; call it off
    /// the main thread. Returns the error when loading failed.
    @discardableResult
    func loadInstalled(paths: AVPaths, toolkit: any AVDatabaseToolkit) -> Error? {
        let state = AVStateFile(url: paths.stateFile).load()
        guard let installed = state.installed else {
            install(nil, compiledAt: nil)
            return nil
        }
        if let loaded = loadedDatabaseDate, abs(loaded.timeIntervalSince(installed.compiledAt)) < 1, hasDefinitions { return nil }
        do {
            let loaded = try toolkit.load(from: paths.engine)
            install(loaded, compiledAt: installed.compiledAt)
            return nil
        } catch {
            return error
        }
    }

    /// Scans one file with the loaded engine, off the calling thread.
    /// Returns nil when definitions aren't loaded (the built-in test signatures aren't used here).
    func scanFile(at path: String, options: AVScanOptions = AVScanOptions()) async -> AVFileScanResult? {
        guard let scanner = loadedEngine?.scanner else { return nil }
        return await BackgroundWork.run(qos: .userInitiated) {
            AVThreadIO.disableCloudDownloads()
            return scanner.scanFile(atPath: path, options: options)
        }
    }
}
