import Foundation
import XCTest
@testable import usAIge_iOS

final class PersistenceStoreTests: XCTestCase {
    func testToolConfigurationStoreRoundTripsAndNormalizesInterval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolConfigurationStore(
            fileURL: directory.appendingPathComponent("tools.json")
        )
        let tool = RemoteToolConfiguration(
            name: "Remote Tool",
            endpointURL: URL(string: "https://example.com/limits")!,
            refreshIntervalMinutes: 0,
            isEnabled: true
        )

        try await store.save([tool])
        let restored = try await store.load()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, tool.id)
        XCTAssertEqual(restored.first?.refreshIntervalMinutes, 1)
    }

    func testMissingFilesLoadAsEmpty() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tools = try await ToolConfigurationStore(
            fileURL: directory.appendingPathComponent("missing-tools.json")
        ).load()
        let cache = try await SharedQuotaCache(
            appGroupIdentifier: "invalid.test.group.\(UUID().uuidString)",
            fallbackDirectoryURL: directory
        ).load()

        XCTAssertTrue(tools.isEmpty)
        XCTAssertEqual(cache, .empty)
    }

    func testSharedCacheRoundTripsSnapshotsAndRefreshMetadata() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SharedQuotaCache(
            appGroupIdentifier: "invalid.test.group.\(UUID().uuidString)",
            fallbackDirectoryURL: directory
        )
        let toolID = UUID()
        let now = Date(timeIntervalSince1970: 1_721_000_000)
        let snapshot = QuotaSnapshot(
            id: QuotaSnapshot.stableID(toolID: toolID, limitID: "messages"),
            limitID: "messages",
            toolID: toolID,
            toolName: "Remote Tool",
            displayName: "Messages",
            remainingPercent: 60,
            resetAt: now.addingTimeInterval(3_600),
            updatedAt: now,
            planType: "Pro",
            windowDurationMinutes: 300,
            secondaryWindow: nil
        )
        let metadata = RefreshScheduleMetadata(toolID: toolID)
            .recordingSuccess(at: now, refreshIntervalMinutes: 15)
        let state = QuotaCacheState(
            snapshots: [snapshot],
            refreshMetadata: [metadata],
            savedAt: now
        )

        try await cache.save(state)
        let restored = try await cache.load()

        XCTAssertEqual(restored, state)
        XCTAssertFalse(cache.usesAppGroupContainer)
        XCTAssertEqual(restored.metadata(for: toolID), metadata)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
