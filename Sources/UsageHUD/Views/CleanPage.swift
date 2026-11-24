import SwiftUI

@available(macOS 14.0, *)
struct CleanPage: View {
    @ObservedObject var store: BranchesStore
    @ObservedObject var presentation: BranchesPaperweightPresentation
    @State private var showsGeneratedFiles = false
    @State private var worktreeReview: ClearReviewRequest?
    @State private var allGenerated = false
    @State private var allWorktrees = false
    @Environment(\.locale) private var locale

    var body: some View {
        let now = Date()
        let items = store.snapshot.items.filter { BranchesBoard.lane(for: $0) == .safeToClear }
            .sorted { ($0.size?.totalBytes ?? 0, $0.id) > ($1.size?.totalBytes ?? 0, $1.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Clean", bundle: AppLanguage.resourceBundle)
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        store.refresh()
                        store.loadCleanupInventory(force: true)
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isScanningCleanup || store.isDeleting)
                }
                .padding(.horizontal, 4)
                ModernSection(title: "Generated Files", tint: ModernPalette.buildCache) {
                    Button {
                        beginReview()
                        showsGeneratedFiles = true
                    } label: {
                        Text("Review Files…", bundle: AppLanguage.resourceBundle)
                    }
                    .disabled(store.isDeleting)
                } content: {
                    if let inventory = store.cleanupInventory {
                        if inventory.rows.isEmpty {
                            ModernNoteRow(text: "No generated folders found.", symbol: "checkmark")
                        } else {
                            let rows = inventory.rows.sorted { $0.candidate != nil && $1.candidate == nil }
                            candidateRows(rows, expanded: $allGenerated) { row in
                                detailRow(title: row.location.title, path: row.id, bytes: row.bytes,
                                          note: row.reason, symbol: row.candidate == nil ? "lock.fill" : "hammer.fill")
                            }
                        }
                    } else {
                        ModernNoteRow(text: "Scanning for generated files…", symbol: "hourglass")
                    }
                }
                ModernSection(title: "Finished Worktrees", tint: ModernPalette.worktrees) {
                    Button {
                        beginReview()
                        worktreeReview = ClearReviewRequest(items: items, selection: ClearSelection(items: items, now: now), now: now)
                    } label: {
                        Text("Review Worktrees…", bundle: AppLanguage.resourceBundle)
                    }
                    .disabled(items.isEmpty || store.isDeleting)
                } content: {
                    if items.isEmpty {
                        ModernNoteRow(text: store.hasCheckedWorktrees && store.snapshot.activity == .idle
                                      ? "No finished worktrees to review." : "Checking worktrees…", symbol: "folder")
                    } else {
                        candidateRows(items, expanded: $allWorktrees) { item in
                            detailRow(title: item.workTitle, path: item.worktreePath ?? item.repositoryName,
                                      bytes: item.facts.folderExists ? item.size?.totalBytes : 0,
                                      note: [item.branch, AppLanguage.text(item.status.label, locale: locale)].compactMap { $0 }.joined(separator: " · "),
                                      symbol: "folder")
                        }
                    }
                }
                if store.cleanupProgress != nil || store.resultMessage != nil ||
                    !BranchesPresentation.restorable(store.snapshot.deletions, now: now).isEmpty {
                    ModernCard {
                        StorageRecoveryView(store: store) { presentation.showsCleanupProgress = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(ModernPalette.page)
        .onAppear {
            if store.cleanupInventory == nil { store.loadCleanupInventory() }
        }
        .sheet(isPresented: $showsGeneratedFiles, onDismiss: reviewDismissed) {
            StorageCleanupReview(store: store) { chosen in
                guard store.startStorageCleanup(chosen) else { return false }
                showsGeneratedFiles = false
                return true
            } cancel: { showsGeneratedFiles = false }
        }
        .sheet(item: $worktreeReview, onDismiss: reviewDismissed) { request in
            ClearReviewSheet(request: request, disk: store.diskSpace) { chosen in
                worktreeReview = nil
                store.startDelete(chosen)
            } cancel: { worktreeReview = nil }
        }
    }

    private func candidateRows<Item: Identifiable, Row: View>(_ items: [Item], expanded: Binding<Bool>,
                                                              @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        let limit = 4
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items.prefix(expanded.wrappedValue ? items.count : limit), content: row)
            if items.count > limit {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    Text(expanded.wrappedValue ? AppLanguage.text("Show less", locale: locale)
                         : AppLanguage.format("Show all %lld", locale: locale, items.count))
                }
                .buttonStyle(.link)
                .padding(.horizontal, ModernMetrics.rowPadding)
                .padding(.vertical, 8)
            }
        }
    }

    private func detailRow(title: String, path: String, bytes: Int64?, note: String?, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .frame(width: ModernMetrics.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(verbatim: BranchesPresentation.abbreviated(path))
                    .lineLimit(1).truncationMode(.middle).help(path)
                if let note { Text(verbatim: note).fixedSize(horizontal: false, vertical: true) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(bytes.map { $0.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale)) }
                 ?? AppLanguage.text("Unknown size", locale: locale))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, ModernMetrics.rowPadding)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().padding(.leading, ModernMetrics.separatorInset) }
        .accessibilityElement(children: .combine)
    }

    private func beginReview() {
        store.resultMessage = nil
        presentation.isReviewingCleanup = true
    }

    private func reviewDismissed() {
        presentation.isReviewingCleanup = false
        if store.cleanupProgress != nil || store.resultMessage != nil {
            presentation.showsCleanupProgress = true
        }
    }
}
