import SwiftUI

/// Explained recommendations: memory pressure and swap, apps with unusual CPU or
/// large memory use, busy background processes and startup activity.
struct PerformanceOptimizeTab: View {
    @Bindable var model: PerformanceViewModel

    var body: some View {
        let recommendations = model.recommendations
        let memoryApps = model.memoryHeavyApps
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if let sample = model.monitor.latest {
                PerformanceOptimizeSummary(sample: sample, recommendations: recommendations)
            } else {
                PerformanceMeasuringView()
            }

            InfoCallout(
                style: .info,
                title: "About free memory",
                message: "macOS uses free memory to cache files and apps on purpose, because unused memory is wasted memory. What matters is memory pressure: while it's normal, your Mac has enough memory. Mac Cleaner doesn't “free up RAM” or purge caches — that only makes apps slower until macOS rebuilds them."
            )

            if let sample = model.monitor.latest {
                PerformanceMemoryHealthCard(sample: sample)
            }

            let pressure = model.monitor.latest?.memoryPressure ?? .normal
            // Under memory pressure the largest apps matter most, so they come first.
            if pressure >= .warning, !memoryApps.isEmpty {
                PerformanceMemoryAppsCard(model: model, apps: memoryApps, pressure: pressure)
            }

            PerformanceRecommendationsCard(model: model, recommendations: recommendations)

            if pressure == .normal, !memoryApps.isEmpty {
                PerformanceMemoryAppsCard(model: model, apps: memoryApps, pressure: pressure)
            }

            PerformanceStartupCard(model: model, showsReviewButton: !recommendations.contains { $0.category == .startup })
        }
    }
}

// MARK: - Summary

private struct PerformanceOptimizeSummary: View {
    var sample: PerformanceSample
    var recommendations: [PerformanceRecommendation]

    var body: some View {
        let actionable = recommendations.filter { $0.severity >= .recommendation }
        let (title, message, symbol, tint) = summary(actionable: actionable)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func summary(actionable: [PerformanceRecommendation]) -> (String, String, String, Color) {
        switch sample.memoryPressure {
        case .critical:
            return ("Your Mac is short on memory", "Quitting apps you aren't using will help the most. The apps using the most memory are listed below.", "exclamationmark.octagon.fill", .red)
        case .warning:
            return ("Memory is getting tight", "Quitting an app you aren't using would relieve memory pressure. The apps using the most memory are listed below.", "exclamationmark.triangle.fill", .orange)
        case .normal:
            break
        }
        if actionable.isEmpty {
            return ("Your Mac is running smoothly", "Nothing needs your attention right now. Suggestions appear here when an app works unusually hard or memory gets tight.", "checkmark.seal.fill", .green)
        }
        let count = actionable.count
        return ("\(count) suggestion\(count == 1 ? "" : "s") to review", "Each one explains why it's shown. Nothing is changed unless you confirm.", "lightbulb.fill", .orange)
    }
}

// MARK: - Memory health

private struct PerformanceMemoryHealthCard: View {
    var sample: PerformanceSample

    var body: some View {
        let interpretation = PerformanceMemoryInterpretation.message(for: sample)
        Card("Memory Pressure & Swap", symbol: "memorychip") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: interpretation.level.symbolName)
                    .font(.system(size: 20))
                    .foregroundStyle(interpretation.level.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(interpretation.title).font(.headline)
                    Text(interpretation.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                StatTile(title: "Memory pressure", value: sample.memoryPressure.title, caption: "The measure that matters", symbol: sample.memoryPressure.symbolName, tint: sample.memoryPressure.tint)
                StatTile(title: "Compressed", value: PerformanceFormat.memory(sample.memory.compressed), caption: "Squeezed to avoid swap", symbol: "rectangle.compress.vertical", tint: PerformancePalette.memoryCompressed)
                StatTile(title: "Swap used", value: PerformanceFormat.swap(sample.swapUsed), caption: sample.swapTotal > 0 ? "of \(PerformanceFormat.memory(sample.swapTotal)) swap files" : "No swap files right now", symbol: "arrow.left.arrow.right", tint: AppSection.performance.tint)
                StatTile(title: "Swap activity", value: ByteFormatting.rate(sample.swapInPerSecond + sample.swapOutPerSecond), caption: "Read + written now", symbol: "arrow.triangle.2.circlepath", tint: ChartPalette.colors[8])
            }
        }
    }
}

// MARK: - Recommendations

private struct PerformanceRecommendationsCard: View {
    var model: PerformanceViewModel
    var recommendations: [PerformanceRecommendation]

