import Foundation
import XCTest
@testable import usAIge_iOS

@MainActor
final class AppModelTransactionTests: XCTestCase {
    func testEditRotatesConnectionIdentityTokenAndCachedSnapshots() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let oldTool = RemoteToolConfiguration(
            name: "Old Tool",
            endpointURL: URL(string: "https://old.example.com/limits")!
        )
        try await harness.store.save([oldTool])
        try harness.vault.save("old-token", for: oldTool.id)

        let model = harness.makeModel()
        await model.start()
        let newID = try await model.testAndUpdateTool(
            toolID: oldTool.id,
            name: "New Tool",
            endpointURL: URL(string: "https://new.example.com/limits")!,
            replacementBearerToken: "new-token",
            removeSavedToken: false,
            refreshIntervalMinutes: 30
        )

        XCTAssertNotEqual(newID, oldTool.id)
        XCTAssertEqual(model.tools.map(\.id), [newID])
        XCTAssertEqual(model.snapshots.map(\.toolID), [newID])
        XCTAssertNil(try harness.vault.token(for: oldTool.id))
        XCTAssertEqual(try harness.vault.token(for: newID), "new-token")
        let persistedIDs = try await harness.store.load().map(\.id)
        XCTAssertEqual(persistedIDs, [newID])
    }

    func testStartupReconcilesOrphanedKeychainTokens() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let orphanedID = UUID()
        try harness.vault.save("orphaned-token", for: orphanedID)

        let model = harness.makeModel()
        await model.start()

        XCTAssertNil(try harness.vault.token(for: orphanedID))
        XCTAssertFalse(try harness.vault.storedToolIDs().contains(orphanedID))
    }

    func testEnabledStateIsDurableWhenMutationReturns() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let tool = RemoteToolConfiguration(
            name: "Remote Tool",
            endpointURL: URL(string: "https://example.com/limits")!,
            isEnabled: false
        )
        try await harness.store.save([tool])

        let model = harness.makeModel()
        await model.start()
        let didEnable = await model.setToolEnabled(toolID: tool.id, isEnabled: true)
        let persistedEnabledState = try await harness.store.load().first?.isEnabled

        XCTAssertTrue(didEnable)
        XCTAssertEqual(persistedEnabledState, true)
        XCTAssertEqual(model.tools.first?.isEnabled, true)
        XCTAssertEqual(model.snapshots.first?.toolID, tool.id)
    }

    func testFreshnessChecksEachEnabledToolsOwnMetadata() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let currentTool = RemoteToolConfiguration(
            name: "Current",
            endpointURL: URL(string: "https://current.example.com/limits")!
        )
        let failedTool = RemoteToolConfiguration(
            name: "Failed",
            endpointURL: URL(string: "https://failed.example.com/limits")!
        )
        let now = Date()
        let currentSnapshot = snapshot(for: currentTool, updatedAt: now)
        let failedSnapshot = snapshot(for: failedTool, updatedAt: now)
        let model = harness.makeModel()
        model.tools = [currentTool, failedTool]
        model.snapshots = [currentSnapshot, failedSnapshot]
        model.refreshMetadata = [
            RefreshScheduleMetadata(toolID: currentTool.id)
                .recordingSuccess(at: now, refreshIntervalMinutes: 15),
            RefreshScheduleMetadata(toolID: failedTool.id)
                .recordingSuccess(at: now, refreshIntervalMinutes: 15)
                .recordingFailure(at: now, retryDelay: 300),
        ]

        XCTAssertTrue(model.isCacheStale)
    }

    func testOverlappingRefreshesShareTheInFlightRequest() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let tool = RemoteToolConfiguration(
            name: "Remote Tool",
            endpointURL: URL(string: "https://example.com/limits")!
        )
        try await harness.store.save([tool])
        let model = harness.makeModel()
        await model.start()
        AppModelStubURLProtocol.resetProbe(responseDelay: 0.15)

        let first = Task { @MainActor in await model.refreshAll() }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { @MainActor in await model.refreshAll() }
        await first.value
        await second.value

        XCTAssertEqual(AppModelStubURLProtocol.requestCount, 1)
    }

    func testReenabledToolQueuesNewRevisionBehindOldInFlightRequest() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let tool = RemoteToolConfiguration(
            name: "Remote Tool",
            endpointURL: URL(string: "https://example.com/limits")!
        )
        try await harness.store.save([tool])
        let model = harness.makeModel()
        await model.start()
        AppModelStubURLProtocol.resetProbe(responseDelay: 0.15)

        let oldRevisionRefresh = Task { @MainActor in await model.refreshAll() }
        try await Task.sleep(for: .milliseconds(20))
        let didDisable = await model.setToolEnabled(toolID: tool.id, isEnabled: false)
        let didReenable = await model.setToolEnabled(toolID: tool.id, isEnabled: true)
        await oldRevisionRefresh.value

        XCTAssertTrue(didDisable)
        XCTAssertTrue(didReenable)
        XCTAssertEqual(AppModelStubURLProtocol.requestCount, 2)
        XCTAssertEqual(model.snapshots.first?.toolID, tool.id)
        XCTAssertNil(model.errorsByToolID[tool.id])
    }

    private func makeHarness() async throws -> AppModelHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return AppModelHarness(directory: directory)
    }

    private func snapshot(
        for tool: RemoteToolConfiguration,
        updatedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: QuotaSnapshot.stableID(toolID: tool.id, limitID: "messages"),
            limitID: "messages",
            toolID: tool.id,
            toolName: tool.name,
            displayName: "Messages",
            remainingPercent: 75,
            resetAt: updatedAt.addingTimeInterval(3_600),
            updatedAt: updatedAt,
            windowDurationMinutes: 300
        )
    }
}

private struct AppModelHarness {
    let directory: URL
    let store: ToolConfigurationStore
    let cache: SharedQuotaCache
    let vault: KeychainTokenVault
    let client: RemoteUsageClient

    init(directory: URL) {
        self.directory = directory
        store = ToolConfigurationStore(
            fileURL: directory.appendingPathComponent("tools.json")
        )
        cache = SharedQuotaCache(
            appGroupIdentifier: "invalid.test.group.\(UUID().uuidString)",
            fallbackDirectoryURL: directory
        )
        vault = KeychainTokenVault(
            service: "com.richardq.usaige.tests.\(UUID().uuidString)"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppModelStubURLProtocol.self]
        client = RemoteUsageClient(session: URLSession(configuration: configuration))
    }

    @MainActor
    func makeModel() -> AppModel {
        AppModel(
            toolStore: store,
            quotaCache: cache,
            tokenVault: vault,
            usageClient: client
        )
    }

    func cleanup() {
        if let toolIDs = try? vault.storedToolIDs() {
            for toolID in toolIDs {
                try? vault.deleteToken(for: toolID)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class AppModelStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let probe = RequestProbe()

    static var requestCount: Int { probe.requestCount }

    static func resetProbe(responseDelay: TimeInterval) {
        probe.reset(responseDelay: responseDelay)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseDelay = Self.probe.recordRequest()
        if responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + responseDelay) { [self] in
                sendResponse()
            }
        } else {
            sendResponse()
        }
    }

    private func sendResponse() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"limits":[{"id":"messages","usedPercent":25,"windowMinutes":300}]}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var responseDelay: TimeInterval = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset(responseDelay: TimeInterval) {
        lock.lock()
        count = 0
        self.responseDelay = responseDelay
        lock.unlock()
    }

    func recordRequest() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return responseDelay
    }
}
