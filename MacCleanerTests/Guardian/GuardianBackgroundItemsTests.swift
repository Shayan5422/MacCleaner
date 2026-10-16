import Foundation
import Testing
@testable import MacCleaner

/// `sfltool dumpbtm` samples. The first follows the output of macOS 27 (no "visible" word, plain
/// and bundle-relative paths, home folders printed as /Users/<uid>, "Last Use"); the second the
/// macOS 13–15 format (file:// URLs, "visible", "SharedFileList migrated"). Names are examples.
enum GuardianBTMSamples {
    static let current = """
    ========================
     Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    ========================

     ServiceManagement migrated: true
     LaunchServices registered: false

     Items:

     #1:
                     UUID: 7A1C0D52-3B7E-4E44-9B0E-1D7D3A6F1E01
                     Name: Docker Inc
           Developer Name: Docker Inc
                     Type: developer (0x20)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: Docker Inc
                      URL: (null)
               Generation: 0
      Embedded Item Identifiers:
        #1: 16.com.docker.vmnetd

     #2:
                     UUID: 2E5B1C66-0C34-4D1B-8E6A-6B3F2A1D9C02
                     Name: com.docker.vmnetd
           Developer Name: Docker Inc
          Team Identifier: 9BNSXJN65R
                     Type: legacy daemon (0x10010)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.com.docker.vmnetd
                      URL: /Library/LaunchDaemons/com.docker.vmnetd.plist
          Executable Path: /Library/PrivilegedHelperTools/com.docker.vmnetd
               Generation: 4
                 Last Use: 2026-10-16 14:36:26+02:00
        Parent Identifier: Docker Inc

    ========================
     Records for UID 501 : 3C47867B-4378-4973-9638-45A1F00D92F7
    ========================

     ServiceManagement migrated: true
     LaunchServices registered: true

     Items:

     #1:
                     UUID: 5DC8A340-7A97-4331-80F9-1CDC32CF6124
                     Name: Clicky
           Developer Name: Example Developer
          Team Identifier: EXAMPLE123
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.example.clicky
                      URL: /Users/501/Downloads/Clicky/Clicky.app
               Generation: 2
        Bundle Identifier: com.example.clicky
                 Last Use: 2026-10-16 10:28:18+02:00

     #2:
                     UUID: 8A0F3E1B-6E0C-4C2E-9D7C-2B6A1E3F4D05
                     Name: Spotify
           Developer Name: (null)
          Team Identifier: 2FNC3A47ZF
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: 2.com.spotify.client
                      URL: /Applications/Spotify.app
               Generation: 1
        Bundle Identifier: com.spotify.client
      Embedded Item Identifiers:
        #1: 4.com.spotify.client.startuphelper

     #3:
                     UUID: 0B9C2D4E-1F3A-4B5C-8D6E-7F8091A2B3C4
                     Name: StartUpHelper
           Developer Name: Spotify
          Team Identifier: 2FNC3A47ZF
                     Type: login item (0x4)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.com.spotify.client.startuphelper
                      URL: Contents/Library/LoginItems/StartUpHelper.app
               Generation: 1
        Bundle Identifier: com.spotify.client.startuphelper
        Parent Identifier: 2.com.spotify.client

     #4:
                     UUID: 1D2E3F40-5162-4738-89AB-CDEF01234567
                     Name: Example Remote - background tasks
           Developer Name: Example Remote GmbH
                     Type: background tasks (0x2000)
                    Flags: [  ] (0)
              Disposition: [enabled, disallowed, notified] (0x9)
               Identifier: 8192.com.example.remote
                      URL: (null)
               Generation: 68
        Parent Identifier: 2.com.example.remote

     #5:
                     UUID: 9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A
                     Name: redis-server
           Developer Name: (null)
                     Type: legacy agent (0x10008)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.homebrew.mxcl.redis
                      URL: /Users/501/Library/LaunchAgents/homebrew.mxcl.redis.plist
          Executable Path: /opt/homebrew/opt/redis/bin/redis-server
               Generation: 1
        Parent Identifier: Unknown Developer

     #6:
                     UUID: 4B3A2918-0716-4F5E-A4D3-C2B1A0918273
                     Name: WeatherMenu
           Developer Name: (null)
                     Type: login item (0x4)
                    Flags: [ sandboxed ] (0x40)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.com.apple.weather.menu
                      URL: Contents/Library/LoginItems/WeatherMenu.app
               Generation: 2
        Bundle Identifier: com.apple.weather.menu
        Parent Identifier: 2.com.apple.weather

     #7:
                     UUID: 6C5B4A39-2817-4F6E-8D5C-4B3A29180716
                     Name: Example Importer
           Developer Name: Example Inc
          Team Identifier: EXAMPLE456
                     Type: spotlight (0x40)
                    Flags: [ curated ] (0x4)
              Disposition: [enabled, allowed, not notified] (0x3)
               Identifier: 64.com.example.importer
                      URL: /Applications/Example.app/Contents/Library/Spotlight/Example.mdimporter
               Generation: 1
        Assoc. Bundle IDs: [ com.example.app ]
        Parent Identifier: 2.com.example.app

    ========================
     Records for UID 502 : C7DB0195-B77A-4DC9-96FB-372987D793C2
    ========================

     ServiceManagement migrated: true
     LaunchServices registered: true

     Items:

     #1:
                     UUID: 11111111-2222-3333-4444-555555555555
                     Name: Other Account App
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.example.other
                      URL: /Users/502/Applications/Other.app
        Bundle Identifier: com.example.other
    """

