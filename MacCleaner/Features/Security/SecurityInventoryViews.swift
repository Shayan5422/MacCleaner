import SwiftUI

// MARK: - Startup & persistence

struct SecurityPersistenceTab: View {
    var model: SecurityViewModel

    var body: some View {
        let items = model.persistenceItems
        if items.isEmpty {
            EmptyStateView(title: "No Items", symbol: "power.circle",
                           message: model.searchText.isEmpty ? "Nothing starts automatically in the locations Mac Cleaner checks." : "No items match “\(model.searchText)”.")
        } else {
            Text("Everything that starts automatically or hooks into login, with its signature. Flagged items are explained under Findings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(SecurityPersistenceItem.Kind.allCases, id: \.self) { kind in
                let group = items.filter { $0.kind == kind }
                if !group.isEmpty {
                    SecurityPersistenceGroup(kind: kind, items: group, model: model)
                }
            }
        }
    }
}

private struct SecurityPersistenceGroup: View {
    let kind: SecurityPersistenceItem.Kind
    let items: [SecurityPersistenceItem]
    var model: SecurityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbolName).foregroundStyle(AppSection.security.tint)
                Text(kind.title).font(.headline)
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    SecurityPersistenceRow(item: item, model: model)
                    if item.id != items.last?.id { Divider().padding(.leading, 46) }
                }
            }
        }
        .card(padding: 0)
    }
}

private struct SecurityPersistenceRow: View {
    let item: SecurityPersistenceItem
    var model: SecurityViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.severity.map(\.symbolName) ?? (item.isRunning == true ? "play.circle.fill" : item.kind.symbolName))
                .foregroundStyle(item.severity.map(SecurityStyle.color) ?? (item.isRunning == true ? Color.green : Color.secondary))
                .frame(width: 20)
                .help(item.severity?.title ?? (item.isRunning == true ? "Running" : item.kind.title))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let location = item.location {
                    PathText(path: location, font: .caption2)
                }
            }
            Spacer(minLength: 8)
            if let trust = item.trust {
                Badge(text: trust.title, symbol: trust.symbolName, tint: SecurityStyle.trustColor(trust))
                    .help(item.trustSummary ?? trust.title)
            }
            if let severity = item.severity {
                SeverityBadge(severity: severity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { openFinding() }
        .contextMenu {
            if item.findingID != nil {
                Button("Show Finding", systemImage: "info.circle") { openFinding() }
            }
            if let location = item.location {
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(location) }
                Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(location) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.title): \(item.name)\(item.severity.map { ", \($0.title)" } ?? "")")
    }

    private var subtitle: String {
        [item.developer, item.detail].compactMap { $0 }.joined(separator: " · ")
    }

    private func openFinding() {
        if let id = item.findingID, let finding = model.finding(id: id) {
            model.selectedFinding = finding
        }
    }
}

// MARK: - App signatures

struct SecurityApplicationsTab: View {
    @Bindable var model: SecurityViewModel

