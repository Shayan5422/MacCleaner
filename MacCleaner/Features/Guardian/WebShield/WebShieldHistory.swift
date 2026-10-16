import Darwin
import Foundation

/// One browser history database to watch (a browser profile).
struct WebShieldHistorySource: Sendable, Hashable, Identifiable {
    enum Engine: String, Sendable, Codable {
        case safari, chromium, firefox
    }

    /// "chrome|Profile 1", "safari".
    var id: String
    var browserID: String
    var browserName: String
    var profileName: String?
    var engine: Engine
    var databasePath: String
}

/// Whether a browser's history can be read.
enum WebShieldAccess: String, Codable, Sendable, Hashable {
    case readable
    /// macOS privacy protection blocks it (Safari always; other browsers on recent macOS versions).
    case needsFullDiskAccess
    /// The browser has no history database (never used, or a fresh profile).
    case noHistory
}

/// Where Mac Cleaner left off in one history database. Holds visit numbers and file sizes only,
/// never addresses.
struct WebShieldCursor: Codable, Sendable, Hashable {
    /// Highest visit row read.
    var lastVisitID: Int64
    /// Its visit time, in the browser's own units (used when history was cleared and rows restart).
    var lastVisitTime: Int64
    /// Sizes and modification times of the database files when they were last read; unchanged files are skipped.
    var fileSignature: String
    var updatedAt: Date
}

/// A visit read from history. Lives only inside the background job that reads and checks it.
struct WebShieldVisit: Sendable, Hashable {
    var id: Int64
    /// Browser's own units: microseconds since 1601 (Chromium), since 1970 (Firefox), since 2001 (Safari).
    var time: Int64
    var url: String
}

enum WebShieldReadError: Error, Equatable, Sendable {
    case needsFullDiskAccess
    case missing
    /// The history changed while it was being copied, or the copy couldn't be read; tried again next time.
    case unreadable(String)
    case unexpectedSchema
}

/// Finds the history databases of the supported browsers. Only folder names and the small
/// profile lists are read here.
enum WebShieldSources {
    static func discover(browser: PrivacyBrowser, home: String) -> (sources: [WebShieldHistorySource], access: WebShieldAccess) {
        switch browser.engine {
        case .safari:
            let path = home + "/Library/Safari/History.db"
            switch PrivacyFileAccess.probe(path) {
            case .file:
                return ([WebShieldHistorySource(id: browser.id, browserID: browser.id, browserName: browser.name, profileName: nil,
                                                engine: .safari, databasePath: path)], .readable)
            case .blocked:
                return ([], .needsFullDiskAccess)
            default:
                return ([], PrivacyFileAccess.probe(home + "/Library/Safari") == .blocked ? .needsFullDiskAccess : .noHistory)
            }

        case .chromium:
            guard let supportRoot = browser.supportRoot(home: home) else { return ([], .noHistory) }
            if PrivacyFileAccess.probe(supportRoot) == .blocked || PrivacyFileAccess.isBlockedDirectory(supportRoot) {
                return ([], .needsFullDiskAccess)
            }
            let discovery = PrivacyProfileDiscovery.chromiumProfiles(supportRoot: supportRoot, cacheRoot: nil)
            if discovery.supportBlocked { return ([], .needsFullDiskAccess) }
            var sources: [WebShieldHistorySource] = []
            var blocked = false
            for profile in discovery.profiles {
                guard let data = profile.dataPath else { continue }
                let path = data + "/History"
                switch PrivacyFileAccess.probe(path) {
                case .file:
                    sources.append(WebShieldHistorySource(
                        id: browser.id + "|" + (profile.directoryName.isEmpty ? "Default" : profile.directoryName),
                        browserID: browser.id, browserName: browser.name,
                        profileName: discovery.profiles.count > 1 ? profile.displayName : nil,
                        engine: .chromium, databasePath: path
                    ))
                case .blocked:
                    blocked = true
                default:
                    continue
                }
            }
            if sources.isEmpty { return ([], blocked ? .needsFullDiskAccess : .noHistory) }
            return (sources, .readable)

        case .firefox:
            guard let supportRoot = browser.supportRoot(home: home) else { return ([], .noHistory) }
            if PrivacyFileAccess.probe(supportRoot) == .blocked || PrivacyFileAccess.isBlockedDirectory(supportRoot) {
                return ([], .needsFullDiskAccess)
            }
            let discovery = PrivacyProfileDiscovery.firefoxProfiles(supportRoot: supportRoot, cacheRoot: nil, home: home)
            if discovery.supportBlocked { return ([], .needsFullDiskAccess) }
            var sources: [WebShieldHistorySource] = []
            var blocked = false
            for profile in discovery.profiles {
                guard let data = profile.dataPath else { continue }
                let path = data + "/places.sqlite"
                switch PrivacyFileAccess.probe(path) {
                case .file:
                    sources.append(WebShieldHistorySource(
                        id: browser.id + "|" + profile.directoryName, browserID: browser.id, browserName: browser.name,
                        profileName: discovery.profiles.count > 1 ? profile.displayName : nil,
                        engine: .firefox, databasePath: path
                    ))
                case .blocked:
                    blocked = true
                default:
                    continue
                }
            }
            if sources.isEmpty { return ([], blocked ? .needsFullDiskAccess : .noHistory) }
            return (sources, .readable)
        }
    }
}