    static let legacy = """
    ========================
     Records for UID 501 : 4D63A2C3-6F4C-4E0B-8B66-0E1F0B29A1D2
    ========================

     ServiceManagement migrated: true
     SharedFileList migrated: true

     Items:

     #1:
                     UUID: 1C3A5E70-9B2D-4F61-8A3C-5E7092B4D6F8
                     Name: Docker
           Developer Name: Docker Inc
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 2.com.docker.docker
                      URL: file:///Applications/Docker.app/
               Generation: 2
        Bundle Identifier: com.docker.docker
        Embedded Item Identifiers:
          #1: 16.com.docker.vmnetd

     #2:
                     UUID: 3E5F7A9B-1C2D-4E3F-8A9B-0C1D2E3F4A5B
                     Name: GoogleSoftwareUpdateAgent
           Developer Name: Google LLC
          Team Identifier: EQHXZ8M8AV
                     Type: legacy agent (0x10008)
                    Flags: [ legacy ] (0x1)
              Disposition: [disabled, allowed, visible, not notified] (0x6)
               Identifier: 8.com.google.keystone.agent
                      URL: file:///Users/test/Library/LaunchAgents/com.google.keystone.agent.plist
          Executable Path: /Users/test/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent
               Generation: 1
        Assoc. Bundle IDs: [com.google.Chrome ]
        Parent Identifier: Google LLC
    """
}

struct GuardianBTMParserTests {
    private let home: (Int) -> String? = { uid in uid == 501 ? "/Users/tester" : uid == 502 ? "/Users/other" : nil }

    private func parse(_ text: String) -> (sections: [GuardianBTMUserSection], items: [GuardianBTMItem]) {
        GuardianBTMParser.parse(text, homeForUID: home)
    }

    @Test func parsesSectionsAndItemsOfTheCurrentFormat() {
        let parsed = parse(GuardianBTMSamples.current)
        #expect(parsed.sections.map(\.uid) == [-2, 501, 502])
        #expect(parsed.sections[0].properties["LaunchServices registered"] == "false")
        #expect(parsed.sections[1].itemCount == 7)
        #expect(parsed.items.count == 10)

        let daemon = parsed.items.first { $0.identifier == "16.com.docker.vmnetd" }
        #expect(daemon?.kind == .legacyDaemon)
        #expect(daemon?.typeCode == 0x10010)
        #expect(daemon?.teamIdentifier == "9BNSXJN65R")
        #expect(daemon?.flags == ["legacy"])
        #expect(daemon?.path == "/Library/LaunchDaemons/com.docker.vmnetd.plist")
        #expect(daemon?.executablePath == "/Library/PrivilegedHelperTools/com.docker.vmnetd")
        #expect(daemon?.disposition == GuardianBTMDisposition(enabled: true, allowed: true, visible: nil, notified: true, rawValue: 0xB))
        #expect(daemon?.lastUse == ISO8601DateFormatter().date(from: "2026-10-16T12:36:26Z"))
        #expect(daemon?.parentIdentifier == "Docker Inc")

        let developer = parsed.items.first { $0.kind == .developer }
        #expect(developer?.embeddedIdentifiers == ["16.com.docker.vmnetd"])
        #expect(developer?.url == nil)
        #expect(developer?.kind.isRunnable == false)
    }

    @Test func appThatRegisteredItselfIsAnActiveLoginItem() {
        let parsed = parse(GuardianBTMSamples.current)
        let clicky = parsed.items.first { $0.bundleIdentifier == "com.example.clicky" }
        #expect(clicky?.kind == .app)
        #expect(clicky?.disposition.isActive == true)
        #expect(clicky?.startsAutomatically == true)
        // Home folders are printed as /Users/<uid>.
        #expect(clicky?.path == "/Users/tester/Downloads/Clicky/Clicky.app")

        let spotify = parsed.items.first { $0.bundleIdentifier == "com.spotify.client" }
        #expect(spotify?.disposition.isActive == false)
        #expect(spotify?.developerName == nil)
    }

