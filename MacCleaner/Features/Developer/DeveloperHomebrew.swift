import Foundation

/// What `brew cleanup --dry-run` says it would remove.
struct DeveloperHomebrewCleanupPlan: Sendable, Hashable {
    struct Entry: Sendable, Hashable {
        var path: String
        var bytes: Int64?
        var fileCount: Int?
    }

    var entries: [Entry] = []
    var emptyDirectoryCount = 0
    /// "This operation would free approximately …".
    var reportedTotalBytes: Int64?
    /// Formulae Homebrew would uninstall as unneeded dependencies (Mac Cleaner never does).
    var autoremoveFormulae: [String] = []

    var estimatedBytes: Int64 {
        reportedTotalBytes ?? entries.compactMap(\.bytes).reduce(0, +)
    }

    var isEmpty: Bool {
        entries.isEmpty && (reportedTotalBytes ?? 0) == 0
    }

    func entries(inside folder: String) -> [Entry] {
        entries.filter { PathUtilities.isSameOrDescendant($0.path, of: folder) }
    }

    /// Old installed versions (Cellar and Caskroom entries).
    var oldVersionCount: Int {
        entries.filter { $0.path.contains("/Cellar/") || $0.path.contains("/Caskroom/") }.count
    }
}

/// Parses Homebrew output. Homebrew prints sizes in binary units labelled KB/MB/GB.
enum DeveloperHomebrewParser {
    static func parseCleanupDryRun(_ output: String) -> DeveloperHomebrewCleanupPlan {
        var plan = DeveloperHomebrewCleanupPlan()
        var readingAutoremove = false
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("Would remove (empty directory):") {
                plan.emptyDirectoryCount += 1
                continue
            }
            if line.hasPrefix("Would remove:") {
                plan.entries.append(parseEntry(String(line.dropFirst("Would remove:".count)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("==>") {
                readingAutoremove = line.contains("Would autoremove")
                if let range = line.range(of: "would free approximately ") {
                    let rest = line[range.upperBound...]
                    let size = rest.components(separatedBy: " of disk space").first ?? String(rest)
                    plan.reportedTotalBytes = parseSize(size)
                }
                continue
            }
            if readingAutoremove, !line.contains(" ") {
                plan.autoremoveFormulae.append(line)
            } else {
                readingAutoremove = false
            }
        }
        return plan
    }

    /// "<path> (806 files, 12.8MB)" or "<path> (112.2KB)".
    static func parseEntry(_ text: String) -> DeveloperHomebrewCleanupPlan.Entry {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else {
            return .init(path: text, bytes: nil, fileCount: nil)
        }
        let inside = text[open.upperBound..<text.index(before: text.endIndex)]
        let parts = inside.components(separatedBy: ", ")
        var fileCount: Int?
        var sizeText = parts.last ?? ""
        if parts.count == 2 {
            let countText = parts[0].replacingOccurrences(of: " files", with: "").replacingOccurrences(of: " file", with: "")
            fileCount = Int(countText.replacingOccurrences(of: ",", with: ""))
            sizeText = parts[1]
        }
        guard let bytes = parseSize(sizeText) else {
            return .init(path: text, bytes: nil, fileCount: nil)
        }
        return .init(path: String(text[..<open.lowerBound]), bytes: bytes, fileCount: fileCount)
    }

    static func parseSize(_ text: String) -> Int64? {
        DeveloperSizeParser.parse(text, decimal: false)
    }
}
