import SwiftUI

struct SmartScanView: View {
    @Bindable var model: SmartScanViewModel

    var body: some View {
        VStack(spacing: 0) {
            PageScroll {
                PageHeader(section: .smartScan, subtitle: "One scan across junk, apps, storage, duplicates, startup items, security, privacy and developer caches.") {
                    if model.phase == .results {
                        Button {
                            model.start()
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
                FullDiskAccessBanner(reason: "Smart Scan can't check protected folders such as app containers, Safari data and Mail without Full Disk Access.")
                switch model.phase {
                case .idle:
                    idleView
                case .scanning:
                    ScanProgressCard(
                        title: "Smart Scan in progress",
                        message: runningMessage,
                        fraction: model.overallProgress,
                        tint: AppSection.smartScan.tint,
                        onCancel: model.cancel
                    )
                    areaGrid(interactive: false)
                case .results:
                    summaryCard
                    areaGrid(interactive: true)
                    detail
                }
            }
            if model.phase == .results && !model.candidates.isEmpty {
                SelectionActionBar(selectedCount: model.selectedCount, selectedBytes: model.selectedBytes) {
                    Button("Select Recommended") { model.selectRecommended() }
                    Button {
                        model.cleanSelected()
                    } label: {
                        Text("Clean").frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppSection.smartScan.tint)
                    .disabled(model.selectedCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter results")
        .cleanupFlow(model.cleanupFlow, services: model.services)
    }

    private var runningMessage: String {
        let running = model.areas.filter { $0.status == .running }
        if let first = running.first, !first.message.isEmpty { return "\(first.area.title): \(first.message)" }
        return running.map(\.area.title).joined(separator: ", ")
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleView: some View {
        ScanLaunchView(
            section: .smartScan,
            headline: "Check your whole Mac in one go",
            message: "Smart Scan only reads your files. You'll see everything it found, with explanations, before anything is removed.",
            buttonTitle: "Start Smart Scan",
            bullets: [
                "Junk, leftovers, large files and duplicates",
                "Startup items and security checks",
                "Browser caches and developer caches",
                "Nothing counted twice across categories",
            ],
            action: model.start
        )
        if let last = model.services.settings.lastSmartScanDate {
            Text("Last Smart Scan \(DateFormatting.relative(last)) found \(ByteFormatting.string(model.services.settings.lastSmartScanReclaimable)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 24) {
            RingGauge(fraction: model.totalReclaimable == 0 ? 0 : Double(model.safeReclaimable) / Double(max(model.totalReclaimable, 1)), tint: .green, lineWidth: 12) {
                VStack(spacing: 2) {
                    Text(ByteFormatting.string(model.totalReclaimable))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    Text("found").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(width: 140, height: 140)

            VStack(alignment: .leading, spacing: 10) {
                Text(model.totalReclaimable > 0 ? "Smart Scan complete" : "Your Mac looks clean")
                    .font(.title2.weight(.semibold))
                summaryLine(symbol: "checkmark.shield.fill", tint: .green,
                            text: "\(ByteFormatting.string(model.safeReclaimable)) safe to remove — selected for you")
                summaryLine(symbol: "eye.fill", tint: .orange,
                            text: "\(ByteFormatting.string(model.reviewReclaimable)) in \(NumberFormatting.count(model.reviewCandidates.count)) items needs your review")
                summaryLine(symbol: securitySymbol, tint: securityTint, text: securityText)
                if model.count(.recommendation) > 0 {
                    summaryLine(symbol: "lightbulb.fill", tint: .blue, text: "\(model.count(.recommendation)) recommendation\(model.count(.recommendation) == 1 ? "" : "s")")
                }
                if let started = model.startedAt, let finished = model.finishedAt {
                    Text("Finished in \(DateFormatting.duration(finished.timeIntervalSince(started)))" + (model.duplicatesMerged > 0 ? " · \(model.duplicatesMerged) items found by more than one check were counted once" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .card(padding: 20)
    }

    private var securitySymbol: String {
        model.count(.threat) > 0 ? "xmark.octagon.fill" : model.count(.suspicious) > 0 ? "exclamationmark.triangle.fill" : "lock.shield.fill"
    }

    private var securityTint: Color {
        model.count(.threat) > 0 ? .red : model.count(.suspicious) > 0 ? .orange : .green
    }

    private var securityText: String {
        let threats = model.count(.threat)
        let suspicious = model.count(.suspicious)
        if threats > 0 { return "\(threats) known threat\(threats == 1 ? "" : "s") found — review Security" }
        if suspicious > 0 { return "No known threats · \(suspicious) suspicious item\(suspicious == 1 ? "" : "s") to check" }
        return "No known threats or suspicious items"
    }

    private func summaryLine(symbol: String, tint: Color, text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    // MARK: - Areas

    private func areaGrid(interactive: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            ForEach(model.areas.filter { $0.status != .unavailable }) { state in
                SmartScanAreaCard(state: state, value: value(for: state.area), tone: tone(for: state.area), isFocused: model.focusedArea == state.area)
                    .onTapGesture {
                        guard interactive else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.focusedArea = model.focusedArea == state.area ? nil : state.area
                        }
                    }
                    .accessibilityAddTraits(interactive ? .isButton : [])
            }
        }
    }

    private func value(for area: SmartScanArea) -> String {
        switch area {
        case .security:
            if model.count(.threat) > 0 { return "\(model.findings(in: .security).filter { $0.severity == .threat }.count) threats" }
            let suspicious = model.findings(in: .security).filter { $0.severity == .suspicious }.count
            return suspicious > 0 ? "\(suspicious) to check" : "No threats"
        case .startup:
            let count = model.findings(in: .startup).count
            return count == 0 ? "Looks good" : "\(count) suggestion\(count == 1 ? "" : "s")"
        default:
            let bytes = model.bytes(in: area)
            if bytes > 0 { return ByteFormatting.string(bytes) }
            let findings = model.findings(in: area).count
            return findings > 0 ? "\(findings) note\(findings == 1 ? "" : "s")" : "Nothing found"
        }
    }

    private func tone(for area: SmartScanArea) -> Color {
        switch area {
        case .security:
            if model.findings(in: .security).contains(where: { $0.severity == .threat }) { return .red }
            if model.findings(in: .security).contains(where: { $0.severity == .suspicious }) { return .orange }
            return .green
        default:
            return area.tint
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let shownAreas = model.focusedArea.map { [$0] } ?? SmartScanArea.allCases
        ForEach(shownAreas) { area in
            let groups = model.groups(in: area)
            let findings = model.findings(in: area)
            if !groups.isEmpty || !findings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(area.title, systemImage: area.symbolName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("Open \(area.section.title)") { model.navigate?(area.section) }
                            .buttonStyle(.link)
                    }
                    if !groups.isEmpty {
                        CandidateGroupsView(groups: groups, selection: model.selection, searchText: model.searchText) { candidate in
                            model.exclude(candidate)
                        }
                    }
                    if !findings.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(findings) { finding in
                                SmartScanFindingRow(finding: finding) { section in model.navigate?(section) }
                                if finding.id != findings.last?.id { Divider() }
                            }
                        }
                        .card(padding: 0)
                    }
                }
            }
        }
    }
}

private struct SmartScanAreaCard: View {
    var state: SmartScanViewModel.AreaState
    var value: String
    var tone: Color
    var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconTile(symbol: state.area.symbolName, gradient: state.area.section.gradient, size: 32)
                Spacer()
                statusView
            }
            Text(state.area.title).font(.headline)
            if state.status == .done {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(tone)
                    .monospacedDigit()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .topLeading)
            if state.status == .running {
                ProgressView(value: state.progress).tint(state.area.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(isFocused ? state.area.tint : Color.subtleBorder, lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        switch state.status {
        case .waiting: return "Waiting…"
        case .running: return state.message.isEmpty ? "Scanning…" : state.message
        case .done: return state.summary ?? "Done"
        case .failed(let message): return message
        case .unavailable: return "Not available"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .unavailable:
            EmptyView()
        }
    }
}

/// A finding with severity, explanation and a link to where it can be handled.
struct SmartScanFindingRow: View {
    var finding: Finding
    var open: (AppSection) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.severity.symbolName)
                .foregroundStyle(finding.severity == .info ? Color.secondary : finding.severity.tint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(finding.title).font(.callout.weight(.semibold))
                    SeverityBadge(severity: finding.severity)
                }
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recommendation = finding.recommendation {
                    Label(recommendation, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let path = finding.path {
                    PathText(path: path)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let destination = finding.destination {
                    Button("Open \(destination.title)") { open(destination) }
                        .controlSize(.small)
                }
                if let path = finding.path {
                    Button("Reveal") { FinderActions.reveal(path) }
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .contextMenu {
            if let path = finding.path { FileContextMenu(path: path) }
        }
    }
}
