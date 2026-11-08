import SwiftUI

/// The primary storage action stays in the resource header; operation details
/// are presented separately without taking over the overview's layout.
@available(macOS 14.0, *)
struct StorageCleanupButton: View {
    @ObservedObject var store: BranchesStore
    var review: () -> Void
    var showProgress: () -> Void

    var body: some View {
        let now = Date()
        let board = BranchesBoard.make(snapshot: store.snapshot, now: now)
        Button(action: store.cleanupProgress != nil || store.resultMessage != nil ? showProgress : review) {
            Label(title, systemImage: store.cleanupProgress != nil ? "hourglass" : "sparkles")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(store.cleanupProgress == nil && store.resultMessage == nil && board.safeToClear.isEmpty)
        .accessibilityHint(store.cleanupProgress == nil && store.resultMessage == nil
                           ? "Review the selected items before anything is cleared"
                           : "Open cleanup progress and recovery controls")
        .frame(width: 240, alignment: .trailing)
    }

    private var title: String {
        if store.cleanupProgress != nil { return "Show Progress…" }
        if store.resultMessage != nil { return "View Cleanup Result…" }
        return "Review and Clear…"
    }
}

/// Current cleanup scope accompanies the free-space figure, independent of
/// the primary action's placement.
@available(macOS 14.0, *)
struct StorageCleanupSummary: View {
    @ObservedObject var store: BranchesStore

    var body: some View {
        let now = Date()
        let board = BranchesBoard.make(snapshot: store.snapshot, now: now)
        let selection = ClearSelection(items: board.safeToClear, now: now)
        Text(summary(board: board, selection: selection))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summary(board: BranchesBoard, selection: ClearSelection) -> String {
        if let progress = store.cleanupProgress {
            return "\(progress.completed) of \(progress.total) items processed"
        }
        if let result = store.resultMessage {
            return result.isProblem ? "Cleanup needs attention" : "Operation complete"
        }
        if board.safeToClear.isEmpty {
            return store.snapshot.activity == .idle ? "Nothing to clear right now" : "Checking repositories…"
        }
        return selection.chosen.isEmpty
            ? "Review \(board.safeToClear.count) items to choose what to clear."
            : "About \(BoardText.bytes(selection.bytes(from: board.safeToClear))) can be freed from \(selection.chosen.count) \(selection.chosen.count == 1 ? "item" : "items")."
    }
}

/// Recovery remains part of local storage rather than a separate destination.
@available(macOS 14.0, *)
struct StorageRecoveryView: View {
    @ObservedObject var store: BranchesStore
    var showProgress: () -> Void
    @State private var showsRecentlyDeleted = false

    var body: some View {
        let now = Date()
        let restorable = BranchesPresentation.restorable(store.snapshot.deletions, now: now)
        VStack(alignment: .leading, spacing: 12) {
            if store.cleanupProgress != nil || store.resultMessage != nil {
                Button(store.cleanupProgress != nil ? "Show Cleanup Progress…" : "View Cleanup Result…", action: showProgress)
            }
            DisclosureGroup(isExpanded: $showsRecentlyDeleted) {
                recentlyDeleted(restorable, now: now)
                    .padding(.top, 10)
            } label: {
                Text(restorable.isEmpty ? "Recently Deleted" : "Recently Deleted (\(restorable.count))")
                    .font(.headline)
            }
        }
    }

    @ViewBuilder
    private func recentlyDeleted(_ records: [DeletionRecord], now: Date) -> some View {
        if records.isEmpty {
            Text("No items available to restore.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                CleanupRestorationNote()
                ForEach(records) { record in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.displayName).font(.callout.weight(.medium))
                                .lineLimit(2).truncationMode(.middle)
                            Text("\(record.repositoryName) · \(BranchesPresentation.relativeTime(record.deletedAt, now: now))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Restore") {
                            Task { await store.undo([record]) }
                            showProgress()
                        }
                        .disabled(store.isDeleting)
                        .accessibilityLabel("Restore \(record.displayName)")
                    }
                }
            }
        }
    }
}

/// A native sheet owns only presentation. The store keeps the operation alive
/// when this popup or the main window is closed.
@available(macOS 14.0, *)
struct CleanupProgressView: View {
    @ObservedObject var store: BranchesStore
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(store.cleanupProgress?.operation == .restoring ? "Restoring Items" : "Cleanup")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let progress = store.cleanupProgress {
                progressContent(progress)
            } else if let result = store.resultMessage {
                resultContent(result)
            } else {
                Label("No cleanup is running", systemImage: "checkmark.circle")
                    .font(.headline)
            }
            Divider()
            HStack(spacing: 12) {
                if let progress = store.cleanupProgress {
                    if progress.operation == .clearing {
                        Button(progress.isStopping ? "Stopping…" : "Stop After Current Item") { store.stopDeleting() }
                            .disabled(progress.isStopping)
                    }
                    Spacer()
                    Button("Hide", action: close).keyboardShortcut(.cancelAction)
                } else {
                    if let result = store.resultMessage, !result.undoable.isEmpty {
                        Button("Restore Cleared Items") { Task { await store.undo(result.undoable) } }
                            .disabled(store.isDeleting)
                    }
                    Spacer()
                    Button("Done") {
                        store.resultMessage = nil
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
    }

    private func progressContent(_ progress: BranchesStore.CleanupProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(progress.isStopping ? "Stopping after the current item"
                  : progress.operation == .restoring ? "Restoring items" : "Clearing reviewed items",
                  systemImage: progress.operation == .restoring ? "arrow.uturn.backward" : "sparkles")
                .font(.headline)
            ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                .accessibilityLabel("Cleanup progress")
            Text("\(progress.completed) of \(progress.total) items processed")
                .font(.callout.monospacedDigit())
            Text(progress.currentName ?? "Preparing…")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(3).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Text("Cleanup continues when this popup or the main window is closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resultContent(_ result: BranchesStore.ResultMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.isProblem ? "Needs attention" : "Operation complete",
                  systemImage: result.isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.headline)
                .foregroundStyle(result.isProblem ? Color.orange : Color.primary)
            if result.freedBytes > 0 {
                Text("Freed about \(BoardText.bytes(result.freedBytes))")
                    .font(.title3).monospacedDigit()
            }
            ScrollView {
                Text(result.text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            if !result.undoable.isEmpty { CleanupRestorationNote() }
        }
    }
}

@available(macOS 14.0, *)
private struct CleanupRestorationNote: View {
    var body: some View {
        Text("Restore brings back branches and folders. Caches and ignored files cannot be restored.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
