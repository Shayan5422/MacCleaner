import Foundation

/// Developer tools whose caches and build products Mac Cleaner understands.
enum DeveloperToolKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case xcode, simulators, swiftPM, cocoaPods, carthage
    case homebrew, npm, pnpm, yarn, bun, pip, uv, go, cargo
    case docker, gradle, maven, temporaryFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcode: return "Xcode"
        case .simulators: return "Simulators"
        case .swiftPM: return "Swift Package Manager"
        case .cocoaPods: return "CocoaPods"
        case .carthage: return "Carthage"
        case .homebrew: return "Homebrew"
        case .npm: return "npm"
        case .pnpm: return "pnpm"
        case .yarn: return "Yarn"
        case .bun: return "Bun"
        case .pip: return "pip"
        case .uv: return "uv"
        case .go: return "Go"
        case .cargo: return "Cargo"
        case .docker: return "Docker"
        case .gradle: return "Gradle"
        case .maven: return "Maven"
        case .temporaryFiles: return "Temporary Build Files"
        }
    }

    var symbol: String {
        switch self {
        case .xcode: return "hammer"
        case .simulators: return "iphone"
        case .swiftPM: return "swift"
        case .cocoaPods: return "leaf"
        case .carthage: return "cart"
        case .homebrew: return "mug"
        case .npm: return "n.square"
        case .pnpm: return "p.square"
        case .yarn: return "y.square"
        case .bun: return "b.square"
        case .pip: return "p.circle"
        case .uv: return "u.square"
        case .go: return "g.square"
        case .cargo: return "shippingbox"
        case .docker: return "cube.transparent"
        case .gradle: return "g.circle"
        case .maven: return "m.square"
        case .temporaryFiles: return "clock.arrow.circlepath"
        }
    }

    /// One-line description of what Mac Cleaner looks at for this tool.
    var summary: String {
        switch self {
        case .xcode: return "Build products, archives, device support files and caches"
        case .simulators: return "Simulator runtimes, unavailable devices and caches"
        case .swiftPM: return "Downloaded package repositories"
        case .cocoaPods: return "Downloaded pods and spec repositories"
        case .carthage: return "Downloaded dependencies"
        case .homebrew: return "Old versions and cached downloads"
        case .npm: return "Package download cache"
        case .pnpm: return "Content-addressable package store"
        case .yarn: return "Package download cache"
        case .bun: return "Package download cache"
        case .pip: return "Downloaded wheels and HTTP cache"
        case .uv: return "Package and build cache"
        case .go: return "Build cache and module cache"
        case .cargo: return "Downloaded crates and sources"
        case .docker: return "Build cache, unused images and stopped containers"
        case .gradle: return "Dependency cache, wrapper distributions and daemon logs"
        case .maven: return "Local dependency repository"
        case .temporaryFiles: return "Leftover temporary folders from build tools"
        }
    }
}

/// A file or folder removed as part of a developer item.
struct DeveloperFileTarget: Sendable, Hashable {
    var path: String
    var snapshot: FileSnapshot?
    var usage: DiskUsage
}

/// An official command-line cleanup command, shown to people exactly as it runs.
struct DeveloperCommand: Sendable, Hashable {
    /// Absolute path of the executable that runs.
    var executable: String
    /// The name people type, such as "brew" or "xcrun".
    var displayName: String
    var arguments: [String]
    /// Variables added to the standard tool environment.
    var environment: [String: String] = [:]
    var timeout: TimeInterval

    /// The command as people would type it in Terminal.
    var commandLine: String {
        ([displayName] + arguments.map(Self.quoted)).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One thing that can be cleaned: files removed through the cleanup engine, or
/// an official command run after confirmation.
struct DeveloperItem: Identifiable, Sendable, Hashable {
    enum Action: Sendable, Hashable {
        case delete([DeveloperFileTarget])
        case command(DeveloperCommand)
    }

    var id: String
    var tool: DeveloperToolKind
    /// Section inside the tool's card ("DerivedData", "Archives"...).
    var group: String
    var title: String
    var detail: String?
    /// What the data is.
    var explanation: String
    /// When and how it comes back.
    var regeneration: String
    var safety: CleanupSafety
    var action: Action
    /// Estimated space freed.
    var bytes: Int64
    /// The real amount may be smaller (shown as "up to").
    var sizeIsUpperBound = false
    /// Included in totals; false for alternatives that overlap other items.
    var countsTowardTotal = true
    /// Folder or file to reveal in Finder.
    var path: String?
    /// Extra warning shown before cleaning.
    var warning: String?
    /// Destructive commands need an explicit acknowledgement.
    var requiresAcknowledgement = false
    /// Never deleted immediately, only moved to the Trash (for example archives).
    var trashOnly = false
    var date: Date?
    /// "Always Exclude" makes sense for this item's path (not for a shared parent folder).
    var canExclude = true

    var targets: [DeveloperFileTarget] {
        if case .delete(let targets) = action { return targets }
        return []
    }

    var command: DeveloperCommand? {
        if case .command(let command) = action { return command }
        return nil
    }

    var isFileItem: Bool { command == nil }

    var cleanupItems: [CleanupItem] {
        targets.map {
            CleanupItem(path: $0.path, purpose: .developerData, snapshot: $0.snapshot, estimatedBytes: $0.usage.reclaimableBytes, category: tool.title + " — " + group)
        }
    }

    /// Single-path file items as a design-system candidate (Smart Scan).
    var candidate: CleanupCandidate? {
        guard let target = targets.first, targets.count == 1 else { return nil }
        return CleanupCandidate(
            path: target.path,
            title: title,
            detail: detail,
            categoryID: "developer." + tool.rawValue,
            categoryTitle: tool.title,
            usage: target.usage,
            snapshot: target.snapshot,
            safety: safety,
            purpose: .developerData,
            modificationDate: date
        )
    }
}

/// Information or a warning shown in a tool's card.
struct DeveloperNote: Identifiable, Sendable, Hashable {
    enum Style: Sendable, Hashable {
        case info, warning
    }

    var style: Style
    var message: String
    var id: String { message }

    static func info(_ message: String) -> DeveloperNote { DeveloperNote(style: .info, message: message) }
    static func warning(_ message: String) -> DeveloperNote { DeveloperNote(style: .warning, message: message) }
}

/// Everything found for one installed tool.
struct DeveloperToolReport: Identifiable, Sendable {
    var tool: DeveloperToolKind
    /// Where the tool was found (executable or app), for display.
    var location: String?
    var items: [DeveloperItem]
    var notes: [DeveloperNote]

    var id: String { tool.rawValue }

    var recoverableBytes: Int64 {
        items.filter { $0.countsTowardTotal && !$0.sizeIsUpperBound }.reduce(0) { $0 + $1.bytes }
    }

    var possibleExtraBytes: Int64 {
        items.filter { $0.countsTowardTotal && $0.sizeIsUpperBound }.reduce(0) { $0 + $1.bytes }
    }

    /// Item groups in the order they were found.
    var groups: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }
}

/// Result of a developer tools scan.
struct DeveloperScanResult: Sendable {
    var reports: [DeveloperToolReport] = []
    /// Tools that weren't found on this Mac.
    var missingTools: [DeveloperToolKind] = []
    var isXcodeRunning = false
    var date = Date()

    var recoverableBytes: Int64 { reports.reduce(0) { $0 + $1.recoverableBytes } }
}
