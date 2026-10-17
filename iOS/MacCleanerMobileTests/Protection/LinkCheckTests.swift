import Foundation
import Testing
@testable import MacCleanerMobile

struct LinkNormalizationTests {
    @Test func addsASchemeLowercasesTheHostAndDropsWWW() throws {
        let link = try #require(CheckedLink("  WWW.Example.COM/Some/Path?Q=1#top "))
        #expect(link.url == "https://example.com/Some/Path?Q=1")
        #expect(link.host == "example.com")
        #expect(link.originalHost == "www.example.com")
        #expect(link.display == "example.com/Some/Path?Q=1")
    }

    @Test func keepsTheTypedScheme() throws {
        #expect(CheckedLink("http://evil.example.net/x")?.url == "http://evil.example.net/x")
        #expect(CheckedLink("HTTPS://evil.example.net")?.url == "https://evil.example.net/")
    }

    @Test func aBareDomainDisplaysWithoutASlash() {
        #expect(CheckedLink("example.com")?.display == "example.com")
        #expect(CheckedLink("example.com:8080")?.display == "example.com:8080")
    }

    @Test func dropsCredentialsDefaultPortsAndFragments() {
        #expect(CheckedLink("https://user:pass@example.com:443/a#b")?.url == "https://example.com/a")
        #expect(CheckedLink("http://example.com:8080/a")?.url == "http://example.com:8080/a")
    }

    @Test func findsTheLinkInPastedText() {
        #expect(CheckedLink("Your parcel is waiting: https://parcel-help.example.net/track?id=5 reply STOP")?.url
            == "https://parcel-help.example.net/track?id=5")
        #expect(CheckedLink("<https://example.com/x>")?.url == "https://example.com/x")
    }

    @Test func readsAddressesAndInternationalNames() throws {
        #expect(CheckedLink("203.0.113.9:8080/i")?.isIPAddress == true)
        #expect(CheckedLink("http://[2001:DB8::1]/x")?.host == "2001:db8::1")
        let international = try #require(CheckedLink("https://bücher.example/"))
        #expect(international.host == "xn--bcher-kva.example")
    }

    @Test func rejectsWhatIsntALink() {
        for text in ["", "   ", "hello", "not a link at all", "javascript:alert(1)", "mailto:", "http://", "http://evil..com/"] {
            #expect(CheckedLink(text) == nil, "\(text)")
        }
    }

    @Test func recognizesLocalAddresses() {
        #expect(CheckedLink("192.168.1.1")?.isLocal == true)
        #expect(CheckedLink("http://localhost.localdomain:3000")?.isLocal == true)
        #expect(CheckedLink("router.local")?.isLocal == true)
        #expect(CheckedLink("http://[::1]/")?.isLocal == true)
        #expect(CheckedLink("example.com")?.isLocal == false)
        #expect(CheckedLink("8.8.8.8")?.isLocal == false)
    }
}

