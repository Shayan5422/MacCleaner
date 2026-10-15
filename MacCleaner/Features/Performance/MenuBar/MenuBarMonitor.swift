import AppKit
import SwiftUI

/// Compact menu bar label: a gauge symbol and total CPU usage.
///
/// Use as the label of the `MenuBarExtra`. While it is in the menu bar it keeps the
/// shared monitor sampling system totals (not the process list) through
/// `monitor.isMenuBarExtraActive`. The shell may also set that flag itself (for
/// example from `settings.showMenuBarExtra`); it's idempotent.
struct MenuBarMonitorLabel: View {
    var monitor: PerformanceMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            Text(cpuText)
                .monospacedDigit()
        }
        .onAppear { monitor.isMenuBarExtraActive = true }
        .onDisappear { monitor.isMenuBarExtraActive = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac Cleaner")
        .accessibilityValue(monitor.latest.map { "CPU \(NumberFormatting.percent($0.cpuUsage))" } ?? "Measuring")
    }

    /// Fixed-width percentage (figure spaces pad short values) so the item doesn't jitter.
    private var cpuText: String {
        guard let sample = monitor.latest, sample.isCPUAvailable else { return "\u{2007}\u{2007}–%" }
        let value = Int((sample.cpuUsage * 100).rounded())
        let digits = String(value)
        return String(repeating: "\u{2007}", count: max(0, 3 - digits.count)) + digits + "%"
    }

    private var symbolName: String {
        guard let sample = monitor.latest else { return "gauge.with.dots.needle.0percent" }
        switch sample.cpuUsage {
        case ..<0.34: return "gauge.with.dots.needle.33percent"
        case ..<0.67: return "gauge.with.dots.needle.50percent"
        default: return "gauge.with.dots.needle.67percent"
        }
    }
}

/// Popover content for the menu bar extra (use `.menuBarExtraStyle(.window)`):
/// CPU, memory and pressure, network, disk, the busiest processes, and buttons to
/// open or quit Mac Cleaner. Collects the process list only while it's open.
struct MenuBarMonitorView: View {
    var monitor: PerformanceMonitor

    @Environment(\.openWindow) private var openWindow
    @State private var holdsMonitor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconTile(section: .performance, size: 22)
                Text("Mac Cleaner").font(.headline)
                Spacer()
                if let sample = monitor.latest {
                    Badge(text: sample.thermalState.performanceTitle, symbol: sample.thermalState.performanceSymbol, tint: sample.thermalState.performanceTint)
                        .help("Thermal state: \(sample.thermalState.performanceExplanation)")
                }
            }

            if let sample = monitor.latest {
                cpuSection(sample)
                Divider()
                memorySection(sample)
                Divider()
                ratesSection(sample)
                Divider()
                processesSection
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }

            Divider()
            HStack {
                Button("Open Mac Cleaner") { openMainWindow() }
                    .keyboardShortcut("o")
                Spacer()
                Button("Quit Mac Cleaner") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            guard !holdsMonitor else { return }
            holdsMonitor = true
            monitor.acquire(includingProcesses: true)
        }
        .onDisappear {
            guard holdsMonitor else { return }
            holdsMonitor = false
            monitor.release(includingProcesses: true)
        }
    }

    // MARK: Sections

    private func cpuSection(_ sample: PerformanceSample) -> some View {
        let history = monitor.history
        let range: TimeInterval = 120
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("CPU", systemImage: "cpu").font(.subheadline.weight(.medium))
                Spacer()
                Text(sample.isCPUAvailable ? NumberFormatting.percent(sample.cpuUsage) : "—")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            PerformanceSparkline(
                points: PerformanceChartMath.series(from: history, range: range, interval: monitor.refreshInterval, maxPoints: 60) { $0.cpuUsage * 100 },
                domain: PerformanceChartMath.domain(history: history, range: range),
                color: PerformancePalette.cpu
            )
            .frame(height: 34)
            Text("User \(NumberFormatting.percent(sample.cpuUserUsage)) · System \(NumberFormatting.percent(sample.cpuSystemUsage))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func memorySection(_ sample: PerformanceSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Memory", systemImage: "memorychip").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(PerformanceFormat.memory(sample.memoryUsed)) of \(PerformanceFormat.memory(sample.memoryTotal))")
                    .font(.callout)
                    .monospacedDigit()
            }
            PerformanceMemoryBar(memory: sample.memory, height: 7)
            HStack {
                Text("Pressure").font(.caption).foregroundStyle(.secondary)
                Badge(text: sample.memoryPressure.title, symbol: sample.memoryPressure.symbolName, tint: sample.memoryPressure.tint)
                Spacer()
                Text("Swap: \(PerformanceFormat.swap(sample.swapUsed))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func ratesSection(_ sample: PerformanceSample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Label("Network", systemImage: "network").font(.subheadline.weight(.medium))
                rate("arrow.down", ByteFormatting.rate(sample.networkInPerSecond), PerformancePalette.networkIn, label: "Received")
                rate("arrow.up", ByteFormatting.rate(sample.networkOutPerSecond), PerformancePalette.networkOut, label: "Sent")
            }
            GridRow {
                Label("Disk", systemImage: "internaldrive").font(.subheadline.weight(.medium))
                rate("arrow.down", ByteFormatting.rate(sample.diskReadPerSecond), PerformancePalette.diskRead, label: "Read")
                rate("arrow.up", ByteFormatting.rate(sample.diskWritePerSecond), PerformancePalette.diskWrite, label: "Written")
            }
        }
    }

    private func rate(_ symbol: String, _ value: String, _ color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color).imageScale(.small)
            Text(value).font(.caption).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    @ViewBuilder
    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Processes").font(.subheadline.weight(.medium))
            let top = PerformanceViewModel.topProcesses(monitor.processes, limit: 3)
            if !monitor.processesMeasured || top.isEmpty {
                Text(monitor.processesMeasured ? "No busy processes." : "Measuring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(top) { process in
                    HStack(spacing: 8) {
                        PerformanceProcessIcon(pid: nil, path: process.appBundlePath, size: 16)
                        Text(process.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(PerformanceFormat.cpuColumn(process.cpu))%")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Actions

    /// Brings the main window forward. A window that is already open (or minimized)
    /// is reused, so a `WindowGroup` never gets a duplicate; otherwise SwiftUI opens it.
    private func openMainWindow() {
        NSApplication.shared.activate()
        let existing = NSApplication.shared.windows.first { window in
            window.identifier?.rawValue.hasPrefix("main") == true && (window.isVisible || window.isMiniaturized)
        }
        if let existing {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
