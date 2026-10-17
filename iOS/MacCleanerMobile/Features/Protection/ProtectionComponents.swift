import SafariServices
import SwiftUI

/// One row of the security checkup.
struct CheckupItem: Identifiable {
    enum Tone: Equatable {
        case good, attention, info, neutral, unknown, checking
    }

    var id: String
    var title: String
    var symbol: String
    var tint: Color
    /// "On", "Update available", …
    var state: String
    var tone: Tone
    var detail: String
    var guide: GuideKey

    var linkTitle: String {
        switch tone {
        case .attention: return "How to fix"
        case .unknown: return "How to check"
        case .good, .info, .neutral, .checking: return "Learn more"
        }
    }
}

extension ProtectionModel {
    /// Passcode, Face ID, iOS version, Safari protection, then VPN and proxy (information only).
    var checkupItems: [CheckupItem] {
        [passcodeItem, biometricsItem, softwareItem, safariItem, networkItem]
    }

    /// The checks behind the summary. VPN is information only, and a device without a sensor has no Face ID check.
    var checkTally: (passed: Int, total: Int) {
        var passed = 0
        var total = 0
        func count(_ isOK: Bool?) {
            total += 1
            if isOK == true { passed += 1 }
        }
        count(passcodeSet)
        switch biometrics {
        case .unavailable?: break
        case .enrolled?, .lockedOut?: count(true)
        default: count(false)
        }
        count(systemUpToDate)
        count(safariProtectionEnabled)
        return (passed, total)
    }

    private var passcodeItem: CheckupItem {
        func item(_ state: String, _ tone: CheckupItem.Tone, _ detail: String) -> CheckupItem {
            CheckupItem(id: "passcode", title: "Passcode", symbol: "lock.fill", tint: ProtectionPalette.green,
                        state: state, tone: tone, detail: detail, guide: .passcode)
        }
        let device = self.device.deviceWord
        switch passcode {
        case .set?: return item("On", .good, "Your \(device) locks, and its data is encrypted.")
        case .notSet?: return item("Off", .attention, "Anyone who picks up your \(device) can open it and see your data.")
        case .unknown?: return item("Unknown", .unknown, "iOS didn't say whether a passcode is set.")
        case nil: return item("Checking", .checking, "Checking…")
        }
    }

    private var biometricsItem: CheckupItem {
        let kind = biometrics?.kind
        let name = kind?.name ?? (device.isPad ? "Touch ID or Face ID" : "Face ID or Touch ID")
        func item(_ state: String, _ tone: CheckupItem.Tone, _ detail: String) -> CheckupItem {
            CheckupItem(id: "biometrics", title: name, symbol: kind?.symbol ?? "faceid", tint: ProtectionPalette.green,
                        state: state, tone: tone, detail: detail, guide: .passcode)
        }
        let device = self.device.deviceWord
        switch biometrics {
        case .enrolled?: return item("On", .good, "\(name) unlocks your \(device), so a long passcode is easy to use.")
        case .notEnrolled?: return item("Not set up", .attention, "\(name) makes a long passcode easy to live with.")
        case .lockedOut?: return item("Locked", .info, "\(name) is set up but locked. Enter your passcode to use it again.")
        case .unavailable?: return item("Not available", .neutral, "This \(device) doesn't have Face ID or Touch ID.")
        case .unknown?: return item("Unknown", .unknown, "iOS didn't say whether \(name) is set up.")
        case nil: return item("Checking", .checking, "Checking…")
        }
    }

    private var softwareItem: CheckupItem {
        func item(_ state: String, _ tone: CheckupItem.Tone, _ detail: String) -> CheckupItem {
            CheckupItem(id: "software", title: "\(systemName) version", symbol: "arrow.triangle.2.circlepath", tint: ProtectionPalette.gray,
                        state: state, tone: tone, detail: detail, guide: .updateSystem)
        }
        let running = "\(systemName) \(runningVersion)"
        let checked = softwareCheckedAt.map { " Checked \(DateFormatting.relative($0))." } ?? ""
        switch software {
        case .upToDate(let newer)?:
            if let newer {
                return item("Up to date", .good, "\(running) still gets security updates. \(systemName) \(newer) is also available." + checked)
            }
            return item("Up to date", .good, "\(running) is the latest version for your \(device.deviceWord)." + checked)
        case .updateAvailable(let version, _)?:
            return item("Update available", .attention, "\(systemName) \(version) is available. You have \(running).")
        case .couldNotCheck(let problem)?:
            let reason: String
            switch problem {
            case .offline: reason = "Couldn't reach Apple's update catalog. Check your connection, then pull to refresh."
            case .unknownModel: reason = "Apple's update catalog doesn't list this model (\(device.modelIdentifier))."
            case .unreadable, .server: reason = "Apple's update catalog couldn't be read. Mac Cleaner tries again later."
            }
            return item("Couldn't check", .unknown, reason + " You have \(running).")
        case nil:
            return item("Checking", .checking, "Comparing \(running) with Apple's update catalog…")
        }
    }

