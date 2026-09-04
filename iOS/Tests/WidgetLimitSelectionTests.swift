import Foundation
import XCTest
@testable import usAIge_iOS

final class WidgetLimitSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ name: String, remaining: Double, tool: UUID = UUID()) -> QuotaSnapshot {
        QuotaSnapshot(
            id: QuotaSnapshot.stableID(toolID: tool, limitID: name),
            limitID: name,
            toolID: tool,
            toolName: "Tool",
            displayName: name,
            remainingPercent: remaining,
            resetAt: nil,
            updatedAt: now,
            windowDurationMinutes: 300
        )
    }

    func testAutomaticSelectionOrdersByLowestRemaining() {
        let snapshots = [
            snapshot("a", remaining: 80),
            snapshot("b", remaining: 10),
            snapshot("c", remaining: 50),
        ]

        let resolved = WidgetLimitSelection.resolve(selectedIDs: [], from: snapshots, maximumCount: 2)

        XCTAssertEqual(resolved.map(\.displayName), ["b", "c"])
    }

    func testExplicitSelectionKeepsConfiguredOrder() {
        let a = snapshot("a", remaining: 80)
        let b = snapshot("b", remaining: 10)
        let c = snapshot("c", remaining: 50)

        let resolved = WidgetLimitSelection.resolve(selectedIDs: [c.id, a.id], from: [a, b, c], maximumCount: 2)

        XCTAssertEqual(resolved.map(\.displayName), ["c", "a"])
    }

    func testMissingConfiguredLimitsAreBackfilledInsteadOfShrinkingTheWidget() {
        let a = snapshot("a", remaining: 80)
        let b = snapshot("b", remaining: 10)
        let c = snapshot("c", remaining: 50)
        let removed = snapshot("gone", remaining: 5)

        let resolved = WidgetLimitSelection.resolve(
            selectedIDs: [a.id, removed.id],
            from: [a, b, c],
            maximumCount: 2
        )

        XCTAssertEqual(resolved.map(\.displayName), ["a", "b"])
    }

    func testEntirelyStaleSelectionFallsBackToAutomaticOrdering() {
        let a = snapshot("a", remaining: 80)
        let b = snapshot("b", remaining: 10)

        let resolved = WidgetLimitSelection.resolve(selectedIDs: ["missing"], from: [a, b], maximumCount: 4)

        XCTAssertEqual(resolved.map(\.displayName), ["b", "a"])
    }
}
