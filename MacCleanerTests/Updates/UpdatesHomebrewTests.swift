import Foundation
import Testing
@testable import MacCleaner

struct UpdatesHomebrewTests {
    /// Trimmed output of `brew info --cask --installed --json=v2`.
    private static let info = """
    {
      "formulae": [],
      "casks": [
        {
          "token": "mongodb-compass",
          "full_token": "mongodb-compass",
          "name": ["MongoDB Compass"],
          "version": "1.52.0",
          "installed": "1.47.1",
          "outdated": false,
          "auto_updates": true,
          "homepage": "https://www.mongodb.com/products/compass",
          "artifacts": [
            {"uninstall": [{"quit": "com.mongodb.compass"}]},
            {"app": ["MongoDB Compass.app"], "target": "/Applications/MongoDB Compass.app"},
            {"zap": [{"trash": ["~/Library/Application Support/MongoDB Compass"]}]}
          ]
        },
        {
          "token": "wine-stable",
          "full_token": "wine-stable",
          "name": ["WineHQ-stable"],
          "version": "11.0_1",
          "installed": "9.0_3",
          "outdated": true,
          "auto_updates": null,
          "artifacts": [
            {"app": ["Wine Stable.app"]},
            {"binary": ["/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine"], "target": "/opt/homebrew/bin/wine"}
          ]
        },
        {
          "token": "renamed-tool",
          "full_token": "someone/tap/renamed-tool",
          "name": ["Renamed Tool"],
          "version": "2.0.0,456",
          "installed": "2.0.0,456",
          "outdated": false,
          "auto_updates": false,
          "artifacts": [
            {"app": ["Tool.app", {"target": "Renamed Tool.app"}]}
          ]
        },
        {
          "token": "nightly-thing",
          "full_token": "nightly-thing",
          "name": ["Nightly Thing"],
          "version": "latest",
          "installed": "latest",
          "artifacts": [{"app": ["Nightly Thing.app"]}]
        },
        {
          "token": "cli-only",
          "full_token": "cli-only",
          "name": [],
          "version": "1.0",
          "installed": "1.0",
          "artifacts": [{"binary": ["cli"]}]
        }
      ]
    }
    """

    /// Output of `brew outdated --cask --greedy --json=v2`.
    private static let outdated = """
    {
      "formulae": [],
      "casks": [
        {"name": "mongodb-compass", "installed_versions": ["1.47.1"], "current_version": "1.52.0", "pinned": false, "pinned_version": null},
        {"name": "wine-stable", "installed_versions": ["9.0_3"], "current_version": "11.0_1", "pinned": false, "pinned_version": null}
      ]
    }
    """

    private func casks() throws -> [UpdatesHomebrewCask] {
        let parsed = try UpdatesHomebrew.parseInfo(Data(Self.info.utf8), homeDirectory: "/Users/tester")
        let entries = try UpdatesHomebrew.parseOutdated(Data(Self.outdated.utf8))
        return UpdatesHomebrew.merge(parsed, outdated: entries)
    }

    @Test func parsesInstalledCasksAndAppLocations() throws {
        let parsed = try UpdatesHomebrew.parseInfo(Data(Self.info.utf8), homeDirectory: "/Users/tester")
        #expect(parsed.map(\.token) == ["mongodb-compass", "wine-stable", "renamed-tool", "nightly-thing", "cli-only"])
        let compass = try #require(parsed.first)
        #expect(compass.appPaths == ["/Applications/MongoDB Compass.app"])
        #expect(compass.autoUpdates)
        #expect(compass.installedVersion == "1.47.1")
        #expect(compass.homepage == URL(string: "https://www.mongodb.com/products/compass"))
        #expect(parsed[1].appPaths == ["/Applications/Wine Stable.app"])
        #expect(parsed[2].appPaths == ["/Applications/Renamed Tool.app"])
        #expect(parsed[2].upgradeToken == "someone/tap/renamed-tool")
        #expect(parsed[3].isUnversioned)
        #expect(parsed[4].appPaths.isEmpty)
    }

