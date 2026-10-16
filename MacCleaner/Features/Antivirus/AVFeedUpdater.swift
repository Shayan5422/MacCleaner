import Foundation

/// What updating the abuse.ch feeds changed.
struct AVFeedUpdateResult: Sendable {
    /// A hash list handed to the compiler changed (MalwareBazaar, ThreatFox hashes).
    var hashListsChanged = false
    /// URLhaus/ThreatFox indicators changed.
    var intelChanged = false
    var problems: [String] = []
    var messages: [String] = []
}

/// Downloads the abuse.ch exports, accumulates them locally (MalwareBazaar hashes for about a
/// year, URLhaus and ThreatFox indicators for 30 days after they were last listed) and writes
/// the hash lists the engine compiles.
struct AVFeedUpdater: Sendable {
    var paths: AVPaths
    var transport: any AVHTTPTransport
    var allowsConstrainedNetwork = true
    var now: @Sendable () -> Date = { Date() }
    var progress: @Sendable (AVUpdateProgress) -> Void = { _ in }

    var recentStoreURL: URL { paths.intel.appendingPathComponent("malwarebazaar-recent.tsv") }
    var recentListURL: URL { paths.intel.appendingPathComponent("malwarebazaar-recent.txt") }
    var fullListURL: URL { paths.intel.appendingPathComponent("malwarebazaar-full.txt") }
    var threatFoxHashesURL: URL { paths.intel.appendingPathComponent("threatfox-sha256.txt") }
    var indicatorsURL: URL { paths.intel.appendingPathComponent("indicators.tsv") }

