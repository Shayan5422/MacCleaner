import Foundation

/// How a Network Check row reads.
enum NetCheckSeverity: Int, Sendable, Comparable, Hashable {
    /// Checked and fine.
    case good = 0
    /// Worth knowing, nothing to do.
    case info = 1
    /// Worth checking: may be intended, may not be.
    case attention = 2
    /// Likely a problem.
    case risk = 3

    static func < (lhs: NetCheckSeverity, rhs: NetCheckSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .good: return "OK"
        case .info: return "Info"
        case .attention: return "Check"
        case .risk: return "Risk"
        }
    }

    var symbolName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .risk: return "xmark.octagon.fill"
        }
    }

    /// Counted in "N things to check".
    var needsAttention: Bool { self >= .attention }
}

/// A button on a check row.
struct NetCheckAction: Sendable, Hashable {
    let title: String
    let url: URL
}

/// One row of the Network Check.
struct NetCheckItem: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case connection, wifiSecurity, router, dns, proxies, firewall, exposedServices, devices
    }

    let kind: Kind
    var severity: NetCheckSeverity
    let title: String
    /// Short status shown next to the title ("WPA3 Personal", "Off", "2 set").
    let status: String
    /// What was found, in plain English.
    let explanation: String
    /// What to do (nil when nothing).
    let recommendation: String?
    var details: [String] = []
    var actions: [NetCheckAction] = []

    var id: Kind { kind }
}

// MARK: - Facts the checks are made from

/// The interface that carries the default route.
struct NetInterfaceInfo: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case wifi, ethernet, vpn, cellular, other
    }

    let bsdName: String
    /// "Wi-Fi", "Ethernet", "Thunderbolt Bridge", "USB 10/100/1000 LAN"…
    let displayName: String
    let kind: Kind
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
}

/// Wi-Fi security as reported by CoreWLAN (`CWSecurity`).
enum NetWiFiSecurity: Sendable, Hashable {
    case open, wep, dynamicWEP, wpaPersonal, wpaPersonalMixed, wpa2Personal, personal, wpaEnterprise,
         wpaEnterpriseMixed, wpa2Enterprise, enterprise, wpa3Personal, wpa3Enterprise, wpa3Transition,
         enhancedOpen, enhancedOpenTransition, unknown

    /// Maps `CWSecurity.rawValue` (0 none, 1 WEP, 2 WPA Personal, 3 WPA/WPA2 Personal, 4 WPA2 Personal, 5 Personal,
    /// 6 Dynamic WEP, 7 WPA Enterprise, 8 WPA/WPA2 Enterprise, 9 WPA2 Enterprise, 10 Enterprise, 11 WPA3 Personal,
    /// 12 WPA3 Enterprise, 13 WPA3 Transition, 14 OWE, 15 OWE Transition).
    init(coreWLANRawValue raw: Int) {
        switch raw {
        case 0: self = .open
        case 1: self = .wep
        case 2: self = .wpaPersonal
        case 3: self = .wpaPersonalMixed
        case 4: self = .wpa2Personal
        case 5: self = .personal
        case 6: self = .dynamicWEP
        case 7: self = .wpaEnterprise
        case 8: self = .wpaEnterpriseMixed
        case 9: self = .wpa2Enterprise
        case 10: self = .enterprise
        case 11: self = .wpa3Personal
        case 12: self = .wpa3Enterprise
        case 13: self = .wpa3Transition
        case 14: self = .enhancedOpen
        case 15: self = .enhancedOpenTransition
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .open: return "Open (no password)"
        case .wep: return "WEP"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "WPA2/WPA3 Personal"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "WPA2/WPA3 Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .enhancedOpen, .enhancedOpenTransition: return "Enhanced Open (OWE)"
        case .unknown: return "Unknown"
        }
    }

    var severity: NetCheckSeverity {
        switch self {
        case .open, .wep, .dynamicWEP: return .risk
        case .wpaPersonal, .wpaEnterprise, .enhancedOpen, .enhancedOpenTransition: return .attention
        case .wpaPersonalMixed, .wpaEnterpriseMixed, .wpa2Personal, .personal, .wpa2Enterprise, .enterprise,
             .wpa3Personal, .wpa3Enterprise, .wpa3Transition: return .good
        case .unknown: return .info
        }
    }
}

struct NetWiFiInfo: Sendable, Hashable {
    let interfaceName: String
    /// nil when macOS hides the name (Mac Cleaner has no Location access, which macOS requires for it).
    let ssid: String?
    let security: NetWiFiSecurity
    let channel: Int?
    /// "2.4 GHz", "5 GHz", "6 GHz".
    let band: String?
    /// "Wi-Fi 6 (802.11ax)"…
    let standard: String?
    /// Mbit/s.
    let transmitRate: Double?
}

/// The default gateway.
struct NetRouterInfo: Sendable, Hashable {
    let address: String
    let interface: String?
    /// From the ARP cache, when known.
    let macAddress: String?
}

/// One DNS server with what Mac Cleaner can honestly say about it.
struct NetDNSServer: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case router, privateNetwork, knownPublic, unknownPublic, loopback, other
    }

    let address: String
    let kind: Kind
    /// "Cloudflare", "Google Public DNS", "Your router", "Private network address", "This Mac"…
    let label: String

    var id: String { address }
}

struct NetDNSInfo: Sendable, Hashable {
    let servers: [NetDNSServer]
    /// Set by hand in System Settings (Network › Details › DNS), not provided by the network.
    let isManual: Bool
    let searchDomains: [String]
}

struct NetProxyEntry: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case http = "Web proxy (HTTP)"
        case https = "Secure web proxy (HTTPS)"
        case socks = "SOCKS proxy"
        case ftp = "FTP proxy"
        case rtsp = "Streaming proxy (RTSP)"
        case gopher = "Gopher proxy"
        case autoConfig = "Automatic proxy configuration"
        case autoDiscovery = "Auto proxy discovery (WPAD)"
    }

    let kind: Kind
    /// "proxy.example:8080", a PAC URL, or nil for auto discovery.
    let value: String?

    var id: String { kind.rawValue + (value ?? "") }
}

struct NetProxyInfo: Sendable, Hashable {
    let entries: [NetProxyEntry]
    let exceptions: [String]
}

struct NetFirewallInfo: Sendable, Hashable {
    let enabled: Bool?
    let blocksAllIncoming: Bool?
    let stealthMode: Bool?
}

/// A listening socket other devices can reach.
struct NetExposedListener: Sendable, Hashable, Identifiable {
    let port: UInt16
    let address: String
    let pid: Int32
    let processName: String
    let isCurrentUser: Bool
    let service: NetKnownService?

    var id: String { "\(port)|\(address)|\(pid)" }
}

/// A device in this Mac's ARP cache (it talked to it recently).
struct NetDevice: Sendable, Hashable, Identifiable {
    let address: String
    let macAddress: String
    let interface: String
    var hostName: String?
    let isThisMac: Bool
    let isRouter: Bool

    var id: String { address + "|" + interface }
}

/// Everything one Network Check found.
struct NetCheckReport: Sendable {
    let date: Date
    let items: [NetCheckItem]
    let interface: NetInterfaceInfo?
    let wifi: NetWiFiInfo?
    let router: NetRouterInfo?
    let dns: NetDNSInfo
    let proxies: NetProxyInfo
    let firewall: NetFirewallInfo
    let exposed: [NetExposedListener]
    let devices: [NetDevice]
    /// macOS provided its system-wide socket list (other users' and macOS's listeners were checked).
    let systemListenersAvailable: Bool

    var attentionCount: Int { items.filter { $0.severity.needsAttention }.count }
}
