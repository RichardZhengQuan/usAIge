import Foundation
import Testing
@testable import UsageHUD

@MainActor
@Test func publishesCurrentSnapshotsAfterRefresh() async {
    let provider = StubUsageProvider(results: [.success(.authenticated([Fixtures.codexSnapshot]))])
    let store = UsageStore(provider: provider)

    await store.refresh()

    #expect(store.state == .current([Fixtures.codexSnapshot]))
}

@MainActor
@Test func retainsSnapshotsAsStaleAfterRefreshFailure() async {
    let provider = StubUsageProvider(results: [
        .success(.authenticated([Fixtures.codexSnapshot])),
        .failure(StoreTestError.offline),
    ])
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let store = UsageStore(provider: provider, now: { now })

    await store.refresh()
    await store.refresh()

    #expect(store.state == .stale([Fixtures.codexSnapshot], since: now))
}

@MainActor
@Test func reportsSignedOutAndEmptyStates() async {
    let provider = StubUsageProvider(results: [
        .success(.signedOut),
        .success(.authenticated([])),
    ])
    let store = UsageStore(provider: provider)

    await store.refresh()
    #expect(store.state == .signedOut)
    await store.refresh()
    #expect(store.state == .empty)
}

@Test func formatsCountdownAtRequiredPrecision() {
    #expect(UsageStore.countdown(secondsRemaining: 7_260) == "2h 1m")
    #expect(UsageStore.countdown(secondsRemaining: 3_599) == "59m")
    #expect(UsageStore.countdown(secondsRemaining: 42) == "0:42")
    #expect(UsageStore.countdown(secondsRemaining: -1) == "Resetting…")
}

private actor StubUsageProvider: CodexUsageProviding {
    private var results: [Result<AccountUsageResult, Error>]

    init(results: [Result<AccountUsageResult, Error>]) {
        self.results = results
    }

    func refresh() async throws -> AccountUsageResult {
        guard !results.isEmpty else { throw StoreTestError.noResult }
        return try results.removeFirst().get()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }
}

private enum StoreTestError: Error {
    case offline
    case noResult
}
