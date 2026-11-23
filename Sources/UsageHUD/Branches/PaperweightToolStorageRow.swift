import SwiftUI

/// These folders are shown for inspection and never enter a delete review.
@available(macOS 14.0, *)
struct PaperweightToolStorageRow: View {
    let entry: ToolStorageEntry
    let share: Double
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if style == .modern { modern } else { classic }
    }

    private var modern: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 10) {
                    ModernIcon(symbol: "shippingbox.fill", color: ModernPalette.toolStorage)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(entry.kind.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(BoardText.bytes(entry.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    FoldChevron(isExpanded: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name), \(entry.kind.label)")
            .accessibilityValue("\(BoardText.bytes(entry.bytes)), \(isExpanded ? "unfolded" : "folded")")
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    pathDetails
                }
                .padding(.leading, ModernMetrics.separatorInset - 14)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                .padding(.leading, ModernMetrics.separatorInset)
        }
    }

    @ViewBuilder
    private var pathDetails: some View {
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

    private var classic: some View {
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
