import Charts
import SwiftUI

/// Colors used consistently by every Performance chart.
enum PerformancePalette {
    static let cpu = AppSection.performance.tint
    static let cpuSystem = AppSection.performance.tint.mix(with: .black, by: 0.25)
    static let performanceCore = AppSection.performance.tint
    static let efficiencyCore = ChartPalette.colors[5]
    static let networkIn = ChartPalette.colors[0]
    static let networkOut = ChartPalette.colors[2]
    static let diskRead = ChartPalette.colors[1]
    static let diskWrite = ChartPalette.colors[3]
    static let memoryApp = ChartPalette.colors[0]
    static let memoryWired = ChartPalette.colors[2]
    static let memoryCompressed = ChartPalette.colors[3]
    static let memoryCached = ChartPalette.colors[5]
}

/// One line of a history chart.
struct PerformanceChartSeries: Identifiable {
    var name: String
    var color: Color
    var points: [PerformanceChartPoint]
    /// Drawn below the axis (sent / written), so two directions share one chart.
    var mirrored = false

    var id: String { name }
}

/// Smooth area + line chart over time. Gaps (monitoring paused) aren't bridged.
struct PerformanceHistoryChart: View {
    var series: [PerformanceChartSeries]
    var domain: ClosedRange<Date>
    /// Fixed vertical range (CPU is 0...100); nil scales to the data.
    var valueRange: ClosedRange<Double>?
    var height: CGFloat = 150
    var valueLabel: (Double) -> String
    var accessibilityLabel: String

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value(line.name, line.mirrored ? -point.value : point.value),
                        series: .value("Series", "\(line.name)-\(point.segment)"),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [line.color.opacity(0.32), line.color.opacity(0.04)],
                            startPoint: line.mirrored ? .bottom : .top,
                            endPoint: line.mirrored ? .top : .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(line.name, line.mirrored ? -point.value : point.value),
                        series: .value("Series", "\(line.name)-\(point.segment)-line")
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
            }
            if series.contains(where: \.mirrored) {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: showsSeconds ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(valueLabel(abs(number)))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilitySummary)
    }

    /// Short spans need seconds on the time axis, or every label reads the same minute.
    private var showsSeconds: Bool {
        domain.upperBound.timeIntervalSince(domain.lowerBound) <= 240
    }

    private var yDomain: ClosedRange<Double> {
        if let valueRange { return valueRange }
        let upper = max(1, series.filter { !$0.mirrored }.flatMap(\.points).map(\.value).max() ?? 0)
        let lower = max(1, series.filter(\.mirrored).flatMap(\.points).map(\.value).max() ?? 0)
        let hasMirrored = series.contains(where: \.mirrored)
        return (hasMirrored ? -lower * 1.1 : 0)...(upper * 1.1)
    }

    private var accessibilitySummary: String {
        series.map { line in
            let latest = line.points.last.map { valueLabel($0.value) } ?? "no data"
            return "\(line.name): \(latest)"
        }.joined(separator: ", ")
    }
}

/// Per-core usage bars, colored by core kind when known.
struct PerformanceCoreChart: View {
    var usage: [Double]
    var topology: PerformanceCPUTopology

    private struct Bar: Identifiable {
        var id: Int
        var label: String
        var value: Double
        var kind: PerformanceCPUTopology.CoreKind?
    }

    private var bars: [Bar] {
        usage.enumerated().map { index, value in
            Bar(id: index, label: topology.label(forCore: index), value: min(100, max(0, value * 100)), kind: topology.kind(ofCore: index))
        }
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Core", bar.label),
                y: .value("Usage", bar.value),
                width: .ratio(0.62)
            )
            .foregroundStyle(color(for: bar.kind).gradient)
            .cornerRadius(3)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Int(number))%").font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.caption2)
            }
        }
        .frame(height: 130)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage per CPU core")
        .accessibilityValue(bars.map { "\($0.label) \(Int($0.value.rounded())) percent" }.joined(separator: ", "))
    }

    private func color(for kind: PerformanceCPUTopology.CoreKind?) -> Color {
        switch kind {
        case .efficiency: return PerformancePalette.efficiencyCore
        case .performance, nil: return PerformancePalette.performanceCore
        }
    }
}

/// A compact line of a value over time, without axes (menu bar popover).
struct PerformanceSparkline: View {
    var points: [PerformanceChartPoint]
    var domain: ClosedRange<Date>
    var color: Color
    var maximum: Double = 100

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value),
                series: .value("Segment", point.segment),
                stacking: .unstacked
            )
            .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value),
                series: .value("Segment", "\(point.segment)-line")
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.2))
            .interpolationMethod(.monotone)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...maximum)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

extension PerformanceChartMath {
    /// Chart points for one metric of the monitor's history.
    static func series(
        from history: [PerformanceSample],
        range: TimeInterval,
        interval: TimeInterval,
        maxPoints: Int = 150,
        value: (PerformanceSample) -> Double
    ) -> [PerformanceChartPoint] {
        guard let end = history.last?.date else { return [] }
        return series(
            dates: history.map(\.date),
            values: history.map(value),
            end: end,
            window: range,
            gapThreshold: max(5, interval * 2.5),
            maxPoints: maxPoints
        )
    }

    /// X-axis range ending at the newest sample. It starts at the oldest sample
    /// within `range` (but spans at least `minimum` seconds), so a freshly opened
    /// chart isn't mostly empty; `range` is the most it shows.
    static func domain(history: [PerformanceSample], range: TimeInterval, minimum: TimeInterval = 60) -> ClosedRange<Date> {
        let end = history.last?.date ?? Date()
        let earliestAllowed = end.addingTimeInterval(-range)
        let oldest = history.first { $0.date >= earliestAllowed }?.date ?? end
        let start = max(earliestAllowed, min(oldest, end.addingTimeInterval(-min(minimum, range))))
        return start...end
    }
}

/// Stacked bar of memory composition. Like the rest of the memory figures it uses
/// binary units, so tooltips match the labels.
struct PerformanceMemoryBar: View {
    struct Segment: Identifiable, Hashable {
        var label: String
        var bytes: UInt64
        var color: Color

        var id: String { label }
    }

    var memory: PerformanceMemoryBreakdown
    var height: CGFloat = 10

    static func segments(_ memory: PerformanceMemoryBreakdown) -> [Segment] {
        [
            Segment(label: "App", bytes: memory.app, color: PerformancePalette.memoryApp),
            Segment(label: "Wired", bytes: memory.wired, color: PerformancePalette.memoryWired),
            Segment(label: "Compressed", bytes: memory.compressed, color: PerformancePalette.memoryCompressed),
            Segment(label: "Cached files", bytes: memory.cachedFiles, color: PerformancePalette.memoryCached),
        ]
    }

    var body: some View {
        let segments = Self.segments(memory)
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(2, proxy.size.width * CGFloat(Double(segment.bytes) / Double(max(memory.total, 1)))))
                        .help("\(segment.label): \(PerformanceFormat.memory(segment.bytes))")
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory composition")
        .accessibilityValue(segments.map { "\($0.label) \(PerformanceFormat.memory($0.bytes))" }.joined(separator: ", "))
    }
}