    var body: some View {
        Picker("Filter", selection: $model.appFilter) {
            ForEach(SecurityViewModel.AppFilter.allCases) { filter in
                Text("\(filter.title) (\(model.applicationCount(filter)))").tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 520)
        .accessibilityLabel("Filter apps by signature")

        Text("Signatures were checked quickly, without verifying every file. Deep Verify checks every file and asks Gatekeeper for its verdict. “Not confirmed offline” means the app has no stapled notarization ticket; Gatekeeper checks it online the first time it opens.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        let apps = model.applications
        if apps.isEmpty {
            EmptyStateView(title: "No Apps", symbol: "app.badge.checkmark",
                           message: model.appFilter == .all ? "No apps match your search." : "No apps fall into this category. That's good news.")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(apps) { app in
                    SecurityAppRow(app: app, model: model)
                    if app.id != apps.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .card(padding: 0)
        }
    }
}

private struct SecurityAppRow: View {
    let app: SecurityAppRecord
    var model: SecurityViewModel

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: app.path, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).lineLimit(1)
                    Text(app.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(app.evaluation.developer ?? app.evaluation.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let verification = model.deepVerifications[app.path] {
                    Label(verification.gatekeeper?.summary ?? verification.evaluation.summary,
                          systemImage: verification.gatekeeper?.accepted == false || verification.evaluation.category.isSignatureProblem
                              ? "xmark.seal.fill" : "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(verification.gatekeeper?.accepted == false || verification.evaluation.category.isSignatureProblem ? .orange : .green)
                }
            }
            Spacer(minLength: 8)
            if let note = notarizationNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Badge(text: app.evaluation.category.title, symbol: app.evaluation.category.symbolName,
                  tint: SecurityStyle.trustColor(app.evaluation.category))
                .help(app.evaluation.summary)
            if model.verifyingPaths.contains(app.path) {
                ProgressView().controlSize(.small).frame(width: 90)
            } else {
                Button("Deep Verify") { model.deepVerify(app.path) }
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("Verify every file of the app and ask Gatekeeper")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Deep Verify", systemImage: "checkmark.shield") { model.deepVerify(app.path) }
            Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(app.path) }
            Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(app.path) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name), \(app.evaluation.summary)")
    }

    /// Notarization is only spelled out when the badge doesn't already say it.
    private var notarizationNote: String? {
        switch app.evaluation.category {
        case .developerID: return "Notarization not confirmed offline"
        case .adHoc, .unsigned, .untrustedCertificate, .appleDevelopment, .invalid, .revoked: return "Not notarized"
        default: return nil
        }
    }
}

// MARK: - Downloads

struct SecurityDownloadsTab: View {
    @Bindable var model: SecurityViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Apps, installers, disk images and scripts in Downloads that still carry macOS's quarantine flag. Mac Cleaner never removes the flag; it only shows what Gatekeeper will check.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.archiveCount > 0 {
                Toggle("Include archives (\(model.archiveCount))", isOn: $model.includesArchives)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
        }

        let files = model.downloads
        if files.isEmpty {
            EmptyStateView(title: "No Quarantined Installers", symbol: "arrow.down.circle",
                           message: model.searchText.isEmpty
                               ? "There are no downloaded apps, installers, disk images or scripts waiting in your Downloads folder."
                               : "No downloads match “\(model.searchText)”.")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    SecurityDownloadRow(file: file, model: model)
                    if file.id != files.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .card(padding: 0)
        }
    }
}

private struct SecurityDownloadRow: View {
    let file: SecurityQuarantinedFile
    var model: SecurityViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileIcon(path: file.path, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Badge(text: file.kind.title, symbol: file.kind.symbolName, tint: file.kind.canRunCode ? .blue : .gray)
                    if let category = file.evaluation?.category, category.isSignatureProblem || category.lacksIdentity {
                        Badge(text: category.title, symbol: category.symbolName, tint: SecurityStyle.trustColor(category))
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(file.gatekeeperNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let verification = model.deepVerifications[file.path], let gatekeeper = verification.gatekeeper {
                    Label(gatekeeper.summary, systemImage: gatekeeper.accepted ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(gatekeeper.accepted ? .green : .orange)
                }
            }
            Spacer(minLength: 8)
            SizeText(bytes: file.sizeBytes, font: .callout)
                .foregroundStyle(.secondary)
            if canVerify {
                if model.verifyingPaths.contains(file.path) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Verify") { model.deepVerify(file.path) }
                        .controlSize(.small)
                        .help("Check the signature fully and ask Gatekeeper")
                }
            }
            Button("Move to Trash…") { trash() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(file.path) }
            Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(file.path) }
            if canVerify {
                Button("Verify Signature", systemImage: "checkmark.shield") { model.deepVerify(file.path) }
            }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { trash() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.name), \(file.kind.title), \(details)")
    }

    private var canVerify: Bool { file.kind == .application || file.kind == .installerPackage }

    private var details: String {
        var parts: [String] = []
        parts.append("From " + (file.quarantine.agent ?? "an unknown app"))
        if let date = file.downloadedDate { parts.append(DateFormatting.relative(date)) }
        if file.quarantine.isUserApproved {
            parts.append("opened")
        } else if let opened = file.lastOpened {
            parts.append("last opened \(DateFormatting.relative(opened))")
        } else {
            parts.append("never opened")
        }
        return parts.joined(separator: " · ")
    }

    private func trash() {
        model.requestTrash(paths: [file.path], purpose: .userFile, title: "Move “\(file.name)” to the Trash", warning: nil)
    }
}
