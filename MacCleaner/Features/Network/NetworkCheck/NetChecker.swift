import Darwin
import Foundation

/// The Network Check (like a Wi-Fi inspector, but honest about its limits): it reads this Mac's own network
/// settings and caches, then explains each finding in plain English. It doesn't scan other devices, probe the
/// router or send anything to the network (except reverse-DNS queries for device names when that is turned on).
enum NetChecker {
    /// Everything the checks are made from.
    struct Facts: Sendable {
        var interface: NetInterfaceInfo?
        var wifi: NetWiFiInfo?
        var router: NetRouterInfo?
        var dns = NetDNSInfo(servers: [], isManual: false, searchDomains: [])
        var proxies = NetProxyInfo(entries: [], exceptions: [])
        var firewall = NetFirewallInfo(enabled: nil, blocksAllIncoming: nil, stealthMode: nil)
        var exposed: [NetExposedListener] = []
        var devices: [NetDevice] = []
        var systemListenersAvailable = false
    }

    /// Runs every check. Blocking reads happen off the main thread.
    static func run(currentUID: UInt32 = PortSysProc.currentUID) async -> NetCheckReport {
        async let firewall = NetConfigReader.firewall()
        var facts = await BackgroundWork.run(qos: .userInitiated) { gatherLocalFacts(currentUID: currentUID) }
        facts.firewall = await firewall
        return report(for: facts)
    }

    static func report(for facts: Facts, date: Date = Date()) -> NetCheckReport {
        NetCheckReport(date: date, items: items(for: facts), interface: facts.interface, wifi: facts.wifi,
                       router: facts.router, dns: facts.dns, proxies: facts.proxies, firewall: facts.firewall,
                       exposed: facts.exposed, devices: facts.devices,
                       systemListenersAvailable: facts.systemListenersAvailable)
    }

    /// Everything but the firewall (which runs a tool): dynamic store, routing table, ARP, Wi-Fi, sockets.
    static func gatherLocalFacts(currentUID: UInt32) -> Facts {
        var facts = Facts()
        let store = NetConfigReader.readStore()
        let route = NetConfigReader.defaultGateway()
        let routerAddress = route?.address ?? (store.globalIPv4?["Router"] as? String)
        facts.interface = NetConfigReader.primaryInterface(from: store, routeInterface: route?.interface)
        if let interface = facts.interface, interface.kind == .wifi {
            facts.wifi = NetConfigReader.wifi(interface: interface.bsdName)
        }
        let arp = NetConfigReader.arpEntries()
        if let routerAddress {
            let mac = arp.first { $0.destination == routerAddress }?.gateway
            facts.router = NetRouterInfo(address: routerAddress, interface: route?.interface ?? facts.interface?.bsdName,
                                         macAddress: mac)
        }
        facts.dns = NetConfigReader.dns(from: store, router: routerAddress)
        facts.proxies = NetConfigReader.proxies(from: store.proxies)
        let listeners = exposedListeners(currentUID: currentUID)
        facts.exposed = listeners.listeners
        facts.systemListenersAvailable = listeners.systemListAvailable
        facts.devices = devices(from: arp, interface: facts.interface, router: routerAddress)
        return facts
    }

    // MARK: - Exposed services

    /// Listening TCP sockets other devices can reach: every user's from the kernel list when macOS provides it,
    /// plus this user's own from their descriptor tables.
    static func exposedListeners(currentUID: UInt32) -> (listeners: [NetExposedListener], systemListAvailable: Bool) {
        let system = PortSysProc.systemTCPListeners()
        var sockets = system ?? []
        var fdBuffer: [proc_fdinfo] = []
        let processes = PortSysProc.allProcesses()
        let table = PortProcessTable(processes: processes)
        for process in processes where process.uid == currentUID {
            for socket in PortSysProc.listeningTCPSockets(pid: process.pid, fdBuffer: &fdBuffer) ?? []
            where !sockets.contains(socket) {
                sockets.append(socket)
            }
        }
        var seen = Set<String>()
        var result: [NetExposedListener] = []
        for socket in sockets.sorted(by: PortSysProc.socketOrder) where isReachableFromNetwork(socket.address) {
            let basic = table[socket.pid]
            let name: String
            if socket.pid == 1 {
                name = "launchd"
            } else if let path = PortSysProc.executablePath(pid: socket.pid) {
                name = (path as NSString).lastPathComponent
            } else {
                name = basic?.comm ?? "pid \(socket.pid)"
            }
            // One row per port and process (IPv4 and IPv6 sockets of the same service read as one).
            guard seen.insert("\(socket.port)|\(socket.pid)").inserted else { continue }
            result.append(NetExposedListener(port: socket.port, address: socket.address, pid: socket.pid,
                                             processName: name, isCurrentUser: basic?.uid == currentUID,
                                             service: NetServiceCatalog.service(port: socket.port, processName: name)))
        }
        return (result, system != nil)
    }

