import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct StorageCleanupReview: View {
    @ObservedObject var store: BranchesStore
    let confirm: ([StorageCleanupCandidate]) -> Bool
    let cancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var page: Page = .generated
    @State private var confirming = false
    @State private var review: [StorageCleanupCandidate] = []
    @State private var notice: String?

    private enum Page: String, CaseIterable {
        case generated = "Generated Files"
        case largest = "Largest Folders"
    }

    private struct MeasuredFolder: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
    }

    private var inventory: StorageCleanupInventory? {
        store.isScanningCleanup ? nil : store.cleanupInventory
    }

    private var chosen: [StorageCleanupCandidate] {
        (inventory?.rows ?? []).compactMap(\.candidate).filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            if let inventory {
                switch page {
                case .generated: generatedFiles(inventory)
                case .largest: largestFolders(inventory)
                }
            } else {
                ProgressView("Scanning for generated files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 540)
        .onAppear {
            if store.cleanupInventory == nil { store.loadCleanupInventory() }
        }
        .alert(review.count == 1 ? "Permanently delete this folder?" : "Permanently delete \(review.count) folders?",
               isPresented: $confirming) {
            Button("Cancel", role: .cancel) { review = [] }
                .keyboardShortcut(.defaultAction)
            Button("Delete Permanently", role: .destructive) {
                if !confirm(review) {
                    notice = "Could not start cleanup. Check for overlapping folders or another cleanup in progress."
                }
                review = []
            }
        } message: {
            Text("usAIge checks each folder again before deleting it. Tools may need to download or rebuild files.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Cleanup")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Picker("Storage view", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 12)
                Button("Add Folder…") {
                    if store.chooseFolder() { selected.removeAll() }
                }
                Button("Rescan", systemImage: "arrow.clockwise", action: rescan)
                    .disabled(inventory == nil)
            }
            if let inventory {
                Text(scopeText(inventory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !inventory.skippedFolders.isEmpty {
                    DisclosureGroup("Skipped folders (\(inventory.skippedFolders.count))") {
                        ScrollView {
                            Text(inventory.skippedFolders.joined(separator: "\n"))
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 72)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func scopeText(_ inventory: StorageCleanupInventory) -> String {
        let count = inventory.foldersChecked
        var description = count == 1 ? "1 workspace folder and known tool locations"
            : "\(count) workspace folders and known tool locations"
        if inventory.reachedScanLimit {
            description += " · Some subfolders were outside the scan limit."
        }
        return description
    }

    @ViewBuilder
    private func generatedFiles(_ inventory: StorageCleanupInventory) -> some View {
        if inventory.rows.isEmpty {
            ContentUnavailableView("No Generated Folders Found", systemImage: "magnifyingglass",
                                   description: Text("Add a project folder to check it and its Git worktrees."))
        } else {
            List(inventory.rows) { row in
                HStack(alignment: .center, spacing: 10) {
                    if row.candidate != nil {
                        Toggle(row.location.title, isOn: selection(for: row.id))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .frame(width: 16)
                            .accessibilityLabel("Select \(row.location.title), \(row.location.path)")
                    } else {
                        Image(systemName: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.location.title).font(.headline)
                        Text(row.location.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.location.path)
                        Text(row.reason ?? row.location.kind.consequence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    size(row.bytes)
                    reveal(row.location.path)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func largestFolders(_ inventory: StorageCleanupInventory) -> some View {
        let folders = measuredFolders(inventory)
        if folders.isEmpty {
            ContentUnavailableView("No Folder Sizes Available", systemImage: "folder",
                                   description: Text("Add a project folder to measure its generated files."))
        } else {
            List(folders) { folder in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).font(.headline)
                        Text(folder.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.id)
                    }
                    Spacer(minLength: 8)
                    size(folder.bytes)
                    reveal(folder.id)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    private func measuredFolders(_ inventory: StorageCleanupInventory) -> [MeasuredFolder] {
        var folders: [String: MeasuredFolder] = [:]
        for item in store.toolStorage {
            guard let path = item.path else { continue }
            folders[path] = MeasuredFolder(id: path, name: item.name, bytes: item.bytes)
        }
        for item in store.snapshot.items {
            guard let path = item.worktreePath, let bytes = item.size?.totalBytes, item.facts.folderExists else { continue }
            folders[path] = MeasuredFolder(id: path, name: item.repositoryName, bytes: bytes)
        }
        for row in inventory.rows {
            guard let bytes = row.bytes else { continue }
            folders[row.id] = MeasuredFolder(id: row.id, name: row.location.title, bytes: bytes)
        }
        return folders.values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if page == .largest {
                    Text("Measured size on disk")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !chosen.isEmpty {
                    let bytes = chosen.reduce(Int64(0)) { $0 + $1.bytes }
                    Text("\(chosen.count) selected · \(BoardText.bytes(bytes)) on disk")
                        .font(.callout.monospacedDigit())
                }
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                if page == .generated {
                    Button("Review Deletion…") {
                        review = chosen
                        confirming = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || store.isDeleting)
                }
            }
        }
    }

    private func size(_ bytes: Int64?) -> some View {
        Text(bytes.map(BoardText.bytes) ?? "Unknown size")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private func reveal(_ path: String) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Show in Finder")
        .accessibilityLabel("Show \(path) in Finder")
    }

    private func selection(for path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) }, set: { isOn in
            if isOn { selected.insert(path) } else { selected.remove(path) }
        })
    }

    private func rescan() {
        selected = []
        notice = nil
        store.loadCleanupInventory(force: true)
    }
}
