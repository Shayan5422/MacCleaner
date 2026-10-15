import SwiftUI

/// An APFS local snapshot, as listed by `tmutil listlocalsnapshots`. Informational only:
/// snapshots are managed by Time Machine and macOS, and Mac Cleaner never deletes them.
struct StorageLocalSnapshot: Identifiable, Sendable, Hashable {
    enum Kind: Sendable {
        case timeMachine, systemUpdate, other

        var title: String {
            switch self {
            case .timeMachine: return "Time Machine"
            case .systemUpdate: return "macOS update"
            case .other: return "Other"
            }
        }
    }

    var name: String
    var kind: Kind
    var date: Date?

    var id: String { name }
}

enum StorageSnapshotReader {
    /// Lists local snapshots of the volume (group) containing `volumePath`.
    static func localSnapshots(volumePath: String) async throws -> [StorageLocalSnapshot] {
        let result = try await ProcessRunner.run("/usr/bin/tmutil", arguments: ["listlocalsnapshots", volumePath], timeout: 20)
        guard result.succeeded else {
            throw CommandError.failed(command: "tmutil listlocalsnapshots", result: result)
        }
        return parse(result.standardOutput)
    }

    /// Parses `tmutil listlocalsnapshots` output: a header line followed by one snapshot name per line.
    static func parse(_ output: String) -> [StorageLocalSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Snapshots for"), !line.contains(" ") else { return nil }
            if line.hasPrefix("com.apple.TimeMachine.") {
                return StorageLocalSnapshot(name: line, kind: .timeMachine, date: timeMachineDate(line))
            }
            if line.hasPrefix("com.apple.os.update-") {
                return StorageLocalSnapshot(name: line, kind: .systemUpdate, date: nil)
            }
            return StorageLocalSnapshot(name: line, kind: .other, date: nil)
        }
    }

    /// `com.apple.TimeMachine.2024-10-15-123456.local` → date.
    static func timeMachineDate(_ name: String) -> Date? {
        let trimmed = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: trimmed)
    }
}

/// Capacity of the scanned volume compared with what the scan found.
struct StorageVolumeSummaryCard: View {
    var volume: VolumeInfo
    var scannedBytes: Int64
    var isWholeVolume: Bool
    var statistics: StorageScanStatistics
    var snapshots: [StorageLocalSnapshot]
    var snapshotMessage: String?
    @State private var showsExplanation = false
    @State private var showsSnapshots = false