/// Reads the visits added to a browser's history since the last read, without touching the
/// browser's own files.
///
/// Browsers keep their history database locked while they run (Chrome and Firefox use SQLite's
/// exclusive locking), and reading it in place would also take locks the browser may need. So the
/// database and its journal are first copied into Mac Cleaner's private cache folder with an
/// APFS clone — instant, no extra disk space, and the browser's files are never opened for
/// writing or locked. The copy is read with SQLite, then deleted before the function returns.
/// A copy that raced with a write (the files changed while copying) is retried.
enum WebShieldHistoryReader {
    /// At most this many visits per read; the rest is read on the next check.
    static let maximumVisitsPerRead = 2_000
    /// Longer addresses (data: URLs and the like) aren't checked.
    static let maximumURLLength = 8_192

    static func read(source: WebShieldHistorySource, cursor: WebShieldCursor?, scratchDirectory: String, now: Date = Date()) throws -> (cursor: WebShieldCursor, visits: [WebShieldVisit], skipped: Bool) {
        switch PrivacyFileAccess.probe(source.databasePath) {
        case .file: break
        case .blocked: throw WebShieldReadError.needsFullDiskAccess
        default: throw WebShieldReadError.missing
        }
        let signature = fileSignature(source.databasePath)
        if let cursor, cursor.fileSignature == signature, !signature.isEmpty {
            return (cursor, [], true)
        }

        let workFolder = try makeWorkFolder(in: scratchDirectory)
        defer { try? FileManager.default.removeItem(atPath: workFolder) }
        let copy = try snapshot(source.databasePath, into: workFolder)

        let database: PrivacySQLiteDatabase
        do {
            database = try PrivacySQLiteDatabase(path: copy, readOnly: false, busyTimeoutMilliseconds: 500)
        } catch {
            throw WebShieldReadError.unreadable(String(describing: error))
        }
        defer { database.close() }

        let schema = Schema(engine: source.engine)
        do {
            guard try database.tableExists(schema.visitsTable), try database.tableExists(schema.pagesTable) else {
                throw WebShieldReadError.unexpectedSchema
            }
            let maxID = try database.integer("SELECT MAX(id) FROM \(schema.visitsTable)") ?? 0
            guard let cursor else {
                // First look: start from now, so only visits after this point are ever read.
                let maxTime = try database.integer("SELECT MAX(\(schema.timeExpression)) FROM \(schema.visitsTable) v") ?? 0
                return (WebShieldCursor(lastVisitID: maxID, lastVisitTime: maxTime, fileSignature: signature, updatedAt: now), [], false)
            }

            let rows: [String]
            if maxID < cursor.lastVisitID {
                // History was cleared and visit numbers started over: read by time instead.
                rows = try database.strings(schema.query(condition: "\(schema.timeExpression) > ?"),
                                            [.integer(cursor.lastVisitTime), .integer(Int64(maximumVisitsPerRead))])
            } else {
                rows = try database.strings(schema.query(condition: "v.id > ?"),
                                            [.integer(cursor.lastVisitID), .integer(Int64(maximumVisitsPerRead))])
            }
            let visits = rows.compactMap(parseRow)
            let hasMore = rows.count >= maximumVisitsPerRead
            var next = cursor
            if let last = visits.last {
                next.lastVisitID = hasMore ? last.id : max(maxID, last.id)
                next.lastVisitTime = max(visits.map(\.time).max() ?? last.time, maxID < cursor.lastVisitID ? 0 : cursor.lastVisitTime)
            } else {
                next.lastVisitID = maxID
            }
            next.fileSignature = hasMore ? "" : signature
            next.updatedAt = now
            return (next, visits.filter { $0.url.utf8.count <= maximumURLLength }, false)
        } catch let error as WebShieldReadError {
            throw error
        } catch {
            throw WebShieldReadError.unreadable(String(describing: error))
        }
    }

