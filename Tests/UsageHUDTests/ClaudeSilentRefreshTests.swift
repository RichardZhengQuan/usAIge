import Foundation
import Testing
@testable import UsageHUD

@Suite("Claude silent usage refresh")
struct ClaudeSilentRefreshTests {
    @Test func automaticTicksAcceptNewHistoryAndBridgeReportsWhileNormalRefreshIsThrottled() async throws {
        let files = try SilentClaudeFiles()
        defer { files.remove() }
        let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        try files.writeHistory(at: clock.now.addingTimeInterval(-30), session: 10, weekly: 40)
        try files.writeBridge(at: clock.now.addingTimeInterval(-60), session: 20, weekly: 50)
        let pipeline = await files.pipeline(clock: clock)

        let initial = try await pipeline.provider.refresh()
        #expect(initial.snapshots.first?.usedPercent == 10)
        #expect(initial.snapshots.first?.resetAt == nil)
        #expect(await pipeline.status.status(for: .claude) == .connectedThroughClaudeApp)

        clock.now.addTimeInterval(5)
        try files.writeBridge(at: clock.now, session: 30, weekly: 60)
        let fromBridge = try await pipeline.provider.refreshAutomatically()
        #expect(fromBridge.snapshots.first?.usedPercent == 30)
        #expect(fromBridge.snapshots.first?.secondaryWindow?.usedPercent == 60)
        #expect(fromBridge.snapshots.first?.updatedAt == clock.now)
        #expect(fromBridge.snapshots.first?.resetAt == clock.now.addingTimeInterval(10_800))
        #expect(await pipeline.status.status(for: .claude) == .connectedThroughClaudeBridge)

        clock.now.addTimeInterval(5)
        try files.writeHistory(at: clock.now, session: 40, weekly: 70)
        let fromHistory = try await pipeline.provider.refreshAutomatically()
        #expect(fromHistory.snapshots.first?.usedPercent == 40)
        #expect(fromHistory.snapshots.first?.secondaryWindow?.usedPercent == 70)
        #expect(fromHistory.snapshots.first?.updatedAt == clock.now)
        #expect(fromHistory.snapshots.first?.resetAt == nil)
        #expect(await pipeline.status.status(for: .claude) == .connectedThroughClaudeApp)

        // Equal observation times prefer the bridge's exact server reset times.
        try files.writeBridge(at: clock.now, session: 40, weekly: 70)
        clock.now.addTimeInterval(5)
        let sameTimeBridge = try await pipeline.provider.refreshAutomatically()
        #expect(sameTimeBridge.snapshots.first?.usedPercent == 40)
        #expect(sameTimeBridge.snapshots.first?.resetAt == clock.now.addingTimeInterval(10_795))
        #expect(await pipeline.status.status(for: .claude) == .connectedThroughClaudeBridge)

        // The minute tick polls the other providers again, but Claude's normal
        // five-minute gate must neither hide nor roll back the new local value.
        clock.now.addTimeInterval(45)
        try files.writeHistory(at: clock.now, session: 45, weekly: 75)
        let minuteTick = try await pipeline.provider.refreshAutomatically()
        #expect(minuteTick.snapshots.first?.usedPercent == 45)
        #expect(minuteTick.snapshots.first?.updatedAt == clock.now)
        #expect(await pipeline.claude.refreshCount == 1)
        #expect(await pipeline.claude.localRefreshCount == 4)
        #expect(await pipeline.remote.refreshCount == 2)
        #expect(await pipeline.http.requests.isEmpty)
        await pipeline.provider.stop()
    }

    @Test func staleValuesDisappearAndNewBridgeReportRecoversDuringTheSameRefreshGate() async throws {
        let files = try SilentClaudeFiles()
        defer { files.remove() }
        let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let almostExpired = clock.now.addingTimeInterval(-ClaudeUsageProvider.claudeAppMaximumAge + 10)
        try files.writeHistory(at: almostExpired, session: 80, weekly: 90)
        try files.writeBridge(at: almostExpired, session: 80, weekly: 90)
        let pipeline = await files.pipeline(clock: clock)

        #expect(try await pipeline.provider.refresh().snapshots.first?.usedPercent == 80)
        clock.now.addTimeInterval(15)
        #expect(try await pipeline.provider.refreshAutomatically() == .authenticated([]))
        #expect(await pipeline.status.status(for: .claude) == .waitingForClaudeUsage)

        clock.now.addTimeInterval(5)
        try files.writeBridge(at: clock.now, session: 2, weekly: 91)
        let recovered = try await pipeline.provider.refreshAutomatically()
        #expect(recovered.snapshots.first?.usedPercent == 2)
        #expect(recovered.snapshots.first?.secondaryWindow?.usedPercent == 91)
        #expect(recovered.snapshots.first?.updatedAt == clock.now)
        #expect(await pipeline.status.status(for: .claude) == .connectedThroughClaudeBridge)

        clock.now.addTimeInterval(40)
        #expect(try await pipeline.provider.refreshAutomatically() == recovered)
        #expect(await pipeline.claude.refreshCount == 1)
        #expect(await pipeline.claude.localRefreshCount == 3)
        #expect(await pipeline.http.requests.isEmpty)
        await pipeline.provider.stop()
    }

