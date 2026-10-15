import Foundation
import Testing
@testable import UsageHUD

@Test func compositeRetainsFailedSourceCacheWhenAnotherSourceSucceeds() async throws {
    let remote = Fixtures.codexSnapshot.withRemoteIdentity()
    let localProvider = SequencedUsageProvider(results: [
        .success(.authenticated([Fixtures.codexSnapshot])),
        .success(.authenticated([Fixtures.codexSnapshot])),
    ])
    let remoteProvider = SequencedUsageProvider(results: [
        .success(.authenticated([remote])),
        .failure(RemoteUsageError.requestTimedOut),
    ])
    let provider = CompositeUsageProvider(local: localProvider, remote: remoteProvider)

    let first = try await provider.refresh()
    let second = try await provider.refresh()

    #expect(first.snapshots.count == 2)
    #expect(second.snapshots.count == 2)
}

@Test func compositeDropsRemoteCacheWhenAllRemoteSourcesAreRemoved() async throws {
    let remote = Fixtures.codexSnapshot.withRemoteIdentity()
    let localProvider = SequencedUsageProvider(results: [
        .success(.authenticated([Fixtures.codexSnapshot])),
        .success(.authenticated([Fixtures.codexSnapshot])),
    ])
    let remoteProvider = SequencedUsageProvider(results: [
        .success(.authenticated([remote])),
        .failure(RemoteUsageError.noSources),
    ])
    let provider = CompositeUsageProvider(local: localProvider, remote: remoteProvider)

    _ = try await provider.refresh()
    let second = try await provider.refresh()

    #expect(second.snapshots == [Fixtures.codexSnapshot])
}

@Test func remoteAuthenticatedEmptyOverridesLocalSignedOutState() async throws {
    let local = SequencedUsageProvider(results: [.success(.signedOut)])
    let remote = SequencedUsageProvider(results: [.success(.authenticated([]))])
    let provider = CompositeUsageProvider(local: local, remote: remote)

    let result = try await provider.refresh()

    #expect(result == .authenticated([]))
}

@Test func automaticRefreshKeepsRemoteRequestsOnMinuteCadence() async throws {
    let clock = CompositeTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let remoteSnapshot = Fixtures.codexSnapshot.withRemoteIdentity()
    let local = CompositeCountingProvider(result: .authenticated([Fixtures.codexSnapshot]))
    let remote = CompositeCountingProvider(result: .authenticated([remoteSnapshot]))
    let provider = CompositeUsageProvider(
        local: local,
        remote: remote,
        remoteRefreshInterval: 60,
        now: { clock.now }
    )

    _ = try await provider.refresh()
    clock.now.addTimeInterval(5)
    let cachedRemoteResult = try await provider.refreshAutomatically()

    #expect(await local.refreshCount == 2)
    #expect(await remote.refreshCount == 1)
    #expect(cachedRemoteResult.snapshots.count == 2)

    clock.now.addTimeInterval(55)
    _ = try await provider.refreshAutomatically()

    #expect(await local.refreshCount == 3)
    #expect(await remote.refreshCount == 2)
}

@Test func throttledSourcesMergeAndKeepTheirCacheOnFailure() async throws {
    let claude = Fixtures.codexSnapshot.withToolIdentity(.claude, id: "claude")
    let cursor = Fixtures.codexSnapshot.withToolIdentity(.cursor, id: "cursor")
    let localProvider = SequencedUsageProvider(results: [
        .success(.authenticated([Fixtures.codexSnapshot])),
        .success(.authenticated([Fixtures.codexSnapshot])),
    ])
    let claudeProvider = SequencedUsageProvider(results: [
        .success(.authenticated([claude])),
        .failure(LocalToolUsageError.rateLimited),
    ])
    let cursorProvider = SequencedUsageProvider(results: [
        .success(.signedOut),
        .success(.authenticated([cursor])),
    ])
    let remoteProvider = SequencedUsageProvider(results: [
        .failure(RemoteUsageError.noSources),
        .failure(RemoteUsageError.noSources),
    ])
    let provider = CompositeUsageProvider(
        local: localProvider,
        throttled: [claudeProvider, cursorProvider],
        remote: remoteProvider
    )

    let first = try await provider.refresh()
    #expect(first.snapshots.map(\.id) == ["codex", "claude"])

    let second = try await provider.refresh()
    #expect(second.snapshots.map(\.id) == ["codex", "claude", "cursor"])
}

@Test func everySourceSignedOutReportsSignedOut() async throws {
    let local = SequencedUsageProvider(results: [.success(.signedOut)])
    let claude = SequencedUsageProvider(results: [.success(.signedOut)])
    let remote = SequencedUsageProvider(results: [.failure(RemoteUsageError.noSources)])
    let provider = CompositeUsageProvider(local: local, throttled: [claude], remote: remote)

    #expect(try await provider.refresh() == .signedOut)
}

