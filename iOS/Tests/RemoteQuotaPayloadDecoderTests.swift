import Foundation
import XCTest
@testable import usAIge_iOS

final class RemoteQuotaPayloadDecoderTests: XCTestCase {
    private let toolID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let updatedAt = Date(timeIntervalSince1970: 1_721_000_000)

    func testDecodesDocumentedAliasesAndMultipleWindows() throws {
        let data = Data(#"""
        {
          "tool": { "id": "ignored", "name": "Ignored" },
          "limits": [{
            "id": "five-hour",
            "name": "5-hour limit",
            "usedPercent": 42,
            "resetAt": "2026-07-14T12:00:00Z",
            "windowMinutes": 300,
            "plan": "Team",
            "secondaryWindow": {
              "usedPercent": 18,
              "resetAt": 1784505600,
              "windowMinutes": 10080
            }
          }]
        }
        """#.utf8)

        let snapshots = try RemoteQuotaPayloadDecoder().decode(
            data,
            for: configuration(),
            updatedAt: updatedAt
        )

        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshot.id, "\(toolID.uuidString.lowercased()):five-hour")
        XCTAssertEqual(snapshot.limitID, "five-hour")
        XCTAssertEqual(snapshot.toolID, toolID)
        XCTAssertEqual(snapshot.toolName, "Claude Team")
        XCTAssertEqual(snapshot.displayName, "5-hour limit")
        XCTAssertEqual(snapshot.remainingPercent, 58)
        XCTAssertEqual(snapshot.usedPercent, 42)
        XCTAssertEqual(snapshot.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.typeTag, "5H")
        XCTAssertEqual(snapshot.planType, "Team")
        XCTAssertEqual(snapshot.updatedAt, updatedAt)
        XCTAssertEqual(snapshot.secondaryWindow?.remainingPercent, 82)
        XCTAssertEqual(snapshot.secondaryWindow?.windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.secondaryWindow?.typeTag, "7D")
    }

    func testAcceptsCanonicalFieldsAndRemainingPercentage() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "limits": [{
            "id": "weekly_messages",
            "displayName": "Weekly messages",
            "remainingPercent": 73.25,
            "windowDurationMinutes": 10080,
            "planType": "Pro"
          }]
        }
        """#.utf8)

        let snapshot = try XCTUnwrap(
            RemoteQuotaPayloadDecoder()
                .decode(data, for: configuration(), updatedAt: updatedAt)
                .first
        )

        XCTAssertEqual(snapshot.remainingPercent, 73.25)
        XCTAssertEqual(snapshot.displayName, "Weekly messages")
        XCTAssertEqual(snapshot.planType, "Pro")
        XCTAssertNil(snapshot.resetAt)
    }

    func testHumanizesMissingDisplayName() throws {
        let data = Data(#"{"limits":[{"id":"weekly-messages","usedPercent":10}]}"#.utf8)

        let snapshot = try XCTUnwrap(
            RemoteQuotaPayloadDecoder().decode(data, for: configuration()).first
        )

        XCTAssertEqual(snapshot.displayName, "Weekly Messages")
    }

    func testRejectsEmptyLimits() {
        let data = Data(#"{"limits":[]}"#.utf8)

        XCTAssertThrowsError(
            try RemoteQuotaPayloadDecoder().decode(data, for: configuration())
        ) { error in
            XCTAssertEqual(error as? RemoteQuotaPayloadError, .emptyLimits)
        }
    }

    func testRejectsDuplicateLimitIDs() {
        let data = Data(#"""
        {"limits":[
          {"id":"messages","usedPercent":10},
          {"id":"messages","remainingPercent":90}
        ]}
        """#.utf8)

        XCTAssertThrowsError(
            try RemoteQuotaPayloadDecoder().decode(data, for: configuration())
        ) { error in
            XCTAssertEqual(
                error as? RemoteQuotaPayloadError,
                .duplicateLimitID("messages")
            )
        }
    }

    func testRejectsOutOfRangeAndConflictingPercentages() {
        let outOfRange = Data(
            #"{"limits":[{"id":"messages","usedPercent":101}]}"#.utf8
        )
        XCTAssertThrowsError(
            try RemoteQuotaPayloadDecoder().decode(outOfRange, for: configuration())
        ) { error in
            XCTAssertEqual(
                error as? RemoteQuotaPayloadError,
                .percentageOutOfRange(limitID: "messages", window: "primary")
            )
        }

        let conflicting = Data(
            #"{"limits":[{"id":"messages","usedPercent":20,"remainingPercent":20}]}"#.utf8
        )
        XCTAssertThrowsError(
            try RemoteQuotaPayloadDecoder().decode(conflicting, for: configuration())
        ) { error in
            XCTAssertEqual(
                error as? RemoteQuotaPayloadError,
                .conflictingUsagePercentages(limitID: "messages", window: "primary")
            )
        }
    }

    private func configuration() -> RemoteToolConfiguration {
        RemoteToolConfiguration(
            id: toolID,
            name: "Claude Team",
            endpointURL: URL(string: "https://example.com/limits")!,
            refreshIntervalMinutes: 15
        )
    }
}
