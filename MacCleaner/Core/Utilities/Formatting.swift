import Foundation

/// Consistent byte formatting across the app (decimal units, like Finder).
enum ByteFormatting {
    static func string(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        if bytes == 0 { return "Zero KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: style)
    }

    static func string(_ bytes: UInt64) -> String {
        string(Int64(clamping: bytes))
    }

    /// Memory sizes in binary units, like Activity Monitor ("64 GB" for 64 GiB of RAM).
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// Bytes per second, e.g. "12.3 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

enum NumberFormatting {
    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        guard fraction.isFinite else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(digits)))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }
}

enum DateFormatting {
    /// "3 days ago", "in 2 hours".
    static func relative(_ date: Date, to reference: Date = Date()) -> String {
        if abs(date.timeIntervalSince(reference)) < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    static func short(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}

extension Int64 {
    var formattedBytes: String { ByteFormatting.string(self) }
}

extension UInt64 {
    var formattedBytes: String { ByteFormatting.string(self) }
}

extension String {
    /// Decodes a NUL-terminated C character buffer as UTF-8.
    init(nulTerminated buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
