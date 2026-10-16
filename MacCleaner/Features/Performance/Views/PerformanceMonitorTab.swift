import AppKit
import SwiftUI

/// Live system metrics: CPU, memory, network, disk, battery, thermal state and processes.
struct PerformanceMonitorTab: View {
    @Bindable var model: PerformanceViewModel

    private var monitor: PerformanceMonitor { model.monitor }

    var body: some View {
        if let sample = monitor.latest {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                PerformanceEqualHeightRow {
                    PerformanceCPUCard(sample: sample, topology: monitor.topology)
                } trailing: {
                    PerformanceMemoryCard(sample: sample)
                }
                PerformanceCPUHistoryCard(model: model, sample: sample)
                PerformanceEqualHeightRow {
                    PerformanceNetworkCard(model: model, sample: sample)
                } trailing: {
                    PerformanceDiskCard(model: model, sample: sample)
                }
                PerformanceEqualHeightRow {
                    PerformancePowerCard(status: monitor.battery, source: monitor.powerSource, bootDate: model.bootDate)
                } trailing: {
                    PerformanceThermalCard(state: monitor.thermalState)
                }
                PerformanceProcessesCard(model: model)
                PerformanceAlertsCard(model: model)
            }
        } else {
            PerformanceMeasuringView()
        }
    }
}

// MARK: - Layout helpers

/// Two cards side by side with equal heights.
struct PerformanceEqualHeightRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            leading().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            trailing().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled card that stretches to the height its row gives it.
struct PerformancePanel<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer(minLength: 8)
                accessory()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

struct PerformanceMeasuringView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Measuring…").font(.headline)
                Text("Reading CPU, memory, disk and network activity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card()
    }
}

/// Large value with a caption and a colored marker.
struct PerformanceRateStat: View {
    var title: String
    var value: String
    var symbol: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - CPU

struct PerformanceCPUCard: View {
    var sample: PerformanceSample
    var topology: PerformanceCPUTopology

    var body: some View {
        PerformancePanel("CPU", symbol: "cpu") {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: sample.cpuUsage, tint: PerformancePalette.cpu, lineWidth: 11) {
                    VStack(spacing: 0) {
                        Text(sample.isCPUAvailable ? NumberFormatting.percent(sample.cpuUsage) : "—")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("in use").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 116, height: 116)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("CPU usage")
                .accessibilityValue(NumberFormatting.percent(sample.cpuUsage))

                VStack(alignment: .leading, spacing: 7) {
                    KeyValueRow(key: "User", value: NumberFormatting.percent(sample.cpuUserUsage))
                    KeyValueRow(key: "System", value: NumberFormatting.percent(sample.cpuSystemUsage))
                    KeyValueRow(key: "Idle", value: NumberFormatting.percent(max(0, 1 - sample.cpuUsage)))
                    if let load = sample.loadAverage {
                        let values = [load.oneMinute, load.fiveMinutes, load.fifteenMinutes].map { $0.formatted(.number.precision(.fractionLength(2))) }
                        HStack(alignment: .firstTextBaseline) {
                            Text("Load average").foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            // All three values when they fit, otherwise the last minute's.
                            ViewThatFits(in: .horizontal) {
                                Text(values.joined(separator: "  "))
                                Text(values[0])
                            }
                            .monospacedDigit()
                        }
                        .font(.callout)
                        .help("Average number of threads running or waiting over the last 1, 5 and 15 minutes: \(values.joined(separator: ", ")).")
                    }
                }
            }
            if sample.isCPUAvailable {
                Divider()
                PerformanceCoreClusters(sample: sample, topology: topology)
            }
        }
    }
}

/// Average load of the performance and efficiency cores (or of all cores), and the
/// busiest core — the CPU card's counterpart to the memory card's composition.
struct PerformanceCoreClusters: View {
    var sample: PerformanceSample
    var topology: PerformanceCPUTopology

