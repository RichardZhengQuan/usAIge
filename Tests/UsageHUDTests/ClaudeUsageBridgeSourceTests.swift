import Foundation
import Testing
@testable import UsageHUD

private let bridgeSourceNow = LocalToolDates.parse("2026-10-14T02:00:00Z")!
private let bridgeOrganization = "33333333-3333-4333-8333-333333333333"
private let otherBridgeOrganization = "44444444-4444-4444-8444-444444444444"
private func bridgeUsagePayload() -> [String: Any] {
    [
        "five_hour": ["utilization": 12, "resets_at": "2026-10-14T05:00:00Z"],
        "seven_day": ["utilization": 37, "resets_at": "2026-10-20T05:00:00Z"],
        "seven_day_opus": ["utilization": 23, "resets_at": "2026-10-20T05:00:00Z"],
    ]
}

private struct BridgeSourceFiles {
    let home: URL
    var directory: URL { home.appendingPathComponent("Library/Application Support/usAIge/claude-usage") }
    var response: URL { directory.appendingPathComponent("response.json") }
    var status: URL { directory.appendingPathComponent("status.json") }
    var history: URL { home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-bridge-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func writeResponse(
        observedAt: Date = bridgeSourceNow.addingTimeInterval(-10),
        organization: String = bridgeOrganization,
        usage: [String: Any] = bridgeUsagePayload(),
        schemaVersion: Int = 1
    ) throws {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "observedAt": ISO8601DateFormatter().string(from: observedAt),
            "organizationID": organization,
            "usage": usage,
        ]).write(to: response)
    }

    func writeStatus(state: String, checkedAt: Date, organization: String? = nil) throws {
        var value: [String: Any] = [
            "schemaVersion": 1, "checkedAt": ISO8601DateFormatter().string(from: checkedAt), "state": state,
        ]
        if let organization { value["organizationID"] = organization }
        try JSONSerialization.data(withJSONObject: value).write(to: status)
    }

    func writeHistory(_ samples: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["samples": samples]).write(to: history)
    }

    func source() -> ClaudeUsageBridgeSource {
        ClaudeUsageBridgeSource(homeDirectory: home, now: { bridgeSourceNow })
    }
}

private actor BridgeCredentialProbe: ClaudeCredentialSource {
    private(set) var reads = 0
    func load() async throws -> ClaudeCredentials? {
        reads += 1
        throw LocalToolUsageError.keychainAccessDenied
    }
}

private struct BridgeStaticSource: ClaudeAppUsageSource {
    let sample: ClaudeAppUsageSample?
    func latestSample() -> ClaudeAppUsageSample? { sample }
}

@Suite("ClaudeUsageBridgeSource")
struct ClaudeUsageBridgeSourceTests {
    @Test func freshBridgeNeedsNeitherClaudeHistoryNorCacheAndNeverReadsCredentialsOrRequestsUsage() async throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(organization: bridgeOrganization.uppercased())
        let bridge = files.source()
        let sample = try #require(bridge.latestSample())
        #expect(sample.origin == .bridge)
        #expect(sample.organizationID == bridgeOrganization)
        #expect(sample.sessionPercent == 12)
        #expect(sample.weeklyPercent == 37)
        #expect(sample.cachedUsage?.recordedAt == sample.recordedAt)
        #expect(!FileManager.default.fileExists(atPath: files.history.path))

        let desktop = ClaudeAppUsageHistory(homeDirectory: files.home, readCachedUsage: { _, _ in nil }, now: { bridgeSourceNow })
        let source = ClaudeAutomaticUsageSource(bridge: bridge, desktop: desktop)
        #expect(source.latestSample() == sample)
        try files.writeHistory([[
            "t": bridgeSourceNow.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000,
            "org": bridgeOrganization, "u": ["fh": 1, "sd": 2],
        ]])
        #expect(source.latestSample() == sample)

