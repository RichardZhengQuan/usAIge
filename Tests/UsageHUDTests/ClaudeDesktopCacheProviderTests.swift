import Foundation
import Testing
@testable import UsageHUD

private let cacheProviderNow = LocalToolDates.parse("2026-10-12T14:30:00Z")!
private let cacheProviderOrganization = "33333333-3333-4333-8333-333333333333"
private let cacheProviderPayload = JSONValue.parse(Data(#"{"five_hour":{"utilization":4,"resets_at":"2026-10-12T17:00:00.211351Z"},"seven_day":{"utilization":97,"resets_at":"2026-10-13T05:00:00.211371Z"},"seven_day_opus":{"utilization":38,"resets_at":"2026-10-14T05:00:00Z"},"limits":[],"extra_usage":{"is_enabled":false}}"#.utf8))!

private actor CacheProviderCredentialProbe: ClaudeCredentialSource {
    private(set) var loads = 0
    let credential: ClaudeCredentials?
    let error: LocalToolUsageError?

    init(credential: ClaudeCredentials? = nil, error: LocalToolUsageError? = nil) {
        self.credential = credential
        self.error = error
    }

    func load() async throws -> ClaudeCredentials? {
        loads += 1
        if let error { throw error }
        return credential
    }
}

private final class CacheProviderSampleSource: ClaudeAppUsageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var sample: ClaudeAppUsageSample?

    init(_ sample: ClaudeAppUsageSample?) { self.sample = sample }
    func latestSample() -> ClaudeAppUsageSample? {
        lock.lock()
        defer { lock.unlock() }
        return sample
    }
    func replace(with sample: ClaudeAppUsageSample?) {
        lock.lock()
        defer { lock.unlock() }
        self.sample = sample
    }
}

private func providerCacheSample(
    payload: JSONValue = cacheProviderPayload,
    cacheDate: Date = cacheProviderNow.addingTimeInterval(-10)
) -> ClaudeAppUsageSample {
    ClaudeAppUsageSample(
        recordedAt: cacheProviderNow.addingTimeInterval(-5),
        sessionPercent: 4,
        weeklyPercent: 97,
        organizationID: cacheProviderOrganization,
        cachedUsage: ClaudeDesktopCachedUsage(payload: payload, recordedAt: cacheDate)
    )
}

@Suite("ClaudeDesktopCacheProvider")
struct ClaudeDesktopCacheProviderTests {
    @Test func automaticLocalReadTracksChangesWithoutCredentialsOrRequests() async throws {
        let credentials = CacheProviderCredentialProbe(error: .keychainAccessDenied)
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let source = CacheProviderSampleSource(nil)
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: source, usesAPIKeyHelper: { true }, now: { cacheProviderNow }
        )
        #expect(await provider.refreshLocalUsage() == .authenticated([]))
        source.replace(with: providerCacheSample())
        #expect(await provider.refreshLocalUsage()?.snapshots.first?.usedPercent == 4)
        let changed = try #require(JSONValue.parse(Data(#"{"five_hour":{"utilization":19,"resets_at":"2026-10-12T17:00:00Z"},"seven_day":{"utilization":98,"resets_at":"2026-10-13T05:00:00Z"}}"#.utf8)))
        source.replace(with: providerCacheSample(payload: changed))
        let refreshed = try #require(await provider.refreshLocalUsage())
        #expect(refreshed.snapshots.first?.usedPercent == 19)
        #expect(refreshed.snapshots.first?.secondaryWindow?.usedPercent == 98)
        #expect(refreshed.snapshots.first?.resetAt != nil)
        #expect(await credentials.loads == 0)
        #expect(await http.requests.isEmpty)
        #expect(await registry.status(for: .claude) == .connectedThroughClaudeAppCache)
    }

    @Test func automaticLocalReadDropsExpiredUsageWithoutReadingCredentials() async throws {
        let credentials = CacheProviderCredentialProbe(error: .keychainAccessDenied)
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let clock = TestClockBox(cacheProviderNow)
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: CacheProviderSampleSource(providerCacheSample()),
            now: { clock.now }
        )
        #expect(await provider.refreshLocalUsage()?.snapshots.isEmpty == false)
        clock.now.addTimeInterval(ClaudeUsageProvider.claudeAppMaximumAge + 1)
        #expect(await provider.refreshLocalUsage() == .authenticated([]))
        #expect(await registry.status(for: .claude) == .waitingForClaudeUsage)
        #expect(await credentials.loads == 0)
        #expect(await http.requests.isEmpty)
    }

    @Test func automaticLocalReadDropsPreviousOrganizationAfterAnEmptySwitch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-local-switch-\(UUID())")
        let directory = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = directory.appendingPathComponent("plan-usage-history.json")
        let observed = cacheProviderNow.addingTimeInterval(-10).timeIntervalSince1970 * 1_000
        let original = #"{"samples":[{"t":\#(observed),"org":"\#(cacheProviderOrganization)","u":{"fh":4,"sd":97}}]}"#
        try Data(original.utf8).write(to: history)
        let source = ClaudeAppUsageHistory(
            homeDirectory: home,
            readCachedUsage: { id, _ in
                id == cacheProviderOrganization
                    ? ClaudeDesktopCachedUsage(payload: cacheProviderPayload, recordedAt: cacheProviderNow.addingTimeInterval(-5))
                    : nil
            },
            now: { cacheProviderNow }
        )
        let credentials = CacheProviderCredentialProbe(error: .keychainAccessDenied)
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let provider = ClaudeUsageProvider(credentials: credentials, http: http, statusRegistry: registry,
                                          claudeApp: source, now: { cacheProviderNow })
        #expect(await provider.refreshLocalUsage()?.snapshots.isEmpty == false)
        let switched = original.replacingOccurrences(of: "]}", with: #",{"t":\#(cacheProviderNow.timeIntervalSince1970 * 1_000),"org":"44444444-4444-4444-8444-444444444444","u":{}}]}"#)
        try Data(switched.utf8).write(to: history)
        #expect(await provider.refreshLocalUsage() == .authenticated([]))
        #expect(await registry.status(for: .claude) == .waitingForClaudeUsage)
        #expect(await credentials.loads == 0)
        #expect(await http.requests.isEmpty)
    }

    @Test func recentCacheProvidesExactResetsWithoutCredentialReadsOrHTTP() async throws {
        let credentials = CacheProviderCredentialProbe(error: .keychainAccessDenied)
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let observation = cacheProviderNow.addingTimeInterval(-10)
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: CacheProviderSampleSource(providerCacheSample(cacheDate: observation)),
            usesAPIKeyHelper: { true }, now: { cacheProviderNow }
        )
        let result = try await provider.refresh()
        let main = try #require(result.snapshots.first)
        #expect(main.usedPercent == 4)
        #expect(main.secondaryWindow?.usedPercent == 97)
        #expect(main.resetAt == LocalToolDates.parse("2026-10-12T17:00:00.211351Z"))
        #expect(main.secondaryWindow?.resetAt == LocalToolDates.parse("2026-10-13T05:00:00.211371Z"))
        #expect(main.updatedAt == observation)
        #expect(result.snapshots.map(\.id) == ["claude", "claude_opus"])
        #expect(result.snapshots.allSatisfy { $0.toolID == .claude })
        #expect(await credentials.loads == 0)
        #expect(await http.requests.isEmpty)
        #expect(await registry.status(for: .claude) == .connectedThroughClaudeAppCache)
    }

    @Test(arguments: [-1_801.0, 1.0])
    func staleAndFutureCacheDoNotAttachResetTimesToRecentHistory(offset: TimeInterval) async throws {
        let credentials = CacheProviderCredentialProbe()
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: CacheProviderSampleSource(providerCacheSample(cacheDate: cacheProviderNow.addingTimeInterval(offset))),
            usesAPIKeyHelper: { false }, now: { cacheProviderNow }
        )
        let snapshots = try await provider.refresh().snapshots
        #expect(snapshots.map(\.id) == ["claude"])
        #expect(snapshots.first?.usedPercent == 4)
        #expect(snapshots.first?.secondaryWindow?.usedPercent == 97)
        #expect(snapshots.first?.resetAt == nil)
        #expect(snapshots.first?.secondaryWindow?.resetAt == nil)
        #expect(await credentials.loads == 1)
        #expect(await http.requests.isEmpty)
        #expect(await registry.status(for: .claude) == .connectedThroughClaudeApp)
    }

    @Test func expiredAuthoritativeLimitsDoNotReviveLegacyCacheWindows() async throws {
        let payload = try #require(JSONValue.parse(Data(#"{"five_hour":{"utilization":4,"resets_at":"2026-10-12T17:00:00Z"},"limits":[{"kind":"session","group":"session","percent":4,"resets_at":"2026-10-12T14:00:00Z"}]}"#.utf8)))
        let credentials = CacheProviderCredentialProbe()
        let http = ScriptedUsageHTTPClient(responses: [:])
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http,
            claudeApp: CacheProviderSampleSource(providerCacheSample(payload: payload)),
            usesAPIKeyHelper: { false }, now: { cacheProviderNow }
        )
        let snapshots = try await provider.refresh().snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.resetAt == nil)
        #expect(await credentials.loads == 1)
        #expect(await http.requests.isEmpty)
    }

    @Test func modernCacheKeepsModelAndSurfaceScopedLimits() async throws {
        let payload = try #require(JSONValue.parse(Data(#"{"limits":[{"kind":"session","group":"session","percent":4,"resets_at":"2026-10-12T17:00:00Z"},{"kind":"weekly_all","group":"weekly","percent":97,"resets_at":"2026-10-13T05:00:00Z"},{"kind":"weekly_scoped","group":"weekly","percent":18,"resets_at":"2026-10-14T05:00:00Z","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","group":"weekly","percent":23,"resets_at":"2026-10-14T05:00:00Z","scope":{"surface":{"display_name":"Cowork"}}}]}"#.utf8)))
        let credentials = CacheProviderCredentialProbe(error: .keychainAccessDenied)
        let http = ScriptedUsageHTTPClient(responses: [:])
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http,
            claudeApp: CacheProviderSampleSource(providerCacheSample(payload: payload)),
            usesAPIKeyHelper: { false }, now: { cacheProviderNow }
        )
        let snapshots = try await provider.refresh().snapshots
        #expect(snapshots.map(\.id) == ["claude", "claude_fable", "claude_cowork"])
        #expect(snapshots.map(\.displayName) == ["All models", "Fable", "Cowork"])
        #expect(snapshots[1].usedPercent == 18)
        #expect(snapshots[2].usedPercent == 23)
        #expect(snapshots[1].typeTag == "7D" && snapshots[2].typeTag == "7D")
        #expect(snapshots.allSatisfy { $0.resetAt != nil })
        #expect(await credentials.loads == 0)
        #expect(await http.requests.isEmpty)
    }

    @Test func cachedResponseWorksDuringAnExistingOAuthRateLimitPause() async throws {
        let credential = ClaudeCredentials(
            accessToken: "offline-fixture", expiresAt: cacheProviderNow.addingTimeInterval(3_600),
            scopes: ["user:profile"], subscriptionType: nil, rateLimitTier: nil
        )
        let credentials = CacheProviderCredentialProbe(credential: credential)
        let http = ScriptedUsageHTTPClient(responses: [ClaudeUsageProvider.usageURL.absoluteString: .init(status: 429)])
        var history = providerCacheSample()
        history.cachedUsage = nil
        let source = CacheProviderSampleSource(history)
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, claudeApp: source,
            usesAPIKeyHelper: { false }, now: { cacheProviderNow }
        )
        #expect(try await provider.refresh().snapshots.first?.resetAt == nil)
        #expect(await credentials.loads == 1)
        #expect(await http.requests.count == 1)
        source.replace(with: providerCacheSample())
        #expect(try await provider.refresh().snapshots.first?.resetAt != nil)
        #expect(await credentials.loads == 1)
        #expect(await http.requests.count == 1)
    }

    @Test(arguments: [4.0, 12.0])
    func laterHistoryMustAgreeBeforeUsingAnOlderCachedReset(sessionPercent: Double) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-cache-provider-\(UUID().uuidString)")
        let directory = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history: [String: Any] = ["version": 2, "samples": [[
            "t": cacheProviderNow.addingTimeInterval(-5).timeIntervalSince1970 * 1_000,
            "org": cacheProviderOrganization,
            "u": ["fh": sessionPercent, "sd": 97],
        ]]]
        try JSONSerialization.data(withJSONObject: history).write(to: directory.appendingPathComponent("plan-usage-history.json"))
        let source = ClaudeAppUsageHistory(
            homeDirectory: home,
            readCachedUsage: { _, _ in ClaudeDesktopCachedUsage(payload: cacheProviderPayload, recordedAt: cacheProviderNow.addingTimeInterval(-10)) },
            now: { cacheProviderNow }
        )
        let credentials = CacheProviderCredentialProbe()
        let http = ScriptedUsageHTTPClient(responses: [:])
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, claudeApp: source,
            usesAPIKeyHelper: { false }, now: { cacheProviderNow }
        )
        let snapshots = try await provider.refresh().snapshots
        #expect(snapshots.first?.usedPercent == sessionPercent)
        #expect((snapshots.first?.resetAt != nil) == (sessionPercent == 4))
        #expect(await credentials.loads == (sessionPercent == 4 ? 0 : 1))
        #expect(await http.requests.isEmpty)
    }
}

