import Foundation
import Testing
@testable import MacCleaner

struct SecurityPUARulesTests {
    @Test func exactIdentifiersAreThreats() throws {
        let match = try #require(SecurityPUARules.match(identifier: "com.genieo.engine"))
        #expect(match.strength == .exact)
        #expect(match.severity == .threat)
        #expect(match.rule.family == "Genieo")
        #expect(match.ruleTitle == "Known adware/PUP rule match: Genieo")
    }

    @Test func matchingIsCaseInsensitive() throws {
        let match = try #require(SecurityPUARules.match(identifier: "COM.MACKEEPER.MACKEEPER"))
        #expect(match.strength == .exact)
        #expect(match.rule.family == "MacKeeper")
    }

    @Test func vendorPrefixesAreOnlySuspicious() throws {
        let match = try #require(SecurityPUARules.match(identifier: "com.genieo.something-new"))
        #expect(match.strength == .prefix)
        #expect(match.severity == .suspicious)
        #expect(match.ruleTitle == "Matches the naming pattern of Genieo")

        let pcv = try #require(SecurityPUARules.match(identifier: "com.pcv.newhelper"))
        #expect(pcv.strength == .prefix)
        let documented = try #require(SecurityPUARules.match(identifier: "com.pcv.hlpramc"))
        #expect(documented.strength == .exact)
    }

    @Test(arguments: [
        "com.apple.Safari", "com.google.Chrome", "com.vsearchengine.app", "com.genie.helper",
        "com.mackeeperish.tool", "com.zeobitx.agent", "", "org.mozilla.firefox", "com.conduitlabs.app",
    ])
    func unrelatedIdentifiersDontMatch(identifier: String) {
        #expect(SecurityPUARules.match(identifier: identifier) == nil)
    }

    @Test func documentedPathsAndTheirContentsMatchExactly() throws {
        let app = try #require(SecurityPUARules.match(path: "/Applications/MacKeeper.app", home: "/Users/test"))
        #expect(app.strength == .exact)
        let inside = try #require(SecurityPUARules.match(path: "/Library/Application Support/VSearch/agent.bin", home: "/Users/test"))
        #expect(inside.rule.id == "vsearch")
        let userFolder = try #require(SecurityPUARules.match(path: "/Users/test/Library/Application Support/Genieo/data", home: "/Users/test"))
        #expect(userFolder.rule.id == "genieo")
        #expect(SecurityPUARules.match(path: "/Applications/MacKeeperLite.app", home: "/Users/test") == nil)
        #expect(SecurityPUARules.match(path: "/Users/other/Library/Application Support/Genieo", home: "/Users/test") == nil)
    }

    @Test func installedKnownPathsUseTheInjectedFileSystem() {
        let present: Set<String> = ["/Library/Frameworks/VSearch.framework", "/Users/test/Library/Application Support/MacKeeper Helper"]
        let matches = SecurityPUARules.installedKnownPaths(home: "/Users/test", exists: { present.contains($0) })
        #expect(Set(matches.map(\.matchedValue)) == present)
        #expect(matches.allSatisfy { $0.strength == .exact && $0.severity == .threat })
    }

    @Test func knownPathFindingsSkipItemsAlreadyReported() {
        let matches = SecurityPUARules.installedKnownPaths(home: "/Users/test", exists: { $0 == "/Library/LaunchDaemons/Jack.plist" || $0 == "/Applications/Genieo.app" })
        let findings = SecurityScanner.knownPathFindings(matches, alreadyFlagged: ["/Library/LaunchDaemons/Jack.plist"], home: "/Users/test")
        #expect(findings.count == 1)
        #expect(findings.first?.path == "/Applications/Genieo.app")
        #expect(findings.first?.severity == .threat)
        #expect(findings.first?.remediation == .application(path: "/Applications/Genieo.app"))
    }

    @Test func rulesAreWellFormed() {
        for rule in SecurityPUARules.all {
            #expect(!rule.family.isEmpty)
            #expect(rule.identifierPrefixes.allSatisfy { $0.hasSuffix(".") && $0 == $0.lowercased() })
            #expect(rule.knownPaths.allSatisfy { $0.hasPrefix("/") || $0.hasPrefix("~/") })
            #expect(!rule.exactIdentifiers.isEmpty || !rule.identifierPrefixes.isEmpty || !rule.knownPaths.isEmpty)
        }
        #expect(Set(SecurityPUARules.all.map(\.id)).count == SecurityPUARules.all.count)
    }
}
