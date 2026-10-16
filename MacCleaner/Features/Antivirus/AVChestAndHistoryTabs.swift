import SwiftUI

struct AVChestTab: View {
    var model: AntivirusViewModel

    var body: some View {
        if model.chestItems.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "archivebox").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("The Virus Chest is empty").font(.title3.weight(.semibold))
                Text("Threats you move here are stored in a form that can't run, and can be restored or deleted later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .card(padding: 0)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "archivebox.fill").foregroundStyle(.purple).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.chestItems.count == 1 ? "1 item in the Virus Chest" : "\(model.chestItems.count) items in the Virus Chest").font(.headline)
                        Text("Stored masked in Mac Cleaner's own folder so they can't run and other scanners don't report them again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    SizeText(bytes: model.chestItems.reduce(0) { $0 + $1.size }, font: .callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(model.chestItems) { item in
                        AVChestRow(item: item, model: model)
                        if item.id != model.chestItems.last?.id { Divider().padding(.leading, 56) }
                    }
                }
            }
            .card(padding: 0)
        }
    }
}

private struct AVChestRow: View {
    let item: AVChestItem
    var model: AntivirusViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? (item.name.hasSuffix(".app") ? "app.dashed" : "folder.fill") : "doc.fill")
                .font(.system(size: 20))
                .foregroundStyle(.purple)
                .frame(width: 30, height: 30)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    AVCategoryBadge(category: item.category)
                }
                PathText(path: item.originalPath)
                Text("\(item.signatureName) · \(DateFormatting.short(item.quarantinedAt)) · \(ByteFormatting.string(item.size))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if model.busyChestIDs.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                Menu("Restore") {
                    Button("Restore to Original Location") { model.restore(item) }
                    Button("Restore To…") { model.restore(item, chooseFolder: true) }
                    if item.sha256 != nil {
                        Divider()
                        Button("Restore and Always Allow") { model.restore(item, alwaysAllow: true) }
                    }
                }
                .fixedSize()
                .controlSize(.small)
                Button("Delete…", role: .destructive) { model.chestItemToDelete = item }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Reveal Original Folder", systemImage: "folder") { FinderActions.reveal((item.originalPath as NSString).deletingLastPathComponent) }
            if let sha256 = item.sha256 {
                Button("Copy SHA-256", systemImage: "doc.on.doc") { FinderActions.copyPath(sha256) }
                Button("Search VirusTotal for This Hash", systemImage: "magnifyingglass") { model.openVirusTotal(sha256: sha256) }
            }
        }
    }
}

struct AVHistoryTab: View {
    var model: AntivirusViewModel

    var body: some View {
        Card("Scan history", symbol: "clock.arrow.circlepath", accessory: {
            if !model.history.isEmpty {
                Button("Clear") { model.clearHistory() }.buttonStyle(.link)
            }
        }) {
            if model.history.isEmpty {
                Text("Scans you run, Smart Scans and scheduled scans appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.history) { summary in
                        AVHistoryRow(summary: summary)
                        if summary.id != model.history.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct AVHistoryRow: View {
    let summary: AVScanSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.threatsFound > 0 ? "xmark.shield.fill" : summary.wasCancelled ? "pause.circle.fill" : "checkmark.shield.fill")
                .foregroundStyle(summary.threatsFound > 0 ? .red : summary.wasCancelled ? .orange : .green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.kind.title).font(.callout.weight(.medium))
                    if !summary.usedDefinitions {
                        Badge(text: "Test signatures only", symbol: nil, tint: .gray)
                    }
                    if summary.quarantinedCount > 0 {
                        Badge(text: "\(summary.quarantinedCount) moved to the Virus Chest", symbol: "archivebox.fill", tint: .purple)
                    }
                }
                Text(summary.resultLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(DateFormatting.short(summary.finishedAt)).font(.caption)
                Text(ByteFormatting.string(summary.bytesScanned) + " read").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