    /// Bound to every interface ("*") or to an address other than loopback.
    static func isReachableFromNetwork(_ address: String) -> Bool {
        if address == "*" { return true }
        if address.hasSuffix("%lo0") { return false }
        switch NetAddress.scope(address) {
        case .loopback?, nil: return false
        default: return true
        }
    }

    // MARK: - Devices

    /// Devices in the ARP cache on the primary interface's network, this Mac and the router marked.
    static func devices(from arp: [NetConfigReader.RouteEntry], interface: NetInterfaceInfo?,
                        router: String?) -> [NetDevice] {
        let ownAddresses = Set(interface?.ipv4Addresses ?? [])
        var seen = Set<String>()
        var devices: [NetDevice] = []
        for entry in arp {
            guard let mac = entry.gateway, NetAddress.scope(entry.destination) != .multicast,
                  !entry.destination.hasSuffix(".255"), entry.destination != "169.254.169.254" else { continue }
            let isLocal = entry.flags & RTF_LOCAL != 0
            let isThisMac: Bool
            if let interface {
                // This Mac's own entry sits on lo0; every other device on the primary interface. This Mac's
                // addresses on other networks (virtual machines, bridges) and devices there aren't on this network.
                isThisMac = ownAddresses.contains(entry.destination)
                if !isThisMac && (isLocal || entry.interface != interface.bsdName) { continue }
            } else {
                isThisMac = isLocal
            }
            guard seen.insert(entry.destination).inserted else { continue }
            devices.append(NetDevice(address: entry.destination, macAddress: mac,
                                     interface: isThisMac ? (interface?.bsdName ?? entry.interface) : entry.interface,
                                     hostName: nil, isThisMac: isThisMac, isRouter: entry.destination == router))
        }
        return devices.sorted { lhs, rhs in
            if lhs.isRouter != rhs.isRouter { return lhs.isRouter }
            if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
            return (NetAddress.bytes(lhs.address) ?? []).lexicographicallyPrecedes(NetAddress.bytes(rhs.address) ?? [])
        }
    }

    // MARK: - Rows

    static func items(for facts: Facts) -> [NetCheckItem] {
        var items = [connectionItem(facts)]
        if let wifi = facts.wifi { items.append(wifiItem(wifi)) }
        items.append(routerItem(facts.router))
        items.append(dnsItem(facts.dns))
        items.append(proxyItem(facts.proxies))
        items.append(firewallItem(facts.firewall))
        items.append(exposedItem(facts.exposed, systemListAvailable: facts.systemListenersAvailable))
        items.append(devicesItem(facts.devices))
        return items
    }

    static func connectionItem(_ facts: Facts) -> NetCheckItem {
        guard let interface = facts.interface else {
            return NetCheckItem(kind: .connection, severity: .info, title: "Connection", status: "Not connected",
                                explanation: "This Mac has no active network connection right now.", recommendation: nil)
        }
        var explanation: String
        var details: [String] = []
        let address = interface.ipv4Addresses.first ?? interface.ipv6Addresses.first
        switch interface.kind {
        case .wifi:
            if let ssid = facts.wifi?.ssid {
                explanation = "Connected to the Wi-Fi network “\(ssid)” (\(interface.bsdName))."
            } else {
                explanation = "Connected through Wi-Fi (\(interface.bsdName)). macOS shows Wi-Fi network names only to "
                    + "apps with Location access, which Mac Cleaner doesn't ask for; the checks don't need it."
            }
            if let wifi = facts.wifi {
                let radio = [wifi.standard, wifi.band, wifi.channel.map { "channel \($0)" }].compactMap { $0 }
                if !radio.isEmpty { details.append(radio.joined(separator: " · ")) }
                if let rate = wifi.transmitRate { details.append("Link speed \(Int(rate.rounded())) Mbit/s") }
            }
        case .ethernet:
            explanation = "Connected by cable (\(interface.displayName), \(interface.bsdName))."
        case .vpn:
            explanation = "Your traffic goes through a VPN (\(interface.bsdName)). DNS and the router below are the VPN's."
        case .cellular:
            explanation = "Connected through a cellular modem (\(interface.bsdName))."
        case .other:
            explanation = "Connected through \(interface.displayName) (\(interface.bsdName))."
        }
        if let address { explanation += " This Mac's address is \(address)." }
        details += interface.ipv4Addresses.map { "IPv4 \($0)" }
        details += interface.ipv6Addresses.filter { !$0.hasPrefix("fe80") }.prefix(2).map { "IPv6 \($0)" }
        let status = interface.kind == .vpn ? "VPN" : interface.displayName
        return NetCheckItem(kind: .connection, severity: .info, title: "Connection", status: status,
                            explanation: explanation, recommendation: nil, details: details)
    }

