import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension StorageCleanupSelection {
    func confirmationMessage(locale: Locale) -> String {
        var parts: [String] = []
        if !folders.isEmpty {
            parts.append(folders.count == 1
                         ? AppLanguage.text("Delete 1 generated folder. Tools may need to download or rebuild files.", locale: locale)
                         : AppLanguage.format("Delete %lld generated folders. Tools may need to download or rebuild files.", locale: locale, folders.count))
        }
        var unavailable = 0, erased = 0
        for simulator in simulators {
            switch simulator.action {
            case .deleteRuntime:
                let size = simulator.bytes.map(BoardText.bytes) ?? AppLanguage.text("Unknown size", locale: locale)
                parts.append(AppLanguage.format("Delete %@. To use it again, download %@ in Xcode.", locale: locale, simulator.name, size))
            case .deleteUnavailableDevice: unavailable += 1
            case .eraseDevice: erased += 1
            }
        }
        if unavailable > 0 {
            parts.append(unavailable == 1
                         ? AppLanguage.text("Delete 1 unavailable simulator and all its data.", locale: locale)
                         : AppLanguage.format("Delete %lld unavailable simulators and all their data.", locale: locale, unavailable))
        }
        if erased > 0 {
            parts.append(erased == 1
                         ? AppLanguage.text("Erase the apps and data on 1 simulator. Its name is kept.", locale: locale)
                         : AppLanguage.format("Erase the apps and data on %lld simulators. Their names are kept.", locale: locale, erased))
        }
        parts.append(AppLanguage.text("Each item is checked again. None of the deleted or erased contents can be restored.", locale: locale))
        return parts.joined(separator: "\n\n")
    }
}

@available(macOS 14.0, *)
struct StorageCleanupReview: View {
    @ObservedObject var store: BranchesStore
    let confirm: (StorageCleanupSelection) -> Bool
    let cancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var page: Page
    @State private var choosingFolder = false
    @State private var confirming = false
    @State private var review = StorageCleanupSelection()
    @State private var notice: String?
    @Environment(\.locale) private var locale

    enum Page: String, CaseIterable, Identifiable {
        case generated = "Generated Files"
        case xcode = "Xcode & Simulators"
        case largest = "Largest Folders"
        var id: Self { self }
    }

    init(store: BranchesStore, initialPage: Page = .generated,
         confirm: @escaping (StorageCleanupSelection) -> Bool, cancel: @escaping () -> Void) {
        self.store = store
        _page = State(initialValue: initialPage)
        self.confirm = confirm
        self.cancel = cancel
    }

    private struct MeasuredFolder: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
    }

    private var inventory: StorageCleanupInventory? {
        store.isScanningCleanup ? nil : store.cleanupInventory
    }

    private var chosen: StorageCleanupSelection {
        StorageCleanupSelection(folders: (inventory?.rows ?? []).compactMap(\.candidate).filter { selected.contains($0.id) },
                                simulators: (inventory?.simulators ?? []).compactMap(\.candidate).filter { selected.contains($0.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            if let inventory {
                switch page {
                case .generated: cleanupItems(inventory.generatedRows.map(StorageReviewItem.init))
                case .xcode:
                    if inventory.simulatorScanFailed {
                        Text("Could not verify the simulator inventory.", bundle: AppLanguage.resourceBundle)
                            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 8)
                    }
                    if inventory.simulatorScanFailed && inventory.xcodeRows.isEmpty { Spacer() }
                    else { cleanupItems(inventory.xcodeRows) }
                case .largest: largestFolders(inventory)
                }
            } else {
                ProgressView(AppLanguage.text(page == .xcode ? "Checking Xcode and simulators…" : "Scanning for generated files…", locale: locale))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 540)
        .onAppear {
            if store.cleanupInventory == nil { store.loadCleanupInventory() }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(folder):
                store.addFolder(CleanupFileInspection.normalized(folder.path))
                selected.removeAll()
            case let .failure(error):
                notice = error.localizedDescription
            }
        }
        .alert(AppLanguage.text("Permanently clean the selected items?", locale: locale), isPresented: $confirming) {
            Button("Cancel", role: .cancel) { review = StorageCleanupSelection() }
                .keyboardShortcut(.defaultAction)
            Button(AppLanguage.text("Clean Permanently", locale: locale), role: .destructive) {
                if !confirm(review) {
                    notice = AppLanguage.text("Could not start cleanup. Check for overlapping folders or another cleanup in progress.", locale: locale)
                }
                review = StorageCleanupSelection()
            }
        } message: {
            Text(verbatim: review.confirmationMessage(locale: locale))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Cleanup", bundle: AppLanguage.resourceBundle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Picker("Storage view", selection: $page) {
                    ForEach(Page.allCases) { Text(verbatim: AppLanguage.text($0.rawValue, locale: locale)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 12)
                if page != .xcode {
                    Button(AppLanguage.text("Add Folder…", locale: locale)) { choosingFolder = true }
                }
                Button(AppLanguage.text("Rescan", locale: locale), systemImage: "arrow.clockwise", action: rescan)
                    .disabled(inventory == nil)
            }
            if let inventory, page != .xcode {
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
    private func cleanupItems(_ rows: [StorageReviewItem]) -> some View {
        if rows.isEmpty {
            if page == .xcode {
                ContentUnavailableView {
                    Label(AppLanguage.text("No verified Xcode or simulator items.", locale: locale), systemImage: "magnifyingglass")
                }
            } else {
                ContentUnavailableView("No Generated Folders Found", systemImage: "magnifyingglass",
                                       description: Text("Add a project folder to check it and its Git worktrees."))
            }
        } else {
            List(rows) { row in
                HStack(alignment: .center, spacing: 10) {
                    if row.isSelectable {
                        Toggle(row.title, isOn: selection(for: row.id))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .frame(width: 16)
                            .accessibilityLabel("\(row.title), \(row.detail)")
                            .accessibilityHint(row.note)
                    } else {
                        Image(systemName: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.headline)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.detail)
                        Text(page == .xcode ? row.note : row.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    size(row.bytes)
                    if let path = row.finderPath { reveal(path) }
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
                let selection = chosen
                if selection.count > 0 || page != .largest {
                    let amount = (selection.hasUnknownSize ? "≥" : "") +
                        selection.bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
                    Text(verbatim: AppLanguage.format("%lld selected · %@ on disk", locale: locale, selection.count, amount))
                        .font(.callout.monospacedDigit())
                } else {
                    Text("Measured size on disk")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                if page != .largest || selection.count > 0 {
                    Button(AppLanguage.text("Review Cleanup…", locale: locale)) {
                        review = selection
                        confirming = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.count == 0 || store.isDeleting)
                }
            }
        }
    }

    private func size(_ bytes: Int64?) -> some View {
        Text(bytes.map { $0.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale)) }
             ?? AppLanguage.text("Unknown size", locale: locale))
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
        .help(AppLanguage.text("Show in Finder", locale: locale))
        .accessibilityLabel(AppLanguage.format("Show %@ in Finder", locale: locale, path))
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