    var body: some View {
        Card("Recommendations", symbol: "lightbulb") {
            if !model.monitor.processesMeasured || model.processObservationSeconds < 30 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Watching activity — apps that keep the CPU busy are reported after about 30 seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if recommendations.isEmpty {
                Label("No apps or processes are working unusually hard right now.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                        if index > 0 { Divider().padding(.leading, 44) }
                        PerformanceRecommendationRow(recommendation: recommendation) { action in
                            model.perform(action, target: recommendation.target)
                        }
                    }
                }
            }
        }
    }
}

private struct PerformanceRecommendationRow: View {
    var recommendation: PerformanceRecommendation
    var onAction: (PerformanceAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(recommendation.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    SeverityBadge(severity: recommendation.severity)
                }
                Text(recommendation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !recommendation.metrics.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(recommendation.metrics, id: \.self) { metric in
                            Text(metric)
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
                if !recommendation.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(recommendation.actions) { action in
                            Button(action.title) { onAction(action) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = recommendation.iconPath, path.hasSuffix(".app") {
            PerformanceProcessIcon(pid: recommendation.target?.kind == .app ? recommendation.target?.pid : nil, path: path, size: 32)
        } else {
            Image(systemName: recommendation.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(recommendation.severity.tint == .secondary ? AppSection.performance.tint : recommendation.severity.tint)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Memory-intensive apps

private struct PerformanceMemoryAppsCard: View {
    var model: PerformanceViewModel
    var apps: [PerformanceMemoryHeavyApp]
    var pressure: MemoryPressureLevel

    var body: some View {
        Card("Apps Using the Most Memory", symbol: "memorychip") {
            if pressure == .normal {
                Text("Memory pressure is normal, so these apps aren't slowing your Mac down. Quit one only if you need memory for something else. Sizes include each app's helper processes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                InfoCallout(
                    style: pressure == .critical ? .danger : .warning,
                    message: "Memory is under pressure. Quitting an app you aren't using frees its memory right away, starting with the largest."
                )
            }
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.leading, 40) }
                    row(app)
                }
            }
        }
    }

    private func row(_ app: PerformanceMemoryHeavyApp) -> some View {
        HStack(spacing: 12) {
            PerformanceProcessIcon(pid: app.app.pid, path: app.app.bundlePath, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.app.name).font(.callout.weight(.medium)).lineLimit(1)
                    if app.processCount > 1 {
                        Text("\(app.processCount) processes").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(PerformanceFormat.memory(app.bytes))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                PerformanceShareBar(fraction: app.fractionOfMemory, color: pressure == .normal ? PerformancePalette.memoryApp : pressure.tint)
            }
            Menu {
                Button("Quit \(app.app.name)") { model.perform(.quit, target: app.target) }
                Button("Force Quit \(app.app.name)…") { model.perform(.forceQuit, target: app.target) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(app.app.name)")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.app.name), \(PerformanceFormat.memory(app.bytes)), \(NumberFormatting.percent(app.fractionOfMemory)) of memory")
    }
}

// MARK: - Startup

private struct PerformanceStartupCard: View {
    var model: PerformanceViewModel
    /// Hidden when a recommendation above already offers the same button.
    var showsReviewButton: Bool

    var body: some View {
        Card("Startup Activity", symbol: "power.circle") {
            if let summary = model.startupSummary {
                HStack(spacing: 12) {
                    StatTile(title: "Your launch agents", value: NumberFormatting.count(summary.userLaunchAgents), caption: "Start when you log in", symbol: "person.crop.circle", tint: AppSection.startup.tint)
                    StatTile(title: "Agents for all users", value: summary.sharedLaunchAgents.map(NumberFormatting.count) ?? "—", caption: "/Library/LaunchAgents", symbol: "person.2.circle", tint: AppSection.startup.tint)
                    StatTile(title: "Launch daemons", value: summary.launchDaemons.map(NumberFormatting.count) ?? "—", caption: "Run at startup as root", symbol: "gearshape.2", tint: AppSection.startup.tint)
                }
                HStack {
                    Text("Apps install these to run helpers in the background. Many of them can slow down login and use memory all the time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if showsReviewButton {
                        Button("Review Startup Items") { model.perform(.openStartupItems, target: nil) }
                            .disabled(model.openSection == nil)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting startup items…").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Thin bar showing a share of a whole (for example of physical memory).
struct PerformanceShareBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(height, proxy.size.width * CGFloat(min(1, max(0, fraction.isFinite ? fraction : 0)))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