    @Test func bundleRelativeURLsResolveAgainstTheParentApp() {
        let parsed = parse(GuardianBTMSamples.current)
        let helper = parsed.items.first { $0.identifier == "4.com.spotify.client.startuphelper" }
        #expect(helper?.kind == .loginItem)
        #expect(helper?.url == "Contents/Library/LoginItems/StartUpHelper.app")
        #expect(helper?.path == "/Applications/Spotify.app/Contents/Library/LoginItems/StartUpHelper.app")
        // The parent isn't in the dump: the relative path stays unresolved instead of guessed.
        let weather = parsed.items.first { $0.bundleIdentifier == "com.apple.weather.menu" }
        #expect(weather?.path == nil)
        #expect(weather?.isApple == true)
        #expect(weather?.isSandboxed == true)
    }

    @Test func dispositionNegationsAndBits() {
        let tasks = parse(GuardianBTMSamples.current).items.first { $0.kind == .backgroundTasks }
        #expect(tasks?.disposition.enabled == true)
        #expect(tasks?.disposition.allowed == false)
        #expect(tasks?.disposition.isActive == false)

        #expect(GuardianBTMParser.parseDisposition("[disabled, allowed, not notified] (0x2)").notified == false)
        #expect(GuardianBTMParser.parseDisposition("[enabled, allowed, visible, notified] (0xb)").visible == true)
        let bitsOnly = GuardianBTMParser.parseDisposition("(0x3)")
        #expect(bitsOnly.enabled == true && bitsOnly.allowed == true && bitsOnly.notified == false)
    }

    @Test func associatedBundleIdentifiersAndPluginKinds() {
        let importer = parse(GuardianBTMSamples.current).items.first { $0.kind == .spotlight }
        #expect(importer?.associatedBundleIdentifiers == ["com.example.app"])
        #expect(importer?.flags == ["curated"])
        #expect(GuardianBTMKind(typeName: "quicklook", code: 0x800) == .quickLook)
        #expect(GuardianBTMKind(typeName: "dock tile", code: 0x80) == .dockTile)
        #expect(GuardianBTMKind(typeName: "agent", code: 0x8) == .agent)
        #expect(GuardianBTMKind(typeName: "daemon", code: 0x10) == .daemon)
        #expect(GuardianBTMKind(typeName: "", code: 0x10008) == .legacyAgent)
        #expect(GuardianBTMKind(typeName: "something new", code: 0x4000) == .unknown)
    }

    @Test func parsesTheOlderFormatWithFileURLs() {
        let parsed = parse(GuardianBTMSamples.legacy)
        #expect(parsed.sections.first?.properties["SharedFileList migrated"] == "true")
        let docker = parsed.items.first { $0.bundleIdentifier == "com.docker.docker" }
        #expect(docker?.path == "/Applications/Docker.app")
        #expect(docker?.disposition.visible == true)
        #expect(docker?.embeddedIdentifiers == ["16.com.docker.vmnetd"])
        let agent = parsed.items.first { $0.kind == .legacyAgent }
        #expect(agent?.path == "/Users/test/Library/LaunchAgents/com.google.keystone.agent.plist")
        #expect(agent?.disposition.enabled == false)
        #expect(agent?.associatedBundleIdentifiers == ["com.google.Chrome"])
    }

    @Test func carriageReturnsFromAppleScriptAreHandled() {
        let crText = GuardianBTMSamples.legacy.replacingOccurrences(of: "\n", with: "\r")
        let crlfText = GuardianBTMSamples.legacy.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(parse(crText).items.count == 2)
        #expect(parse(crlfText).items.count == 2)
    }

    @Test func garbageAndEmptyOutputProduceNothing() {
        #expect(parse("").items.isEmpty)
        #expect(parse("sfltool: unrecognized command\nUsage: sfltool …").sections.isEmpty)
        #expect(GuardianBTMService.looksLikeDump("Usage: sfltool csinfo|dumpbtm") == false)
    }

    @Test func helpers() {
        #expect(GuardianBTMParser.strippedIdentifier("16.com.docker.vmnetd") == "com.docker.vmnetd")
        #expect(GuardianBTMParser.strippedIdentifier("Docker Inc") == "Docker Inc")
        #expect(GuardianBTMParser.mapHome("/Users/501/Library/x.plist", uid: 501, homeForUID: home) == "/Users/tester/Library/x.plist")
        #expect(GuardianBTMParser.mapHome("/Users/5012/x", uid: 501, homeForUID: home) == "/Users/5012/x")
        #expect(GuardianBTMParser.pathFromURL("file:///Applications/My%20App.app/") == "/Applications/My App.app")
        #expect(GuardianBTMParser.keyValue("Last Use: 2026-10-16 14:36:26+02:00")?.value == "2026-10-16 14:36:26+02:00")
        #expect(GuardianBTMParser.keyValue("Embedded Item Identifiers:")?.value == "")
    }
}

