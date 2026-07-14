import Foundation
import WidgetKit

enum QuotaWidgetState: Sendable {
    case current([QuotaSnapshot])
    case stale([QuotaSnapshot], oldestUpdate: Date)
    case empty
    case error

    var snapshots: [QuotaSnapshot] {
        switch self {
        case let .current(snapshots), let .stale(snapshots, _):
            snapshots
        case .empty, .error:
            []
        }
    }
}

struct QuotaTimelineEntry: TimelineEntry, Sendable {
    let date: Date
    let state: QuotaWidgetState
}

struct QuotaTimelineProvider: TimelineProvider {
    typealias Entry = QuotaTimelineEntry

    /// WidgetKit treats this as a request, not a guaranteed refresh deadline.
    static let requestedRefreshInterval: TimeInterval = 15 * 60

    private let cache = SharedQuotaCache()

    func placeholder(in context: Context) -> QuotaTimelineEntry {
        QuotaTimelineEntry(date: .now, state: .empty)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (QuotaTimelineEntry) -> Void
    ) {
        let completion = WidgetKitCompletion(completion)
        Task {
            completion(await entry(at: .now))
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<QuotaTimelineEntry>) -> Void
    ) {
        let completion = WidgetKitCompletion(completion)
        Task {
            let now = Date()
            let currentEntry = await entry(at: now)
            var entries = [currentEntry]

            // If a system refresh is delayed, this prebuilt entry keeps the
            // widget honest about cached data becoming stale.
            if case let .current(snapshots) = currentEntry.state,
               let cachedState = try? await cache.load(),
               let staleDate = earliestStaleDate(in: snapshots, cacheState: cachedState),
               staleDate > now {
                entries.append(
                    QuotaTimelineEntry(
                        date: staleDate,
                        state: .stale(
                            snapshots,
                            oldestUpdate: oldestUpdate(in: snapshots) ?? now
                        )
                    )
                )
            }

            completion(
                Timeline(
                    entries: entries,
                    policy: .after(now.addingTimeInterval(Self.requestedRefreshInterval))
                )
            )
        }
    }

    private func entry(at date: Date) async -> QuotaTimelineEntry {
        do {
            let cachedState = try await cache.load()
            let snapshots = sorted(cachedState.snapshots)
            guard !snapshots.isEmpty else {
                return QuotaTimelineEntry(date: date, state: .empty)
            }

            if snapshots.contains(where: { isStale($0, in: cachedState, at: date) }) {
                return QuotaTimelineEntry(
                    date: date,
                    state: .stale(
                        snapshots,
                        oldestUpdate: oldestUpdate(in: snapshots) ?? cachedState.savedAt
                    )
                )
            }

            return QuotaTimelineEntry(date: date, state: .current(snapshots))
        } catch {
            return QuotaTimelineEntry(date: date, state: .error)
        }
    }

    private func earliestStaleDate(
        in snapshots: [QuotaSnapshot],
        cacheState: QuotaCacheState
    ) -> Date? {
        snapshots.map { snapshot in
            let metadata = cacheState.metadata(for: snapshot.toolID)
            if let metadata, metadata.consecutiveFailureCount > 0 {
                return snapshot.updatedAt
            }
            return metadata?.nextRefreshAt
                ?? snapshot.updatedAt.addingTimeInterval(Self.requestedRefreshInterval)
        }.min()
    }

    private func isStale(
        _ snapshot: QuotaSnapshot,
        in cacheState: QuotaCacheState,
        at date: Date
    ) -> Bool {
        if let metadata = cacheState.metadata(for: snapshot.toolID),
           metadata.consecutiveFailureCount > 0 {
            return true
        }
        if let nextRefreshAt = cacheState.metadata(for: snapshot.toolID)?.nextRefreshAt {
            return date >= nextRefreshAt
        }
        return snapshot.isStale(at: date, maximumAge: Self.requestedRefreshInterval)
    }

    private func oldestUpdate(in snapshots: [QuotaSnapshot]) -> Date? {
        snapshots.map(\QuotaSnapshot.updatedAt).min()
    }

    private func sorted(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        snapshots.sorted { left, right in
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
}

/// WidgetKit's completion-based provider API predates Swift 6 sendability.
/// Each callback is retained only long enough for one task to invoke it once.
private final class WidgetKitCompletion<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func callAsFunction(_ value: Value) {
        callback(value)
    }
}
