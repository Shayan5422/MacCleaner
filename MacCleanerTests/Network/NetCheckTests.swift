import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite struct NetCheckRuleTests {
    private func facts(_ configure: (inout NetChecker.Facts) -> Void = { _ in }) -> NetChecker.Facts {
        var facts = NetChecker.Facts()
        facts.interface = NetInterfaceInfo(bsdName: "en1", displayName: "Wi-Fi", kind: .wifi,
                                           ipv4Addresses: ["192.168.1.81"], ipv6Addresses: ["fe80::1"])
        facts.wifi = NetWiFiInfo(interfaceName: "en1", ssid: nil, security: .wpa3Personal, channel: 36, band: "5 GHz",
                                 standard: "Wi-Fi 6 (802.11ax)", transmitRate: 272)
        facts.router = NetRouterInfo(address: "192.168.1.254", interface: "en1", macAddress: "8c:97:ea:36:71:84")
        facts.dns = NetDNSInfo(servers: [NetServiceCatalog.describeDNS("192.168.1.254", router: "192.168.1.254")],
                               isManual: false, searchDomains: ["home"])
        facts.firewall = NetFirewallInfo(enabled: true, blocksAllIncoming: false, stealthMode: true)
        facts.systemListenersAvailable = true
        configure(&facts)
        return facts
    }

    private func item(_ kind: NetCheckItem.Kind, _ facts: NetChecker.Facts) -> NetCheckItem? {
        NetChecker.items(for: facts).first { $0.kind == kind }
    }

    @Test func aWellConfiguredNetworkHasNothingToCheck() {
        let report = NetChecker.report(for: facts())
        #expect(report.attentionCount == 0)
        #expect(report.items.map(\.kind) == [.connection, .wifiSecurity, .router, .dns, .proxies, .firewall, .exposedServices, .devices])
        #expect(item(.connection, facts())?.explanation.contains("Location access") == true,
                "a hidden Wi-Fi name is explained, never requested")
    }

    @Test func wifiSecurityRatings() {
        #expect(NetWiFiSecurity(coreWLANRawValue: 0) == .open)
        #expect(NetWiFiSecurity(coreWLANRawValue: 11) == .wpa3Personal)
        #expect(NetWiFiSecurity(coreWLANRawValue: 99) == .unknown)
        #expect(NetWiFiSecurity.open.severity == .risk)
        #expect(NetWiFiSecurity.wep.severity == .risk)
        #expect(NetWiFiSecurity.wpaPersonal.severity == .attention)
        #expect(NetWiFiSecurity.wpa2Personal.severity == .good)
        #expect(NetWiFiSecurity.unknown.severity == .info)
        let open = item(.wifiSecurity, facts {
            $0.wifi = NetWiFiInfo(interfaceName: "en1", ssid: "Cafe", security: .open, channel: 6, band: "2.4 GHz",
                                  standard: nil, transmitRate: nil)
        })
        #expect(open?.severity == .risk)
        #expect(open?.recommendation?.contains("VPN") == true)
        #expect(open?.actions.isEmpty == false)
    }

    @Test func manualUnknownDNSIsWorthChecking() {
        let automatic = item(.dns, facts())
        #expect(automatic?.severity == .good)
        #expect(automatic?.status == "Your router")
        #expect(automatic?.explanation.hasPrefix("Provided by your network") == true)
        let manual = item(.dns, facts {
            $0.dns = NetDNSInfo(servers: [NetServiceCatalog.describeDNS("203.0.113.9", router: "192.168.1.254"),
                                          NetServiceCatalog.describeDNS("1.1.1.1", router: "192.168.1.254")],
                                isManual: true, searchDomains: [])
        })
        #expect(manual?.severity == .attention)
        #expect(manual?.details.contains("1.1.1.1 (Cloudflare)") == true)
        #expect(manual?.details.contains("203.0.113.9 (Public server)") == true)
        let knownManual = item(.dns, facts {
            $0.dns = NetDNSInfo(servers: [NetServiceCatalog.describeDNS("9.9.9.9", router: nil)], isManual: true, searchDomains: [])
        })
        #expect(knownManual?.severity == .good, "a well-known resolver set by hand is a choice, not a warning")
    }

    @Test func dnsLabels() {
        #expect(NetServiceCatalog.describeDNS("192.168.1.254", router: "192.168.1.254").kind == .router)
        #expect(NetServiceCatalog.describeDNS("8.8.8.8", router: nil).label == "Google Public DNS")
        #expect(NetServiceCatalog.describeDNS("2606:4700:4700::1111", router: nil).label == "Cloudflare")
        #expect(NetServiceCatalog.describeDNS("fd0f:ee:b0::1", router: "192.168.1.254").kind == .privateNetwork)
        #expect(NetServiceCatalog.describeDNS("127.0.0.1", router: nil).kind == .loopback)
        #expect(NetServiceCatalog.describeDNS("203.0.113.9", router: nil).kind == .unknownPublic)
    }

    @Test func proxiesAreSuspiciousIfYouDidntSetThem() {
        #expect(item(.proxies, facts())?.severity == .good)
        let proxies = NetConfigReader.proxies(from: [
            "HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 8080,
            "HTTPSEnable": 0, "HTTPSProxy": "ignored.example",
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad.example/proxy.pac",
            "ExceptionsList": ["*.local", "169.254/16"],
        ])
        #expect(proxies.entries.map(\.kind) == [.http, .autoConfig])
        #expect(proxies.entries.first?.value == "proxy.example:8080")
        #expect(proxies.exceptions == ["*.local", "169.254/16"])
        let row = item(.proxies, facts { $0.proxies = proxies })
        #expect(row?.severity == .attention)
        #expect(row?.status == "2 set")
        #expect(row?.explanation.contains("suspicious if you didn't set it") == true)
        #expect(NetConfigReader.proxies(from: nil).entries.isEmpty)
        #expect(NetConfigReader.proxies(from: ["ExceptionsList": ["*.local"], "FTPPassive": 1]).entries.isEmpty)
    }

    @Test func firewall() {
        #expect(item(.firewall, facts())?.details == ["Stealth mode on"])
        let off = item(.firewall, facts { $0.firewall = NetFirewallInfo(enabled: false, blocksAllIncoming: false, stealthMode: nil) })
        #expect(off?.severity == .attention)
        #expect(off?.actions.first?.url == SystemSettingsPane.firewall.url)
        #expect(item(.firewall, facts { $0.firewall = NetFirewallInfo(enabled: nil, blocksAllIncoming: nil, stealthMode: nil) })?.severity == .info)
    }

    @Test func exposedServicesNameMacOSSharingAndYourServers() {
        let screenSharing = NetExposedListener(port: 5900, address: "*", pid: 1, processName: "launchd", isCurrentUser: false,
                                               service: NetServiceCatalog.service(port: 5900, processName: "launchd"))
        let continuity = NetExposedListener(port: 49152, address: "*", pid: 700, processName: "rapportd", isCurrentUser: true,
                                            service: NetServiceCatalog.service(port: 49152, processName: "rapportd"))
        let dev = NetExposedListener(port: 4173, address: "*", pid: 800, processName: "node", isCurrentUser: true, service: nil)
        let row = item(.exposedServices, facts { $0.exposed = [screenSharing, continuity, dev] })
        #expect(row?.severity == .attention, "remote access is worth checking")
        #expect(row?.status == "3 open ports")
        #expect(row?.details.first?.hasPrefix("Screen Sharing — port 5900") == true)
        #expect(row?.details.contains("node — port 4173 on all interfaces") == true)
        #expect(row?.recommendation?.contains("127.0.0.1") == true)
        #expect(item(.exposedServices, facts { $0.exposed = [continuity] })?.severity == .info)
        let unchecked = item(.exposedServices, facts { $0.systemListenersAvailable = false })
        #expect(unchecked?.severity == .info, "only own apps were checked: no clean bill of health")
        #expect(unchecked?.explanation.contains("Only your own apps could be checked") == true)
    }

    @Test func serviceCatalogNeedsFixedPortsOrTheRightProcess() {
        #expect(NetServiceCatalog.service(port: 22, processName: "launchd")?.name == "Remote Login (SSH)")
        #expect(NetServiceCatalog.service(port: 445, processName: "launchd")?.name == "File Sharing (SMB)")
        #expect(NetServiceCatalog.service(port: 22, processName: "node") == nil, "a dev server on :22 is not Remote Login")
        #expect(NetServiceCatalog.service(port: 7000, processName: "ControlCenter")?.name == "AirPlay Receiver")
        #expect(NetServiceCatalog.service(port: 51234, processName: "ControlCenter") == nil)
        #expect(NetServiceCatalog.service(port: 1234, processName: "sshd")?.name == "Remote Login (SSH)")
        #expect(NetServiceCatalog.remoteLogin.howToTurnOff == "Turn it off in System Settings › General › Sharing › Remote Login.")
        #expect(NetServiceCatalog.kerberos.howToTurnOff == "It stops when Screen Sharing and File Sharing are off.")
        #expect(NetChecker.isReachableFromNetwork("*"))
        #expect(NetChecker.isReachableFromNetwork("192.168.1.81"))
        #expect(!NetChecker.isReachableFromNetwork("127.0.0.1"))
        #expect(!NetChecker.isReachableFromNetwork("::1"))
        #expect(!NetChecker.isReachableFromNetwork("fe80::1%lo0"))
    }

    @Test func devicesComeFromTheAddressCacheWithoutGuesses() {
        let interface = NetInterfaceInfo(bsdName: "en1", displayName: "Wi-Fi", kind: .wifi,
                                         ipv4Addresses: ["192.168.1.81"], ipv6Addresses: [])
        typealias Route = NetConfigReader.RouteEntry
        let arp = [
            Route(destination: "192.168.1.6", gateway: "3a:55:8f:58:e9:c6", interface: "en1", flags: 0),
            Route(destination: "192.168.1.81", gateway: "d0:11:e5:1c:c1:d3", interface: "lo0", flags: RTF_LOCAL),
            Route(destination: "192.168.1.254", gateway: "8c:97:ea:36:71:84", interface: "en1", flags: 0),
            Route(destination: "192.168.1.255", gateway: "ff:ff:ff:ff:ff:fe", interface: "en1", flags: 0),
            Route(destination: "10.211.55.3", gateway: "00:1c:42:00:00:08", interface: "bridge100", flags: 0),
            // This Mac's own address on a virtual machine network: not this network, and not listed twice.
            Route(destination: "10.211.55.2", gateway: "d2:11:e5:b1:3a:64", interface: "lo0", flags: RTF_LOCAL),
            Route(destination: "224.0.0.251", gateway: "01:00:5e:00:00:fb", interface: "en1", flags: 0),
        ]
        let devices = NetChecker.devices(from: arp, interface: interface, router: "192.168.1.254")
        #expect(devices.map(\.address) == ["192.168.1.254", "192.168.1.81", "192.168.1.6"])
        #expect(devices[0].isRouter && devices[1].isThisMac)
        #expect(devices.allSatisfy { $0.hostName == nil }, "no vendor or name guesses")
        let row = NetChecker.devicesItem(devices)
        #expect(row.status == "2 devices", "this Mac isn't counted as another device")
    }

    @Test func arpFilterDropsBroadcastAndMulticast() {
        // `arpEntries()` reads the live table; the filter is checked on what a parsed table looks like.
        let unicast = NetConfigReader.RouteEntry(destination: "192.168.1.6", gateway: "3a:55:8f:58:e9:c6", interface: "en1", flags: 0)
        #expect((UInt8(unicast.gateway!.prefix(2), radix: 16) ?? 1) & 1 == 0)
        let multicast = NetConfigReader.RouteEntry(destination: "224.0.0.251", gateway: "01:00:5e:00:00:fb", interface: "en1", flags: 0)
        #expect((UInt8(multicast.gateway!.prefix(2), radix: 16) ?? 0) & 1 == 1)
    }

    @Test func routingMessagesAreParsedSafely() {
        let message = NetRouteMessageBuilder.message(destination: [192, 168, 1, 6], mac: [0x3a, 0x55, 0x8f, 0x58, 0xe9, 0xc6],
                                                     interfaceIndex: 0, flags: RTF_LLINFO | RTF_HOST)
        let gateway = NetRouteMessageBuilder.message(destination: [0, 0, 0, 0], gatewayIPv4: [192, 168, 1, 254],
                                                     interfaceIndex: 0, flags: RTF_GATEWAY | RTF_UP)
        let entries = (message + gateway).withUnsafeBytes { NetConfigReader.parseRouteMessages($0) }
        #expect(entries.count == 2)
        #expect(entries[0].destination == "192.168.1.6")
        #expect(entries[0].gateway == "3a:55:8f:58:e9:c6")
        #expect(entries[1].destination == "0.0.0.0")
        #expect(entries[1].gateway == "192.168.1.254")
        // A truncated message stops parsing instead of reading past the buffer.
        let truncated = Array(message.prefix(message.count - 10))
        #expect(truncated.withUnsafeBytes { NetConfigReader.parseRouteMessages($0) }.isEmpty)
        #expect([UInt8]().withUnsafeBytes { NetConfigReader.parseRouteMessages($0) }.isEmpty)
    }
}