    static func wifiItem(_ wifi: NetWiFiInfo) -> NetCheckItem {
        let explanation: String
        let recommendation: String?
        switch wifi.security {
        case .open:
            explanation = "This network has no password: anyone nearby can join it and read traffic that the website "
                + "or app doesn't encrypt itself."
            recommendation = "Avoid signing in or sending private data on it, or use a VPN. Prefer networks protected with WPA2 or WPA3."
        case .wep, .dynamicWEP:
            explanation = "WEP encryption was broken many years ago. Anyone nearby can crack it in minutes."
            recommendation = "If this is your router, switch it to WPA2 or WPA3 Personal. Otherwise use another network or a VPN."
        case .wpaPersonal, .wpaEnterprise:
            explanation = "The first version of WPA is outdated and much weaker than WPA2 and WPA3."
            recommendation = "If this is your router, switch it to WPA2 or WPA3."
        case .enhancedOpen, .enhancedOpenTransition:
            explanation = "Enhanced Open encrypts traffic, but anyone can join the network without a password."
            recommendation = "Fine for browsing; avoid sharing files or your screen on it."
        case .unknown:
            explanation = "macOS didn't report the security type of this network."
            recommendation = nil
        default:
            explanation = "Traffic on this Wi-Fi network is encrypted with \(wifi.security.title)."
            recommendation = nil
        }
        var actions: [NetCheckAction] = []
        if wifi.security.severity.needsAttention, let url = NetServiceCatalog.wifiSettings {
            actions.append(NetCheckAction(title: "Open Wi-Fi Settings", url: url))
        }
        return NetCheckItem(kind: .wifiSecurity, severity: wifi.security.severity, title: "Wi-Fi security",
                            status: wifi.security.title, explanation: explanation, recommendation: recommendation,
                            actions: actions)
    }

    static func routerItem(_ router: NetRouterInfo?) -> NetCheckItem {
        guard let router else {
            return NetCheckItem(kind: .router, severity: .info, title: "Router", status: "None",
                                explanation: "There's no default route, so this Mac can't reach the internet right now.",
                                recommendation: nil)
        }
        var explanation = "Traffic to the internet goes through \(router.address)"
        if let interface = router.interface { explanation += " on \(interface)" }
        explanation += "."
        var details: [String] = []
        if let mac = router.macAddress { details.append("Hardware address \(mac)") }
        return NetCheckItem(kind: .router, severity: .info, title: "Router", status: router.address,
                            explanation: explanation, recommendation: nil, details: details)
    }

    static func dnsItem(_ dns: NetDNSInfo) -> NetCheckItem {
        guard !dns.servers.isEmpty else {
            return NetCheckItem(kind: .dns, severity: .info, title: "DNS servers", status: "None",
                                explanation: "No DNS servers are configured, so names like apple.com can't be looked up.",
                                recommendation: nil)
        }
        let unknown = dns.servers.filter { $0.kind == .unknownPublic }
        let source = dns.isManual ? "Set by hand in System Settings" : "Provided by your network"
        let list = dns.servers.map { "\($0.address) (\($0.label))" }
        let severity: NetCheckSeverity
        let recommendation: String?
        if dns.isManual && !unknown.isEmpty {
            severity = .attention
            recommendation = "If you, your VPN or your organization didn't set "
                + (unknown.count == 1 ? "this server" : "these servers")
                + ", set DNS back to automatic in System Settings › Network › Details › DNS. Malware sometimes changes "
                + "DNS to send you to fake websites."
        } else {
            severity = .good
            recommendation = nil
        }
        let status = dns.servers.count == 1 ? dns.servers[0].label : "\(dns.servers.count) servers"
        var actions: [NetCheckAction] = []
        if severity.needsAttention, let url = NetServiceCatalog.networkSettings {
            actions.append(NetCheckAction(title: "Open Network Settings", url: url))
        }
        var details = list
        if !dns.searchDomains.isEmpty { details.append("Search domains: " + dns.searchDomains.joined(separator: ", ")) }
        return NetCheckItem(kind: .dns, severity: severity, title: "DNS servers", status: status,
                            explanation: "\(source). DNS servers translate names like apple.com into addresses.",
                            recommendation: recommendation, details: details, actions: actions)
    }

