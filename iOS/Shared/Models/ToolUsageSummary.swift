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
    public let availableResetCount: Int?
    public let resetCreditExpiresAt: Date?
    public let resetCredits: [ResetCreditSnapshot]

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
            let credit = limits.firstWithResetCredit
            return ToolUsageSummary(
                id: toolID,
                name: first.toolName,
                symbolName: limits.lazy.compactMap(\.toolSymbolName).first,
                limits: limits,
                tightest: tightest,
                availableResetCount: credit?.availableResetCount,
                resetCreditExpiresAt: credit?.resetCreditExpiresAt,
                resetCredits: limits.first { !$0.resetCredits.isEmpty }?.resetCredits ?? []
            )
        }
    }
}

extension Array where Element == QuotaSnapshot {
    var firstWithResetCredit: QuotaSnapshot? {
        first { ($0.availableResetCount ?? 0) > 0 }
    }
}

#if DEBUG
public extension UsageDemoData {
    /// The sample readings as the iPhone stores them.
    static func snapshots(now: Date = Date()) -> [QuotaSnapshot] {
        macSections(now: now).flatMap(\.snapshots)
    }

    /// The sample readings grouped by Mac, as the iPhone's Usage tab shows them.
    static func macSections(
        _ scenario: Scenario = UsageDemoData.scenario ?? .standard,
        now: Date = Date()
    ) -> [(id: UUID, name: String, snapshots: [QuotaSnapshot], updatedAt: Date)] {
        let tools = envelope(scenario, now: now).tools
        var macs: [String] = []
        for tool in tools where !macs.contains(tool.sourceID ?? "") { macs.append(tool.sourceID ?? "") }
        return macs.enumerated().map { macIndex, mac in
            let macTools = tools.filter { ($0.sourceID ?? "") == mac }
            let snapshots = macTools.flatMap { tool -> [QuotaSnapshot] in
                let index = tools.firstIndex(of: tool) ?? 0
                let toolID = demoUUID(index + 1)
                let credits = resetCredits(for: tool, in: scenario)
                let resetCount = tool.availableResetCount ?? (credits.isEmpty ? nil : credits.count)
                let resetExpiry = tool.resetCreditExpiresAt ?? credits.compactMap(\.expiresAt).min()
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
                        availableResetCount: resetCount,
                        resetCreditExpiresAt: resetExpiry,
                        resetCredits: credits,
                        secondaryWindow: limit.secondary.map {
                            QuotaWindowSnapshot(
                                remainingPercent: $0.remainingPercent,
                                resetAt: $0.resetAt,
                                windowDurationMinutes: $0.windowDurationSeconds.map { $0 / 60 }
                            )
                        },
                        sessionStatus: tool.sessionStatus.flatMap { status in
                            CodexSessionPhase(rawValue: status.phase.rawValue).map {
                                CodexSessionStatus(phase: $0, updatedAt: status.updatedAt)
                            }
                        },
                        toolSymbolName: tool.symbolName
                    )
                }
            }
            return (
                id: demoUUID(1_000 + macIndex),
                name: macTools.first?.sourceName ?? "Mac",
                snapshots: snapshots,
                updatedAt: macTools.map(\.sourceUpdatedAt).max() ?? now
            )
        }
    }

    private static func demoUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value)) ?? UUID()
    }
}
#endif