struct LinkMatchingTests {
    private let index = ThreatIndex(
        urlhausHosts: ["malware-host.example.com", "www.only-www.example.net"],
        urlhausAddresses: [
            "http://shared-host.example.org/files/payload.exe",
            "http://45.95.169.105:4321/i",
        ],
        threatFox: [
            ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1601001", kind: .domain, value: "c2.evil-domain.com", threatType: "botnet_cc",
                                                   malware: "Vidar", confidence: 100,
                                                   firstSeen: Date(timeIntervalSince1970: 1_792_225_800)),
                                 lastSeen: Date(timeIntervalSince1970: 1_792_300_000)),
            ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1601005", kind: .domain, value: "hacked-shop.example.org",
                                                   threatType: "payload_delivery", confidence: 50, isCompromised: true),
                                 lastSeen: Date(timeIntervalSince1970: 1_792_300_000)),
            ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1601008", kind: .url, value: "https://hacked-shop.example.org/wp-content/x.js",
                                                   threatType: "payload_delivery", confidence: 75, isCompromised: true),
                                 lastSeen: Date(timeIntervalSince1970: 1_792_300_000)),
            ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1601003", kind: .ipPort, value: "185.220.101.4:443", threatType: "botnet_cc",
                                                   malware: "Cobalt Strike", confidence: 100),
                                 lastSeen: Date(timeIntervalSince1970: 1_792_300_000)),
            ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1601009", kind: .domain, value: "both.example.com", threatType: "botnet_cc",
                                                   confidence: 100),
                                 lastSeen: Date(timeIntervalSince1970: 1_792_300_000)),
        ] + [
            ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "1601010", kind: .domain, value: "unsure.example.com", threatType: "botnet_cc",
                                                   confidence: 25),
                                 lastSeen: Date(timeIntervalSince1970: 1_792_300_000)),
        ]
    )

    private func verdict(_ text: String) -> LinkVerdict? {
        CheckedLink(text).map(index.verdict(for:))
    }

    private func scope(_ text: String) -> LinkMatch.Scope? {
        if case .listed(let match)? = verdict(text) { return match.scope }
        return nil
    }

    @Test func matchesTheExactAddressOnEitherScheme() {
        #expect(scope("http://shared-host.example.org/files/payload.exe") == .address)
        #expect(scope("https://www.shared-host.example.org/files/payload.exe") == .address)
        #expect(scope("shared-host.example.org/files/payload.exe") == .address)
    }

    @Test func otherPagesOfAHostWithOneBadAddressArentListed() {
        #expect(verdict("http://shared-host.example.org/") == .notListed)
        #expect(verdict("http://shared-host.example.org/files/payload.exe.txt") == .notListed)
    }

    @Test func matchesAListedDomainAndItsSubdomains() {
        #expect(scope("malware-host.example.com") == .host("malware-host.example.com"))
        #expect(scope("https://cdn.malware-host.example.com/a/b") == .host("malware-host.example.com"))
        #expect(scope("www.c2.evil-domain.com") == .host("c2.evil-domain.com"))
        #expect(verdict("example.com") == .notListed)
        #expect(verdict("evil-domain.com") == .notListed)
    }

    @Test func wwwMatchesBothWays() {
        #expect(scope("only-www.example.net") == .host("www.only-www.example.net"))
        #expect(scope("https://www.only-www.example.net/") == .host("www.only-www.example.net"))
        #expect(scope("www.malware-host.example.com") == .host("malware-host.example.com"))
    }

    @Test func matchesServersByTheirAddress() {
        #expect(scope("http://45.95.169.105:4321/i") == .address)
        #expect(scope("http://45.95.169.105/other") == .ipAddress("45.95.169.105"))
        #expect(scope("185.220.101.4") == .ipAddress("185.220.101.4"))
        #expect(verdict("8.8.8.8") == .notListed)
    }

    @Test func hackedSitesMatchOnlyTheirListedAddresses() {
        #expect(verdict("hacked-shop.example.org") == .notListed)
        #expect(scope("https://hacked-shop.example.org/wp-content/x.js") == .address)
    }

    @Test func lowConfidenceIndicatorsArentUsed() {
        #expect(verdict("unsure.example.com") == .notListed)
    }

    @Test func localAddressesArentLookedUp() {
        #expect(verdict("http://192.168.1.1/admin") == .localAddress)
    }

    @Test func namesTheListsThatHaveIt() throws {
        guard case .listed(let urlhaus)? = verdict("malware-host.example.com"),
              case .listed(let threatFox)? = verdict("c2.evil-domain.com") else {
            Issue.record("Expected both to be listed")
            return
        }
        #expect(urlhaus.headline == "Listed as malicious by URLhaus")
        #expect(urlhaus.reason == "URLhaus lists it for spreading malware.")
        #expect(threatFox.headline == "Listed as malicious by ThreatFox")
        #expect(threatFox.reason == "ThreatFox lists it as a malware control server (Vidar).")
        #expect(threatFox.listing.firstSeen == Date(timeIntervalSince1970: 1_792_225_800))
        #expect(threatFox.referenceURL == URL(string: "https://threatfox.abuse.ch/ioc/1601001/"))
    }

    @Test func mergesBothLists() {
        let both = ThreatIndex(
            urlhausHosts: ["both.example.com"], urlhausAddresses: [],
            threatFox: [ThreatFoxStore.Entry(ioc: ThreatFoxIOC(id: "9", kind: .domain, value: "both.example.com", threatType: "botnet_cc",
                                                               malware: "Lumma", confidence: 100), lastSeen: .now)]
        )
        guard case .listed(let match)? = CheckedLink("both.example.com").map(both.verdict(for:)) else {
            Issue.record("Expected a match")
            return
        }
        #expect(match.headline == "Listed as malicious by URLhaus and ThreatFox")
        #expect(match.reason == "URLhaus and ThreatFox list it as a malware control server (Lumma).")
    }

    @Test func saysWhatAMissMeans() {
        #expect(LinkVerdict.notListed.headline == "Not in the lists — that doesn't prove it's safe")
    }

    @Test func anEmptyIndexKnowsItsEmpty() {
        #expect(ThreatIndex().isEmpty)
        #expect(!index.isEmpty)
    }
}
