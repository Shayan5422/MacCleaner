import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Read-only access to this Mac's network configuration: the primary interface, DNS servers and proxies
/// (SystemConfiguration's dynamic store), the default route and the ARP cache (the kernel routing table through
/// sysctl), interface addresses (getifaddrs) and Wi-Fi details (CoreWLAN).
///
/// Nothing here changes a setting or sends anything to the network. CoreWLAN is only asked for what it reports
/// without Location access; Mac Cleaner never requests that permission, so the Wi-Fi name is usually hidden.
enum NetConfigReader {
    // MARK: - Dynamic store

    /// Values of the keys the checks need, read once.
    struct StoreSnapshot: @unchecked Sendable {
        let globalIPv4: [String: Any]?
        let globalDNS: [String: Any]?
        let proxies: [String: Any]?
        /// `Setup:/Network/Service/<primary>/DNS` and `/Proxies`: what the person set by hand for the primary service.
        let manualDNS: [String: Any]?
        let manualProxies: [String: Any]?
    }

    static func readStore() -> StoreSnapshot {
        let store = SCDynamicStoreCreate(nil, "Mac Cleaner Network Check" as CFString, nil, nil)
        func value(_ key: String) -> [String: Any]? {
            guard let store else { return nil }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        let ipv4 = value("State:/Network/Global/IPv4")
        let service = ipv4?["PrimaryService"] as? String
        return StoreSnapshot(
            globalIPv4: ipv4,
            globalDNS: value("State:/Network/Global/DNS"),
            proxies: SCDynamicStoreCopyProxies(store) as? [String: Any],
            manualDNS: service.flatMap { value("Setup:/Network/Service/\($0)/DNS") },
            manualProxies: service.flatMap { value("Setup:/Network/Service/\($0)/Proxies") })
    }

    /// The DNS servers macOS uses, and whether they were set by hand.
    static func dns(from store: StoreSnapshot, router: String?) -> NetDNSInfo {
        let servers = (store.globalDNS?["ServerAddresses"] as? [String]) ?? []
        let manual = (store.manualDNS?["ServerAddresses"] as? [String]) ?? []
        let domains = (store.globalDNS?["SearchDomains"] as? [String]) ?? []
        return NetDNSInfo(servers: servers.map { NetServiceCatalog.describeDNS($0, router: router) },
                          isManual: !manual.isEmpty, searchDomains: domains)
    }

    /// Enabled proxies from `SCDynamicStoreCopyProxies` (HTTP, HTTPS, SOCKS, FTP, RTSP, Gopher, PAC, WPAD).
    static func proxies(from dictionary: [String: Any]?) -> NetProxyInfo {
        guard let dictionary else { return NetProxyInfo(entries: [], exceptions: []) }
        func flag(_ key: String) -> Bool { (dictionary[key] as? NSNumber)?.boolValue ?? false }
        func endpoint(_ host: String, _ port: String) -> String? {
            guard let name = dictionary[host] as? String, !name.isEmpty else { return nil }
            if let number = (dictionary[port] as? NSNumber)?.intValue, number > 0 { return "\(name):\(number)" }
            return name
        }
        var entries: [NetProxyEntry] = []
        let manual: [(NetProxyEntry.Kind, String, String, String)] = [
            (.http, "HTTPEnable", "HTTPProxy", "HTTPPort"),
            (.https, "HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
            (.socks, "SOCKSEnable", "SOCKSProxy", "SOCKSPort"),
            (.ftp, "FTPEnable", "FTPProxy", "FTPPort"),
            (.rtsp, "RTSPEnable", "RTSPProxy", "RTSPPort"),
            (.gopher, "GopherEnable", "GopherProxy", "GopherPort"),
        ]
        for (kind, enable, host, port) in manual where flag(enable) {
            entries.append(NetProxyEntry(kind: kind, value: endpoint(host, port)))
        }
        if flag("ProxyAutoConfigEnable") {
            entries.append(NetProxyEntry(kind: .autoConfig, value: dictionary["ProxyAutoConfigURLString"] as? String))
        }
        if flag("ProxyAutoDiscoveryEnable") {
            entries.append(NetProxyEntry(kind: .autoDiscovery, value: nil))
        }
        let exceptions = (dictionary["ExceptionsList"] as? [String]) ?? []
        return NetProxyInfo(entries: entries, exceptions: exceptions)
    }

    // MARK: - Interfaces

    /// The interface of the default route, with its kind and display name.
    static func primaryInterface(from store: StoreSnapshot, routeInterface: String?) -> NetInterfaceInfo? {
        guard let name = (store.globalIPv4?["PrimaryInterface"] as? String) ?? routeInterface else { return nil }
        let addresses = interfaceAddresses()[name] ?? ([], [])
        var kind = NetInterfaceInfo.Kind.other
        var displayName = name
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun")
            || name.hasPrefix("tap") || name.hasPrefix("wg") {
            kind = .vpn
            displayName = "VPN"
        } else if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces where (SCNetworkInterfaceGetBSDName(interface) as String?) == name {
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
                if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                    kind = .wifi
                } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                    kind = .ethernet
                } else if type == (kSCNetworkInterfaceTypeWWAN as String) {
                    kind = .cellular
                }
                if let localized = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? { displayName = localized }
            }
        }
        if kind == .other, (CWWiFiClient.shared().interfaceNames() ?? []).contains(name) { kind = .wifi }
        if kind == .wifi, displayName == name { displayName = "Wi-Fi" }
        return NetInterfaceInfo(bsdName: name, displayName: displayName, kind: kind,
                                ipv4Addresses: addresses.0, ipv6Addresses: addresses.1)
    }

    /// Interface name → (IPv4 addresses, IPv6 addresses), link-local IPv6 included.
    static func interfaceAddresses() -> [String: ([String], [String])] {
        var result: [String: ([String], [String])] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                result[name, default: ([], [])].0.append(PortSysProc.render(ipv4: ipv4))
            case AF_INET6:
                var ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                result[name, default: ([], [])].1.append(PortSysProc.render(ipv6: &ipv6))
            default:
                break
            }
        }
        return result
    }

    // MARK: - Wi-Fi

    /// Wi-Fi details from CoreWLAN, nil when `interface` isn't a Wi-Fi interface or Wi-Fi is off.
    static func wifi(interface: String) -> NetWiFiInfo? {
        guard let wlan = CWWiFiClient.shared().interface(withName: interface), wlan.powerOn() else { return nil }
        let channel = wlan.wlanChannel()
        let band: String?
        switch channel?.channelBand {
        case .band2GHz?: band = "2.4 GHz"
        case .band5GHz?: band = "5 GHz"
        case .band6GHz?: band = "6 GHz"
        default: band = nil
        }
        let standard: String?
        switch wlan.activePHYMode() {
        case .mode11a: standard = "802.11a"
        case .mode11b: standard = "802.11b"
        case .mode11g: standard = "802.11g"
        case .mode11n: standard = "Wi-Fi 4 (802.11n)"
        case .mode11ac: standard = "Wi-Fi 5 (802.11ac)"
        case .mode11ax: standard = "Wi-Fi 6 (802.11ax)"
        default: standard = nil
        }
        let rate = wlan.transmitRate()
        return NetWiFiInfo(interfaceName: interface, ssid: wlan.ssid(),
                           security: NetWiFiSecurity(coreWLANRawValue: wlan.security().rawValue),
                           channel: channel.map { $0.channelNumber }, band: band, standard: standard,
                           transmitRate: rate > 0 ? rate : nil)
    }

    // MARK: - Routing table

    /// One entry of the kernel routing table (IPv4).
    struct RouteEntry: Sendable, Hashable {
        let destination: String
        /// IPv4 gateway, or a MAC address for ARP entries.
        let gateway: String?
        let interface: String
        let flags: Int32
    }

    /// The default IPv4 gateway from the routing table (the `0.0.0.0` route with RTF_GATEWAY).
    static func defaultGateway() -> (address: String, interface: String)? {
        let routes = routeEntries(flags: RTF_GATEWAY)
        // Prefer the unscoped default route (the one the system uses); fall back to any default.
        let defaults = routes.filter { $0.destination == "0.0.0.0" && $0.gateway != nil }
        let chosen = defaults.first { $0.flags & RTF_IFSCOPE == 0 } ?? defaults.first
        guard let chosen, let gateway = chosen.gateway else { return nil }
        return (gateway, chosen.interface)
    }

    /// ARP cache entries (`arp -an`) of complete, unicast neighbours.
    static func arpEntries() -> [RouteEntry] {
        routeEntries(flags: RTF_LLINFO).filter { entry in
            guard let mac = entry.gateway, mac.count == 17, mac != "ff:ff:ff:ff:ff:ff" else { return false }
            // Multicast MACs (01:00:5e…, 33:33…) belong to group addresses, not devices.
            let first = UInt8(mac.prefix(2), radix: 16) ?? 0
            return first & 0x01 == 0
        }
    }

    /// `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags)`, parsed.
    static func routeEntries(flags: Int32) -> [RouteEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
        for attempt in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            guard size > 0 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size + size / 4 + 1024 * (attempt + 1))
            var length = buffer.count
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            return buffer.withUnsafeBytes { parseRouteMessages(UnsafeRawBufferPointer(rebasing: $0.prefix(length))) }
        }
        return []
    }

    /// Parses routing messages (`rt_msghdr` + sockaddrs). Bounds-checked; stops at the first malformed message.
    static func parseRouteMessages(_ buffer: UnsafeRawBufferPointer) -> [RouteEntry] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var entries: [RouteEntry] = []
        var offset = 0
        while offset + headerSize <= buffer.count {
            let header = buffer.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= buffer.count else { break }
            var cursor = offset + headerSize
            let end = offset + length
            var destination: String?
            var gateway: String?
            for index in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << index) != 0 {
                guard cursor + 2 <= end else { break }
                let saLength = Int(buffer[cursor])
                let family = Int32(buffer[cursor + 1])
                let consumed = saLength > 0 ? (1 + ((saLength - 1) | (MemoryLayout<UInt32>.size - 1))) : MemoryLayout<UInt32>.size
                guard cursor + max(saLength, 2) <= end else { break }
                if index == Int(RTAX_DST), family == AF_INET, saLength >= 8 {
                    destination = PortSysProc.render(ipv4: in_addr(s_addr: buffer.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self)))
                } else if index == Int(RTAX_GATEWAY) {
                    if family == AF_INET, saLength >= 8 {
                        gateway = PortSysProc.render(ipv4: in_addr(s_addr: buffer.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self)))
                    } else if family == AF_LINK, saLength >= 8 {
                        // sockaddr_dl: len, family, index(2), type, nlen, alen, slen, data[nlen + alen…]
                        let nameLength = Int(buffer[cursor + 5])
                        let addressLength = Int(buffer[cursor + 6])
                        let start = cursor + 8 + nameLength
                        if addressLength == 6, start + 6 <= end {
                            gateway = (0..<6).map { String(format: "%02x", buffer[start + $0]) }.joined(separator: ":")
                        }
                    }
                }
                cursor += consumed
            }
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let interface = if_indextoname(UInt32(header.rtm_index), &name) != nil ? String(nulTerminated: name) : ""
            if let destination {
                // "0.0.0.0" renders as "*" in PortSysProc: keep the route table's own spelling.
                let shown = destination == "*" ? "0.0.0.0" : destination
                entries.append(RouteEntry(destination: shown, gateway: gateway == "*" ? nil : gateway,
                                          interface: interface, flags: header.rtm_flags))
            }
            offset += length
        }
        return entries
    }

    // MARK: - Firewall

    /// The application firewall's state, read with `socketfilterfw` as the Security page does.
    static func firewall() async -> NetFirewallInfo {
        let tool = SecurityPostureChecker.socketfilterfw
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return NetFirewallInfo(enabled: nil, blocksAllIncoming: nil, stealthMode: nil)
        }
        async let global = try? ProcessRunner.run(tool, arguments: ["--getglobalstate"], timeout: 10)
        async let stealth = try? ProcessRunner.run(tool, arguments: ["--getstealthmode"], timeout: 10)
        let state = await global.map { SecurityPostureParser.firewall($0.combinedOutput) }
        let stealthMode = await stealth.flatMap { SecurityPostureParser.stealthMode($0.combinedOutput) }
        return NetFirewallInfo(enabled: state?.enabled, blocksAllIncoming: state?.blocksAll, stealthMode: stealthMode)
    }
}