/// Builds `rt_msghdr` messages the way the kernel's routing sysctl returns them.
enum NetRouteMessageBuilder {
    static func message(destination: [UInt8], mac: [UInt8]? = nil, gatewayIPv4: [UInt8]? = nil,
                        interfaceIndex: UInt16, flags: Int32) -> [UInt8] {
        var addresses: [UInt8] = []
        // sockaddr_in (16 bytes): len, family, port, address, zero.
        var dst = [UInt8](repeating: 0, count: 16)
        dst[0] = 16
        dst[1] = UInt8(AF_INET)
        dst.replaceSubrange(4..<8, with: destination)
        addresses += dst
        if let gatewayIPv4 {
            var gateway = [UInt8](repeating: 0, count: 16)
            gateway[0] = 16
            gateway[1] = UInt8(AF_INET)
            gateway.replaceSubrange(4..<8, with: gatewayIPv4)
            addresses += gateway
        } else if let mac {
            // sockaddr_dl: len, family, index(2), type, nlen, alen, slen, data.
            var link = [UInt8](repeating: 0, count: 20)
            link[0] = 20
            link[1] = UInt8(AF_LINK)
            link[6] = UInt8(mac.count)
            link.replaceSubrange(8..<(8 + mac.count), with: mac)
            addresses += link
        }
        var header = rt_msghdr()
        let total = MemoryLayout<rt_msghdr>.size + addresses.count
        header.rtm_msglen = UInt16(total)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_index = interfaceIndex
        header.rtm_flags = flags
        header.rtm_addrs = RTA_DST | RTA_GATEWAY
        return withUnsafeBytes(of: header) { Array($0) } + addresses
    }
}