@Test func throttledSourceCarriesTheRailWhenCodexIsMissing() async throws {
    let claude = Fixtures.codexSnapshot.withToolIdentity(.claude, id: "claude")
    let local = SequencedUsageProvider(results: [.failure(LocalToolTestError.offline)])
    let claudeProvider = SequencedUsageProvider(results: [.success(.authenticated([claude]))])
    let remote = SequencedUsageProvider(results: [.failure(RemoteUsageError.noSources)])
    let provider = CompositeUsageProvider(local: local, throttled: [claudeProvider], remote: remote)

    let result = try await provider.refresh()

    #expect(result.snapshots.map(\.id) == ["claude"])
}

@Test func manualRefreshAsksThrottledProvidersForAManualRefresh() async throws {
    let claude = Fixtures.codexSnapshot.withToolIdentity(.claude, id: "claude")
    let base = ScriptedUsageProvider(result: .authenticated([claude]))
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let throttled = ThrottledUsageProvider(
        base: base,
        minimumInterval: 300,
        manualMinimumInterval: 30,
        now: { clock.now }
    )
    let local = ScriptedUsageProvider(result: .authenticated([Fixtures.codexSnapshot]))
    let remote = SequencedUsageProvider(results: [.failure(RemoteUsageError.noSources)])
    let provider = CompositeUsageProvider(
        local: local,
        throttled: [throttled],
        remote: remote,
        remoteRefreshInterval: 60,
        now: { clock.now }
    )

    _ = try await provider.refresh()
    clock.now.addTimeInterval(61)
    _ = try await provider.refreshAutomatically()
    #expect(await base.refreshCount == 1)

    _ = try await provider.refresh()
    #expect(await base.refreshCount == 2)
}

@Test func automaticRefreshReadsPassiveUsageDuringNetworkBackoffWithoutAdvancingOtherSources() async throws {
    let clock = CompositeTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let firstClaude = Fixtures.codexSnapshot.withToolIdentity(.claude, id: "claude")
    let updatedClaude = firstClaude.withUsage(usedPercent: 31, updatedAt: clock.now.addingTimeInterval(60))
    let cursorSnapshot = Fixtures.codexSnapshot.withToolIdentity(.cursor, id: "cursor")
    let claude = CompositePassiveProvider(
        refreshResult: .failure(LocalToolUsageError.rateLimited),
        localResults: [.authenticated([firstClaude]), .authenticated([updatedClaude]), nil]
    )
    let throttledClaude = ThrottledUsageProvider(
        base: claude,
        minimumInterval: 300,
        rateLimitedInterval: 900,
        now: { clock.now }
    )
    let codex = CompositeCountingProvider(result: .authenticated([Fixtures.codexSnapshot]))
    let cursor = CompositeCountingProvider(result: .authenticated([cursorSnapshot]))
    let remote = CompositeCountingProvider(result: .signedOut)
    let provider = CompositeUsageProvider(
        local: codex,
        throttled: [cursor, throttledClaude],
        remote: remote,
        now: { clock.now }
    )

    _ = try await provider.refresh()
    clock.now.addTimeInterval(5)
    let detected = try await provider.refreshAutomatically()

    #expect(detected.snapshots.map(\.id) == ["codex", "cursor", "claude"])
    #expect(await claude.refreshCount == 1)
    #expect(await claude.localRefreshCount == 1)
    #expect(await cursor.refreshCount == 1)
    #expect(await remote.refreshCount == 1)

    clock.now.addTimeInterval(55)
    let refreshed = try await provider.refreshAutomatically()
    #expect(refreshed.snapshots.last == updatedClaude)
    #expect(await claude.refreshCount == 1)
    #expect(await claude.localRefreshCount == 2)
    #expect(await remote.refreshCount == 2)

    clock.now.addTimeInterval(5)
    let missingLocalData = try await provider.refreshAutomatically()
    #expect(missingLocalData.snapshots.last == updatedClaude)
    #expect(await claude.refreshCount == 1)
    #expect(await claude.localRefreshCount == 3)
    #expect(await cursor.refreshCount == 2)
    #expect(await remote.refreshCount == 2)
}

