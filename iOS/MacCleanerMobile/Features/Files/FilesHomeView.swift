import SwiftUI

/// The Files page: the picked folders, the scan, and what it found.
struct FilesHomeView: View {
    var model: FileCleanupModel
    @State private var isImporting = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.notice) { _, notice in
                    if notice != nil { withAnimation { proxy.scrollTo(Self.noticeID, anchor: .top) } }
                }
        }
    }

    private static let noticeID = "notice"

    private var list: some View {
        List {
            if let notice = model.notice {
                Section {
                    FileNoticeView(notice: notice) { withAnimation { model.notice = nil } }
                        .id(Self.noticeID)
                }
            }
            if model.folders.isEmpty {
                Section {
                    PermissionCard(
                        section: .files, title: "Choose folders to clean",
                        message: "Pick folders in On My \(model.deviceWord), iCloud Drive or another location, such as Downloads. Mac Cleaner finds large, old and duplicate files and empty folders in them.",
                        buttonTitle: "Add Folder"
                    ) { isImporting = true }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Mac Cleaner only sees the folders you pick.")
                }
            } else {
                foldersSection
                scanSection
                if let result = model.result, !model.isScanning {
                    resultsSection(result)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Files")
        .toolbar {
            if model.result != nil, !model.isScanning, !model.availableFolders.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                        .disabled(model.isDeleting)
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.addFolders(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .task { await model.prepare() }
        .modifier(FileErrorAlert(model: model))
        .animation(.default, value: model.isScanning)
        .animation(.default, value: model.notice)
    }

    // MARK: Folders

    private var foldersSection: some View {
        Section {
            ForEach(model.folders) { folder in
                FolderRow(folder: folder) { isImporting = true }
                    .swipeActions {
                        Button(role: .destructive) { model.removeFolder(folder) } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { model.removeFolder(folder) } label: {
                            Label("Remove from List", systemImage: "minus.circle")
                        }
                    }
            }
            Button { isImporting = true } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .disabled(model.isScanning)
        } header: {
            Text("Folders")
        } footer: {
            Text("Mac Cleaner only sees the folders you pick. Removing one from this list doesn't delete it.")
        }
    }

    // MARK: Scan

    @ViewBuilder
    private var scanSection: some View {
        if let progress = model.progress {
            Section {
                Card {
                    HStack {
                        Text("Scanning \(NumberFormatting.count(model.availableFolders.count, "folder"))").font(.headline)
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancelScan() }
                            .buttonStyle(.borderless)
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: min(1, max(0, fraction)))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(progress.message).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        } else if model.result == nil {
            Section {
                Button { model.scan() } label: {
                    Label("Scan \(NumberFormatting.count(model.availableFolders.count, "Folder"))", systemImage: "magnifyingglass")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(MobileSection.files.tint)
                .disabled(model.availableFolders.isEmpty)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Files that are only in iCloud are skipped, so nothing is downloaded.")
            }
        }
    }

    // MARK: Results

    private func resultsSection(_ result: FileScanResult) -> some View {
        Section {
            ForEach(FileCategory.allCases) { category in
                let total = result.total(of: category)
                if total.count > 0 {
                    NavigationLink {
                        if category == .duplicates {
                            FileDuplicatesView(model: model)
                        } else {
                            FileListView(model: model, category: category)
                        }
                    } label: {
                        FileCategoryRow(category: category, count: total.count, bytes: total.bytes)
                    }
                } else {
                    FileCategoryRow(category: category, count: 0, bytes: 0)
                }
            }
        } header: {
            Text("Results")
        } footer: {
            Text(resultFooter(result))
        }
    }

    private func resultFooter(_ result: FileScanResult) -> String {
        var parts = ["\(NumberFormatting.count(result.itemCount, "file")) checked \(DateFormatting.relative(result.date))."]
        if result.cloudOnlyCount > 0 {
            parts.append("\(NumberFormatting.count(result.cloudOnlyCount, "file")) \(result.cloudOnlyCount == 1 ? "is" : "are") only in iCloud and \(result.cloudOnlyCount == 1 ? "wasn't" : "weren't") checked, so nothing was downloaded.")
        }
        if result.unreadableCount > 0 {
            parts.append("\(NumberFormatting.count(result.unreadableCount, "folder")) couldn't be read.")
        }
        return parts.joined(separator: " ")
    }
}

/// A picked folder, or a note that it has to be picked again.
private struct FolderRow: View {
    var folder: FileCleanupModel.Folder
    var addAgain: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: folder.needsReselection ? "folder.badge.questionmark" : "folder.fill",
                     tint: folder.needsReselection ? .orange : MobileSection.files.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.body.weight(.medium)).lineLimit(1)
                if folder.needsReselection {
                    Text("Can't open this folder anymore. Add it again to scan it.").font(.subheadline).foregroundStyle(.orange)
                } else if !folder.location.isEmpty {
                    Text(folder.location).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if folder.needsReselection {
                Button("Add Again", action: addAgain).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A result category with its count and size.
private struct FileCategoryRow: View {
    var category: FileCategory
    var count: Int
    var bytes: Int64
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: category.symbol, tint: category.tint, size: 38)
            if dynamicTypeSize.isAccessibilitySize {
                // Large text: the totals go under the title so neither wraps word by word.
                VStack(alignment: .leading, spacing: 4) {
                    titles
                    totals(alignment: .leading)
                }
            } else {
                titles
                Spacer(minLength: 8)
                totals(alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.title).font(.body.weight(.medium))
            Text(category.subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func totals(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if count == 0 {
                Text("None").font(.subheadline).foregroundStyle(.secondary)
            } else {
                if category != .emptyFolders {
                    Text(ByteFormatting.string(bytes)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text(countText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var countText: String {
        switch category {
        case .duplicates: return NumberFormatting.count(count, "extra copy", plural: "extra copies")
        case .emptyFolders: return NumberFormatting.count(count, "folder")
        default: return NumberFormatting.count(count, "file")
        }
    }
}