        let credentials = BridgeCredentialProbe()
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: source, usesAPIKeyHelper: { false }, now: { bridgeSourceNow }
        )
        let result = try await provider.refresh()
        #expect(result.snapshots.map(\.id) == ["claude", "claude_opus"])
        #expect(result.snapshots.first?.usedPercent == 12)
        #expect(result.snapshots.first?.secondaryWindow?.usedPercent == 37)
        #expect(result.snapshots.first?.resetAt == LocalToolDates.parse("2026-10-14T05:00:00Z"))
        #expect(result.snapshots.first?.updatedAt == sample.recordedAt)
        #expect(await provider.refreshLocalUsage() == result)
        #expect(await credentials.reads == 0)
        #expect(await http.requests.isEmpty)
        #expect(await registry.status(for: .claude) == .connectedThroughClaudeBridge)
    }

    @Test(arguments: [-1_801.0, 1.0])
    func rejectsExpiredOrFutureObservation(offset: TimeInterval) throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(observedAt: bridgeSourceNow.addingTimeInterval(offset))
        #expect(files.source().latestSample() == nil)
    }

    @Test func futureNativeHistoryCannotHideFreshBridgeUsageAfterClockRollback() async throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse()
        try files.writeHistory([[
            "t": bridgeSourceNow.addingTimeInterval(60).timeIntervalSince1970 * 1_000,
            "org": bridgeOrganization, "u": ["fh": 99, "sd": 98],
        ]])
        let bridge = files.source()
        let desktop = ClaudeAppUsageHistory(homeDirectory: files.home, readCachedUsage: { _, _ in nil }, now: { bridgeSourceNow })
        let source = ClaudeAutomaticUsageSource(bridge: bridge, desktop: desktop)
        let sample = try #require(source.latestSample())
        #expect(desktop.latestSample() == nil)
        #expect(sample.origin == .bridge)
        #expect(sample.recordedAt == bridgeSourceNow.addingTimeInterval(-10))

        let credentials = BridgeCredentialProbe()
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: source, usesAPIKeyHelper: { false }, now: { bridgeSourceNow }
        )
        let local = try #require(await provider.refreshLocalUsage())
        #expect(local.snapshots.map(\.id) == ["claude", "claude_opus"])
        #expect(local.snapshots.first?.usedPercent == 12)
        #expect(local.snapshots.first?.secondaryWindow?.usedPercent == 37)
        #expect(local.snapshots.first?.resetAt == LocalToolDates.parse("2026-10-14T05:00:00Z"))
        #expect(local.snapshots.first?.secondaryWindow?.resetAt == LocalToolDates.parse("2026-10-20T05:00:00Z"))
        #expect(try await provider.refresh() == local)
        #expect(await credentials.reads == 0)
        #expect(await http.requests.isEmpty)
        #expect(await registry.status(for: .claude) == .connectedThroughClaudeBridge)
    }

    @Test func rejectsPartialJSONAndAcceptsTheCompletedReportOnTheNextRead() throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try Data(#"{"schemaVersion":1,"observedAt":"2026-10-14"#.utf8).write(to: files.response)
        #expect(files.source().latestSample() == nil)
        try files.writeResponse()
        #expect(files.source().latestSample()?.sessionPercent == 12)
    }

    @Test func rejectsResponseSymlinkAndOversizedFile() throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse()
        let target = files.home.appendingPathComponent("valid-response.json")
        try FileManager.default.moveItem(at: files.response, to: target)
        try FileManager.default.createSymbolicLink(at: files.response, withDestinationURL: target)
        #expect(files.source().latestSample() == nil)
        try FileManager.default.removeItem(at: files.response)
        try Data(repeating: 32, count: ClaudeUsageBridgeSource.maximumBytes + 1).write(to: files.response)
        #expect(files.source().latestSample() == nil)
    }

    @Test func rejectsMalformedEnvelopeAndUsageRatherThanInventingLimits() throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(schemaVersion: 2)
        #expect(files.source().latestSample() == nil)
        try files.writeResponse(organization: "invalid-organization")
        #expect(files.source().latestSample() == nil)
        for usage in [
            [:],
            ["five_hour": ["utilization": -1, "resets_at": "2026-10-14T05:00:00Z"]],
            ["five_hour": ["utilization": 12, "resets_at": "invalid-date"]],
            ["five_hour": ["utilization": 12, "resets_at": "2026-10-14T01:59:59Z"]],
            ["limits": [["kind": "session", "percent": 12, "resets_at": "2026-10-14T01:59:59Z"]]],
        ] as [[String: Any]] {
            try files.writeResponse(usage: usage)
            #expect(files.source().latestSample() == nil)
        }
    }

    @Test func newerBoundStatusInvalidatesPreviousOrganizationEvenIfUsageRefreshFailed() throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(observedAt: bridgeSourceNow.addingTimeInterval(-20))
        try files.writeStatus(state: "error", checkedAt: bridgeSourceNow.addingTimeInterval(-10), organization: otherBridgeOrganization)
        #expect(files.source().latestSample() == nil)
        try files.writeStatus(state: "error", checkedAt: bridgeSourceNow.addingTimeInterval(-10), organization: bridgeOrganization)
        #expect(files.source().latestSample()?.sessionPercent == 12)
        try files.writeStatus(state: "unavailable", checkedAt: bridgeSourceNow.addingTimeInterval(-10))
        #expect(files.source().latestSample() == nil)
    }

    @Test(arguments: [-30.0, 1.0])
    func oldOrFutureStatusCannotOverrideTheFreshBoundResponse(statusOffset: TimeInterval) throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(observedAt: bridgeSourceNow.addingTimeInterval(-20))
        try files.writeStatus(state: "error", checkedAt: bridgeSourceNow.addingTimeInterval(statusOffset), organization: otherBridgeOrganization)
        #expect(files.source().latestSample()?.organizationID == bridgeOrganization)
    }

    @Test func emptyNativeHistoryObservationStillRejectsPreviousOrganization() throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(observedAt: bridgeSourceNow.addingTimeInterval(-20))
        try files.writeHistory([
            ["t": bridgeSourceNow.addingTimeInterval(-30).timeIntervalSince1970 * 1_000,
             "org": bridgeOrganization, "u": ["fh": 1, "sd": 2]],
            ["t": bridgeSourceNow.addingTimeInterval(-10).timeIntervalSince1970 * 1_000,
             "org": otherBridgeOrganization, "u": [:]],
        ])
        #expect(ClaudeAppUsageHistory.latestSample(from: try Data(contentsOf: files.history)) == nil)
        #expect(files.source().latestSample() == nil)
        try files.writeResponse(observedAt: bridgeSourceNow.addingTimeInterval(-5), organization: otherBridgeOrganization)
        #expect(files.source().latestSample()?.organizationID == otherBridgeOrganization)
    }

    @Test(arguments: [-60.0, 0.0, 60.0])
    func combinedSourceSelectsFreshestAndUsesBridgeWhenObservationTimesAgree(nativeOffset: TimeInterval) throws {
        let files = try BridgeSourceFiles()
        defer { files.remove() }
        try files.writeResponse(observedAt: bridgeSourceNow.addingTimeInterval(-120))
        let bridge = try #require(files.source().latestSample())
        let native = ClaudeAppUsageSample(recordedAt: bridge.recordedAt.addingTimeInterval(nativeOffset), sessionPercent: 7,
                                          weeklyPercent: 29, organizationID: bridgeOrganization)
        let source = ClaudeAutomaticUsageSource(bridge: BridgeStaticSource(sample: bridge), desktop: BridgeStaticSource(sample: native))
        #expect(source.latestSample() == (nativeOffset > 0 ? native : bridge))
        #expect(ClaudeAutomaticUsageSource(bridge: BridgeStaticSource(sample: nil), desktop: BridgeStaticSource(sample: native)).latestSample() == native)
        #expect(ClaudeAutomaticUsageSource(bridge: BridgeStaticSource(sample: bridge), desktop: BridgeStaticSource(sample: nil)).latestSample() == bridge)
    }
}
