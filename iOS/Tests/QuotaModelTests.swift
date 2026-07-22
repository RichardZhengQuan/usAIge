import Foundation
import XCTest
@testable import usAIge_iOS

final class QuotaModelTests: XCTestCase {
    func testSessionStatusPhasesExposeMacOSLabelsAndLightState() {
        XCTAssertEqual(CodexSessionPhase.thinking.label, "Thinking")
        XCTAssertEqual(CodexSessionPhase.complete.label, "Complete")
        XCTAssertEqual(CodexSessionPhase.needsInput.label, "Needs input")
        XCTAssertEqual(CodexSessionPhase.error.label, "Error")
        XCTAssertFalse(CodexSessionPhase.idle.showsLight)
        XCTAssertTrue(CodexSessionPhase.thinking.showsLight)
    }

    func testQuotaSeverityMatchesMacOSFiveBandThresholds() {
        let cases: [(Double, QuotaSeverity)] = [
            (100, .abundant),
            (60.1, .abundant),
            (60, .healthy),
            (40.1, .healthy),
            (40, .caution),
            (20.1, .caution),
            (20, .low),
            (10.1, .low),
            (10, .critical),
            (0, .critical),
        ]

        for (remainingPercent, expectedSeverity) in cases {
            XCTAssertEqual(
                QuotaSeverity(remainingPercent: remainingPercent),
                expectedSeverity
            )
        }
    }

    func testWindowTypeTagsAndPercentageNormalization() {
        XCTAssertEqual(window(minutes: 300).typeTag, "5H")
        XCTAssertEqual(window(minutes: 1_440).typeTag, "1D")
        XCTAssertEqual(window(minutes: 10_080).typeTag, "7D")
        XCTAssertEqual(window(minutes: 45).typeTag, "45M")
        XCTAssertEqual(window(minutes: nil).typeTag, "LIMIT")

        let clamped = QuotaWindowSnapshot(
            remainingPercent: 120,
            resetAt: nil,
            windowDurationMinutes: 0
        )
        XCTAssertEqual(clamped.remainingPercent, 100)
        XCTAssertEqual(clamped.usedPercent, 0)
        XCTAssertNil(clamped.windowDurationMinutes)
    }

    func testFreshnessUsesCallerSuppliedMaximumAge() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = QuotaSnapshot(
            id: "tool:limit",
            limitID: "limit",
            toolID: UUID(),
            toolName: "Tool",
            displayName: "Limit",
            remainingPercent: 50,
            resetAt: nil,
            updatedAt: updatedAt
        )

