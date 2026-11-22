import Foundation

public extension QuotaSnapshot {
    /// How close this limit is to running out: what's left of its lower window.
    var tightness: Double {
        min(remainingPercent, secondaryWindow?.remainingPercent ?? 100)
    }
}

/// One AI tool's limits, for a row that shows the tool at a glance.
public struct ToolUsageSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let symbolName: String?
    /// Every limit the tool reported, in the order the Mac sent them.
    public let limits: [QuotaSnapshot]
    /// The limit closest to running out. A row names it when the tool has
    /// others, so a nearly used-up limit is never hidden behind a healthy one.
    public let tightest: QuotaSnapshot

    public var otherLimitCount: Int { limits.count - 1 }

    /// Groups limits by tool, keeping the order in which each tool first appears.
    public static func group(_ snapshots: [QuotaSnapshot]) -> [ToolUsageSummary] {
        var order: [UUID] = []
        for snapshot in snapshots where !order.contains(snapshot.toolID) {
            order.append(snapshot.toolID)
        }
        return order.compactMap { toolID in
            let limits = snapshots.filter { $0.toolID == toolID }
            guard let first = limits.first,
                  let tightest = limits.min(by: { $0.tightness < $1.tightness }) else { return nil }
            return ToolUsageSummary(
                id: toolID,
                name: first.toolName,
                symbolName: limits.lazy.compactMap(\.toolSymbolName).first,
                limits: limits,
                tightest: tightest
            )
        }
    }
}

#if DEBUG
public extension UsageDemoData {
    /// The sample readings as the iPhone stores them.
    static func snapshots(now: Date = Date()) -> [QuotaSnapshot] {
        envelope(now: now).tools.enumerated().flatMap { index, tool in
            let toolID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1)) ?? UUID()
            return tool.limits.map { limit in
                QuotaSnapshot(
                    id: QuotaSnapshot.stableID(toolID: toolID, limitID: limit.id),
                    limitID: limit.id,
                    toolID: toolID,
                    toolName: tool.displayName,
                    displayName: limit.displayName,
                    remainingPercent: limit.primary.remainingPercent,
                    resetAt: limit.primary.resetAt,
                    updatedAt: tool.sourceUpdatedAt,
                    planType: limit.planType,
                    windowDurationMinutes: limit.primary.windowDurationSeconds.map { $0 / 60 },
                    secondaryWindow: limit.secondary.map {
                        QuotaWindowSnapshot(
                            remainingPercent: $0.remainingPercent,
                            resetAt: $0.resetAt,
                            windowDurationMinutes: $0.windowDurationSeconds.map { $0 / 60 }
                        )
                    },
                    toolSymbolName: tool.symbolName
                )
            }
        }
    }
}
#endif
