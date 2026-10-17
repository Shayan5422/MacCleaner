import SwiftUI

/// Large files, old files or empty folders: select, preview and delete.
struct FileListView: View {
    var model: FileCleanupModel
    var category: FileCategory
    @State private var selection: Set<URL> = []
    @State private var isConfirming = false
    @State private var preview: FilePreviewRequest?

    private var items: [FileScanItem] { model.result?.items(in: category) ?? [] }
    private var selectedItems: [FileScanItem] { items.filter { selection.contains($0.url) } }
    private var allSelected: Bool { !items.isEmpty && items.allSatisfy { selection.contains($0.url) } }

    var body: some View {
        let items = items
        List {
            if let notice = model.notice {
                Section {
                    FileNoticeView(notice: notice) { withAnimation { model.notice = nil } }
                }
            }
            Section {
                ForEach(items) { item in
                    FileItemRow(item: item, isSelected: selection.contains(item.url), toggle: { toggle(item) },
                                preview: item.kind == .folder ? nil : { show(item, in: items) })
                }
            } header: {
                Text(header(for: items))
            } footer: {
                Text(footer)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if items.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing left here", message: "Everything in this list was deleted.")
            }
        }
        .navigationTitle(category.title)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : Set(items.map(\.url))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                FileActionBar(title: deleteTitle, isBusy: model.isDeleting) { isConfirming = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .confirmationDialog(confirmationTitle, isPresented: $isConfirming, titleVisibility: .visible) {
                        Button(deleteButtonTitle, role: .destructive) {
                            let chosen = selectedItems
                            Task { await model.delete(chosen) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(selection.count == 1
                             ? "It goes to Recently Deleted in the Files app, where you can restore it. If its location doesn't have Recently Deleted, you'll be asked first."
                             : "They go to Recently Deleted in the Files app, where you can restore them. If a location doesn't have Recently Deleted, you'll be asked first.")
                    }
            }
        }
        .modifier(FilePermanentDeletionPrompt(model: model))
        .modifier(FileErrorAlert(model: model))
        .sheet(item: $preview) { request in
            FileQuickLookPreview(request: request) { preview = nil }
                .ignoresSafeArea()
        }
        .onAppear { model.notice = nil }
        .onChange(of: items) { _, items in
            selection.formIntersection(items.map(\.url))
        }
        .animation(.default, value: selection.isEmpty)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func toggle(_ item: FileScanItem) {
        if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
    }

    private func show(_ item: FileScanItem, in items: [FileScanItem]) {
        let previewable = items.filter { $0.kind != .folder }
        preview = FilePreviewRequest(urls: previewable.map(\.url), index: previewable.firstIndex(of: item) ?? 0)
    }

    private func header(for items: [FileScanItem]) -> String {
        let count = NumberFormatting.count(items.count, category.noun)
        guard category != .emptyFolders else { return count }
        return "\(count) · \(ByteFormatting.string(items.reduce(0) { $0 + $1.size }))"
    }

    private var footer: String {
        switch category {
        case .large: return "Files of 50 MB or more, largest first."
        case .old: return "Files of 1 MB or more that haven't changed in over a year, oldest first."
        case .emptyFolders: return "Folders with nothing inside. Folders that only hold empty folders are listed once."
        case .duplicates: return ""
        }
    }

    private var noun: String { FileCleanupModel.count(selection.count, of: selectedItems) }

    private var deleteTitle: String {
        let title = "Delete \(titleCase(noun))"
        guard category != .emptyFolders else { return title }
        return "\(title) · \(ByteFormatting.string(selectedItems.reduce(0) { $0 + $1.size }))"
    }

    private var deleteButtonTitle: String { "Delete \(titleCase(noun))" }
    private var confirmationTitle: String { "Delete \(noun)?" }
}

/// Identical files grouped by content. Every copy but the one to keep is selected at first, and each group always
/// keeps at least one copy.
struct FileDuplicatesView: View {
    var model: FileCleanupModel
    @State private var selection: Set<URL> = []
    @State private var hasPreselected = false
    @State private var isConfirming = false
    @State private var preview: FilePreviewRequest?
    @State private var refusedGroup: String?

    private var groups: [FileDuplicateGroup] { model.result?.duplicateGroups ?? [] }
    private var selectedItems: [FileScanItem] { groups.flatMap(\.files).filter { selection.contains($0.url) } }

    var body: some View {
        let groups = groups
        List {
            if let notice = model.notice {
                Section {
                    FileNoticeView(notice: notice) { withAnimation { model.notice = nil } }
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.files) { file in
                        FileItemRow(item: file, isSelected: selection.contains(file.url),
                                    badge: selection.contains(file.url) ? nil : "Kept",
                                    toggle: { toggle(file, in: group) },
                                    preview: { show(file, in: group) })
                    }
                } header: {
                    Text("\(NumberFormatting.count(group.files.count, "copy", plural: "copies")) · \(ByteFormatting.string(group.keeper.size)) each")
                } footer: {
                    if refusedGroup == group.id {
                        Text("Keep at least one copy of each file.").foregroundStyle(.orange)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if groups.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "No duplicates left", message: "Every file here is the only copy.")
            }
        }
        .navigationTitle("Duplicates")
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select All Extra Copies") { selection = Self.extras(of: groups) }
                        Button("Deselect All") { selection = [] }
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                FileActionBar(title: "Delete \(titleCase(noun)) · \(ByteFormatting.string(selectedItems.reduce(0) { $0 + $1.size }))",
                              isBusy: model.isDeleting) { isConfirming = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .confirmationDialog("Delete \(noun)?", isPresented: $isConfirming, titleVisibility: .visible) {
                        Button("Delete \(titleCase(noun))", role: .destructive) {
                            let chosen = selectedItems
                            Task { await model.delete(chosen, fromDuplicates: true) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(selection.count == 1
                             ? "At least one copy of each file stays. The selected copy goes to Recently Deleted in the Files app, where you can restore it."
                             : "At least one copy of each file stays. The selected copies go to Recently Deleted in the Files app, where you can restore them.")
                    }
            }
        }
        .modifier(FilePermanentDeletionPrompt(model: model))
        .modifier(FileErrorAlert(model: model))
        .sheet(item: $preview) { request in
            FileQuickLookPreview(request: request) { preview = nil }
                .ignoresSafeArea()
        }
        .onAppear {
            model.notice = nil
            guard !hasPreselected else { return }
            hasPreselected = true
            selection = Self.extras(of: groups)
        }
        .onChange(of: groups) { _, groups in
            selection.formIntersection(groups.flatMap(\.files).map(\.url))
        }
        .task(id: refusedGroup) {
            // The hint goes away on its own after a few seconds.
            guard refusedGroup != nil, (try? await Task.sleep(for: .seconds(4))) != nil else { return }
            refusedGroup = nil
        }
        .animation(.default, value: selection.isEmpty)
        .animation(.default, value: refusedGroup)
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.warning, trigger: refusedGroup) { _, new in new != nil }
    }

    private var noun: String { NumberFormatting.count(selection.count, "file") }

    private static func extras(of groups: [FileDuplicateGroup]) -> Set<URL> {
        Set(groups.flatMap(\.extras).map(\.url))
    }

    private func toggle(_ file: FileScanItem, in group: FileDuplicateGroup) {
        if selection.contains(file.url) {
            selection.remove(file.url)
            if refusedGroup == group.id { refusedGroup = nil }
        } else if group.files.filter({ !selection.contains($0.url) && $0.url != file.url }).isEmpty {
            refusedGroup = group.id
        } else {
            selection.insert(file.url)
        }
    }

    private func show(_ file: FileScanItem, in group: FileDuplicateGroup) {
        preview = FilePreviewRequest(urls: group.files.map(\.url), index: group.files.firstIndex(of: file) ?? 0)
    }
}

/// "3 files" → "3 Files", for button titles.
private func titleCase(_ text: String) -> String {
    text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}