    private var safariItem: CheckupItem {
        func item(_ state: String, _ tone: CheckupItem.Tone, _ detail: String) -> CheckupItem {
            CheckupItem(id: "safari", title: "Safari protection", symbol: "safari", tint: ProtectionPalette.blue,
                        state: state, tone: tone, detail: detail, guide: .safariProtection)
        }
        switch safariExtension {
        case .on?:
            if let blocklist = feedState.blocklist, blocklist.siteCount > 0 {
                return item("On", .good, "Blocking \(NumberFormatting.count(blocklist.siteCount, "malware site")) in Safari.")
            }
            return item("On", .good, "Mac Cleaner Protection is on. Its lists download while the app is open.")
        case .off?: return item("Off", .attention, "Turn it on in Settings to block sites that spread malware.")
        case .unknown?: return item("Unknown", .unknown, "iOS didn't say whether Mac Cleaner Protection is on.")
        case nil: return item("Checking", .checking, "Checking…")
        }
    }

    private var networkItem: CheckupItem {
        func item(_ state: String, _ tone: CheckupItem.Tone, _ detail: String) -> CheckupItem {
            CheckupItem(id: "network", title: "VPN and proxy", symbol: "network", tint: ProtectionPalette.indigo,
                        state: state, tone: tone, detail: detail, guide: .profiles)
        }
        let fine = "That's fine if you, or your work or school, set it up."
        switch networkRoute {
        case .direct?: return item("None", .neutral, "Your traffic isn't going through a VPN or a proxy.")
        case .vpn?: return item("VPN on", .info, "A VPN is connected. \(fine)")
        case .proxy?: return item("Proxy on", .info, "A proxy is set for this network. \(fine)")
        case .vpnAndProxy?: return item("VPN and proxy", .info, "A VPN is connected and a proxy is set. \(fine)")
        case .unknown?: return item("Unknown", .unknown, "Couldn't read the network settings.")
        case nil: return item("Checking", .checking, "Checking…")
        }
    }
}

extension View {
    /// Keeps a scrolling page at a comfortable reading width on iPad.
    func readableColumn() -> some View {
        frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
}

/// The Protect tab's colors (Settings' icon colors).
enum ProtectionPalette {
    static let green = Color(red: 0.20, green: 0.74, blue: 0.36)
    static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let gray = Color(red: 0.50, green: 0.52, blue: 0.56)
    static let indigo = Color(red: 0.36, green: 0.40, blue: 0.92)
}

/// A check's state: a colored symbol and a word or two.
struct StateBadge: View {
    var text: String
    var tone: CheckupItem.Tone

    var body: some View {
        if tone == .checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        } else {
            Label(text, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .checking: return "circle.dotted"
        }
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .attention: return .orange
        case .info: return .blue
        case .neutral, .unknown, .checking: return .secondary
        }
    }
}

/// A checkup row: the check, its state, what it means and a link to the matching guide.
struct CheckupRow: View {
    var item: CheckupItem
    var guideContext: GuideContext

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: item.symbol, tint: item.tint, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Spacer(minLength: 0)
                        StateBadge(text: item.state, tone: item.tone)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        StateBadge(text: item.state, tone: item.tone)
                    }
                }
                .accessibilityElement(children: .combine)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    GuideDetailView(guide: GuideLibrary.guide(item.guide), context: guideContext)
                } label: {
                    Text(item.linkTitle).font(.subheadline.weight(.semibold))
                }
                .accessibilityHint("Opens the guide for \(item.title)")
            }
        }
        .padding(.vertical, 4)
    }

    private var title: some View {
        Text(item.title).font(.body.weight(.semibold))
    }
}