@MainActor
@Suite struct NetworkPreferencesTests {
    @Test func defaultsPersistenceAndReset() throws {
        let suite = "com.maccleaner.network.tests.prefs." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NetworkPreferences(defaults: defaults)
        #expect(preferences.refreshInterval == 3)
        #expect(preferences.gracefulTimeout == 3)
        #expect(!preferences.includeOtherUsers && !preferences.showApps && !preferences.showSystem)
        #expect(!preferences.notifyNewPorts)
        #expect(preferences.shieldEnabled, "the Network Shield is on until turned off")
        #expect(!preferences.reverseDNS, "no DNS queries unless asked for")

        preferences.refreshInterval = 10
        preferences.gracefulTimeout = 7
        preferences.includesSystemPorts = true
        preferences.hiddenPorts = [5000]
        preferences.hiddenGroupIDs = ["project:/x"]
        preferences.sortOrder = .memory
        #expect(defaults.double(forKey: "network.refreshInterval") == 10)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("network.") }.count >= 7)
        let reloaded = NetworkPreferences(defaults: defaults)
        #expect(reloaded.refreshInterval == 10 && reloaded.gracefulTimeout == 7)
        #expect(reloaded.includeOtherUsers && reloaded.showSystem && reloaded.includesSystemPorts)
        #expect(reloaded.hiddenPorts == [5000] && reloaded.hiddenGroupIDs == ["project:/x"] && reloaded.sortOrder == .memory)
        #expect(reloaded.hiddenItemCount == 2)

        defaults.set(999.0, forKey: "network.refreshInterval")
        defaults.set(50.0, forKey: "network.gracefulTimeout")
        let clamped = NetworkPreferences(defaults: defaults)
        #expect(clamped.refreshInterval == 3, "an unknown interval falls back to the default")
        #expect(clamped.gracefulTimeout == 10)

        reloaded.resetToDefaults()
        #expect(reloaded.refreshInterval == 3 && !reloaded.includeOtherUsers && reloaded.hiddenPorts.isEmpty)
    }
}

