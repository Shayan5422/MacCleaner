import Foundation
import Testing
import WebKit
@testable import MacCleanerMobile

/// The url-filter of each rule in a content-blocker list.
private func filters(_ json: Data) throws -> [String] {
    let rules = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: [String: String]]])
    for rule in rules { #expect(rule["action"] == ["type": "block"]) }
    return rules.compactMap { $0["trigger"]?["url-filter"] }
}

private func host(_ value: String, _ seconds: TimeInterval? = nil) -> SafariBlocklist.Candidate {
    SafariBlocklist.Candidate(kind: .host, value: value, date: seconds.map(Date.init(timeIntervalSince1970:)))
}

private func address(_ value: String, _ seconds: TimeInterval? = nil) -> SafariBlocklist.Candidate {
    SafariBlocklist.Candidate(kind: .address, value: value, date: seconds.map(Date.init(timeIntervalSince1970:)))
}

struct RegexEscapingTests {
    @Test func escapesEveryRegexCharacter() {
        #expect(SafariBlocklist.escapeForRegex(#"a.b\c^d$e|f?g*h+i(j)k[l]m{n}o"#) == #"a\.b\\c\^d\$e\|f\?g\*h\+i\(j\)k\[l\]m\{n\}o"#)
        #expect(SafariBlocklist.escapeForRegex("plain-text_1/2") == "plain-text_1/2")
    }

    @Test func hostRulesCoverSubdomainsWithEscapedDots() {
        #expect(SafariBlocklist.hostFilter("evil.com") == #"^[a-z]+://([^/]+\.)?evil\.com[:/]"#)
        #expect(SafariBlocklist.hostFilter("Bad_Sub-Domain.Evil.ORG.") == #"^[a-z]+://([^/]+\.)?bad_sub-domain\.evil\.org[:/]"#)
    }

    @Test func publicAddressesMatchExactly() {
        #expect(SafariBlocklist.hostFilter("8.8.4.4") == #"^[a-z]+://8\.8\.4\.4[:/]"#)
        #expect(SafariBlocklist.hostFilter("2606:4700::1111") == #"^[a-z]+://\[2606:4700::1111\][:/]"#)
    }

    @Test func localNamesPrivateAddressesAndJunkGetNoRule() {
        for skipped in ["localhost", "router.local", "nas.home.arpa", "printer.lan", "10.0.0.1", "192.168.1.20", "172.20.0.1",
                        "127.0.0.1", "169.254.10.10", "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fd00::1", "2001:db8::1",
                        "224.0.0.1", "not a host", "evil..com", ".evil.com", "com", ""] {
            #expect(SafariBlocklist.hostFilter(skipped) == nil, "\(skipped)")
        }
    }

    @Test func addressRulesMatchThatAddressOnAnyScheme() throws {
        let page = try #require(ThreatIntel.address("https://steamcommunity.com/profiles/76561199000000000"))
        #expect(SafariBlocklist.addressFilter(page) == #"^[a-z]+://steamcommunity\.com/profiles/76561199000000000"#)
        let download = try #require(ThreatIntel.address("http://evil.example.com:8080/get.php?id=1+2&x=(a)"))
        #expect(SafariBlocklist.addressFilter(download) == #"^[a-z]+://evil\.example\.com:8080/get\.php\?id=1\+2&x=\(a\)"#)
    }
}

struct BlocklistRuleTests {
    @Test func oneRulePerHostInLowerCase() throws {
        let rules = SafariBlocklist.rules(from: [host("Evil.com"), host("evil.com"), host("EVIL.COM."), host("other.net")])
        #expect(try filters(rules.json).sorted() == [#"^[a-z]+://([^/]+\.)?evil\.com[:/]"#, #"^[a-z]+://([^/]+\.)?other\.net[:/]"#])
        #expect(rules.siteCount == 2)
        #expect(rules.linkCount == 0)
    }

    @Test func aListedParentCoversItsSubdomainsAndKeepsTheNewerDate() throws {
        let rules = SafariBlocklist.rules(from: [host("evil.com", 100), host("cdn.evil.com", 900), host("a.b.evil.com", 50),
                                                 host("newer.net", 500)], limit: 2)
        // evil.com takes cdn.evil.com's date (900), so it outranks newer.net (500).
        #expect(try filters(rules.json) == [#"^[a-z]+://([^/]+\.)?evil\.com[:/]"#, #"^[a-z]+://([^/]+\.)?newer\.net[:/]"#])
        #expect(rules.omittedCount == 0)
    }