    @Test func waitingForFirstReadingStillAcceptsHistoryOnTheNextAutomaticTick() async throws {
        let files = try SilentClaudeFiles()
        defer { files.remove() }
        let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let pipeline = await files.pipeline(clock: clock)

        #expect(try await pipeline.provider.refresh() == .authenticated([]))
        #expect(await pipeline.status.status(for: .claude) == .waitingForClaudeUsage)
        clock.now.addTimeInterval(5)
        try files.writeHistory(at: clock.now, session: 12, weekly: 34)
        let detected = try await pipeline.provider.refreshAutomatically()
        #expect(detected.snapshots.first?.usedPercent == 12)
        #expect(detected.snapshots.first?.secondaryWindow?.usedPercent == 34)
        #expect(await pipeline.claude.refreshCount == 1)
        #expect(await pipeline.status.status(for: .claude) == .connectedThroughClaudeApp)
        #expect(await pipeline.http.requests.isEmpty)
        await pipeline.provider.stop()
    }
}

private struct SilentClaudeFiles {
    private let home: URL
    private let organization = "33333333-3333-4333-8333-333333333333"
    private var history: URL { home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json") }
    private var response: URL { home.appendingPathComponent("Library/Application Support/usAIge/claude-usage/response.json") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-silent-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: response.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func writeHistory(at date: Date, session: Double, weekly: Double) throws {
        try JSONSerialization.data(withJSONObject: ["samples": [[
            "t": date.timeIntervalSince1970 * 1_000, "org": organization,
            "u": ["fh": session, "sd": weekly],
        ]]]).write(to: history, options: .atomic)
    }

    func writeBridge(at date: Date, session: Double, weekly: Double) throws {
        let formatter = ISO8601DateFormatter()
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "observedAt": formatter.string(from: date), "organizationID": organization,
            "usage": [
                "five_hour": ["utilization": session, "resets_at": formatter.string(from: date.addingTimeInterval(10_800))],
                "seven_day": ["utilization": weekly, "resets_at": formatter.string(from: date.addingTimeInterval(604_800))],
            ],
        ]).write(to: response, options: .atomic)
    }

    func pipeline(clock: TestClockBox) async -> SilentClaudePipeline {
        let status = await LocalToolStatusRegistry()
        let http = ScriptedUsageHTTPClient(responses: [:])
        let source = ClaudeAutomaticUsageSource(
            bridge: ClaudeUsageBridgeSource(homeDirectory: home, now: { clock.now }),
            desktop: ClaudeAppUsageHistory(homeDirectory: home, readCachedUsage: { _, _ in nil }, now: { clock.now })
        )
        // Keep the app's default credential policy, and fail any attempted HTTP
        // request instead of depending on a sign-in or an installed Claude app.
        let claude = SilentClaudeRefreshProbe(base: ClaudeUsageProvider(
            http: http, statusRegistry: status, userAgentVersion: { "offline-fixture" },
            claudeApp: source, usesAPIKeyHelper: { false }, now: { clock.now }
        ))
        let throttled = ThrottledUsageProvider(base: claude, minimumInterval: 300, now: { clock.now })
        let remote = ScriptedUsageProvider(result: .signedOut)
        let provider = CompositeUsageProvider(
            local: ScriptedUsageProvider(result: .signedOut), throttled: [throttled],
            remote: remote, remoteRefreshInterval: 60, now: { clock.now }
        )
        return SilentClaudePipeline(provider: provider, claude: claude, remote: remote, http: http, status: status)
    }
}

private struct SilentClaudePipeline {
    let provider: CompositeUsageProvider
    let claude: SilentClaudeRefreshProbe
    let remote: ScriptedUsageProvider
    let http: ScriptedUsageHTTPClient
    let status: LocalToolStatusRegistry
}

private actor SilentClaudeRefreshProbe: LocalUsageProviding {
    private let base: ClaudeUsageProvider
    private(set) var refreshCount = 0
    private(set) var localRefreshCount = 0

    init(base: ClaudeUsageProvider) { self.base = base }

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        return try await base.refresh()
    }

    func refreshLocalUsage() async -> AccountUsageResult? {
        localRefreshCount += 1
        return await base.refreshLocalUsage()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> { await base.updates() }
    func stop() async { await base.stop() }
}
