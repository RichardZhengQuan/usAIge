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
            secondaryWindow: nil,
            sessionStatus: CodexSessionStatus(
                phase: .thinking,
                updatedAt: now.addingTimeInterval(-2)
            )
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

    func testRelayConnectionStoreRoundTripsMultipleMacs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RelayConnectionStore(
            fileURL: directory.appendingPathComponent("relay-connections.json")
        )
        let firstToolID = UUID()
        let firstSnapshot = QuotaSnapshot(
            id: QuotaSnapshot.stableID(toolID: firstToolID, limitID: "codex"),
            limitID: "codex",
            toolID: firstToolID,
            toolName: "ChatGPT",
            displayName: "Codex",
            remainingPercent: 64,
            resetAt: nil,
            updatedAt: Date(timeIntervalSince1970: 999)
        )
        let first = RelayConnectionState(
            connection: RelayConnection(
                channelID: UUID(),
                deviceID: UUID(),
                macName: "Studio Mac"
            ),
            snapshots: [firstSnapshot],
            serverReceivedAt: Date(timeIntervalSince1970: 1_000),
            cacheSavedAt: Date(timeIntervalSince1970: 1_001),
            etag: "\"7\""
        )
        let second = RelayConnectionState(
            connection: RelayConnection(
                channelID: UUID(),
                deviceID: UUID(),
                macName: "Travel MacBook"
            )
        )

        try await store.save([first, second])
        let restored = try await store.load()

        XCTAssertEqual(restored, [first, second])
    }

    func testRelayConnectionStoreMigratesOriginalSingleMacDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("relay-connection.json")
        let connection = RelayConnection(
            channelID: UUID(),
            deviceID: UUID(),
            macName: "Original Mac"
        )
        try JSONFileStorage.save(connection, to: fileURL)

        let restored = try await RelayConnectionStore(fileURL: fileURL).load()

        XCTAssertEqual(restored, [RelayConnectionState(connection: connection)])
    }

    func testSessionEventStoreRoundTripsNotificationHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionEventStore(
            fileURL: directory.appendingPathComponent("session-events.json")
        )
        let event = SessionEventRecord(
            eventID: "session-1:permission_needed:123",
            channelID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            macName: "Studio Mac",
            kind: .permissionNeeded,
            sessionTitle: "Publish the iOS build",
            workspaceName: "GPTUsage",
            occurredAt: Date(timeIntervalSince1970: 1_721_000_000)
        )

        try await store.save([event])
        let restored = try await store.load()

        XCTAssertEqual(restored, [event])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
