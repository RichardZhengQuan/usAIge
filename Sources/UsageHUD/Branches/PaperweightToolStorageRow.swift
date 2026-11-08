import SwiftUI

/// These folders are shown for inspection and never enter a delete review.
@available(macOS 14.0, *)
struct PaperweightToolStorageRow: View {
    let entry: ToolStorageEntry
    let share: Double
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 4)
                        FoldChevron(isExpanded: isExpanded)
                    }
                    PaperweightRowBar(share: share, color: StorageCategory.toolStorage.tint)
                    HStack {
                        Text(entry.kind.label).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(BoardText.bytes(entry.bytes)).monospacedDigit()
                    }
                    .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name), \(entry.kind.label)")
            .accessibilityValue("\(BoardText.bytes(entry.bytes)), \(isExpanded ? "unfolded" : "folded")")
            if isExpanded {
                Divider()
                Text(entry.path.map { BranchesPresentation.abbreviated($0) } ?? "Managed by Xcode")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let path = entry.path {
                    Button("Show in Finder") { FolderActions.showInFinder(path) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
    }
}
