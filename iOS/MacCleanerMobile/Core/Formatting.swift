import Foundation

/// Byte counts in decimal units, like the Files app and Settings ("1.2 GB").
enum ByteFormatting {
    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "Zero KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum NumberFormatting {
    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// "1 photo", "12,345 photos". `plural` defaults to the noun with an "s".
    static func count(_ value: Int, _ noun: String, plural: String? = nil) -> String {
        "\(count(value)) \(value == 1 ? noun : plural ?? noun + "s")"
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

enum DateFormatting {
    /// "3 days ago", "just now".
    static func relative(_ date: Date, to reference: Date = Date()) -> String {
        if abs(date.timeIntervalSince(reference)) < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