struct GuardianBackgroundItemsStateTests {
    private func dump(_ text: String, date: Date) throws -> GuardianBTMDump {
        try GuardianBTMService.makeDump(text, usedAdministrator: false, date: date)
    }

    @Test func firstListHasNoNewItemsThenChangesAreMarked() throws {
        let first = GuardianBackgroundItemsState.make(dump: try dump(GuardianBTMSamples.legacy, date: Date(timeIntervalSince1970: 1_000)), previous: nil)
        #expect(first.newItemIDs.isEmpty)
        #expect(first.removedItems.isEmpty)

        let second = GuardianBackgroundItemsState.make(dump: try dump(GuardianBTMSamples.current, date: Date(timeIntervalSince1970: 2_000)), previous: first)
        #expect(second.previousDate == Date(timeIntervalSince1970: 1_000))
        #expect(second.newItemIDs.contains("501|2.com.example.clicky"))
        // The Docker app record of uid 501 disappeared; the keystone agent too.
        #expect(Set(second.removedItems.map(\.id)) == ["501|2.com.docker.docker", "501|8.com.google.keystone.agent"])
    }

    @Test func recordsSkipMacOSItemsGroupsAndOtherAccounts() throws {
        let state = GuardianBackgroundItemsState.make(dump: try dump(GuardianBTMSamples.current, date: Date()), previous: nil)
        let records = state.records(now: Date(), currentUID: 501)
        let names = Set(records.map(\.name))
        #expect(names.contains("Clicky"))
        #expect(names.contains("com.docker.vmnetd"))
        #expect(!names.contains("WeatherMenu"))       // part of macOS
        #expect(!names.contains("Docker Inc"))        // developer group
        #expect(!names.contains("Other Account App")) // another account
        #expect(!names.contains("Spotify"))           // only owns its login helper
        #expect(names.contains("StartUpHelper"))
        let clicky = records.first { $0.name == "Clicky" }
        #expect(clicky?.kind == .appLoginItem)
        #expect(clicky?.isEnabled == true)
        #expect(records.first { $0.name == "Example Remote - background tasks" }?.isEnabled == false)
        #expect(records.allSatisfy { $0.source == .registeredItems })
    }

    @Test func relevantItemsAreThisAccountAndTheSystem() throws {
        let parsed = try dump(GuardianBTMSamples.current, date: Date())
        #expect(Set(parsed.relevantItems(currentUID: 501).map(\.uid)) == [-2, 501])
    }
}

struct GuardianBTMServiceTests {
    @Test func unprivilegedDumpIsUsedWhenMacOSAllowsIt() async throws {
        let fake = GuardianFakeRunner { call in
            call.executable == GuardianBTMService.sfltool ? GuardianFakeRunner.result(GuardianBTMSamples.legacy) : GuardianFakeRunner.result(exitCode: 1)
        }
        let dump = try await GuardianBTMService.dump(runner: fake.runner)
        #expect(dump.usedAdministrator == false)
        #expect(dump.items.count == 2)
        #expect(fake.calls == [GuardianFakeRunner.Call(executable: "/usr/bin/sfltool", arguments: ["dumpbtm"])])
    }

    @Test func fallsBackToTheAdministratorPrompt() async throws {
        let fake = GuardianFakeRunner { call in
            if call.executable == GuardianBTMService.sfltool { return GuardianFakeRunner.result(error: "requires root", exitCode: 1) }
            return GuardianFakeRunner.result(GuardianBTMSamples.legacy)
        }
        let dump = try await GuardianBTMService.dump(runner: fake.runner)
        #expect(dump.usedAdministrator == true)
        #expect(fake.calls.count == 2)
        #expect(fake.calls[1].executable == "/usr/bin/osascript")
        #expect(fake.calls[1].arguments == ["-e", "do shell script \"/usr/bin/sfltool dumpbtm\" with administrator privileges without altering line endings"])
    }

    @Test func cancellingThePasswordPromptIsReportedAsCancelled() async {
        let fake = GuardianFakeRunner { call in
            call.executable == GuardianBTMService.sfltool
                ? GuardianFakeRunner.result(exitCode: 1)
                : GuardianFakeRunner.result(error: "0:47: execution error: User canceled. (-128)", exitCode: 1)
        }
        await #expect(throws: GuardianBTMError.cancelled) {
            _ = try await GuardianBTMService.dump(runner: fake.runner)
        }
    }

    @Test func neverPromptsWhenNotAllowed() async {
        let fake = GuardianFakeRunner { _ in GuardianFakeRunner.result(exitCode: 1) }
        await #expect(throws: GuardianBTMError.self) {
            _ = try await GuardianBTMService.dump(runner: fake.runner, allowAdministratorPrompt: false)
        }
        #expect(fake.calls.map(\.executable) == ["/usr/bin/sfltool"])
    }
}
