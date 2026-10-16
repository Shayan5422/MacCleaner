import AppKit
import SwiftUI

/// The menu bar popover with the current status values.
struct MenuBarHub: View {
    let environment: AppEnvironment

    var body: some View {
        MenuBarHubView(environment: environment, status: MenuBarStatus.current(environment), updates: AppUpdateController.shared)
    }
}

/// The menu bar popover: status at a glance, quick actions, recent activity, ports and
/// live system activity. Monitoring runs only while it's open.
struct MenuBarHubView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview, activity, ports, system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .activity: return "Activity"
            case .ports: return "Ports"
            case .system: return "System"
            }
        }
    }

    static let width: CGFloat = 360
    static let contentHeight: CGFloat = 372

    let environment: AppEnvironment
    var status: MenuBarStatus
    var updates: AppUpdateController

    @AppStorage("menuBar.selectedTab") private var tab: Tab = .overview
    @State private var holdsMonitor = false
    @State private var holdsProcesses = false
    @State private var volume: VolumeInfo?
    @State private var updatesSummary: UpdatesResultStore.Summary?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var monitor: PerformanceMonitor { environment.monitor }

    var body: some View {
        VStack(spacing: 12) {
            header
            statusStrip
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .frame(height: Self.contentHeight)
        }
        .padding(14)
        .frame(width: Self.width)
        .onAppear {
            AppPresence.shared.openWindowAction = openWindow
            if !holdsMonitor {
                holdsMonitor = true
                monitor.acquire()
            }
            updateProcessHold()
            ProtectionEventLog.shared.markAllSeen()
            refreshDetails()
        }
        .onDisappear {
            if holdsMonitor {
                holdsMonitor = false
                monitor.release()
            }
            if holdsProcesses {
                holdsProcesses = false
                monitor.release(includingProcesses: true)
            }
        }
        .onChange(of: tab) { _, _ in updateProcessHold() }
    }

    /// The process list is only collected while the System tab shows it.
    private func updateProcessHold() {
        let wants = tab == .system && holdsMonitor
        if wants && !holdsProcesses {
            holdsProcesses = true
            monitor.acquire(includingProcesses: true)
        } else if !wants && holdsProcesses {
            holdsProcesses = false
            monitor.release(includingProcesses: true)
        }
    }

    private func refreshDetails() {
        Task {
            volume = await BackgroundWork.run(qos: .userInitiated) { VolumeService.startupVolume() }
            updatesSummary = await UpdatesResultStore.lastKnownSummary()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AppIconImage(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name).font(.headline)
                Text(statusLine.text)
                    .font(.caption)
                    .foregroundStyle(statusLine.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            MenuBarHeaderButton(symbol: "macwindow", label: "Open Mac Cleaner") {
                AppPresence.shared.open(windowID: AppWindowID.main, using: openWindow)
            }
            .keyboardShortcut("o")
            MenuBarHeaderButton(symbol: "gearshape", label: "Settings") {
                AppPresence.shared.bringToFront()
                openSettings()
            }
            .keyboardShortcut(",")
            MenuBarHeaderButton(symbol: "power", label: "Quit Mac Cleaner") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// One line that sums up what needs attention, most important first.
    private var statusLine: (text: String, tint: Color) {
        switch status.protectionState {
        case .threats(let count)?:
            return ("\(count) threat\(count == 1 ? " needs" : "s need") your attention", .red)
        case .off?:
            return ("Real-time protection is off", .orange)
        case .attention(let message)?:
            return (message, .orange)
        default:
            break
        }
        if let release = updates.availableUpdate {
            return ("Mac Cleaner \(release.version) is available", .accentColor)
        }
        let appUpdates = appUpdateCount
        if appUpdates > 0 {
            return ("\(appUpdates) app update\(appUpdates == 1 ? "" : "s") available", .secondary)
        }
        if let volume, volume.usedFraction > 0.95 {
            return ("The startup disk is almost full", .orange)
        }
        return ("All good — watching over your Mac", .secondary)
    }

    private var appUpdateCount: Int {
        environment.updates.hasLoaded ? environment.updates.availableUpdateCount : (updatesSummary?.availableUpdates ?? 0)
    }

    // MARK: Status strip

    private var statusStrip: some View {
        HStack(spacing: 6) {
            protectionTile
            portsTile
            diskTile
            cpuTile
        }
    }

    private var protectionTile: some View {
        let value: (String, Color)
        switch status.protectionState {
        case .protected?: value = ("On", .green)
        case .attention?: value = ("Check", .orange)
        case .threats(let count)?: value = ("\(count) threat\(count == 1 ? "" : "s")", .red)
        case .off?: value = ("Off", .orange)
        case .scanning?: value = ("Scanning", AppSection.antivirus.tint)
        case nil: value = ("—", .secondary)
        }
        return MenuBarStatusTile(title: "Antivirus", value: value.0, symbol: "shield.lefthalf.filled", tint: value.1,
                                 help: status.protectionState == nil ? "Protection status isn't available." : "Antivirus protection")
            .onTapGesture { MenuBarHubActions.open(.antivirus, environment: environment, openWindow: openWindow) }
    }

    private var portsTile: some View {
        let value: String
        switch status.openPortCount {
        case let count? where count > 0: value = "\(count) open"
        case 0?: value = "None"
        default: value = "—"
        }
        return MenuBarStatusTile(title: "Ports", value: value, symbol: "point.3.connected.trianglepath.dotted", tint: AppSection.network.tint,
                                 help: status.openPortCount == nil ? "Open ports aren't available." : "Ports your projects opened")
            .onTapGesture { tab = .ports }
    }

    private var diskTile: some View {
        let tint: Color = (volume?.usedFraction ?? 0) > 0.9 ? .orange : AppSection.storage.tint
        return MenuBarStatusTile(
            title: "Disk",
            value: volume.map { ByteFormatting.string($0.effectiveAvailable) } ?? "—",
            symbol: "internaldrive",
            tint: tint,
            fraction: volume?.usedFraction,
            help: volume.map { "\(ByteFormatting.string($0.effectiveAvailable)) available of \(ByteFormatting.string($0.totalCapacity)) on \($0.name)" } ?? "Reading the startup disk…"
        )
        .onTapGesture { MenuBarHubActions.open(.storage, environment: environment, openWindow: openWindow) }
    }

    private var cpuTile: some View {
        let sample = monitor.latest
        return MenuBarStatusTile(
            title: "CPU",
            value: sample.map { $0.isCPUAvailable ? NumberFormatting.percent($0.cpuUsage) : "—" } ?? "—",
            symbol: "cpu",
            tint: PerformancePalette.cpu,
            fraction: sample?.cpuUsage,
            help: "CPU in use right now"
        )
        .onTapGesture { tab = .system }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            VStack(spacing: 8) {
                MenuBarProtectionSlot(environment: environment)
                maintenanceCard
                MenuBarCard(title: "Recent Activity", symbol: "list.bullet.rectangle", tint: AppSection.security.tint) {
                    if !ProtectionEventLog.shared.events.isEmpty {
                        Button("Show All") { tab = .activity }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                } content: {
                    MenuBarEventList(log: .shared, limit: 3, environment: environment)
                }
            }
        case .activity:
            MenuBarActivitySlot(environment: environment)
        case .ports:
            MenuBarPortsSlot(environment: environment)
        case .system:
            MenuBarMonitorSections(monitor: monitor)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }

    /// Smart Scan, updates and the startup disk: one row each, with its action.
    private var maintenanceCard: some View {
        let settings = environment.services.settings
        let isScanning = environment.smartScan.phase == .scanning
        return MenuBarCard(title: "Maintenance", symbol: "wrench.and.screwdriver", tint: AppSection.smartScan.tint) {
            VStack(spacing: 6) {
                MenuBarHubRow(title: "Smart Scan", subtitle: smartScanText(isScanning: isScanning)) {
                    IconTile(section: .smartScan, size: 22)
                } trailing: {
                    Button(isScanning ? "Show" : (settings.lastSmartScanDate == nil ? "Scan" : "Scan Again")) {
                        if isScanning {
                            MenuBarHubActions.open(.smartScan, environment: environment, openWindow: openWindow)
                        } else {
                            MenuBarHubActions.runSmartScan(environment: environment, openWindow: openWindow)
                        }
                    }
                    .controlSize(.small)
                }
                if let release = updates.availableUpdate {
                    MenuBarHubRow(title: "Mac Cleaner \(release.version) is available", subtitle: "You have \(updates.currentVersion)") {
                        AppIconImage(size: 22)
                    } trailing: {
                        Button("Update…") { AppPresence.shared.open(windowID: AppWindowID.update, using: openWindow) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
                MenuBarHubRow(title: appUpdatesTitle, subtitle: appUpdatesSubtitle) {
                    IconTile(section: .updates, size: 22)
                } trailing: {
                    Button("Open") { MenuBarHubActions.open(.updates, environment: environment, openWindow: openWindow) }
                        .controlSize(.small)
                }
                MenuBarHubRow(title: volume?.name ?? "Startup Disk", subtitle: diskText) {
                    IconTile(section: .storage, size: 22)
                } trailing: {
                    Button("Analyze") { MenuBarHubActions.open(.storage, environment: environment, openWindow: openWindow) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func smartScanText(isScanning: Bool) -> String {
        if isScanning { return "Scanning… \(NumberFormatting.percent(environment.smartScan.overallProgress))" }
        let settings = environment.services.settings
        guard let date = settings.lastSmartScanDate else { return "Not run yet" }
        return "\(ByteFormatting.string(settings.lastSmartScanReclaimable)) found \(DateFormatting.relative(date))"
    }

    private var appUpdatesTitle: String {
        let count = appUpdateCount
        return count > 0 ? "\(count) app update\(count == 1 ? "" : "s")" : "App Updates"
    }

    private var appUpdatesSubtitle: String {
        guard let checked = environment.updates.lastCheckDate ?? updatesSummary?.checkedAt else { return "Not checked yet" }
        return (appUpdateCount > 0 ? "Checked " : "Up to date · checked ") + DateFormatting.relative(checked)
    }

    private var diskText: String {
        guard let volume else { return "Reading the startup disk…" }
        return "\(ByteFormatting.string(volume.effectiveAvailable)) free of \(ByteFormatting.string(volume.totalCapacity))"
    }
}

/// A round icon button of the hub's header.
private struct MenuBarHeaderButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(isHovering ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
