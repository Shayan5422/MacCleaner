import Foundation
import Testing
@testable import MacCleaner

@Suite("System Junk scanner")
struct SystemJunkScannerTests {
    private func makeScanner(home: TemporaryTree, temporary: String? = nil) -> SystemJunkScanner {
        var locations = SystemJunkScanner.Locations(home: home.root, temporaryDirectory: temporary)
        locations.sharedTemporaryDirectory = nil
        return SystemJunkScanner(locations: locations, includeAppContainers: true, ownBundleIdentifier: "com.maccleaner.MacCleaner")
    }

    @Test func findsAndClassifiesCaches() async throws {
        let home = try TemporaryTree("Home")
        try home.makeFile("Library/Caches/com.example.editor/blob", size: 200_000)
        try home.makeFile("Library/Caches/com.apple.helpd/index", size: 50_000)
        try home.makeFile("Library/Caches/Google/Chrome/Default/Cache/data", size: 80_000) // owned by Privacy
        try home.makeFile("Library/Caches/com.maccleaner.MacCleaner/own", size: 80_000)  // our own cache
        try home.makeFile("Library/Containers/com.example.sandboxed/Data/Library/Caches/thumbs/a", size: 40_000)

        let results = try await makeScanner(home: home).scan(
            categories: [JunkCategory.applicationCaches.id, JunkCategory.systemCaches.id],
            preferences: ScanPreferences()
        )
        let app = try #require(results.first { $0.category == .applicationCaches })
        let system = try #require(results.first { $0.category == .systemCaches })
        #expect(Set(app.candidates.map { ($0.path as NSString).lastPathComponent }) == ["com.example.editor", "thumbs"])
        #expect(app.candidates.allSatisfy { $0.safety == .safe && $0.purpose == .junk })
        #expect(system.candidates.map(\.title) == ["com.apple.helpd"])
        #expect(system.candidates.allSatisfy { $0.safety == .review }, "macOS caches are never pre-selected")
    }

    @Test func logAgeRuleMarksRecentLogsForReview() async throws {
        let home = try TemporaryTree("Home")
        let old = Date().addingTimeInterval(-30 * 86_400)
        try home.makeFile("Library/Logs/OldApp/old.log", size: 20_000, modified: old)
        try home.setModified(home.path("Library/Logs/OldApp"), old)
        try home.makeFile("Library/Logs/BusyApp/today.log", size: 20_000)
        var preferences = ScanPreferences()
        preferences.logAgeDays = 7
        let results = try await makeScanner(home: home).scan(categories: [JunkCategory.logs.id], preferences: preferences)
        let logs = try #require(results.first)
        let byTitle = Dictionary(uniqueKeysWithValues: logs.candidates.map { ($0.title, $0) })
        #expect(byTitle["OldApp"]?.safety == .safe)
        #expect(byTitle["BusyApp"]?.safety == .review)
    }

    @Test func recentTemporaryFilesAreNeverOffered() async throws {
        let home = try TemporaryTree("Home")
        let temp = try TemporaryTree("Temp")
        try temp.makeFile("fresh/data", size: 30_000)
        try temp.makeFile("stale/data", size: 30_000, modified: Date().addingTimeInterval(-10 * 86_400))
        try temp.setModified(temp.path("stale"), Date().addingTimeInterval(-10 * 86_400))
        let results = try await makeScanner(home: home, temporary: temp.root).scan(categories: [JunkCategory.temporaryFiles.id], preferences: ScanPreferences())
        #expect(results.first?.candidates.map(\.title) == ["stale"])
    }

    @Test func downloadsAreReviewOnlyPersonalFiles() async throws {
        let home = try TemporaryTree("Home")
        let old = Date().addingTimeInterval(-400 * 86_400)
        try home.makeFile("Downloads/Setup.dmg", size: 100_000, modified: old)
        try home.makeFile("Downloads/old-report.pdf", size: 100_000, modified: old)
        try home.makeFile("Downloads/new-report.pdf", size: 100_000)
        let results = try await makeScanner(home: home).scan(
            categories: [JunkCategory.installers.id, JunkCategory.oldDownloads.id], preferences: ScanPreferences()
        )
        let all = results.flatMap(\.candidates)
        #expect(Set(all.map(\.title)) == ["Setup.dmg", "old-report.pdf"])
        #expect(all.allSatisfy { $0.purpose == .userFile && $0.safety == .review })
    }