@Test func passiveUsageCarriesAutomaticRefreshWhenCodexBecomesUnavailable() async throws {
    let clock = CompositeTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let claudeSnapshot = Fixtures.codexSnapshot.withToolIdentity(.claude, id: "claude")
    let codex = SequencedUsageProvider(results: [
        .success(.signedOut), .failure(LocalToolTestError.offline),
    ])
    let claude = CompositePassiveProvider(
        refreshResult: .success(.signedOut),
        localResults: [.authenticated([claudeSnapshot])]
    )
    let remote = CompositeCountingProvider(result: .signedOut)
    let provider = CompositeUsageProvider(
        local: codex,
        throttled: [claude],
        remote: remote,
        now: { clock.now }
    )

    #expect(try await provider.refresh() == .signedOut)
    clock.now.addTimeInterval(5)
    #expect(try await provider.refreshAutomatically().snapshots == [claudeSnapshot])
    #expect(await claude.refreshCount == 1)
    #expect(await remote.refreshCount == 1)
}

@Test func gatedRefreshDoesNotRollBackAcceptedPassiveUsageWhenTheLocalReadingIsMissing() async throws {
    let clock = CompositeTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let previousClaude = Fixtures.codexSnapshot.withToolIdentity(.claude, id: "claude")
    let currentClaude = previousClaude.withUsage(usedPercent: 48, updatedAt: clock.now.addingTimeInterval(5))
    let claude = CompositePassiveProvider(
        refreshResult: .success(.authenticated([previousClaude])),
        localResults: [.authenticated([currentClaude]), nil]
    )
    let throttledClaude = ThrottledUsageProvider(base: claude, minimumInterval: 300, now: { clock.now })
    let codex = CompositeCountingProvider(result: .authenticated([Fixtures.codexSnapshot]))
    let remote = CompositeCountingProvider(result: .signedOut)
    let provider = CompositeUsageProvider(
        local: codex,
        throttled: [throttledClaude],
        remote: remote,
        now: { clock.now }
    )

    _ = try await provider.refresh()
    clock.now.addTimeInterval(5)
    #expect(try await provider.refreshAutomatically().snapshots.last == currentClaude)
    clock.now.addTimeInterval(55)
    #expect(try await provider.refreshAutomatically().snapshots.last == currentClaude)
    #expect(await claude.refreshCount == 1)
    #expect(await claude.localRefreshCount == 2)
    #expect(await remote.refreshCount == 2)
}

private actor CompositePassiveProvider: LocalUsageProviding {
    private let refreshResult: Result<AccountUsageResult, Error>
    private var localResults: [AccountUsageResult?]
    private(set) var refreshCount = 0
    private(set) var localRefreshCount = 0

    init(refreshResult: Result<AccountUsageResult, Error>, localResults: [AccountUsageResult?]) {
        self.refreshResult = refreshResult
        self.localResults = localResults
    }

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        return try refreshResult.get()
    }

    func refreshLocalUsage() async -> AccountUsageResult? {
        localRefreshCount += 1
        return localResults.isEmpty ? nil : localResults.removeFirst()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private actor SequencedUsageProvider: CodexUsageProviding {
    private var results: [Result<AccountUsageResult, Error>]

    init(results: [Result<AccountUsageResult, Error>]) {
        self.results = results
    }

    func refresh() async throws -> AccountUsageResult {
        guard !results.isEmpty else { throw RemoteUsageError.invalidResponse }
        return try results.removeFirst().get()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private actor CompositeCountingProvider: CodexUsageProviding {
    private let result: AccountUsageResult
    private(set) var refreshCount = 0

    init(result: AccountUsageResult) {
        self.result = result
    }

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        return result
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private final class CompositeTestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private extension QuotaSnapshot {
    func withUsage(usedPercent: Double, updatedAt: Date) -> Self {
        QuotaSnapshot(
            id: id,
            toolID: toolID,
            displayName: displayName,
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent,
            resetAt: resetAt,
            windowDurationMinutes: windowDurationMinutes,
            planType: planType,
            updatedAt: updatedAt,
            secondaryWindow: secondaryWindow
        )
    }

    func withToolIdentity(_ toolID: AIToolID, id: String) -> Self {
        QuotaSnapshot(
            id: id,
            toolID: toolID,
            displayName: displayName,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            windowDurationMinutes: windowDurationMinutes,
            planType: planType,
            updatedAt: updatedAt,
            secondaryWindow: secondaryWindow
        )
    }

    func withRemoteIdentity() -> Self {
        var copy = self
        copy.toolID = AIToolID(rawValue: "remote")
        copy.toolName = "Remote"
        return QuotaSnapshot(
            id: "remote:\(id)",
            toolID: copy.toolID,
            toolName: copy.toolName,
            toolWebURL: copy.toolWebURL,
            toolSystemImage: copy.toolSystemImage,
            displayName: copy.displayName,
            usedPercent: copy.usedPercent,
            remainingPercent: copy.remainingPercent,
            resetAt: copy.resetAt,
            windowDurationMinutes: copy.windowDurationMinutes,
            planType: copy.planType,
            updatedAt: copy.updatedAt,
            secondaryWindow: copy.secondaryWindow
        )
    }
}