    @Test func parsesOutdatedListAndMerges() throws {
        let entries = try UpdatesHomebrew.parseOutdated(Data(Self.outdated.utf8))
        #expect(entries.map(\.token) == ["mongodb-compass", "wine-stable"])
        #expect(entries[1].installedVersions == ["9.0_3"])
        let merged = try casks()
        #expect(merged[0].isOutdated && merged[0].latestVersion == "1.52.0")
        #expect(merged[1].isOutdated)
        #expect(!merged[2].isOutdated)
    }

    @Test func fallbackWhenOutdatedCantBeRead() throws {
        let parsed = try UpdatesHomebrew.parseInfo(Data(Self.info.utf8), homeDirectory: "/Users/tester")
        let marked = UpdatesHomebrew.markingOutdatedByRecord(parsed)
        #expect(marked[0].isOutdated, "1.47.1 recorded, 1.52.0 in the catalog")
        #expect(!marked[2].isOutdated)
        #expect(!marked[3].isOutdated, "Unversioned casks can't be compared")
    }

    @Test func matchesCasksToInstalledApps() throws {
        let matched = UpdatesHomebrew.match(
            casks: try casks(),
            appPaths: ["/Applications/MongoDB Compass.app", "/Applications/Wine Stable.app", "/Applications/Other.app"]
        )
        #expect(matched["/Applications/MongoDB Compass.app"]?.token == "mongodb-compass")
        #expect(matched["/Applications/Wine Stable.app"]?.token == "wine-stable")
        #expect(matched["/Applications/Other.app"] == nil)
    }

    @Test func evaluationUsesTheRealAppVersion() throws {
        let all = try casks()
        // brew's record is old, but an app that updates itself may already be current.
        let selfUpdated = UpdatesHomebrew.evaluate(cask: all[0], installedShortVersion: "1.52.0", installedBuildVersion: nil)
        #expect(selfUpdated.status == .upToDate)
        let behind = UpdatesHomebrew.evaluate(cask: all[0], installedShortVersion: "1.47.1", installedBuildVersion: nil)
        #expect(behind.status == .updateAvailable)
        #expect(behind.latest == "1.52.0")
        // Homebrew revision suffixes ("_1") don't count as a newer app.
        #expect(UpdatesHomebrew.evaluate(cask: all[1], installedShortVersion: "11.0", installedBuildVersion: nil).status == .upToDate)
        #expect(UpdatesHomebrew.evaluate(cask: all[1], installedShortVersion: "9.0", installedBuildVersion: nil).status == .updateAvailable)
        // Not outdated: current. Build suffix after the comma is dropped for display.
        let current = UpdatesHomebrew.evaluate(cask: all[2], installedShortVersion: "2.0.0", installedBuildVersion: "456")
        #expect(current.status == .upToDate)
        #expect(current.latest == "2.0.0")
        // "latest" casks have no version to compare.
        #expect(UpdatesHomebrew.evaluate(cask: all[3], installedShortVersion: "1.0", installedBuildVersion: nil).status == .unknown)
    }

    @Test func upgradeCommandsOnlyUseSafeTokens() throws {
        let all = try casks()
        #expect(all[0].upgradeArguments == ["upgrade", "--cask", "mongodb-compass"])
        #expect(all[0].upgradeCommand == "brew upgrade --cask mongodb-compass")
        #expect(all[0].hasSafeToken)
        var hostile = all[0]
        hostile.token = "x; rm -rf ~"
        hostile.fullToken = hostile.token
        #expect(!hostile.hasSafeToken)
        hostile.token = "--force"
        hostile.fullToken = hostile.token
        #expect(!hostile.hasSafeToken)
    }

    @Test func invalidJSONThrows() {
        #expect(throws: (any Error).self) { try UpdatesHomebrew.parseInfo(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try UpdatesHomebrew.parseOutdated(Data("[]".utf8)) }
    }
}
