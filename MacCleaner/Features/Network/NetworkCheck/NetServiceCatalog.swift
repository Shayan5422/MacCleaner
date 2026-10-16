import Foundation

/// A macOS sharing feature or well-known service behind a listening port.
struct NetKnownService: Sendable, Hashable {
    let name: String
    /// What it lets other devices do.
    let summary: String
    /// Where to turn it off ("System Settings › General › Sharing › Remote Login"), or how it goes away.
    let settingsPath: String
    let settingsURL: URL?
    let severity: NetCheckSeverity

    /// "Turn it off in System Settings › General › Sharing › Remote Login." / "Stops when … are off."
    var howToTurnOff: String {
        settingsPath.hasPrefix("System Settings") ? "Turn it off in \(settingsPath)." : "\(settingsPath)."
    }
}

/// Well-known ports and macOS services. No guessing: a port only gets a name when it is a fixed, well-known one
/// (or the listening process says what it is).
enum NetServiceCatalog {
    static let sharingSettings = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")
    static let airDropSettings = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")
    static let networkSettings = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")
    static let wifiSettings = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")

    private static let sharing = "System Settings › General › Sharing"

    static let remoteLogin = NetKnownService(
        name: "Remote Login (SSH)", summary: "Lets anyone who can reach this Mac try to sign in to a command line.",
        settingsPath: sharing + " › Remote Login", settingsURL: sharingSettings, severity: .attention)
    static let screenSharing = NetKnownService(
        name: "Screen Sharing", summary: "Lets other computers view and control this Mac's screen after signing in.",
        settingsPath: sharing + " › Screen Sharing", settingsURL: sharingSettings, severity: .attention)
    static let remoteManagement = NetKnownService(
        name: "Remote Management", summary: "Lets Apple Remote Desktop administrators observe and control this Mac.",
        settingsPath: sharing + " › Remote Management", settingsURL: sharingSettings, severity: .attention)
    static let fileSharingSMB = NetKnownService(
        name: "File Sharing (SMB)", summary: "Shares folders with other computers on the network.",
        settingsPath: sharing + " › File Sharing", settingsURL: sharingSettings, severity: .attention)
    static let fileSharingAFP = NetKnownService(
        name: "File Sharing (AFP)", summary: "Shares folders with older Macs on the network.",
        settingsPath: sharing + " › File Sharing", settingsURL: sharingSettings, severity: .attention)
    static let remoteAppleEvents = NetKnownService(
        name: "Remote Application Scripting", summary: "Lets scripts on other Macs control apps on this Mac.",
        settingsPath: sharing + " › Remote Application Scripting", settingsURL: sharingSettings, severity: .attention)
    static let printerSharing = NetKnownService(
        name: "Printer Sharing", summary: "Shares this Mac's printers with other computers.",
        settingsPath: sharing + " › Printer Sharing", settingsURL: sharingSettings, severity: .info)
    static let mediaSharing = NetKnownService(
        name: "Media Sharing", summary: "Shares your music and video library with devices on the network.",
        settingsPath: sharing + " › Media Sharing", settingsURL: sharingSettings, severity: .info)
    static let kerberos = NetKnownService(
        name: "Kerberos (macOS)", summary: "macOS's sign-in service used by Screen Sharing and File Sharing.",
        settingsPath: "It stops when Screen Sharing and File Sharing are off", settingsURL: sharingSettings, severity: .info)
    static let airPlayReceiver = NetKnownService(
        name: "AirPlay Receiver", summary: "Lets nearby devices play audio and video on this Mac.",
        settingsPath: "System Settings › General › AirDrop & Handoff › AirPlay Receiver", settingsURL: airDropSettings,
        severity: .info)
    static let continuity = NetKnownService(
        name: "Continuity (macOS)", summary: "Handoff, Universal Clipboard and AirDrop with your other Apple devices.",
        settingsPath: "System Settings › General › AirDrop & Handoff", settingsURL: airDropSettings, severity: .info)
    static let internetSharing = NetKnownService(
        name: "Internet Sharing", summary: "Shares this Mac's internet connection with other devices.",
        settingsPath: sharing + " › Internet Sharing", settingsURL: sharingSettings, severity: .attention)

