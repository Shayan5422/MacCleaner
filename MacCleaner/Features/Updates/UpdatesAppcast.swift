import Foundation

/// One `<item>` of a Sparkle appcast.
struct UpdatesAppcastItem: Sendable, Hashable {
    var title: String?
    /// `sparkle:version`: the build number Sparkle compares with the app's `CFBundleVersion`.
    var version: String?
    /// `sparkle:shortVersionString`: the version people see.
    var shortVersion: String?
    var minimumSystemVersion: String?
    var maximumSystemVersion: String?
    /// Non-default channels (such as "beta") are only offered to people who opt in.
    var channel: String?
    var releaseNotesURL: URL?
    var fullReleaseNotesURL: URL?
    /// `<link>`: the product or download page.
    var infoURL: URL?
    /// `<description>`: release notes embedded in the feed (usually HTML).
    var descriptionHTML: String?
    var downloadURL: URL?
    var publicationDate: Date?
    var isCritical = false
    var isInformational = false
    var phasedRolloutInterval: TimeInterval?
    var hardwareRequirements: [String] = []
    /// `sparkle:os` of the enclosure ("macos" when nil).
    var operatingSystem: String?

    var displayVersion: String { shortVersion ?? version ?? "?" }
    /// The value Sparkle compares: the build number, or the display version when no build is given.
    var comparisonVersion: String? { version ?? shortVersion }
}

/// Parses Sparkle appcasts and picks the update Sparkle itself would offer.
enum UpdatesAppcast {
    struct Evaluation: Sendable, Hashable {
        var status: UpdatesStatus
        /// The newest update this Mac can install.
        var best: UpdatesAppcastItem?
        /// A newer item that needs a newer macOS (or different hardware), if any.
        var newerIncompatible: UpdatesAppcastItem?
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static func parse(_ data: Data) throws -> [UpdatesAppcastItem] {
        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "invalid XML"
            throw UpdatesCheckError.invalidFeed(reason)
        }
        guard delegate.sawFeedRoot else { throw UpdatesCheckError.invalidFeed("the document isn't an RSS appcast.") }
        return delegate.items
    }

    /// The newest item Sparkle would offer to this Mac: default channel, macOS, and
    /// within the item's system and hardware requirements.
    static func bestItem(
        in items: [UpdatesAppcastItem],
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isAppleSilicon: Bool = UpdatesAppcast.isAppleSilicon
    ) -> UpdatesAppcastItem? {
        newest(items.filter { isOffered($0) && meetsRequirements($0, systemVersion: systemVersion, isAppleSilicon: isAppleSilicon) })
    }

    /// Compares the feed with the installed app's versions.
    static func evaluate(
        items: [UpdatesAppcastItem],
        installedBuild: String?,
        installedVersion: String?,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isAppleSilicon: Bool = UpdatesAppcast.isAppleSilicon
    ) -> Evaluation {
        let best = bestItem(in: items, systemVersion: systemVersion, isAppleSilicon: isAppleSilicon)
        let newestOverall = newest(items.filter(isOffered))

        func isNewerThanInstalled(_ item: UpdatesAppcastItem) -> Bool {
            if let build = item.version, let installedBuild, !installedBuild.isEmpty {
                return UpdatesVersionComparator.isNewer(build, than: installedBuild)
            }
            if let short = item.shortVersion ?? item.version, let installed = installedVersion ?? installedBuild {
                return UpdatesVersionComparator.isNewer(short, than: installed)
            }
            return false
        }

        var evaluation = Evaluation(status: .upToDate, best: best, newerIncompatible: nil)
        if let best, isNewerThanInstalled(best) {
            evaluation.status = .updateAvailable
        }
        if let newestOverall, newestOverall != best, isNewerThanInstalled(newestOverall) {
            let bestKey = best?.comparisonVersion ?? ""
            if let key = newestOverall.comparisonVersion, UpdatesVersionComparator.isNewer(key, than: bestKey) {
                evaluation.newerIncompatible = newestOverall
                if evaluation.status == .upToDate { evaluation.status = .incompatible }
            }
        }
        return evaluation
    }

    // MARK: - Rules

    /// Default channel, macOS enclosure, with something to install or read.
    static func isOffered(_ item: UpdatesAppcastItem) -> Bool {
        if let channel = item.channel, !channel.isEmpty { return false }
        if let os = item.operatingSystem, os.lowercased() != "macos" { return false }
        guard let key = item.comparisonVersion, !key.isEmpty else { return false }
        return item.downloadURL != nil || item.isInformational
    }

    static func meetsRequirements(_ item: UpdatesAppcastItem, systemVersion: OperatingSystemVersion, isAppleSilicon: Bool) -> Bool {
        let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        if let minimum = item.minimumSystemVersion, !minimum.isEmpty,
           UpdatesVersionComparator.compare(minimum, system) == .orderedDescending {
            return false
        }
        if let maximum = item.maximumSystemVersion, !maximum.isEmpty,
           UpdatesVersionComparator.compare(maximum, system) == .orderedAscending {
            return false
        }
        // An Apple silicon–only build can't run on an Intel Mac. (Intel-only builds
        // still run on Apple silicon under Rosetta, so Sparkle offers them.)
        let requirements = Set(item.hardwareRequirements.map { $0.lowercased() })
        if requirements.contains("arm64") && !isAppleSilicon { return false }
        return true
    }

