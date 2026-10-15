import SwiftUI

struct DashboardView: View {
    @Bindable var model: DashboardViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .dashboard, title: greeting, subtitle: model.systemDescription) {
                Button {
                    model.startSmartScan?()
                } label: {
                    Label("Smart Scan", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.smartScan.tint)
                .controlSize(.large)
            }
            FullDiskAccessBanner(reason: "Grant Full Disk Access so scans can include app containers, Safari data, Mail and the Trash.")

            hero

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                storageCard
                cpuCard
                memoryCard
            }

            HStack(alignment: .top, spacing: 16) {
                securityCard
                activityCard
            }

            quickActions
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Overview"
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.attentionCount == 0 ? "Your Mac is in good shape" : "\(model.attentionCount) area\(model.attentionCount == 1 ? "" : "s") could use attention")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Based on free space, memory pressure, macOS protections and your last Smart Scan. Click an item for details.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(model.healthItems) { item in
                        Button {
                            model.navigate?(item.destination)
                        } label: {
                            HealthRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                RingGauge(fraction: reclaimFraction, tint: AppSection.smartScan.tint, lineWidth: 14) {
                    VStack(spacing: 2) {
                        Text(model.services.settings.lastSmartScanDate == nil ? "—" : ByteFormatting.string(model.services.settings.lastSmartScanReclaimable))
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                        Text("can be freed").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
                .frame(width: 160, height: 160)
                Button(model.services.settings.lastSmartScanDate == nil ? "Run First Scan" : "Scan Again") { model.startSmartScan?() }
                    .controlSize(.large)
            }
        }
        .card(padding: 22)
    }

    private var reclaimFraction: Double {
        guard let volume = model.volume, model.services.settings.lastSmartScanDate != nil else { return 0 }
        return min(1, Double(model.services.settings.lastSmartScanReclaimable) / Double(max(volume.usedCapacity, 1)) * 4)
    }

    // MARK: - Metric cards

    private var storageCard: some View {
        Card("Storage", symbol: "internaldrive", accessory: {
            Button("Analyze") { model.navigate?(.storage) }.buttonStyle(.link)
        }) {
            if let volume = model.volume {
                HStack(spacing: 16) {
                    RingGauge(fraction: volume.usedFraction, tint: volume.usedFraction > 0.9 ? .orange : AppSection.storage.tint) {
                        Text(NumberFormatting.percent(volume.usedFraction))
                            .font(.headline.monospacedDigit())
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.name).font(.headline)
                        KeyValueRow(key: "Used", value: ByteFormatting.string(volume.usedCapacity))
                        KeyValueRow(key: "Available", value: ByteFormatting.string(volume.effectiveAvailable))
                        if volume.purgeableCapacity > 0 {
                            KeyValueRow(key: "Purgeable", value: ByteFormatting.string(volume.purgeableCapacity))
                                .help("Space macOS can free automatically (caches, iCloud files, snapshots).")
                        }
                    }
                }
            } else {
                Text("Couldn't read the startup disk.").foregroundStyle(.secondary)
            }
        }
    }

    private var cpuCard: some View {
        Card("Processor", symbol: "cpu", accessory: {
            Button("Monitor") { model.navigate?(.performance) }.buttonStyle(.link)
        }) {
            HStack(spacing: 16) {
                RingGauge(fraction: model.monitor.latest?.cpuUsage ?? 0, tint: AppSection.performance.tint) {
                    Text(model.monitor.latest.map { NumberFormatting.percent($0.cpuUsage) } ?? "—")
                        .font(.headline.monospacedDigit())
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU load").font(.headline)
                    if let sample = model.monitor.latest {
                        KeyValueRow(key: "Cores", value: "\(sample.perCoreUsage.count)")
                        KeyValueRow(key: "Thermal state", value: thermalTitle(sample.thermalState))
                    } else {
                        Text("Measuring…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var memoryCard: some View {
        Card("Memory", symbol: "memorychip", accessory: {
            Button("Details") { model.navigate?(.performance) }.buttonStyle(.link)
        }) {
            HStack(spacing: 16) {
                let fraction = model.monitor.latest.map { Double($0.memoryUsed) / Double(max($0.memoryTotal, 1)) } ?? 0
                RingGauge(fraction: fraction, tint: model.monitor.latest?.memoryPressure.tint ?? .green) {
                    Text(model.monitor.latest == nil ? "—" : NumberFormatting.percent(fraction))
                        .font(.headline.monospacedDigit())
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory pressure").font(.headline)
                    if let sample = model.monitor.latest {
                        KeyValueRow(key: "Pressure", value: sample.memoryPressure.title, valueColor: sample.memoryPressure.tint)
                        KeyValueRow(key: "Used", value: "\(ByteFormatting.memory(sample.memoryUsed)) of \(ByteFormatting.memory(sample.memoryTotal))")
                        KeyValueRow(key: "Swap", value: sample.swapUsed == 0 ? "None" : ByteFormatting.memory(sample.swapUsed))
                    } else {
                        Text("Measuring…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func thermalTitle(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Security & activity

    private var securityCard: some View {
        Card("Protection", symbol: "lock.shield", accessory: {
            Button("Open Security") { model.navigate?(.security) }.buttonStyle(.link)
        }) {
            if let posture = model.posture {
                VStack(spacing: 8) {
                    protectionRow("Gatekeeper", posture.gatekeeperEnabled, help: "Only allows apps from identified developers.")
                    protectionRow("System Integrity Protection", posture.sipEnabled, help: "Protects macOS system files.")
                    protectionRow("FileVault disk encryption", posture.fileVaultEnabled, help: "Encrypts your startup disk.")
                    protectionRow("Firewall", posture.firewallEnabled, help: "Blocks unwanted incoming connections.")
                    if let xprotect = posture.xprotectVersion {
                        KeyValueRow(key: "XProtect definitions", value: xprotect)
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking protections…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func protectionRow(_ title: String, _ value: Bool?, help: String) -> some View {
        HStack {
            Image(systemName: value == true ? "checkmark.circle.fill" : value == false ? "xmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(value == true ? .green : value == false ? .red : .secondary)
            Text(title)
            Spacer()
            Text(value == true ? "On" : value == false ? "Off" : "Unknown")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(help)
    }

    private var activityCard: some View {
        Card("Recent Cleanups", symbol: "clock.arrow.circlepath", accessory: {
            Button("History") { model.navigate?(.history) }.buttonStyle(.link)
        }) {
            if model.recentEntries.isEmpty {
                Text("Nothing cleaned yet. Results of every cleanup appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.recentEntries) { entry in
                        HStack {
                            Image(systemName: entry.dryRun ? "doc.text.magnifyingglass" : "checkmark.circle")
                                .foregroundStyle(entry.dryRun ? Color.secondary : .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).font(.callout).lineLimit(1)
                                Text(DateFormatting.relative(entry.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SizeText(bytes: entry.bytes, font: .callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    KeyValueRow(key: "Total cleaned with Mac Cleaner", value: ByteFormatting.string(model.totalCleaned))
                }
            }
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach([AppSection.systemJunk, .uninstaller, .storage, .duplicates, .privacy, .developer, .startup, .updates], id: \.self) { section in
                    Button {
                        model.navigate?(section)
                    } label: {
                        HStack(spacing: 10) {
                            IconTile(section: section, size: 30)
                            Text(section.title).font(.callout.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.cardBackground))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.subtleBorder))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct HealthRow: View {
    var item: DashboardViewModel.HealthItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(item.title).font(.callout.weight(.medium)).frame(width: 80, alignment: .leading)
            Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(hovering ? Color.hoverFill : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch item.level {
        case .good: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .problem: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch item.level {
        case .good: return .green
        case .attention: return .orange
        case .problem: return .red
        case .unknown: return .secondary
        }
    }
}
