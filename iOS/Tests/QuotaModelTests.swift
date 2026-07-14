import Foundation
import XCTest
@testable import usAIge_iOS

final class QuotaModelTests: XCTestCase {
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