/// Opens Settings at Mac Cleaner Protection, with the API Safari offers on iOS 26.2 and later.
struct SafariExtensionsButton: View {
    static var isAvailable: Bool {
        if #available(iOS 26.2, *) { return true }
        return false
    }

    var body: some View {
        if #available(iOS 26.2, *) {
            Button {
                Task { try? await SFSafariSettings.openExtensionsSettings(forIdentifiers: [SecurityChecks.contentBlockerID]) }
            } label: {
                Label("Open Safari Extensions", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ProtectionPalette.blue)
        }
    }
}

/// Safari protection: on or off, how many sites the rules block and when the lists were updated,
/// or how to turn it on.
struct SafariProtectionCard: View {
    var model: ProtectionModel
    var guideContext: GuideContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        IconTile(symbol: "safari", tint: ProtectionPalette.blue, size: 44)
                        Text("Safari protection").font(.headline)
                        StateBadge(text: stateText, tone: tone)
                    }
                } else {
                    HStack(spacing: 12) {
                        IconTile(symbol: "safari", tint: ProtectionPalette.blue, size: 44)
                        Text("Safari protection").font(.headline)
                        Spacer(minLength: 8)
                        StateBadge(text: stateText, tone: tone)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            switch model.safariExtension {
            case .on?: onContent
            case .off?, .unknown?: offContent
            case nil: EmptyView()
            }

            if model.isUpdatingLists {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.updateMessage ?? "Updating the lists…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let problem = model.safariReloadProblem ?? model.listProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !model.canShareRulesWithSafari {
                Label("Safari can't get the lists because the app's shared storage is missing. Reinstalling Mac Cleaner fixes this.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Text("Blocks sites on abuse.ch's URLhaus and ThreatFox lists, in Safari and in pages apps open with Safari. It can't block every bad site, and other browsers aren't covered.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateText: String {
        switch model.safariExtension {
        case .on?: return "On"
        case .off?: return "Off"
        case .unknown?: return "Unknown"
        case nil: return "Checking"
        }
    }

    private var tone: CheckupItem.Tone {
        switch model.safariExtension {
        case .on?: return .good
        case .off?: return .attention
        case .unknown?: return .unknown
        case nil: return .checking
        }
    }

    @ViewBuilder
    private var onContent: some View {
        if let blocklist = model.feedState.blocklist, blocklist.ruleCount > 0 {
            HStack(spacing: 10) {
                BlockedCount(value: blocklist.siteCount, singular: "site blocked", plural: "sites blocked")
                BlockedCount(value: blocklist.linkCount, singular: "link blocked", plural: "links blocked")
            }
        } else if !model.isUpdatingLists {
            Text("The lists haven't been downloaded yet.").font(.subheadline).foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
            Text(model.listsUpdated.map { "Updated \(DateFormatting.relative($0))" } ?? "Not updated yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Update Now") {
                Task { await model.updateListsNow() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isUpdatingLists)
        }
    }

    @ViewBuilder
    private var offContent: some View {
        Text(model.safariExtension == .off
             ? "Turn on Mac Cleaner Protection to block sites that spread malware:"
             : "iOS didn't say whether Mac Cleaner Protection is on. To check, open:")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        Text(settingsPath)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        Text(model.safariExtension == .off
             ? "Then turn on Allow Extension and come back to Mac Cleaner."
             : "Allow Extension should be on.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        SafariExtensionsButton()
        NavigationLink {
            GuideDetailView(guide: GuideLibrary.guide(.safariProtection), context: guideContext)
        } label: {
            Text("Show me how").font(.subheadline.weight(.semibold))
        }
    }

    /// Settings › Apps › Safari on iOS 18 and later, Settings › Safari on iOS 17.
    private var settingsPath: String {
        model.device.systemMajorVersion >= 18
            ? "Settings › Apps › Safari › Extensions › Mac Cleaner Protection"
            : "Settings › Safari › Extensions › Mac Cleaner Protection"
    }
}

/// "4,210 sites blocked".
private struct BlockedCount: View {
    var value: Int
    var singular: String
    var plural: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NumberFormatting.count(value))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value == 1 ? singular : plural).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
