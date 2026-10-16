import Darwin
import dnssd
import Foundation

/// The ClamAV databases Mac Cleaner uses (`bytecode` isn't needed).
enum AVClamAVDatabase: String, Codable, Sendable, CaseIterable, Identifiable {
    case main, daily

    var id: String { rawValue }
    var cvdName: String { rawValue + ".cvd" }
    var cldName: String { rawValue + ".cld" }
    func cdiffName(version: Int) -> String { "\(rawValue)-\(version).cdiff" }

    var title: String {
        switch self {
        case .main: return "ClamAV main database"
        case .daily: return "ClamAV daily database"
        }
    }

    /// Typical download size, for the first-install estimate.
    var typicalDownloadBytes: Int64 {
        switch self {
        case .main: return 89_000_000
        case .daily: return 23_000_000
        }
    }

    /// Hard cap for one full download.
    var maxDownloadBytes: Int64 {
        switch self {
        case .main: return 300_000_000
        case .daily: return 150_000_000
        }
    }
}

/// Current database versions published by ClamAV.
struct AVClamAVVersionInfo: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable {
        /// The DNS TXT record `current.cvd.clamav.net` (what freshclam uses).
        case dns
        /// The headers of the published files (fallback when DNS fails).
        case databaseHeaders
    }

    var clamavVersion: String?
    var main: Int
    var daily: Int
    var bytecode: Int?
    /// When ClamAV published the record.
    var publishedAt: Date?
    var source: Source

    func version(of database: AVClamAVDatabase) -> Int {
        switch database {
        case .main: return main
        case .daily: return daily
        }
    }
}

/// Parses the TXT record of `current.cvd.clamav.net`, e.g.
/// `1.4.6:63:28155:1792157340:1:90:49192:339`
/// (ClamAV version : main : daily : time : … : bytecode).
enum AVClamAVTXTRecord {
    static func parse(_ text: String) -> AVClamAVVersionInfo? {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let main = Int(fields[1]), let daily = Int(fields[2]), main > 0, daily > 0 else { return nil }
        let published = TimeInterval(fields[3]).map { Date(timeIntervalSince1970: $0) }
        let bytecode = fields.count >= 8 ? Int(fields[7]) : nil
        return AVClamAVVersionInfo(clamavVersion: fields[0].isEmpty ? nil : fields[0], main: main, daily: daily,
                                   bytecode: bytecode, publishedAt: published, source: .dns)
    }
}

/// The text header of a ClamAV database: the first 512 bytes of a `.cvd`/`.cld` or the first
/// line of its `.info` file, e.g. `ClamAV-VDB:16 Oct 2026 06-24 +0000:28155:355765:90:…:builder:1792131857`.
struct AVClamAVHeaderLine: Sendable, Hashable {
    var version: Int
    var signatureCount: Int?
    var functionalityLevel: Int?
    var buildTime: Date?
    var builder: String?

    static func parse(_ data: Data) -> AVClamAVHeaderLine? {
        parse(String(decoding: data.prefix(512), as: UTF8.self))
    }

    static func parse(_ text: String) -> AVClamAVHeaderLine? {
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, fields[0] == "ClamAV-VDB", let version = Int(fields[2]) else { return nil }
        var header = AVClamAVHeaderLine(version: version)
        header.signatureCount = Int(fields[3])
        header.functionalityLevel = fields.count > 4 ? Int(fields[4]) : nil
        header.builder = fields.count > 7 ? fields[7] : nil
        if fields.count > 8, let seconds = TimeInterval(fields[8].trimmingCharacters(in: .whitespaces)) {
            header.buildTime = Date(timeIntervalSince1970: seconds)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd MMM yyyy HH-mm Z"
            header.buildTime = formatter.date(from: fields[1])
        }
        return header
    }

    /// Reads the header of a database file on disk.
    static func read(at url: URL) -> AVClamAVHeaderLine? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        return parse(data)
    }
}

/// Looks up the current database versions.
protocol AVVersionLookup: Sendable {
    func currentVersions() async -> AVClamAVVersionInfo?
}

/// DNS TXT lookup of `current.cvd.clamav.net` with `DNSServiceQueryRecord` (no extra libraries).
struct AVDNSVersionLookup: AVVersionLookup {
    var hostName = "current.cvd.clamav.net"
    var timeout: TimeInterval = 6

    init() {}

    func currentVersions() async -> AVClamAVVersionInfo? {
        let name = hostName
        let timeout = timeout
        return await BackgroundWork.run(qos: .utility) {
            AVDNSTXTResolver.query(name, timeout: timeout)?.lazy.compactMap(AVClamAVTXTRecord.parse).first
        }
    }
}

enum AVDNSTXTResolver {
    private final class Box {
        var records: [Data] = []
        var errorCode: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        var done = false
    }

    /// TXT strings for `name`, or nil when the lookup failed or timed out. Blocks.
    static func query(_ name: String, timeout: TimeInterval) -> [String]? {
        let box = Box()
        var reference: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, _, _, length, data, _, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            if errorCode != kDNSServiceErr_NoError {
                box.errorCode = errorCode
                box.done = true
                return
            }
            if let data, length > 0 { box.records.append(Data(bytes: data, count: Int(length))) }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { box.done = true }
        }
        let unmanaged = Unmanaged.passRetained(box)
        defer { unmanaged.release() }
        let status = DNSServiceQueryRecord(&reference, 0, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), callback, unmanaged.toOpaque())
        guard status == kDNSServiceErr_NoError, let reference else { return nil }
        defer { DNSServiceRefDeallocate(reference) }

        let socket = DNSServiceRefSockFD(reference)
        guard socket >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !box.done {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 && errno != EINTR { return nil }
            if ready > 0, DNSServiceProcessResult(reference) != kDNSServiceErr_NoError { return nil }
        }
        guard box.errorCode == kDNSServiceErr_NoError else { return nil }
        return box.records.flatMap(parseTXT)
    }

    /// TXT rdata is a sequence of length-prefixed strings.
    static func parseTXT(_ data: Data) -> [String] {
        var strings: [String] = []
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            strings.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end
        }
        return strings
    }
}
