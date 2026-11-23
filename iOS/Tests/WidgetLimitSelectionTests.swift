import Foundation
import XCTest
@testable import usAIge_iOS

final class WidgetLimitSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ name: String,
        remaining: Double,
        tool: UUID = UUID(),
        secondaryRemaining: Double? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: QuotaSnapshot.stableID(toolID: tool, limitID: name),
            limitID: name,
            toolID: tool,
            toolName: "Tool",
            displayName: name,
            remainingPercent: remaining,
            resetAt: nil,
            updatedAt: now,
            windowDurationMinutes: 300,
            secondaryWindow: secondaryRemaining.map {
                QuotaWindowSnapshot(remainingPercent: $0, resetAt: nil, windowDurationMinutes: 10_080)
            }
        )
    }

    func testAutomaticSelectionOrdersByLowestRemaining() {
        let snapshots = [
            snapshot("a", remaining: 80),
            snapshot("b", remaining: 90, secondaryRemaining: 10),
            snapshot("c", remaining: 50),
        ]

        let resolved = WidgetLimitSelection.resolve(selectedIDs: [], from: snapshots, maximumCount: 2)

        XCTAssertEqual(resolved.map(\.displayName), ["b", "c"])
    }

    func testAutomaticSelectionKeepsOneTightestLimitPerTool() {
        let tool = UUID()
        let a = snapshot("a", remaining: 20, tool: tool)
        let b = snapshot("b", remaining: 90, tool: tool, secondaryRemaining: 10)
        let c = snapshot("c", remaining: 50)

        let resolved = WidgetLimitSelection.resolve(selectedIDs: [], from: [a, c, b], maximumCount: 4)

        XCTAssertEqual(resolved.map(\.id), [b.id, c.id])
    }

    func testExplicitSelectionKeepsConfiguredOrder() {
        let a = snapshot("a", remaining: 80)
        let b = snapshot("b", remaining: 10)
        let c = snapshot("c", remaining: 50)

        let resolved = WidgetLimitSelection.resolve(selectedIDs: [c.id, a.id], from: [a, b, c], maximumCount: 2)

        XCTAssertEqual(resolved.map(\.displayName), ["c", "a"])
    }

    func testExplicitSelectionAllowsTwoLimitsOfTheSameTool() {
        let tool = UUID()
        let a = snapshot("a", remaining: 80, tool: tool)
        let b = snapshot("b", remaining: 10, tool: tool)
        let c = snapshot("c", remaining: 50)

        let resolved = WidgetLimitSelection.resolve(selectedIDs: [a.id, b.id], from: [b, c, a], maximumCount: 2)

        XCTAssertEqual(resolved.map(\.id), [a.id, b.id])
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

    func testBackfillSkipsToolsRepresentedByExplicitAndBackfilledLimits() {
        let selectedTool = UUID()
        let nextTool = UUID()
        let picked = snapshot("picked", remaining: 80, tool: selectedTool)
        let sameTool = snapshot("same-tool", remaining: 5, tool: selectedTool)
        let next = snapshot("next", remaining: 90, tool: nextTool, secondaryRemaining: 10)
        let otherLimit = snapshot("other-limit", remaining: 20, tool: nextTool)
        let last = snapshot("last", remaining: 50)

        let resolved = WidgetLimitSelection.resolve(
            selectedIDs: [picked.id, "missing"],
            from: [picked, last, sameTool, otherLimit, next],
            maximumCount: 4
        )

        XCTAssertEqual(resolved.map(\.id), [picked.id, next.id, last.id])
    }

    func testEntirelyStaleSelectionFallsBackToAutomaticOrdering() {
        let a = snapshot("a", remaining: 80)
        let b = snapshot("b", remaining: 10)

        let resolved = WidgetLimitSelection.resolve(selectedIDs: ["missing"], from: [a, b], maximumCount: 4)

        XCTAssertEqual(resolved.map(\.displayName), ["b", "a"])
    }
}