    @Test func addressesOnBlockedHostsAreLeftOut() throws {
        let rules = SafariBlocklist.rules(from: [
            host("evil.com"),
            address("http://www.evil.com/payload.exe"),
            host("45.95.169.105"),
            address("http://45.95.169.105/bins/x86"),
            address("https://t.me/somechannel"),
            address("https://t.me/somechannel"),
        ])
        #expect(try filters(rules.json).sorted() == [
            #"^[a-z]+://([^/]+\.)?evil\.com[:/]"#, #"^[a-z]+://45\.95\.169\.105[:/]"#, #"^[a-z]+://t\.me/somechannel"#,
        ])
        #expect(rules.siteCount == 2)
        #expect(rules.linkCount == 1)
    }

    @Test func skipsLocalAndPrivateEntries() throws {
        let rules = SafariBlocklist.rules(from: [host("localhost"), host("10.1.2.3"), address("http://192.168.0.1/admin"),
                                                 address("http://router.local/"), host("evil.com")])
        #expect(try filters(rules.json) == [#"^[a-z]+://([^/]+\.)?evil\.com[:/]"#])
    }

    @Test func keepsTheNewestWhenOverTheLimit() throws {
        let candidates = (0..<10).map { host("site\($0).evil.com", TimeInterval($0)) } + [host("undated.evil.net")]
        let rules = SafariBlocklist.rules(from: candidates, limit: 3)
        #expect(try filters(rules.json) == [9, 8, 7].map { #"^[a-z]+://([^/]+\.)?site\#($0)\.evil\.com[:/]"# })
        #expect(rules.siteCount == 3)
        #expect(rules.omittedCount == 8)
    }

    @Test func theLimitIsFiftyThousandRules() throws {
        #expect(SafariBlocklist.ruleLimit == 50_000)
        let candidates = (0..<50_010).map { host("host\($0).example-malware.com", TimeInterval($0)) }
        let rules = SafariBlocklist.rules(from: candidates)
        #expect(rules.ruleCount == 50_000)
        #expect(rules.omittedCount == 10)
        #expect(try filters(rules.json).first == #"^[a-z]+://([^/]+\.)?host50009\.example-malware\.com[:/]"#)
    }

    @Test func anEmptyListStillGivesSafariOneRule() throws {
        let rules = SafariBlocklist.rules(from: [])
        #expect(try filters(rules.json) == [SafariBlocklist.placeholderFilter])
        #expect(rules.ruleCount == 0)
    }
}

struct BlocklistCandidateTests {
    private let seen = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ kind: ThreatFoxIOC.Kind, _ value: String, confidence: Int? = 100, compromised: Bool = false,
                       firstSeen: Date? = nil) -> ThreatFoxStore.Entry {
        ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1", kind: kind, value: value, threatType: "botnet_cc", malware: nil,
                                               confidence: confidence, firstSeen: firstSeen, isCompromised: compromised),
                             lastSeen: seen)
    }

    @Test func turnsIndicatorsIntoHostsAndAddresses() {
        let reported = Date(timeIntervalSince1970: 1_799_000_000)
        let candidates = SafariBlocklist.candidates(urlhausHosts: ["urlhaus.example.com"], urlhausDate: seen, threatFox: [
            entry(.domain, "c2.example.net", firstSeen: reported),
            entry(.url, "http://203.0.113.9/bins/x86"),
            entry(.url, "https://steamcommunity.com/profiles/76561199000000000"),
            entry(.ipPort, "198.51.100.20:443"),
        ])
        #expect(Set(candidates) == [
            SafariBlocklist.Candidate(kind: .host, value: "urlhaus.example.com", date: seen),
            SafariBlocklist.Candidate(kind: .host, value: "c2.example.net", date: reported),
            SafariBlocklist.Candidate(kind: .host, value: "203.0.113.9", date: seen),
            SafariBlocklist.Candidate(kind: .address, value: "https://steamcommunity.com/profiles/76561199000000000", date: seen),
        ])
    }

    @Test func hackedSitesAndLowConfidenceIndicatorsArentBlockedWhole() {
        let candidates = SafariBlocklist.candidates(urlhausHosts: [], urlhausDate: nil, threatFox: [
            entry(.domain, "hacked-shop.example.org", compromised: true),
            entry(.url, "http://203.0.113.10/x", compromised: true),
            entry(.domain, "maybe.example.net", confidence: 25),
        ])
        #expect(candidates == [SafariBlocklist.Candidate(kind: .address, value: "http://203.0.113.10/x", date: seen)])
    }
}

/// Safari compiles the list with WebKit's content-rule compiler; a rule it rejects would stop the
/// whole list from loading.
@MainActor
struct BlocklistCompilationTests {
    @Test func webKitCompilesTheRules() async throws {
        let candidates = [
            host("evil.com"), host("bad_sub-domain.evil-site.org"), host("xn--80ak6aa92e.com"), host("8.8.4.4"),
            host("2606:4700::1111"),
            address("https://steamcommunity.com/profiles/76561199000000000"),
            address("http://evil.example.net:8080/get.php?id=1+2&x=(a)*[b]{c}|d^e$f"),
            address("http://[2606:4700::1112]:8443/x.sh"),
            address("https://t.me/s/channel%20name"),
        ]
        let rules = SafariBlocklist.rules(from: candidates)
        #expect(rules.ruleCount == candidates.count)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store: WKContentRuleListStore? = WKContentRuleListStore(url: folder)
        let list: WKContentRuleList? = try await #require(store)
            .compileContentRuleList(forIdentifier: "test", encodedContentRuleList: String(decoding: rules.json, as: UTF8.self))
        #expect(list != nil)
    }

    /// The compiler really checks: Safari's rules don't support alternatives ("a|b").
    @Test func webKitRejectsAnUnsupportedRule() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store: WKContentRuleListStore? = WKContentRuleListStore(url: folder)
        let invalid = #"[{"trigger": {"url-filter": "^https?://(a|b)\\.example\\.com/"}, "action": {"type": "block"}}]"#
        await #expect(throws: (any Error).self) {
            _ = try await #require(store).compileContentRuleList(forIdentifier: "invalid", encodedContentRuleList: invalid)
        }
    }
}