    private struct Cluster {
        var title: String
        var usage: Double
        var color: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(clusters, id: \.title) { cluster in
                HStack(spacing: 10) {
                    Text(cluster.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 120, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(cluster.color.gradient)
                                .frame(width: max(4, proxy.size.width * CGFloat(min(1, max(0, cluster.usage)))))
                        }
                    }
                    .frame(height: 8)
                    Text(NumberFormatting.percent(cluster.usage))
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(cluster.title)
                .accessibilityValue(NumberFormatting.percent(cluster.usage))
            }
            if let busiest {
                Text("Busiest core: \(topology.label(forCore: busiest.index)) at \(NumberFormatting.percent(busiest.usage)) · \(topology.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var clusters: [Cluster] {
        let usage = sample.perCoreUsage
        if let kinds = topology.coreKinds, kinds.count == usage.count {
            let performance = zip(kinds, usage).filter { $0.0 == .performance }.map(\.1)
            let efficiency = zip(kinds, usage).filter { $0.0 == .efficiency }.map(\.1)
            var result: [Cluster] = []
            if !performance.isEmpty {
                result.append(Cluster(title: "Performance cores (\(performance.count))", usage: average(performance), color: PerformancePalette.performanceCore))
            }
            if !efficiency.isEmpty {
                result.append(Cluster(title: "Efficiency cores (\(efficiency.count))", usage: average(efficiency), color: PerformancePalette.efficiencyCore))
            }
            if !result.isEmpty { return result }
        }
        return [Cluster(title: "All \(usage.count) cores", usage: average(usage), color: PerformancePalette.cpu)]
    }

    private var busiest: (index: Int, usage: Double)? {
        sample.perCoreUsage.enumerated().max { $0.element < $1.element }.map { ($0.offset, $0.element) }
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

struct PerformanceCPUHistoryCard: View {
    @Bindable var model: PerformanceViewModel
    var sample: PerformanceSample

    var body: some View {
        let history = model.monitor.history
        let range = model.chartRange.seconds
        let interval = model.monitor.refreshInterval
        let domain = PerformanceChartMath.domain(history: history, range: range)
        Card("CPU History", symbol: "chart.xyaxis.line") {
            Picker("Range", selection: $model.chartRange) {
                ForEach(PerformanceChartRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            PerformanceHistoryChart(
                series: [
                    PerformanceChartSeries(name: "User", color: PerformancePalette.cpu, points: PerformanceChartMath.series(from: history, range: range, interval: interval) { $0.cpuUsage * 100 }),
                    PerformanceChartSeries(name: "System", color: PerformancePalette.cpuSystem, points: PerformanceChartMath.series(from: history, range: range, interval: interval) { $0.cpuSystemUsage * 100 }),
                ],
                domain: domain,
                valueRange: 0...100,
                height: 160,
                valueLabel: { "\(Int($0.rounded()))%" },
                accessibilityLabel: "CPU usage history"
            )
            HStack(spacing: 14) {
                LegendItem(color: PerformancePalette.cpu, label: "User", value: NumberFormatting.percent(sample.cpuUserUsage))
                LegendItem(color: PerformancePalette.cpuSystem, label: "System", value: NumberFormatting.percent(sample.cpuSystemUsage))
                Spacer()
                Text("Every \(Int(interval)) s · this session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if sample.isCPUAvailable {
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Usage per core").font(.subheadline.weight(.medium))
                    Spacer()
                    let topology = model.monitor.topology
                    if topology.coreKinds != nil {
                        LegendItem(color: PerformancePalette.performanceCore, label: "Performance", value: topology.performanceCoreCount.map(String.init))
                        LegendItem(color: PerformancePalette.efficiencyCore, label: "Efficiency", value: topology.efficiencyCoreCount.map(String.init))
                    } else if topology.performanceCoreCount != nil {
                        Text(topology.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                PerformanceCoreChart(usage: sample.perCoreUsage, topology: model.monitor.topology)
            }
        }
    }
}

// MARK: - Memory

struct PerformanceMemoryCard: View {
    var sample: PerformanceSample

    var body: some View {
        let memory = sample.memory
        PerformancePanel("Memory", symbol: "memorychip") {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: sample.memoryUsedFraction, tint: sample.memoryPressure.tint, lineWidth: 11) {
                    VStack(spacing: 0) {
                        Text(PerformanceFormat.memory(sample.memoryUsed))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                        Text("of \(PerformanceFormat.memory(sample.memoryTotal))").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                }
                .frame(width: 116, height: 116)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Memory used")
                .accessibilityValue("\(PerformanceFormat.memory(sample.memoryUsed)) of \(PerformanceFormat.memory(sample.memoryTotal)), pressure \(sample.memoryPressure.title)")

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Pressure").foregroundStyle(.secondary)
                        Spacer()
                        Badge(text: sample.memoryPressure.title, symbol: sample.memoryPressure.symbolName, tint: sample.memoryPressure.tint)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    KeyValueRow(key: "Swap used", value: PerformanceFormat.swap(sample.swapUsed))
                    KeyValueRow(key: "Swap activity", value: ByteFormatting.rate(sample.swapInPerSecond + sample.swapOutPerSecond))
                        .help("Memory read back from or written to swap on disk right now.")
                    KeyValueRow(key: "Free", value: PerformanceFormat.memory(memory.free))
                        .help("Memory not used for anything, not even caches. A small number here is normal.")
                }
            }
            PerformanceMemoryBar(memory: memory)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                let segments = PerformanceMemoryBar.segments(memory)
                GridRow {
                    LegendItem(color: segments[0].color, label: segments[0].label, value: PerformanceFormat.memory(segments[0].bytes))
                    LegendItem(color: segments[1].color, label: segments[1].label, value: PerformanceFormat.memory(segments[1].bytes))
                }
                GridRow {
                    LegendItem(color: segments[2].color, label: segments[2].label, value: PerformanceFormat.memory(segments[2].bytes))
                    LegendItem(color: segments[3].color, label: segments[3].label, value: PerformanceFormat.memory(segments[3].bytes))
                }
            }
            .accessibilityElement(children: .combine)
            Text(sample.memoryPressure.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Network & disk

struct PerformanceNetworkCard: View {
    var model: PerformanceViewModel
    var sample: PerformanceSample

    var body: some View {
        let history = model.monitor.history
        let range = model.chartRange.seconds
        let interval = model.monitor.refreshInterval
        PerformancePanel("Network", symbol: "network") {
            HStack {
                PerformanceRateStat(title: "Received", value: ByteFormatting.rate(sample.networkInPerSecond), symbol: "arrow.down", color: PerformancePalette.networkIn)
                PerformanceRateStat(title: "Sent", value: ByteFormatting.rate(sample.networkOutPerSecond), symbol: "arrow.up", color: PerformancePalette.networkOut)
            }
            PerformanceHistoryChart(
                series: [
                    PerformanceChartSeries(name: "Received", color: PerformancePalette.networkIn, points: PerformanceChartMath.series(from: history, range: range, interval: interval) { $0.networkInPerSecond }),
                    PerformanceChartSeries(name: "Sent", color: PerformancePalette.networkOut, points: PerformanceChartMath.series(from: history, range: range, interval: interval) { $0.networkOutPerSecond }, mirrored: true),
                ],
                domain: PerformanceChartMath.domain(history: history, range: range),
                height: 120,
                valueLabel: { ByteFormatting.rate($0) },
                accessibilityLabel: "Network activity history"
            )
            Text("Wi-Fi, Ethernet and other physical connections. VPN tunnels, bridges and virtual machine adapters are left out so traffic isn't counted twice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PerformanceDiskCard: View {
    var model: PerformanceViewModel
    var sample: PerformanceSample

    var body: some View {
        let history = model.monitor.history
        let range = model.chartRange.seconds
        let interval = model.monitor.refreshInterval
        PerformancePanel("Disk", symbol: "internaldrive") {
            HStack {
                PerformanceRateStat(title: "Read", value: ByteFormatting.rate(sample.diskReadPerSecond), symbol: "arrow.down.doc", color: PerformancePalette.diskRead)
                PerformanceRateStat(title: "Written", value: ByteFormatting.rate(sample.diskWritePerSecond), symbol: "arrow.up.doc", color: PerformancePalette.diskWrite)
            }
            PerformanceHistoryChart(
                series: [
                    PerformanceChartSeries(name: "Read", color: PerformancePalette.diskRead, points: PerformanceChartMath.series(from: history, range: range, interval: interval) { $0.diskReadPerSecond }),
                    PerformanceChartSeries(name: "Written", color: PerformancePalette.diskWrite, points: PerformanceChartMath.series(from: history, range: range, interval: interval) { $0.diskWritePerSecond }, mirrored: true),
                ],
                domain: PerformanceChartMath.domain(history: history, range: range),
                height: 120,
                valueLabel: { ByteFormatting.rate($0) },
                accessibilityLabel: "Disk activity history"
            )
            if let volume = model.monitor.startupVolume {
                VStack(alignment: .leading, spacing: 6) {
                    UsageBar(
                        segments: [
                            UsageSegment(label: "Used", bytes: volume.usedCapacity, color: AppSection.storage.tint),
                            UsageSegment(label: "Purgeable", bytes: volume.purgeableCapacity, color: AppSection.storage.tint.opacity(0.35)),
                        ],
                        total: volume.totalCapacity,
                        height: 8
                    )
                    HStack {
                        Text(volume.name).font(.caption.weight(.medium))
                        Spacer()
                        Text("\(ByteFormatting.string(volume.effectiveAvailable)) available of \(ByteFormatting.string(volume.totalCapacity))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Power & thermal

/// Battery (when present), the current power source, Low Power Mode and uptime.
struct PerformancePowerCard: View {
    var status: PerformanceBatteryStatus
    var source: PerformanceBattery.PowerSource?
    var bootDate: Date?

    var body: some View {
        PerformancePanel(status.battery == nil ? "Power" : "Battery & Power", symbol: status.battery == nil ? "powerplug" : "battery.75percent") {
            switch status {
            case .unknown:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading battery…").foregroundStyle(.secondary)
                }
            case .noBattery:
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "powerplug.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No battery").font(.title3.weight(.semibold))
                        Text("This Mac runs on AC power, so there's no battery health to report.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            case .present(let battery):
                PerformanceBatteryDetails(battery: battery)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let source, source != .unknown {
                    KeyValueRow(key: "Power source", value: source == .powerAdapter ? "AC power" : source.title)
                }
                KeyValueRow(key: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                if let bootDate {
                    KeyValueRow(key: "Up since last restart", value: DateFormatting.duration(max(0, Date().timeIntervalSince(bootDate))))
                }
            }
        }
    }
}

private struct PerformanceBatteryDetails: View {
    var battery: PerformanceBattery

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RingGauge(fraction: battery.level ?? 0, tint: levelTint, lineWidth: 9) {
                VStack(spacing: 0) {
                    Text(battery.level.map { NumberFormatting.percent($0) } ?? "—")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: battery.isCharging ? "bolt.fill" : battery.powerSource == .powerAdapter ? "powerplug.fill" : "battery.75percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery charge")
            .accessibilityValue(battery.level.map { NumberFormatting.percent($0) } ?? "Unknown")

            VStack(alignment: .leading, spacing: 6) {
                KeyValueRow(key: "Status", value: statusText)
                if let time = battery.timeToEmpty ?? battery.timeToFull {
                    KeyValueRow(key: battery.timeToFull != nil ? "Until full" : "Remaining", value: DateFormatting.duration(time))
                }
                if let cycles = battery.cycleCount {
                    KeyValueRow(key: "Cycle count", value: NumberFormatting.count(cycles))
                }
                if let health = battery.healthFraction, let full = battery.fullChargeCapacity, let design = battery.designCapacity {
                    KeyValueRow(key: "Maximum capacity", value: NumberFormatting.percent(health))
                        .help("Full-charge capacity \(NumberFormatting.count(full)) mAh of \(NumberFormatting.count(design)) mAh when new.")
                }
                if let condition = battery.condition {
                    KeyValueRow(key: "Condition", value: condition)
                }
                if let temperature = battery.temperatureCelsius {
                    KeyValueRow(key: "Battery temperature", value: Measurement(value: temperature, unit: UnitTemperature.celsius).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))))
                }
            }
        }
    }

    private var statusText: String {
        if battery.isCharging { return "Charging" }
        if battery.isCharged { return "Fully charged" }
        if battery.powerSource == .powerAdapter { return battery.optimizedChargingEngaged == true ? "On hold (optimized charging)" : "Not charging" }
        return "On battery"
    }

    private var levelTint: Color {
        guard let level = battery.level else { return .gray }
        if level <= 0.1 { return .red }
        if level <= 0.2 { return .orange }
        return .green
    }
}

struct PerformanceThermalCard: View {
    var state: ProcessInfo.ThermalState

    private let steps: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    var body: some View {
        PerformancePanel("Thermal State", symbol: "thermometer.medium") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.performanceSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(state.performanceTint)
                    .frame(width: 36, height: 36)
                    .background(state.performanceTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.performanceTitle).font(.title3.weight(.semibold))
                    Text(state.performanceExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 4) {
                ForEach(steps, id: \.rawValue) { step in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(step.rawValue <= state.rawValue ? step.performanceTint : Color.primary.opacity(0.08))
                            .frame(height: 6)
                        Text(step.performanceTitle)
                            .font(.caption2)
                            .foregroundStyle(step == state ? .primary : .secondary)
                    }
                }
            }
            .accessibilityHidden(true)

            InfoCallout(
                style: .info,
                title: "CPU and GPU temperatures",
                message: "Not available through public macOS APIs. Apple silicon chip temperature sensors can only be read with private interfaces, so Mac Cleaner shows the thermal state macOS reports instead."
            )
        }
    }
}

// MARK: - Processes

struct PerformanceProcessesCard: View {
    @Bindable var model: PerformanceViewModel

    var body: some View {
        Card("Processes", symbol: "list.bullet.rectangle") {
            HStack(spacing: 10) {
                Picker("Show", selection: $model.processScope) {
                    ForEach(PerformanceProcessScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                PerformanceSearchField(text: $model.processSearch, prompt: "Search")
                    .frame(width: 170)
            }
        } content: {
            if model.monitor.processes.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Listing processes…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                PerformanceProcessTable(model: model)
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        var text = "% CPU is the share of one core (100% = one fully busy core); % of Total is the share of all \(model.monitor.topology.logicalCoreCount) cores. Right-click a process for actions."
        if model.processScope == .apps {
            text += " In Apps, each app includes its helper processes."
        }
        if let restricted = model.monitor.restrictedProcessCount, restricted > 0 {
            if model.processScope == .all {
                text += restricted == 1
                    ? " 1 process belongs to macOS or another user: only its name and owner are shown, because macOS doesn't let apps read its CPU and memory use."
                    : " \(NumberFormatting.count(restricted)) processes belong to macOS or other users: only their name and owner are shown, because macOS doesn't let apps read their CPU and memory use."
            } else {
                text += restricted == 1
                    ? " 1 process owned by macOS or another user isn't listed here (choose All Processes to see it with limited details)."
                    : " \(NumberFormatting.count(restricted)) processes owned by macOS or other users aren't listed here (choose All Processes to see them with limited details)."
            }
        }
        if !model.monitor.processesMeasured {
            text += " CPU values appear after the second update."
        }
        return text
    }
}

/// Compact search field for card headers.
struct PerformanceSearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.subtleBorder))
    }
}

// MARK: - Alerts

struct PerformanceAlertsCard: View {
    var model: PerformanceViewModel

    var body: some View {
        let settings = model.settings
        Card("Performance Alerts", symbol: "bell.badge") {
            Toggle(isOn: Binding(get: { settings.performanceAlertsEnabled }, set: { model.setAlertsEnabled($0) })) {
                Text("Notify me about sustained high CPU, critical memory pressure and low disk space")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if settings.performanceAlertsEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Label("CPU above \(NumberFormatting.percent(PerformanceAlertSettings(settings: settings, refreshInterval: model.monitor.refreshInterval).cpuThreshold)) for more than a minute", systemImage: "cpu")
                    if settings.memoryPressureAlerts {
                        Label("Memory pressure reaches critical", systemImage: "memorychip")
                    }
                    if settings.lowDiskAlertGB > 0 {
                        Label("Less than \(ByteFormatting.string(Int64(settings.lowDiskAlertGB) * 1_000_000_000)) free on the startup disk", systemImage: "internaldrive")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if model.notificationsAuthorized == false {
                    HStack {
                        Text("Notifications are turned off for Mac Cleaner.")
                            .font(.callout)
                        Spacer()
                        Button("Open Notification Settings") { PerformanceSystemSettings.openNotifications() }
                    }
                }
            }
            Text("Alerts are checked only while monitoring is active — while this page, the Dashboard or the menu bar monitor shows live data. You'll get at most one alert of each kind every 30 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum PerformanceSystemSettings {
    static func openNotifications() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
