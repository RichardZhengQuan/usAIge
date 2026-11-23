import SwiftUI

@available(macOS 14.0, *)
struct CleanPage: View {
    @ObservedObject var store: BranchesStore
    @ObservedObject var presentation: BranchesPaperweightPresentation
    @State private var showsGeneratedFiles = false
    @State private var worktreeReview: ClearReviewRequest?
    @Environment(\.locale) private var locale

    var body: some View {
        let now = Date()
        let items = BranchesBoard.make(snapshot: store.snapshot, now: now).safeToClear
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Clean", bundle: AppLanguage.resourceBundle)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
                ModernGroupBox {
                    ModernNavigationRow(symbol: "hammer.fill", color: ModernPalette.buildCache,
                                        title: "Generated Files", subtitle: "Review build output and downloaded dependencies.") {
                        beginReview()
                        showsGeneratedFiles = true
                    }
                    ModernNavigationRow(symbol: "folder.fill", color: ModernPalette.worktrees,
                                        title: "Finished Worktrees",
                                        subtitle: items.isEmpty ? "No finished worktrees to review." : "Review merged and empty worktrees.",
                                        value: items.isEmpty ? nil : items.count.formatted(.number.locale(locale)),
                                        action: items.isEmpty ? nil : {
                        beginReview()
                        worktreeReview = ClearReviewRequest(items: items, selection: ClearSelection(items: items, now: now), now: now)
                    })
                }
                .disabled(store.isDeleting)
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