    @Test func derivedDataShowsProjectNames() async throws {
        let home = try TemporaryTree("Home")
        let folder = try home.makeDirectory("Library/Developer/Xcode/DerivedData/Demo-abcdefgh")
        try home.makeFile("Library/Developer/Xcode/DerivedData/Demo-abcdefgh/Build/Products/x.o", size: 90_000)
        let info: [String: Any] = ["WorkspacePath": "/Users/nobody/Projects/Demo.xcodeproj"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: folder + "/info.plist"))
        let results = try await makeScanner(home: home).scan(categories: [JunkCategory.xcodeBuildData.id], preferences: ScanPreferences())
        let candidate = try #require(results.first?.candidates.first)
        #expect(candidate.title == "Demo")
        #expect(candidate.detail?.contains("Project no longer exists") == true)
    }

    @Test func exclusionsAreRespected() async throws {
        let home = try TemporaryTree("Home")
        try home.makeFile("Library/Caches/com.example.keep/blob", size: 50_000)
        var preferences = ScanPreferences()
        preferences.exclusions = ExclusionList(paths: [home.path("Library/Caches/com.example.keep")])
        let results = try await makeScanner(home: home).scan(categories: [JunkCategory.applicationCaches.id], preferences: preferences)
        #expect(results.isEmpty)
    }

    @Test func everyCandidatePassesTheSafetyPolicy() async throws {
        let home = try TemporaryTree("Home")
        try home.makeFile("Library/Caches/com.example.a/x", size: 20_000)
        try home.makeFile("Library/Logs/App/x.log", size: 20_000)
        try home.makeFile("Library/Logs/DiagnosticReports/App-2026-01-02-030405.ips", size: 20_000)
        try home.makeFile("Library/Saved Application State/com.example.a.savedState/data.data", size: 20_000)
        let results = try await makeScanner(home: home).scan(preferences: ScanPreferences())
        let policy = makePolicy(home: home.root)
        for candidate in results.flatMap(\.candidates) {
            #expect(policy.evaluate(path: candidate.path, purpose: candidate.purpose).isAllowed, "\(candidate.path)")
        }
    }

    @Test func crashReportNamesAreParsed() {
        let scanner = SystemJunkScanner(locations: .init(home: "/tmp"), includeAppContainers: false, ownBundleIdentifier: nil)
        let (app, date) = scanner.parseCrashReportName("Final Cut Pro-2026-03-14-101530.ips")
        #expect(app == "Final Cut Pro")
        #expect(Calendar.current.component(.day, from: try! #require(date)) == 14)
    }
}

@Suite("Smart Scan merging")
struct SmartScanMergerTests {
    private func candidate(_ path: String, area: String, bytes: Int64, safety: CleanupSafety = .safe) -> CleanupCandidate {
        var usage = DiskUsage()
        usage.allocatedBytes = bytes
        usage.reclaimableBytes = bytes
        return CleanupCandidate(path: path, categoryID: area, categoryTitle: area, usage: usage, snapshot: nil, safety: safety, purpose: .junk)
    }

    @Test func sameItemFromSeveralAreasIsCountedOnce() {
        let junk = SmartScanContribution(area: .junk, candidates: [candidate("/x/cache", area: "junk", bytes: 100)])
        let developer = SmartScanContribution(area: .developer, candidates: [candidate("/x/cache", area: "dev", bytes: 100), candidate("/y", area: "dev", bytes: 5)])
        let merged = SmartScanMerger.merge([developer, junk])
        #expect(merged.candidates.count == 2)
        #expect(merged.candidates.first { $0.path == "/x/cache" }?.categoryID == "junk", "higher-priority area wins")
        #expect(merged.duplicatesRemoved == 1)
    }

    @Test func nestedItemsDontInflateTotals() {
        let items = [candidate("/a", area: "c", bytes: 100), candidate("/a/b", area: "c", bytes: 40), candidate("/c", area: "c", bytes: 10)]
        #expect(SmartScanMerger.reclaimableBytes(items) == 110)
    }

    @Test func findingsAreSortedBySeverity() {
        let findings = [
            Finding(area: .security, severity: .info, title: "a", detail: ""),
            Finding(area: .security, severity: .threat, title: "b", detail: ""),
            Finding(area: .startup, severity: .recommendation, title: "c", detail: ""),
        ]
        let merged = SmartScanMerger.merge([SmartScanContribution(area: .security, findings: findings)])
        #expect(merged.findings.map(\.severity) == [.threat, .recommendation, .info])
    }
}