    func update(state: inout AVDefinitionsState, sources: AVSourceSelection, manual: Bool) async -> AVFeedUpdateResult {
        var result = AVFeedUpdateResult()
        do { try paths.prepare() } catch {
            result.problems.append(error.localizedDescription)
            return result
        }
        var intel = AVIntelDatabase.read(from: indicatorsURL)
        let intelCountBefore = intel.count

        for feed in AVFeedID.allCases {
            if Task.isCancelled { break }
            guard feed.isEnabled(in: sources) else {
                if removeData(of: feed, intel: &intel, state: &state) {
                    if feed == .malwareBazaarRecent || feed == .malwareBazaarFull { result.hashListsChanged = true }
                    if feed == .threatFoxRecent { result.hashListsChanged = true }
                    result.intelChanged = true
                }
                continue
            }
            guard AVUpdatePolicy.isFeedDue(feed, state: state[feed], now: now(), manual: manual) else { continue }
            progress(AVUpdateProgress(phase: .processingFeeds, message: "Updating \(feed.title)…"))
            do {
                let changed = try await fetch(feed, intel: &intel, state: &state)
                if changed {
                    switch feed {
                    case .malwareBazaarRecent, .malwareBazaarFull: result.hashListsChanged = true
                    case .threatFoxRecent: result.hashListsChanged = true; result.intelChanged = true
                    case .urlhausOnline, .urlhausHosts: result.intelChanged = true
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                var file = state[feed]
                file.consecutiveFailures += 1
                let status = (error as? AVFeedHTTPError)?.status
                let retryAfter = (error as? AVFeedHTTPError)?.retryAfter
                file.nextAllowedAttempt = AVUpdatePolicy.retryDate(status: status, retryAfter: retryAfter, failures: file.consecutiveFailures, now: now())
                file.lastError = error.localizedDescription
                state[feed] = file
                let connectivity = (error as? AVTransportError)?.isConnectivityProblem ?? false
                if !connectivity { result.problems.append("\(feed.title): \(error.localizedDescription)") }
            }
        }

        // Expire old indicators, then save.
        let cutoff = now().addingTimeInterval(-AVFeedID.threatFoxRecent.retention)
        let beforeExpiry = intel.count
        intel.expire(before: cutoff)
        if intel.count != beforeExpiry { result.intelChanged = true }
        if result.intelChanged || intel.count != intelCountBefore {
            do {
                try intel.write(to: indicatorsURL)
                try writeList(intel.sha256Hashes, header: "ThreatFox SHA-256 indicators (abuse.ch, CC0)", to: threatFoxHashesURL)
            } catch {
                result.problems.append("Couldn't save the threat feeds: \(error.localizedDescription)")
            }
        }
        state[.urlhausOnline].entryCount = intel.entries.values.filter { $0.source == .urlhaus && $0.kind == .url }.count
        state[.urlhausHosts].entryCount = intel.entries.values.filter { $0.source == .urlhaus && $0.kind == .host }.count
        state[.threatFoxRecent].entryCount = intel.count(source: .threatFox)
        let indicatorBytes = AVPaths.diskUsage(of: indicatorsURL)
        let urlhausShare = intel.count == 0 ? 0 : Double(intel.count(source: .urlhaus)) / Double(intel.count)
        state[.malwareBazaarRecent].bytesOnDisk = AVPaths.diskUsage(of: recentListURL) + AVPaths.diskUsage(of: recentStoreURL)
        state[.malwareBazaarFull].bytesOnDisk = AVPaths.diskUsage(of: fullListURL)
        state[.urlhausOnline].bytesOnDisk = Int64(Double(indicatorBytes) * urlhausShare)
        state[.urlhausHosts].bytesOnDisk = 0
        state[.threatFoxRecent].bytesOnDisk = Int64(Double(indicatorBytes) * (1 - urlhausShare)) + AVPaths.diskUsage(of: threatFoxHashesURL)
        return result
    }

    /// Hash lists for `AVDatabaseCompiler`, with entry counts.
    func hashListInputs(sources: AVSourceSelection) -> [(url: URL, source: AVSignatureSource, count: Int, feed: AVFeedID)] {
        var inputs: [(url: URL, source: AVSignatureSource, count: Int, feed: AVFeedID)] = []
        if sources.malwareBazaarRecent, let count = nonEmptyCount(recentListURL) { inputs.append((recentListURL, .malwareBazaar, count, .malwareBazaarRecent)) }
        if sources.malwareBazaarFull, let count = nonEmptyCount(fullListURL) { inputs.append((fullListURL, .malwareBazaar, count, .malwareBazaarFull)) }
        if sources.threatFox, let count = nonEmptyCount(threatFoxHashesURL) { inputs.append((threatFoxHashesURL, .threatFox, count, .threatFoxRecent)) }
        return inputs
    }

    // MARK: - Fetching

    private func fetch(_ feed: AVFeedID, intel: inout AVIntelDatabase, state: inout AVDefinitionsState) async throws -> Bool {
        var request = AVHTTPRequest(url: feed.url, headers: ["User-Agent": "MacCleaner/\(AVUserAgent.appVersion)"], maxBytes: feed.maxBytes)
        request.allowsConstrainedNetwork = allowsConstrainedNetwork
        let previous = state[feed]
        if hasData(feed) {
            if let etag = previous.etag { request.headers["If-None-Match"] = etag }
            if let modified = previous.lastModifiedHeader { request.headers["If-Modified-Since"] = modified }
        }
        let download = paths.temporary.appendingPathComponent("\(feed.rawValue)-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: download) }
        let title = feed.title
        let progress = self.progress
        let response = try await transport.download(request, to: download) { received, expected in
            progress(AVUpdateProgress(phase: .processingFeeds, message: "Downloading \(title)…", bytesReceived: received, bytesExpected: expected,
                                      fraction: expected.map { Double(received) / Double(max($0, 1)) }))
        }
        let checkedAt = now()
        var file = previous
        file.lastChecked = checkedAt
        if response.statusCode == 304 {
            file.consecutiveFailures = 0
            file.lastError = nil
            state[feed] = file
            return false
        }
        guard response.statusCode == 200 else {
            throw AVFeedHTTPError(status: response.statusCode, retryAfter: response.retryAfter(now: checkedAt))
        }
        let data = try Data(contentsOf: download, options: [.alwaysMapped])
        let changed: Bool
        switch feed {
        case .malwareBazaarRecent: changed = try mergeRecentHashes(data, at: checkedAt, state: &file)
        case .malwareBazaarFull: changed = try installFullArchive(data, state: &file)
        case .urlhausOnline:
            let indicators = AVFeedParser.urls(data).map {
                AVIndicator(kind: .url, value: $0, source: .urlhaus, threatType: "malware_download", firstSeen: checkedAt, lastSeen: checkedAt)
            }
            guard !indicators.isEmpty || data.count < 1_000 else { throw AVFeedHTTPError(status: nil, retryAfter: nil, detail: "The URLhaus list was unreadable.") }
            intel.merge(indicators)
            changed = true
        case .urlhausHosts:
            let indicators = AVFeedParser.hosts(data).map {
                AVIndicator(kind: .host, value: $0, source: .urlhaus, threatType: "malware_download", firstSeen: checkedAt, lastSeen: checkedAt)
            }
            intel.merge(indicators)
            changed = true
        case .threatFoxRecent:
            let indicators = try AVFeedParser.threatFox(data).map { ioc -> AVIndicator in
                let kind: AVIndicator.Kind
                switch ioc.kind {
                case .ipPort: kind = .ipPort
                case .domain: kind = .host
                case .url: kind = .url
                case .sha256: kind = .sha256
                }
                return AVIndicator(kind: kind, value: ioc.value, source: .threatFox, threatType: ioc.threatType, malware: ioc.malware,
                                   confidence: ioc.confidence, firstSeen: ioc.firstSeen ?? checkedAt, lastSeen: checkedAt,
                                   isCompromised: ioc.isCompromised, reference: ioc.id)
            }
            intel.merge(indicators)
            changed = true
        }
        file.etag = response.etag
        file.lastModifiedHeader = response.lastModified
        file.consecutiveFailures = 0
        file.nextAllowedAttempt = nil
        file.lastError = nil
        if changed { file.lastChanged = checkedAt }
        state[feed] = file
        return changed
    }

    /// Adds the last 48 hours of MalwareBazaar hashes to the local collection (kept for a year).
    private func mergeRecentHashes(_ data: Data, at date: Date, state: inout AVFeedFileState) throws -> Bool {
        let hashes = AVFeedParser.sha256Hashes(data)
        guard !hashes.isEmpty else { throw AVFeedHTTPError(status: nil, retryAfter: nil, detail: "The MalwareBazaar list contained no hashes.") }
        var store = AVHashCollection.read(from: recentStoreURL)
        let before = store.count
        store.merge(hashes, seenAt: date)
        store.expire(before: date.addingTimeInterval(-AVFeedID.malwareBazaarRecent.retention))
        try store.write(to: recentStoreURL)
        try writeList(store.hashes, header: "MalwareBazaar SHA-256 hashes collected by Mac Cleaner (abuse.ch, CC0)", to: recentListURL)
        state.entryCount = store.count
        return store.count != before || !FileManager.default.fileExists(atPath: recentListURL.path)
    }

    /// Extracts `full_sha256.txt` from the full export.
    private func installFullArchive(_ data: Data, state: inout AVFeedFileState) throws -> Bool {
        let entries = try AVDefsZip.entries(in: data)
        guard let entry = entries.first(where: { $0.name.hasSuffix(".txt") }) else { throw AVDefsArchiveError.corrupt("no hash list in the archive") }
        let staged = paths.temporary.appendingPathComponent("malwarebazaar-full-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: staged) }
        try AVDefsZip.extract(entry, from: data, to: staged, maxOutput: 600_000_000)
        let count = AVFeedParser.countSHA256Lines(in: staged)
        guard count >= 10_000 else { throw AVFeedHTTPError(status: nil, retryAfter: nil, detail: "The full MalwareBazaar list looked incomplete (\(count) hashes).") }
        try AVFileOps.replace(fullListURL, with: staged)
        state.entryCount = count
        return true
    }

    // MARK: - Files

    private func hasData(_ feed: AVFeedID) -> Bool {
        switch feed {
        case .malwareBazaarRecent: return FileManager.default.fileExists(atPath: recentListURL.path)
        case .malwareBazaarFull: return FileManager.default.fileExists(atPath: fullListURL.path)
        case .urlhausOnline, .urlhausHosts, .threatFoxRecent: return FileManager.default.fileExists(atPath: indicatorsURL.path)
        }
    }

    /// Removes a turned-off feed's data. Returns true when something was removed.
    private func removeData(of feed: AVFeedID, intel: inout AVIntelDatabase, state: inout AVDefinitionsState) -> Bool {
        var removed = false
        switch feed {
        case .malwareBazaarRecent:
            for url in [recentListURL, recentStoreURL] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        case .malwareBazaarFull:
            if FileManager.default.fileExists(atPath: fullListURL.path) {
                try? FileManager.default.removeItem(at: fullListURL)
                removed = true
            }
        case .urlhausOnline, .urlhausHosts:
            if intel.count(source: .urlhaus) > 0 { intel.remove(source: .urlhaus); removed = true }
        case .threatFoxRecent:
            if intel.count(source: .threatFox) > 0 { intel.remove(source: .threatFox); removed = true }
        }
        if removed || state.feeds[feed.rawValue] != nil { state.feeds[feed.rawValue] = nil }
        return removed
    }

    private func nonEmptyCount(_ url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let count = AVFeedParser.countSHA256Lines(in: url)
        return count > 0 ? count : nil
    }

    private func writeList(_ hashes: [String], header: String, to url: URL) throws {
        var text = "# \(header)\n"
        text.reserveCapacity(hashes.count * 65 + 100)
        for hash in hashes { text += hash + "\n" }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// MalwareBazaar hashes collected over time (`hash<TAB>first seen<TAB>last seen`).
struct AVHashCollection: Sendable {
    private(set) var entries: [String: (first: TimeInterval, last: TimeInterval)] = [:]

    var count: Int { entries.count }
    var hashes: [String] { entries.keys.sorted() }

    mutating func merge(_ hashes: [String], seenAt date: Date) {
        let time = date.timeIntervalSince1970
        for hash in hashes {
            if let existing = entries[hash] { entries[hash] = (existing.first, max(existing.last, time)) } else { entries[hash] = (time, time) }
        }
    }

    mutating func expire(before cutoff: Date) {
        let limit = cutoff.timeIntervalSince1970
        entries = entries.filter { $0.value.last >= limit }
    }

    func write(to url: URL) throws {
        var text = ""
        text.reserveCapacity(entries.count * 90)
        for (hash, dates) in entries.sorted(by: { $0.key < $1.key }) { text += "\(hash)\t\(Int(dates.first))\t\(Int(dates.last))\n" }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> AVHashCollection {
        var collection = AVHashCollection()
        guard let data = try? Data(contentsOf: url) else { return collection }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let hash = AVFeedParser.normalizedSHA256(fields[0]),
                  let first = TimeInterval(fields[1]), let last = TimeInterval(fields[2]) else { continue }
            collection.entries[hash] = (first, last)
        }
        return collection
    }
}

/// A feed answered with an error status (or unusable content).
struct AVFeedHTTPError: LocalizedError {
    var status: Int?
    var retryAfter: TimeInterval?
    var detail: String?

    var errorDescription: String? {
        if let detail { return detail }
        switch status {
        case 429?: return "abuse.ch is limiting downloads right now (HTTP 429)."
        case let code?: return "The server answered HTTP \(code)."
        case nil: return "The download couldn't be read."
        }
    }
}