// This opt-in test reads only existing usage history/cache files. Both possible
// authentication/network dependencies are explicit offline probes, so even a
// failed smoke test cannot contact Anthropic or read a real credential.
@Suite("ClaudeLocalCacheLive", .enabled(if: ProcessInfo.processInfo.environment["USAIGE_LIVE_CLAUDE_CACHE"] == "1"))
struct ClaudeLocalCacheLiveTests {
    @Test func existingDesktopCacheSuppliesRealResetTimestampsSilently() async throws {
        let date = Date()
        let source = ClaudeAppUsageHistory(now: { date })
        let reading = try #require(source.latestSample())
        _ = try #require(reading.cachedUsage)
        let credentials = CacheProviderCredentialProbe(error: .notSignedIn)
        let http = ScriptedUsageHTTPClient(responses: [:])
        let registry = await LocalToolStatusRegistry()
        let provider = ClaudeUsageProvider(
            credentials: credentials, http: http, statusRegistry: registry,
            claudeApp: source, usesAPIKeyHelper: { false }, now: { date }
        )
        let result = try await provider.refresh()
        #expect(!result.snapshots.isEmpty)
        #expect(result.snapshots.contains { $0.resetAt != nil || $0.secondaryWindow?.resetAt != nil })
        #expect(await credentials.loads == 0)
        #expect(await http.requests.isEmpty)
        #expect(await registry.status(for: .claude) == .connectedThroughClaudeAppCache)
        for snapshot in result.snapshots {
            print("[local-cache] \(snapshot.id): \(snapshot.usedPercent)% used; reset \(snapshot.resetAt.map { $0.description } ?? "unknown")")
            if let secondary = snapshot.secondaryWindow {
                print("[local-cache] \(snapshot.id) secondary: \(secondary.usedPercent)% used; reset \(secondary.resetAt.map { $0.description } ?? "unknown")")
            }
        }
    }
}