    /// The service behind a listening socket: by process name first (it can't lie about its own role as easily as a
    /// port number can be reused), then by fixed port for sockets macOS opens on a service's behalf (launchd).
    static func service(port: UInt16, processName: String) -> NetKnownService? {
        switch processName {
        case "sshd", "sshd-session": return remoteLogin
        case "screensharingd": return screenSharing
        case "ARDAgent": return remoteManagement
        case "smbd": return fileSharingSMB
        case "AppleFileServer": return fileSharingAFP
        case "AEServer": return remoteAppleEvents
        case "cupsd": return printerSharing
        case "kdc": return kerberos
        case "ControlCenter", "AirPlayXPCHelper": return port == 7000 || port == 5000 || port == 7100 ? airPlayReceiver : nil
        case "rapportd", "sharingd": return continuity
        case "bootpd", "natpmpd": return internetSharing
        default: break
        }
        // launchd holds the listening socket of on-demand services until a client connects.
        guard processName == "launchd" else { return nil }
        switch port {
        case 22: return remoteLogin
        case 88: return kerberos
        case 445: return fileSharingSMB
        case 548: return fileSharingAFP
        case 3031: return remoteAppleEvents
        case 3283: return remoteManagement
        case 5900: return screenSharing
        case 631: return printerSharing
        case 3689: return mediaSharing
        default: return nil
        }
    }

    /// Public DNS resolvers by address.
    static let publicResolvers: [String: String] = {
        var table: [String: String] = [:]
        func add(_ name: String, _ addresses: [String]) { for address in addresses { table[address] = name } }
        add("Cloudflare", ["1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3",
                           "2606:4700:4700::1111", "2606:4700:4700::1001", "2606:4700:4700::1112",
                           "2606:4700:4700::1002", "2606:4700:4700::1113", "2606:4700:4700::1003"])
        add("Google Public DNS", ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"])
        add("Quad9", ["9.9.9.9", "149.112.112.112", "9.9.9.10", "149.112.112.10", "9.9.9.11", "149.112.112.11",
                      "2620:fe::fe", "2620:fe::9", "2620:fe::10", "2620:fe::fe:10", "2620:fe::11", "2620:fe::fe:11"])
        add("OpenDNS (Cisco)", ["208.67.222.222", "208.67.220.220", "208.67.222.123", "208.67.220.123",
                                "2620:119:35::35", "2620:119:53::53"])
        add("AdGuard DNS", ["94.140.14.14", "94.140.15.15", "94.140.14.15", "94.140.15.16",
                            "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"])
        add("CleanBrowsing", ["185.228.168.9", "185.228.169.9", "185.228.168.168", "185.228.169.168"])
        add("Control D", ["76.76.2.0", "76.76.10.0", "2606:1a40::", "2606:1a40:1::"])
        add("NextDNS", ["45.90.28.0", "45.90.30.0"])
        add("DNS.SB", ["185.222.222.222", "45.11.45.11"])
        add("Mullvad DNS", ["194.242.2.2", "194.242.2.3", "194.242.2.4", "194.242.2.5", "194.242.2.9"])
        return table
    }()

    /// Describes a DNS server: the router, a well-known public resolver, a private address or an unknown public one.
    static func describeDNS(_ address: String, router: String?) -> NetDNSServer {
        let plain = address.split(separator: "%").first.map(String.init) ?? address
        if let router, plain == router { return NetDNSServer(address: address, kind: .router, label: "Your router") }
        if let name = publicResolvers[plain.lowercased()] {
            return NetDNSServer(address: address, kind: .knownPublic, label: name)
        }
        switch NetAddress.scope(plain) {
        case .loopback?:
            return NetDNSServer(address: address, kind: .loopback, label: "This Mac (a local DNS service or VPN)")
        case .privateNetwork?, .linkLocal?, .sharedCGNAT?:
            return NetDNSServer(address: address, kind: .privateNetwork, label: "Private network address")
        case .publicInternet?:
            return NetDNSServer(address: address, kind: .unknownPublic, label: "Public server")
        default:
            return NetDNSServer(address: address, kind: .other, label: "Other")
        }
    }
}