    /// The SQL for each browser's history tables.
    struct Schema: Sendable {
        var visitsTable: String
        var pagesTable: String
        /// Visit time as an integer in the browser's units.
        var timeExpression: String
        var join: String

        init(engine: WebShieldHistorySource.Engine) {
            switch engine {
            case .chromium:
                visitsTable = "visits"; pagesTable = "urls"
                timeExpression = "v.visit_time"
                join = "JOIN urls p ON p.id = v.url"
            case .firefox:
                visitsTable = "moz_historyvisits"; pagesTable = "moz_places"
                timeExpression = "v.visit_date"
                join = "JOIN moz_places p ON p.id = v.place_id"
            case .safari:
                visitsTable = "history_visits"; pagesTable = "history_items"
                timeExpression = "CAST(v.visit_time * 1000000 AS INTEGER)"
                join = "JOIN history_items p ON p.id = v.history_item"
            }
        }

        /// One text column per visit: "id time url" (the reader only has single-column helpers).
        func query(condition: String) -> String {
            "SELECT v.id || ' ' || \(timeExpression) || ' ' || COALESCE(p.url, '') FROM \(visitsTable) v \(join) WHERE \(condition) ORDER BY v.id LIMIT ?"
        }
    }

    static func parseRow(_ row: String) -> WebShieldVisit? {
        let parts = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let id = Int64(parts[0]) else { return nil }
        return WebShieldVisit(id: id, time: Int64(parts[1]) ?? 0, url: String(parts[2]))
    }

    // MARK: Files

    static let companionSuffixes = ["-wal", "-journal"]

    /// Size, modification time and inode of the database and its journal or write-ahead log.
    static func fileSignature(_ databasePath: String) -> String {
        ([""] + companionSuffixes).map { suffix -> String in
            var info = stat()
            guard stat(databasePath + suffix, &info) == 0 else { return "-" }
            let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            return "\(info.st_ino):\(info.st_size):\(mtime)"
        }.joined(separator: "|")
    }