        XCTAssertFalse(
            snapshot.isStale(
                at: updatedAt.addingTimeInterval(899),
                maximumAge: 900
            )
        )
        XCTAssertTrue(
            snapshot.isStale(
                at: updatedAt.addingTimeInterval(901),
                maximumAge: 900
            )
        )
    }

    func testWidgetLimitSelectionFiltersAutomaticAndDuplicateIDs() {
        XCTAssertEqual(
            WidgetLimitSelection.explicitIDs(
                from: [
                    WidgetLimitSelection.automaticID,
                    "limit-b",
                    "limit-b",
                    nil,
                    "limit-a",
                ]
            ),
            ["limit-b", "limit-a"]
        )
    }

    func testWidgetLimitSelectionPreservesChoiceAndRecoversFromStaleIDs() {
        let now = Date(timeIntervalSince1970: 1_000)
        let toolID = UUID()
        let snapshots = [
            QuotaSnapshot(
                id: "limit-a",
                limitID: "a",
                toolID: toolID,
                toolName: "Tool",
                displayName: "A",
                remainingPercent: 70,
                resetAt: nil,
                updatedAt: now
            ),
            QuotaSnapshot(
                id: "limit-b",
                limitID: "b",
                toolID: toolID,
                toolName: "Tool",
                displayName: "B",
                remainingPercent: 20,
                resetAt: nil,
                updatedAt: now
            ),
        ]

        XCTAssertEqual(
            WidgetLimitSelection.resolve(
                selectedIDs: ["limit-a", "limit-b"],
                from: snapshots,
                maximumCount: 2
            ).map(\.id),
            ["limit-a", "limit-b"]
        )
        XCTAssertEqual(
            WidgetLimitSelection.resolve(
                selectedIDs: ["removed-limit"],
                from: snapshots,
                maximumCount: 1
            ).map(\.id),
            ["limit-b"]
        )
    }

    func testResetCreditSummaryNormalizesCountAndPreservesExpiration() {
        let expiration = Date(timeIntervalSince1970: 1_800_950_400)
        let snapshot = QuotaSnapshot(
            id: "tool:limit",
            limitID: "limit",
            toolID: UUID(),
            toolName: "Codex",
            displayName: "Codex",
            remainingPercent: 50,
            resetAt: nil,
            updatedAt: Date(),
            availableResetCount: -1,
            resetCreditExpiresAt: expiration
        )

        XCTAssertEqual(snapshot.availableResetCount, 0)
        XCTAssertEqual(snapshot.resetCreditExpiresAt, expiration)
    }

    func testRefreshMetadataRecordsSuccessAndFailure() {
        let toolID = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        let success = RefreshScheduleMetadata(toolID: toolID)
            .recordingSuccess(at: start, refreshIntervalMinutes: 15)

        XCTAssertEqual(success.lastAttemptAt, start)
        XCTAssertEqual(success.lastSuccessAt, start)
        XCTAssertEqual(success.nextRefreshAt, start.addingTimeInterval(900))
        XCTAssertEqual(success.consecutiveFailureCount, 0)
        XCTAssertFalse(success.isRefreshDue(at: start.addingTimeInterval(899)))

        let failure = success.recordingFailure(
            at: start.addingTimeInterval(900),
            retryDelay: 300
        )
        XCTAssertEqual(failure.consecutiveFailureCount, 1)
        XCTAssertEqual(failure.lastSuccessAt, start)
        XCTAssertEqual(failure.nextRefreshAt, start.addingTimeInterval(1_200))
    }

    func testConfigurationSelectsKnownAndFallbackSymbols() {
        XCTAssertEqual(configuration(named: "ChatGPT Enterprise").symbolName, "sparkles")
        XCTAssertEqual(configuration(named: "Claude Team").symbolName, "brain.head.profile")
        XCTAssertEqual(configuration(named: "My Internal AI").symbolName, "cpu")
    }

    func testEndpointValidationKeepsCredentialsOutOfPersistedURLs() {
        XCTAssertTrue(
            RemoteToolConfiguration.isSupportedEndpoint(
                URL(string: "https://example.com/limits")!
            )
        )
        XCTAssertFalse(
            RemoteToolConfiguration.isSupportedEndpoint(
                URL(string: "https://user:secret@example.com/limits")!
            )
        )
        XCTAssertFalse(
            RemoteToolConfiguration.isSupportedEndpoint(
                URL(string: "https://example.com/limits?token=secret")!
            )
        )
        XCTAssertFalse(
            RemoteToolConfiguration.isSupportedEndpoint(
                URL(string: "https://example.com/limits#secret")!
            )
        )
    }

    func testWatchSnapshotPreservesMacSourceMetadata() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_784_400_000)
        let tool = WatchToolQuotaSnapshot(
            id: "mac:tool",
            displayName: "Codex",
            sourceID: "mac",
            sourceName: "Studio Mac",
            serverUpdatedAt: updatedAt,
            sourceUpdatedAt: updatedAt,
            receivedAt: updatedAt,
            limits: [
                WatchQuotaSnapshot(
                    id: "five-hour",
                    displayName: "5 hour",
                    primary: WatchQuotaWindowSnapshot(
                        remainingPercent: 42,
                        resetAt: nil,
                        windowDurationSeconds: 18_000
                    )
                )
            ],
            sessionStatus: WatchSessionStatus(phase: .needsInput, updatedAt: updatedAt)
        )

        let encoded = try WatchUsageSnapshotCodec.encode(
            WatchUsageSnapshotEnvelope(generatedAt: updatedAt, tools: [tool])
        )
        let decoded = try WatchUsageSnapshotCodec.decode(encoded)

        XCTAssertEqual(decoded.tools.first?.sourceID, "mac")
        XCTAssertEqual(decoded.tools.first?.sourceName, "Studio Mac")
        XCTAssertEqual(decoded.tools.first?.serverUpdatedAt, updatedAt)
        XCTAssertEqual(decoded.tools.first?.sessionStatus?.phase, .needsInput)
        XCTAssertEqual(decoded.tools.first?.sessionStatus?.updatedAt, updatedAt)
    }

    func testWatchSnapshotStillDecodesPayloadsWithoutMacMetadata() throws {
        let data = Data(
            #"{"generatedAt":"2026-07-19T00:00:00Z","schemaVersion":1,"tools":[{"displayName":"Codex","id":"tool","limits":[],"receivedAt":"2026-07-19T00:00:00Z","sourceUpdatedAt":"2026-07-19T00:00:00Z"}]}"#.utf8
        )

        let decoded = try WatchUsageSnapshotCodec.decode(data)

        XCTAssertNil(decoded.tools.first?.sourceID)
        XCTAssertNil(decoded.tools.first?.sourceName)
        XCTAssertNil(decoded.tools.first?.serverUpdatedAt)
        XCTAssertNil(decoded.tools.first?.sessionStatus)
    }

    func testWatchSnapshotTreatsFutureSessionPhasesAsUnknown() throws {
        let data = Data(
            #"{"generatedAt":"2026-07-19T00:00:00Z","schemaVersion":1,"tools":[{"displayName":"Codex","id":"tool","limits":[],"receivedAt":"2026-07-19T00:00:00Z","sessionStatus":{"phase":"reviewing","updatedAt":"2026-07-19T00:00:00Z"},"sourceUpdatedAt":"2026-07-19T00:00:00Z"}]}"#.utf8
        )

        let decoded = try WatchUsageSnapshotCodec.decode(data)

        XCTAssertEqual(decoded.tools.first?.sessionStatus?.phase, .unknown)
        XCTAssertFalse(decoded.tools.first?.sessionStatus?.phase.showsLight ?? true)
    }

    func testWatchRelayCredentialsRoundTripSeparatelyFromSnapshots() throws {
        let credential = WatchRelayCredential(
            channelID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            deviceID: UUID(uuidString: "22222222-2222-5222-8222-222222222222")!,
            macName: "Studio Mac",
            readToken: "usg_watch_secret"
        )

        let decoded = try WatchRelayCredentialCodec.decode(
            WatchRelayCredentialCodec.encode([credential])
        )

        XCTAssertEqual(decoded, [credential])
        let snapshotData = try WatchUsageSnapshotCodec.encode(
            WatchUsageSnapshotEnvelope(generatedAt: Date(), tools: [])
        )
        XCTAssertFalse(String(decoding: snapshotData, as: UTF8.self).contains(credential.readToken))
    }

    private func window(minutes: Int?) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            remainingPercent: 50,
            resetAt: nil,
            windowDurationMinutes: minutes
        )
    }

    private func configuration(named name: String) -> RemoteToolConfiguration {
        RemoteToolConfiguration(
            name: name,
            endpointURL: URL(string: "https://example.com")!
        )
    }
}
