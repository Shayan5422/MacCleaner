import Foundation
import OSLog

/// Areas of the app that write to the activity log.
enum LogCategory: String, Codable, Sendable, CaseIterable {
    case scan, cleanup, uninstall, storage, duplicates, startup, monitor, security, antivirus, network, privacy, cloud, updates, developer, automation, permissions, app

    var title: String {
        switch self {
        case .scan: return "Scan"
        case .cleanup: return "Cleanup"
        case .uninstall: return "Uninstaller"
        case .storage: return "Storage"
        case .duplicates: return "Duplicates"
        case .startup: return "Startup"
        case .monitor: return "Monitor"
        case .security: return "Security"
        case .antivirus: return "Antivirus"
        case .network: return "Ports & Network"
        case .privacy: return "Privacy"
        case .cloud: return "Cloud"
        case .updates: return "Updates"
        case .developer: return "Developer"
        case .automation: return "Automation"
        case .permissions: return "Permissions"
        case .app: return "App"
        }
    }
}

/// One line of the activity log. Messages describe operations (counts, sizes,
/// categories, durations, error codes); they never contain file contents and
/// avoid personal paths.
struct ActivityEvent: Codable, Sendable, Identifiable, Hashable {
    enum Level: String, Codable, Sendable { case info, warning, error }

    var id = UUID()
    var date = Date()
    var level: Level
    var category: LogCategory
    var message: String
}

/// Writes to the unified log (`os.Logger`) and to a small rotating file in
/// `~/Library/Logs/Mac Cleaner` that the Settings window can display.
final class ActivityLogger: Sendable {
    static let shared = ActivityLogger()

    let logFileURL: URL
    private let subsystem: String
    private let queue = DispatchQueue(label: "MacCleaner.ActivityLogger", qos: .utility)
    private let maxFileSize: UInt64 = 2 * 1024 * 1024

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mac Cleaner", isDirectory: true)
        logFileURL = base.appendingPathComponent("activity.jsonl")
        subsystem = Bundle.main.bundleIdentifier ?? "com.maccleaner.MacCleaner"
    }

    func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    func info(_ message: String, category: LogCategory) {
        record(ActivityEvent(level: .info, category: category, message: message))
    }

    func warning(_ message: String, category: LogCategory) {
        record(ActivityEvent(level: .warning, category: category, message: message))
    }

    func error(_ message: String, category: LogCategory) {
        record(ActivityEvent(level: .error, category: category, message: message))
    }

    func record(_ event: ActivityEvent) {
        let logger = logger(event.category)
        switch event.level {
        case .info: logger.info("\(event.message, privacy: .public)")
        case .warning: logger.warning("\(event.message, privacy: .public)")
        case .error: logger.error("\(event.message, privacy: .public)")
        }
        let url = logFileURL
        let limit = maxFileSize
        queue.async {
            Self.append(event, to: url, maxSize: limit)
        }
    }

    /// Most recent events first.
    func recentEvents(limit: Int = 500) async -> [ActivityEvent] {
        let url = logFileURL
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.read(url: url, limit: limit))
            }
        }
    }

    func clear() async {
        let url = logFileURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
                continuation.resume()
            }
        }
    }

    // MARK: - File I/O (on `queue`)

    private static func append(_ event: ActivityEvent, to url: URL, maxSize: UInt64) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxSize {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private static func read(url: URL, limit: Int) -> [ActivityEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [ActivityEvent] = []
        for file in [url, url.appendingPathExtension("1")] {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                if let event = try? decoder.decode(ActivityEvent.self, from: line) {
                    events.append(event)
                    if events.count >= limit { return events }
                }
            }
        }
        return events
    }
}
