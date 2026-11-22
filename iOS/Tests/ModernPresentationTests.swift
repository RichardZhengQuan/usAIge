import Foundation
import SwiftUI
import XCTest
@testable import usAIge_iOS

final class ModernPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_400_000)

    func testResetCountdownCompactRoundsUpAtEachTimeUnit() {
        let cases: [(TimeInterval?, String)] = [
            (nil, "—"),
            (-1, "NOW"),
            (0, "NOW"),
            (30, "1M"),
            (59 * 60, "59M"),
            (3_600, "1H"),
            (3_601, "2H"),
            (86_400, "1D"),
            (86_401, "2D"),
        ]

        for (seconds, expected) in cases {
            let resetAt = seconds.map { now.addingTimeInterval($0) }
            XCTAssertEqual(ResetCountdown.compact(until: resetAt, now: now), expected)
        }
    }

    func testResetCountdownPhraseAndAccessibilityLabel() {
        let resetAt = now.addingTimeInterval(3_601)

        XCTAssertNil(ResetCountdown.phrase(until: nil, now: now))
        XCTAssertEqual(ResetCountdown.phrase(until: resetAt, now: now), "resets 2H")
        XCTAssertEqual(
            ResetCountdown.accessibilityLabel(until: nil, now: now),
            "Reset time unavailable"
        )
        XCTAssertEqual(
            ResetCountdown.accessibilityLabel(until: now, now: now),
            "Resetting now"
        )
        XCTAssertEqual(
            ResetCountdown.accessibilityLabel(until: resetAt, now: now),
            "Resets in 2H"
        )
    }

    func testUsageFillFractionDrawsEmptyWindowsFullAndBoundsPositiveValues() {
        let cases: [(Double, Double)] = [
            (0, 1),
            (-5, 1),
            (.nan, 1),
            (0.5, 0.015),
            (50, 0.5),
            (150, 1),
        ]

        for (remainingPercent, expected) in cases {
            XCTAssertEqual(
                ModernUsageColor.fillFraction(remainingPercent: remainingPercent),
                expected,
                accuracy: 0.000_001,
                "Remaining percent \(remainingPercent)"
            )
        }
    }

    func testUsagePercentRoundsToNearestWithTiesAwayFromZeroAndClamps() {
        let cases: [(Double, String)] = [
            (62.4, "62%"),
            (62.5, "63%"),
            (-5, "0%"),
            (120, "100%"),
            (.nan, "0%"),
        ]

        for (remainingPercent, expected) in cases {
            XCTAssertEqual(ModernUsageColor.percent(remainingPercent), expected)
        }
    }

    func testUsageColorUsesFiveRemainingPercentBands() {
        let deepRed = Color(red: 0.72, green: 0, blue: 0.04)
        let cases: [(Double, Color)] = [
            (100, .blue),
            (61, .blue),
            (60, .green),
            (41, .green),
            (40, .orange),
            (21, .orange),
            (20, .red),
            (11, .red),
            (10, deepRed),
            (0, deepRed),
        ]

        for (remainingPercent, expected) in cases {
            XCTAssertEqual(
                ModernUsageColor.color(remainingPercent: remainingPercent),
                expected,
                "Remaining percent \(remainingPercent)"
            )
        }
    }

    func testQuotaSnapshotTightnessUsesLowestRemainingPercent() {
        XCTAssertEqual(snapshot(remainingPercent: 40).tightness, 40)
        XCTAssertEqual(snapshot(remainingPercent: 40, secondaryPercent: 90).tightness, 40)
        XCTAssertEqual(snapshot(remainingPercent: 90, secondaryPercent: 15).tightness, 15)
    }

    func testToolUsageSummaryGroupsInterleavedLimitsInFirstAppearanceOrder() {
        let grokID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let claudeID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let standard = snapshot(
            "standard", toolID: grokID, toolName: "Grok Build", remainingPercent: 40
        )
        let claude = snapshot(
            "only", toolID: claudeID, toolName: "Claude", remainingPercent: 50
        )
        let symbolSource = snapshot(
            "extended", toolID: grokID, toolName: "Grok Build",
            remainingPercent: 70, symbolName: "g.circle"
        )
        let tightest = snapshot(
            "weekly", toolID: grokID, toolName: "Grok Build",
            remainingPercent: 90, secondaryPercent: 15, symbolName: "cpu"
        )
        let tied = snapshot(
            "tied", toolID: grokID, toolName: "Grok Build", remainingPercent: 15
        )

        let summaries = ToolUsageSummary.group([standard, claude, symbolSource, tightest, tied])

        XCTAssertEqual(summaries.map(\.id), [grokID, claudeID])
        XCTAssertEqual(summaries.map(\.name), ["Grok Build", "Claude"])
        XCTAssertEqual(summaries.map(\.limits), [[standard, symbolSource, tightest, tied], [claude]])
        XCTAssertEqual(summaries.map(\.tightest), [tightest, claude])
        XCTAssertEqual(summaries.map(\.symbolName), ["g.circle", nil])
        XCTAssertEqual(summaries.map(\.otherLimitCount), [3, 0])
        XCTAssertTrue(ToolUsageSummary.group([]).isEmpty)
    }

    func testToolMarkKindRecognizesVendorsAndFallsBackToSymbols() {
        let cases: [(String, String?, ToolMarkKind)] = [
            ("ChatGPT", "sparkles", .chatGPT),
            ("Codex", nil, .chatGPT),
            ("OpenAI", nil, .chatGPT),
            ("Claude Max", nil, .claude),
            ("Cursor", nil, .cursor),
            ("Grok Build", nil, .grok),
            ("Gemini", nil, .gemini),
            ("Unknown", "cpu", .symbol("cpu")),
            ("Unknown", nil, .symbol("sparkles")),
            ("Unknown", "", .symbol("sparkles")),
            ("Unknown", "  ", .symbol("sparkles")),
        ]

        for (toolName, symbolName, expected) in cases {
            XCTAssertEqual(
                ToolMarkKind(toolName: toolName, symbolName: symbolName),
                expected,
                "\(toolName) with symbol \(String(reflecting: symbolName))"
            )
        }
    }

    func testWatchQuotaTightnessSelectsLowestWindowAndPrefersPrimaryOnTie() {
        let primary = watchWindow(40, durationSeconds: 18_000)
        let lowerSecondary = watchWindow(15, durationSeconds: 604_800)
        let cases: [(WatchQuotaWindowSnapshot?, WatchQuotaWindowSnapshot)] = [
            (nil, primary),
            (lowerSecondary, lowerSecondary),
            (watchWindow(60, durationSeconds: 604_800), primary),
            (watchWindow(40, durationSeconds: 604_800), primary),
        ]

        for (secondary, expectedWindow) in cases {
            let limit = WatchQuotaSnapshot(
                id: "limit", displayName: "Limit", primary: primary, secondary: secondary
            )

            XCTAssertEqual(limit.tightness, expectedWindow.remainingPercent)
            XCTAssertEqual(limit.tightestWindow, expectedWindow)
        }
    }

    func testWatchWindowLengthTags() {
        let cases: [(Int?, String?)] = [
            (18_000, "5H"),
            (604_800, "7D"),
            (1_800, "30M"),
            (nil, nil),
            (0, nil),
        ]

        for (seconds, expected) in cases {
            XCTAssertEqual(watchWindow(50, durationSeconds: seconds).lengthTag, expected)
        }
    }

    func testWatchToolPicksFirstTightestLimitAndCountsOtherLimits() {
        let standard = WatchQuotaSnapshot(
            id: "standard", displayName: "Standard", primary: watchWindow(40)
        )
        let weekly = WatchQuotaSnapshot(
            id: "weekly", displayName: "Weekly", primary: watchWindow(90), secondary: watchWindow(15)
        )
        let tied = WatchQuotaSnapshot(
            id: "tied", displayName: "Tied", primary: watchWindow(15)
        )
        let cases: [([WatchQuotaSnapshot], WatchQuotaSnapshot?, Int)] = [
            ([], nil, 0),
            ([standard], standard, 0),
            ([standard, weekly, tied], weekly, 2),
        ]

        for (limits, expectedLimit, expectedCount) in cases {
            let tool = WatchToolQuotaSnapshot(
                id: "tool", displayName: "Tool", sourceUpdatedAt: now, receivedAt: now, limits: limits
            )

            XCTAssertEqual(tool.tightestLimit, expectedLimit)
            XCTAssertEqual(tool.otherLimitCount, expectedCount)
        }
    }

    #if DEBUG
    func testDemoEnvelopeRoundTripsThroughWatchCodec() throws {
        let envelope = UsageDemoData.envelope(now: now)
        let data = try WatchUsageSnapshotCodec.encode(envelope)

        XCTAssertEqual(envelope.tools.count, 4)
        XCTAssertEqual(try WatchUsageSnapshotCodec.decode(data), envelope)
    }

    func testDemoSnapshotsMatchWatchToolsAndLimits() throws {
        let envelope = UsageDemoData.envelope(now: now)
        let snapshots = UsageDemoData.snapshots(now: now)
        let summaries = ToolUsageSummary.group(snapshots)

        XCTAssertEqual(snapshots.count, envelope.tools.flatMap(\.limits).count)
        XCTAssertEqual(summaries.count, 4)
        XCTAssertEqual(summaries.map(\.name), envelope.tools.map(\.displayName))
        XCTAssertEqual(summaries.map(\.symbolName), envelope.tools.map(\.symbolName))
        XCTAssertEqual(
            summaries.map { $0.limits.map(\.limitID) },
            envelope.tools.map { $0.limits.map(\.id) }
        )
        let claude = try XCTUnwrap(summaries.first { $0.name == "Claude" })
        XCTAssertEqual(claude.tightest.displayName, "Fable")
    }
    #endif

    func testQuotaSnapshotKeepsSymbolOnRoundTripAndDecodesLegacyJSON() throws {
        let original = snapshot(remainingPercent: 50, symbolName: "cpu")
        let data = try JSONEncoder().encode(original)
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(QuotaSnapshot.self, from: data), original)

        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(legacyJSON.removeValue(forKey: "toolSymbolName") as? String, "cpu")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacySnapshot = try decoder.decode(QuotaSnapshot.self, from: legacyData)
        XCTAssertNil(legacySnapshot.toolSymbolName)
    }

    private func snapshot(
        _ limitID: String = "limit",
        toolID: UUID = UUID(),
        toolName: String = "Tool",
        remainingPercent: Double,
        secondaryPercent: Double? = nil,
        symbolName: String? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: QuotaSnapshot.stableID(toolID: toolID, limitID: limitID),
            limitID: limitID,
            toolID: toolID,
            toolName: toolName,
            displayName: limitID,
            remainingPercent: remainingPercent,
            resetAt: nil,
            updatedAt: now,
            secondaryWindow: secondaryPercent.map {
                QuotaWindowSnapshot(remainingPercent: $0, resetAt: nil, windowDurationMinutes: nil)
            },
            toolSymbolName: symbolName
        )
    }

    private func watchWindow(
        _ remainingPercent: Double,
        durationSeconds: Int? = nil
    ) -> WatchQuotaWindowSnapshot {
        WatchQuotaWindowSnapshot(
            remainingPercent: remainingPercent,
            resetAt: nil,
            windowDurationSeconds: durationSeconds
        )
    }
}