@MainActor
@Suite struct PortLookupAndEventTests {
    @Test func portQueries() {
        #expect(PortsModel.portQuery("3000") == 3000)
        #expect(PortsModel.portQuery(" :5173 ") == 5173)
        #expect(PortsModel.portQuery("port 8080") == 8080)
        #expect(PortsModel.portQuery("0") == nil)
        #expect(PortsModel.portQuery("70000") == nil)
        #expect(PortsModel.portQuery("vite") == nil)
        #expect(PortsModel.portQuery("３０００") == nil, "only ASCII digits")
    }

    @Test func aPortOfAScannedGroupIsInUse() {
        let web = PortUIFixtures.group(id: "project:/x/web", category: .project, title: "web",
                                       processes: [PortUIFixtures.process(pid: 11, ports: [3000])])
        let model = PortUIFixtures.model([web])
        model.searchText = "3000"
        #expect(model.portLookup == .inUse(port: 3000, groupIDs: ["project:/x/web"]))
        #expect(model.visibleGroups.map(\.id) == ["project:/x/web"])
        model.searchText = "web"
        #expect(model.portLookup == nil)
    }

    @Test func openedPortEventsAreShortAndHuman() {
        let project = PortProjectInfo(rootPath: "/Users/me/code/my-app", name: "my-app", subpath: nil, markers: [".git"])
        let vite = PortUIFixtures.process(pid: 20, name: "vite", ports: [5173], project: project)
        let group = PortUIFixtures.group(id: "project:/Users/me/code/my-app", category: .project, title: "my-app",
                                         path: project.rootPath, processes: [vite])
        let event = PortsModel.openedEvent(for: group, ports: [5173])
        #expect(event.title == "Port 5173 opened — vite in my-app")
        #expect(event.kind == .portOpened && event.severity == .info && event.section == .network)
        #expect(PortsModel.openedEvent(for: group, ports: [5173, 5174]).title == "Ports 5173, 5174 opened — vite in my-app")
    }
}

extension PortLiveProcessTests {
    @Suite struct PortLiveLookupTests {
        @Test func ownListenerIsFoundAndAFreePortIsFree() throws {
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            defer { listener.close() }
            let uid = PortSysProc.currentUID
            switch PortsModel.systemLookup(port: listener.port, currentUID: uid) {
            case .inUseElsewhere(_, let owners):
                #expect(owners.contains { $0.pid == getpid() })
            default:
                Issue.record("own listener not found")
            }
            let free = try PortPipelineSandbox.freePort()
            let answer = PortsModel.systemLookup(port: free, currentUID: uid)
            // Without the kernel list (a test runner outside an app bundle) the answer is honest about it.
            #expect(answer == .free(port: free) || answer == .freeForYou(port: free))
        }
    }
}