    static func proxyItem(_ proxies: NetProxyInfo) -> NetCheckItem {
        guard !proxies.entries.isEmpty else {
            return NetCheckItem(kind: .proxies, severity: .good, title: "Proxies", status: "None",
                                explanation: "No proxy is set: web traffic goes straight to the websites you visit.",
                                recommendation: nil)
        }
        var actions: [NetCheckAction] = []
        if let url = NetServiceCatalog.networkSettings { actions.append(NetCheckAction(title: "Open Network Settings", url: url)) }
        let details = proxies.entries.map { entry in entry.value.map { "\(entry.kind.rawValue): \($0)" } ?? entry.kind.rawValue }
        return NetCheckItem(
            kind: .proxies, severity: .attention, title: "Proxies",
            status: proxies.entries.count == 1 ? "1 set" : "\(proxies.entries.count) set",
            explanation: "This Mac sends web traffic through a proxy. Companies, schools and some security apps set "
                + "proxies on purpose, but adware and malware set them too, to watch or change your browsing. "
                + "It's suspicious if you didn't set it.",
            recommendation: "If you don't recognize it, turn it off in System Settings › Network › Details › Proxies.",
            details: details, actions: actions)
    }

    static func firewallItem(_ firewall: NetFirewallInfo) -> NetCheckItem {
        let settings = SystemSettingsPane.firewall.url
        switch firewall.enabled {
        case true?:
            var details: [String] = []
            if firewall.blocksAllIncoming == true { details.append("Blocks all incoming connections") }
            if let stealth = firewall.stealthMode { details.append(stealth ? "Stealth mode on" : "Stealth mode off") }
            return NetCheckItem(kind: .firewall, severity: .good, title: "Firewall", status: "On",
                                explanation: "The macOS firewall decides which apps may accept connections from the network.",
                                recommendation: nil, details: details)
        case false?:
            return NetCheckItem(kind: .firewall, severity: .attention, title: "Firewall", status: "Off",
                                explanation: "The macOS firewall is off, so apps and services on this Mac accept "
                                    + "incoming connections from any device on the network.",
                                recommendation: "Turn it on in System Settings › Network › Firewall, especially on public networks.",
                                actions: [NetCheckAction(title: "Open Firewall Settings", url: settings)])
        case nil:
            return NetCheckItem(kind: .firewall, severity: .info, title: "Firewall", status: "Unknown",
                                explanation: "Mac Cleaner couldn't read the firewall's state.", recommendation: nil,
                                actions: [NetCheckAction(title: "Open Firewall Settings", url: settings)])
        }
    }

    static func exposedItem(_ listeners: [NetExposedListener], systemListAvailable: Bool) -> NetCheckItem {
        let scope = systemListAvailable ? "" : " Only your own apps could be checked: macOS didn't provide the list of other users' and system ports."
        guard !listeners.isEmpty else {
            return NetCheckItem(kind: .exposedServices, severity: systemListAvailable ? .good : .info,
                                title: "Services other devices can reach", status: "None",
                                explanation: "Nothing on this Mac accepts connections from other devices." + scope,
                                recommendation: nil)
        }
        let named = listeners.filter { $0.service != nil }
        let severity = listeners.compactMap { $0.service?.severity }.max() ?? .info
        var details: [String] = []
        var seenServices = Set<String>()
        for listener in named {
            guard let service = listener.service, seenServices.insert(service.name).inserted else { continue }
            let ports = named.filter { $0.service?.name == service.name }.map { String($0.port) }
            details.append("\(service.name) — port \(ports.joined(separator: ", ")). \(service.summary) \(service.howToTurnOff)")
        }
        for listener in listeners where listener.service == nil {
            let address = listener.address == "*" ? "all interfaces" : listener.address
            details.append("\(listener.processName) — port \(listener.port) on \(address)")
        }
        var recommendation = "Turn off sharing you don't use in System Settings › General › Sharing."
        if listeners.contains(where: { $0.service == nil && $0.isCurrentUser }) {
            recommendation += " Your own servers can listen on 127.0.0.1 (localhost) instead, if other devices don't need them."
        }
        var actions: [NetCheckAction] = []
        if let url = NetServiceCatalog.sharingSettings { actions.append(NetCheckAction(title: "Open Sharing Settings", url: url)) }
        let count = listeners.count
        return NetCheckItem(
            kind: .exposedServices, severity: severity, title: "Services other devices can reach",
            status: count == 1 ? "1 open port" : "\(count) open ports",
            explanation: "These listen on all network interfaces, so other devices on this network can connect to "
                + "them (unless the firewall blocks them)." + scope,
            recommendation: recommendation, details: details, actions: actions)
    }

    static func devicesItem(_ devices: [NetDevice]) -> NetCheckItem {
        let others = devices.filter { !$0.isThisMac }
        let status = others.count == 1 ? "1 device" : "\(others.count) devices"
        return NetCheckItem(
            kind: .devices, severity: .info, title: "Devices on this network", status: status,
            explanation: "Devices this Mac exchanged data with recently, from its address cache (ARP). Quiet devices "
                + "may be missing: Mac Cleaner doesn't scan the network.",
            recommendation: nil)
    }
}
