import Foundation
import Testing
@testable import UsageHUD

@Test func compositeDropsFailedSourceCacheWhenAnotherSourceSucceeds() async throws {
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

    let first = try await provider.refresh()
    let second = try await provider.refresh()

    #expect(first.snapshots.count == 2)
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
