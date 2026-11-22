import Foundation

enum WidgetLimitSelection {
    static let automaticID = "com.richardq.usaige.widget.automatic"

    static func explicitIDs(from configuredIDs: [String?]) -> [String] {
        var seen = Set<String>()
        return configuredIDs
            .compactMap { $0 }
            .filter { $0 != automaticID }
            .filter { seen.insert($0).inserted }
    }

    static func resolve(
        selectedIDs: [String],
        from snapshots: [QuotaSnapshot],
        maximumCount: Int
    ) -> [QuotaSnapshot] {
        guard maximumCount > 0 else { return [] }

        let snapshotsByID = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var selectedSnapshots = selectedIDs.prefix(maximumCount).compactMap { snapshotsByID[$0] }
        guard selectedSnapshots.count < maximumCount else { return selectedSnapshots }

        // In tightness order, the first snapshot for each tool is its tightest limit.
        var shownToolIDs = Set(selectedSnapshots.map(\.toolID))
        for snapshot in snapshots.sorted(by: areInDisplayOrder) {
            guard shownToolIDs.insert(snapshot.toolID).inserted else { continue }
            selectedSnapshots.append(snapshot)
            if selectedSnapshots.count == maximumCount { break }
        }
        return selectedSnapshots
    }

    static func areInDisplayOrder(_ left: QuotaSnapshot, _ right: QuotaSnapshot) -> Bool {
        let leftRemaining = left.tightness
        let rightRemaining = right.tightness
        if leftRemaining != rightRemaining {
            return leftRemaining < rightRemaining
        }
        if left.toolName != right.toolName {
            return left.toolName.localizedCaseInsensitiveCompare(right.toolName) == .orderedAscending
        }
        return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
    }
}