    private static func newest(_ items: [UpdatesAppcastItem]) -> UpdatesAppcastItem? {
        items.max { lhs, rhs in
            UpdatesVersionComparator.compare(lhs.comparisonVersion ?? "", rhs.comparisonVersion ?? "") == .orderedAscending
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                       "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// Collects `<item>` elements. Delta updates (`sparkle:deltas`) and the version lists
/// inside `sparkle:informationalUpdate` / `sparkle:criticalUpdate` are not item versions.
private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [UpdatesAppcastItem] = []
    private(set) var sawFeedRoot = false

    private var current: UpdatesAppcastItem?
    private var text = ""
    private var stack: [String] = []
    private var nestedIgnoreDepth = 0
    private var enclosureVersion: String?
    private var enclosureShortVersion: String?
    private var elementVersion: String?
    private var elementShortVersion: String?
    private var releaseNotesLanguage: String?
    private var preferredLanguage = Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() } ?? "en"

    private static let ignoredContainers: Set<String> = ["sparkle:deltas", "sparkle:informationalUpdate", "sparkle:criticalUpdate"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        stack.append(elementName)
        text = ""
        switch elementName {
        case "rss", "channel", "feed":
            sawFeedRoot = true
        case "item":
            current = UpdatesAppcastItem()
            enclosureVersion = nil
            enclosureShortVersion = nil
            elementVersion = nil
            elementShortVersion = nil
        case "enclosure":
            guard nestedIgnoreDepth == 0, current != nil else { break }
            let os = attributes["sparkle:os"]
            // A Windows enclosure in a cross-platform feed isn't for this Mac.
            if let os, os.lowercased() != "macos" {
                if current?.downloadURL == nil { current?.operatingSystem = os }
                break
            }
            current?.operatingSystem = nil
            if let url = attributes["url"].flatMap({ URL(string: $0.trimmingCharacters(in: .whitespaces)) }) {
                current?.downloadURL = url
            }
            if let version = attributes["sparkle:version"], !version.isEmpty { enclosureVersion = version }
            if let short = attributes["sparkle:shortVersionString"], !short.isEmpty { enclosureShortVersion = short }
        case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink":
            releaseNotesLanguage = attributes["xml:lang"]?.lowercased()
        default:
            break
        }
        if Self.ignoredContainers.contains(elementName), current != nil {
            if elementName == "sparkle:criticalUpdate" { current?.isCritical = true }
            if elementName == "sparkle:informationalUpdate" { current?.isInformational = true }
            nestedIgnoreDepth += 1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if !stack.isEmpty { stack.removeLast() }

        if Self.ignoredContainers.contains(elementName), current != nil {
            nestedIgnoreDepth = max(0, nestedIgnoreDepth - 1)
            return
        }
        guard current != nil else { return }
        if elementName == "item" {
            finishItem()
            return
        }
        // Only direct children of <item> describe the item.
        guard nestedIgnoreDepth == 0, stack.last == "item" else { return }

        switch elementName {
        case "title":
            current?.title = value.isEmpty ? nil : value
        case "link":
            current?.infoURL = URL(string: value)
        case "description":
            current?.descriptionHTML = value.isEmpty ? nil : String(value.prefix(200_000))
        case "pubDate":
            current?.publicationDate = UpdatesAppcast.parseDate(value)
        case "sparkle:version":
            if !value.isEmpty { elementVersion = value }
        case "sparkle:shortVersionString":
            if !value.isEmpty { elementShortVersion = value }
        case "sparkle:minimumSystemVersion":
            current?.minimumSystemVersion = value.isEmpty ? nil : value
        case "sparkle:maximumSystemVersion":
            current?.maximumSystemVersion = value.isEmpty ? nil : value
        case "sparkle:channel":
            current?.channel = value.isEmpty ? nil : value
        case "sparkle:releaseNotesLink":
            assignReleaseNotes(value, full: false)
        case "sparkle:fullReleaseNotesLink":
            assignReleaseNotes(value, full: true)
        case "sparkle:phasedRolloutInterval":
            current?.phasedRolloutInterval = TimeInterval(value)
        case "sparkle:hardwareRequirements":
            current?.hardwareRequirements = value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        default:
            break
        }
    }

    private func assignReleaseNotes(_ value: String, full: Bool) {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        let existing = full ? current?.fullReleaseNotesURL : current?.releaseNotesURL
        // Prefer a link without a language or in the person's language.
        let matchesLanguage = releaseNotesLanguage == nil || releaseNotesLanguage?.hasPrefix(preferredLanguage) == true
        guard existing == nil || matchesLanguage else { return }
        if full { current?.fullReleaseNotesURL = url } else { current?.releaseNotesURL = url }
    }

    private func finishItem() {
        guard var item = current else { return }
        // Sparkle reads the enclosure attributes first and falls back to the elements.
        item.version = enclosureVersion ?? elementVersion
        item.shortVersion = enclosureShortVersion ?? elementShortVersion
        items.append(item)
        current = nil
        nestedIgnoreDepth = 0
    }
}
