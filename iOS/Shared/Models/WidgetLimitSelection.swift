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

        let orderedSnapshots = snapshots.sorted(by: areInDisplayOrder)
        let requestedIDs = Array(selectedIDs.prefix(maximumCount))
        guard !requestedIDs.isEmpty else {
            return Array(orderedSnapshots.prefix(maximumCount))
        }

        let snapshotsByID = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedSnapshots = requestedIDs.compactMap { snapshotsByID[$0] }
        guard !selectedSnapshots.isEmpty else {
            return Array(orderedSnapshots.prefix(maximumCount))
        }
        return selectedSnapshots
    }

    static func areInDisplayOrder(_ left: QuotaSnapshot, _ right: QuotaSnapshot) -> Bool {
        let leftRemaining = min(
            left.remainingPercent,
            left.secondaryWindow?.remainingPercent ?? 100
        )
        let rightRemaining = min(
            right.remainingPercent,
            right.secondaryWindow?.remainingPercent ?? 100
        )

        if leftRemaining != rightRemaining {
            return leftRemaining < rightRemaining
        }
        if left.toolName != right.toolName {
            return left.toolName.localizedCaseInsensitiveCompare(right.toolName) == .orderedAscending
        }
        return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
    }
}