    private var notInScan: Int64 { max(0, volume.usedCapacity - scannedBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: volume.usedFraction, tint: AppSection.storage.tint, lineWidth: 11) {
                    VStack(spacing: 1) {
                        Text(ByteFormatting.string(volume.effectiveAvailable))
                            .font(.system(.headline, design: .rounded))
                            .monospacedDigit()
                        Text(volume.purgeableCapacity > 0 ? "available incl.\npurgeable" : "available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: 112, height: 112)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(volume.name): \(NumberFormatting.percent(volume.usedFraction)) used, \(ByteFormatting.string(volume.effectiveAvailable)) available")

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: volume.symbolName).foregroundStyle(.secondary)
                        Text(volume.name).font(.headline)
                        if let format = volume.formatDescription {
                            Text(format).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(ByteFormatting.string(volume.totalCapacity)) capacity")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(segments: segments, total: volume.totalCapacity, height: 12)
                    HStack(spacing: 14) {
                        ForEach(segments) { segment in
                            LegendItem(color: segment.color, label: segment.label, value: ByteFormatting.string(segment.bytes))
                        }
                        LegendItem(color: Color.primary.opacity(0.12), label: "Free", value: ByteFormatting.string(volume.availableCapacity))
                    }
                    .lineLimit(1)
                    explanationRow
                }
            }

            if isWholeVolume {
                Divider()
                snapshotsSection
            }
        }
        .card()
    }

    private var segments: [UsageSegment] {
        var result = [UsageSegment(label: isWholeVolume ? "Scanned" : "This folder", bytes: min(scannedBytes, volume.totalCapacity), color: AppSection.storage.tint)]
        if isWholeVolume {
            result.append(UsageSegment(label: "Not in scanned files", bytes: notInScan, color: Color.gray.opacity(0.55)))
        } else {
            result.append(UsageSegment(label: "Rest of the volume", bytes: max(0, volume.usedCapacity - scannedBytes), color: Color.gray.opacity(0.45)))
        }
        if volume.purgeableCapacity > 0 {
            result.append(UsageSegment(label: "Purgeable", bytes: volume.purgeableCapacity, color: Color.green.opacity(0.45)))
        }
        return result
    }

    @ViewBuilder
    private var explanationRow: some View {
        if isWholeVolume {
            HStack(spacing: 6) {
                Text("macOS reports \(ByteFormatting.string(volume.usedCapacity)) used; the scan found \(ByteFormatting.string(scannedBytes)) in files Mac Cleaner can read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showsExplanation.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Why the numbers differ")
                .accessibilityLabel("Why the numbers differ")
                .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
                    StorageNotScannedExplanation(notInScan: notInScan, purgeable: volume.purgeableCapacity, statistics: statistics)
                }
            }
        } else {
            Text("This folder uses \(ByteFormatting.string(scannedBytes)) — \(NumberFormatting.percent(volume.usedCapacity > 0 ? Double(scannedBytes) / Double(volume.usedCapacity) : 0)) of the space used on \(volume.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var snapshotsSection: some View {
        DisclosureGroup(isExpanded: $showsSnapshots) {
            VStack(alignment: .leading, spacing: 8) {
                Text("APFS local snapshots preserve earlier versions of files for Time Machine and macOS updates. Their space isn't part of any folder, so it appears under “Not in scanned files”. macOS removes them automatically when space is needed; Mac Cleaner never deletes them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let snapshotMessage {
                    Text(snapshotMessage).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshots) { snapshot in
                    HStack(spacing: 8) {
                        Image(systemName: snapshot.kind == .timeMachine ? "clock.arrow.circlepath" : "gearshape.2")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snapshot.kind.title + (snapshot.date.map { " · " + DateFormatting.short($0) } ?? ""))
                                .font(.callout)
                            Text(snapshot.name)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "camera.on.rectangle").foregroundStyle(.secondary)
                Text(snapshots.isEmpty ? "Local snapshots" : "Local snapshots (\(snapshots.count))")
                    .font(.callout.weight(.medium))
                if statistics.duplicateBytesAvoided > 0 {
                    Spacer()
                    Text("Hard links and APFS clones counted once: \(ByteFormatting.string(statistics.duplicateBytesAvoided)) not double-counted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Explains why "used" and "scanned" differ.
struct StorageNotScannedExplanation: View {
    var notInScan: Int64
    var purgeable: Int64
    var statistics: StorageScanStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not in scanned files: \(ByteFormatting.string(notInScan))").font(.headline)
            Text("This is storage that exists on the disk but isn't in any folder the scan could read:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                bullet("The macOS system volume (sealed and read-only) and the hidden volumes that share the disk: Preboot, Recovery and virtual memory.")
                bullet("APFS local snapshots kept by Time Machine and macOS updates.")
                bullet("Files of other users on this Mac.")
                bullet(statistics.unreadableCount > 0
                       ? "\(NumberFormatting.count(statistics.unreadableCount)) folders Mac Cleaner isn't allowed to read. Full Disk Access lets it include most of them."
                       : "Folders protected by macOS, which no app can read.")
                if purgeable > 0 {
                    bullet("Purgeable space (\(ByteFormatting.string(purgeable))) is counted as available by macOS. The files it consists of, such as downloaded iCloud items, may still appear in the scan.")
                }
                if statistics.duplicateBytesAvoided > 0 {
                    bullet("Hard links and APFS clones share storage. The scan counts it once (\(ByteFormatting.string(statistics.duplicateBytesAvoided)) not double-counted), as the disk does.")
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