    static func makeWorkFolder(in scratchDirectory: String) throws -> String {
        try FileManager.default.createDirectory(atPath: scratchDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = PathUtilities.resolvedPath(scratchDirectory) ?? scratchDirectory
        let folder = root + "/read-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Copies the database with its journal or write-ahead log into `folder` and returns the copy's path.
    static func snapshot(_ databasePath: String, into folder: String) throws -> String {
        let name = (databasePath as NSString).lastPathComponent
        let destination = folder + "/" + name
        for _ in 0..<3 {
            let before = fileSignature(databasePath)
            for suffix in companionSuffixes {
                try? FileManager.default.removeItem(atPath: destination + suffix)
                var info = stat()
                // Companions first: a copy of the log taken before the database never misses committed pages.
                if stat(databasePath + suffix, &info) == 0, info.st_size > 0 {
                    try cloneOrCopy(databasePath + suffix, to: destination + suffix)
                }
            }
            try? FileManager.default.removeItem(atPath: destination)
            try cloneOrCopy(databasePath, to: destination)
            if fileSignature(databasePath) == before { return destination }
        }
        throw WebShieldReadError.unreadable("history kept changing while it was copied")
    }

    /// APFS clone; a plain copy when cloning isn't possible (another volume or file system).
    static func cloneOrCopy(_ source: String, to destination: String, maximumCopyBytes: Int64 = 1_000_000_000) throws {
        if clonefile(source, destination, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let code = errno
        if code == EPERM || code == EACCES { throw WebShieldReadError.needsFullDiskAccess }
        var info = stat()
        guard stat(source, &info) == 0 else { throw WebShieldReadError.missing }
        guard Int64(info.st_size) <= maximumCopyBytes else { throw WebShieldReadError.unreadable("history is too large to copy") }
        guard copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            let copyError = errno
            if copyError == EPERM || copyError == EACCES { throw WebShieldReadError.needsFullDiskAccess }
            throw WebShieldReadError.unreadable("copy failed (\(copyError))")
        }
    }

    // MARK: Dates

    static func date(ofVisitTime time: Int64, engine: WebShieldHistorySource.Engine) -> Date? {
        guard time > 0 else { return nil }
        let seconds = Double(time) / 1_000_000
        switch engine {
        case .chromium: return Date(timeIntervalSince1970: seconds - 11_644_473_600)
        case .firefox: return Date(timeIntervalSince1970: seconds)
        case .safari: return Date(timeIntervalSinceReferenceDate: seconds)
        }
    }
}

// MARK: - Matching

/// A visit that matched a threat feed. Only these leave the background job, and only the host
/// and the feed's own indicator are kept.
struct WebShieldMatch: Sendable, Hashable {
    var host: String
    var match: ThreatIntelMatch
    var sourceID: String
    var visitDate: Date?
}

enum WebShieldMatcher {
    /// The host of an http(s) address, lowercased, without a trailing dot. nil for other schemes.
    static func host(of url: String) -> (host: String, port: Int?)? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let scheme = url[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        if let components = URLComponents(string: url), var host = components.host?.lowercased(), !host.isEmpty {
            if host.hasSuffix(".") { host.removeLast() }
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            return (host, components.port)
        }
        // Addresses URLComponents rejects (spaces, unusual characters): take the authority by hand.
        var authority = url[schemeEnd.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var hostPart = String(authority)
        var port: Int?
        if let colon = hostPart.lastIndex(of: ":"), !hostPart.contains("]") {
            port = Int(hostPart[hostPart.index(after: colon)...])
            hostPart = String(hostPart[..<colon])
        }
        hostPart = hostPart.lowercased()
        if hostPart.hasSuffix(".") { hostPart.removeLast() }
        return hostPart.isEmpty ? nil : (hostPart, port)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Checks one address: the full URL first (malware download lists), then the host
    /// (malicious domains), then an IP host with its port.
    static func match(url: String, lookup: any ThreatIntelLookup) -> (host: String, match: ThreatIntelMatch)? {
        guard let parsed = host(of: url) else { return nil }
        if let match = lookup.match(url: url) { return (parsed.host, match) }
        if let match = lookup.match(host: parsed.host) { return (parsed.host, match) }
        if isIPAddress(parsed.host) {
            let port = parsed.port ?? (url.lowercased().hasPrefix("https") ? 443 : 80)
            if let match = lookup.match(ip: parsed.host, port: UInt16(clamping: port)) { return (parsed.host, match) }
        }
        return nil
    }

    /// "URLhaus (abuse.ch)" → "URLhaus".
    static func feedName(_ source: String) -> String {
        if let range = source.range(of: " (") { return String(source[..<range.lowerBound]) }
        return source.isEmpty ? "A threat feed" : source
    }

    /// "URLhaus lists it for malware downloads (AMOS Stealer)".
    static func listingPhrase(_ match: ThreatIntelMatch) -> String {
        let feed = feedName(match.source)
        let reason: String
        switch match.threatType.lowercased() {
        case "malware_download": reason = "for malware downloads"
        case "payload_delivery": reason = "for delivering malware"
        case "botnet_cc", "c2", "command_and_control": reason = "as a malware control server"
        case "phishing": reason = "for phishing"
        case "cc_skimming": reason = "for stealing payment card details"
        case "": reason = "as malicious"
        default: reason = "as malicious (\(match.threatType.replacingOccurrences(of: "_", with: " ")))"
        }
        let family = match.malware.map { " (\($0))" } ?? ""
        return "\(feed) lists it \(reason)\(family)"
    }
}

/// One check of several history databases, run off the main thread. Visited addresses never
/// leave this function; only matches and read positions do.
enum WebShieldScanner {
    struct SourceOutcome: Sendable {
        var source: WebShieldHistorySource
        var cursor: WebShieldCursor?
        var error: WebShieldReadError?
        var visitsChecked: Int
    }

    struct Outcome: Sendable {
        var sources: [SourceOutcome]
        var matches: [WebShieldMatch]
    }

    static func check(sources: [WebShieldHistorySource], cursors: [String: WebShieldCursor], lookup: any ThreatIntelLookup,
                      scratchDirectory: String, now: Date = Date()) -> Outcome {
        var outcomes: [SourceOutcome] = []
        var matches: [WebShieldMatch] = []
        for source in sources {
            do {
                let result = try WebShieldHistoryReader.read(source: source, cursor: cursors[source.id], scratchDirectory: scratchDirectory, now: now)
                for visit in result.visits {
                    if let found = WebShieldMatcher.match(url: visit.url, lookup: lookup) {
                        matches.append(WebShieldMatch(host: found.host, match: found.match, sourceID: source.id,
                                                      visitDate: WebShieldHistoryReader.date(ofVisitTime: visit.time, engine: source.engine)))
                    }
                }
                outcomes.append(SourceOutcome(source: source, cursor: result.cursor, error: nil, visitsChecked: result.visits.count))
            } catch let error as WebShieldReadError {
                outcomes.append(SourceOutcome(source: source, cursor: nil, error: error, visitsChecked: 0))
            } catch {
                outcomes.append(SourceOutcome(source: source, cursor: nil, error: .unreadable(String(describing: error)), visitsChecked: 0))
            }
        }
        return Outcome(sources: outcomes, matches: matches)
    }
}
