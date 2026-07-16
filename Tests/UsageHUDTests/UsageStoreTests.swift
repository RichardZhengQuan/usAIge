import AppKit
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

@MainActor
@Test func publishesSnapshotChangesToTheLimitNotificationObserver() async {
    let provider = StubUsageProvider(results: [
        .success(.authenticated([Fixtures.codexSnapshot])),
        .success(.signedOut),
    ])
    let store = UsageStore(provider: provider)
    var observedSnapshots: [[QuotaSnapshot]] = []
    store.onSnapshotsChanged = { observedSnapshots.append($0) }

    await store.refresh()
    await store.refresh()

    #expect(observedSnapshots == [[Fixtures.codexSnapshot], []])
}

@MainActor
@Test func freshnessCheckAvoidsRedundantRefreshes() async {
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = StubUsageProvider(results: [
        .success(.authenticated([Fixtures.codexSnapshot])),
        .success(.authenticated([Fixtures.codexSnapshot])),
    ])
    let store = UsageStore(provider: provider, now: { clock.now })

    await store.refresh()
    clock.now.addTimeInterval(4)
    await store.refreshIfNeeded(maximumAge: 5)
    #expect(await provider.refreshCount == 1)

    clock.now.addTimeInterval(2)
    await store.refreshIfNeeded(maximumAge: 5)
    #expect(await provider.refreshCount == 2)
}

@Test func formatsCountdownAtRequiredPrecision() {
    #expect(UsageStore.countdown(secondsRemaining: 7_260) == "2h 1m")
    #expect(UsageStore.countdown(secondsRemaining: 3_599) == "59m")
    #expect(UsageStore.countdown(secondsRemaining: 42) == "0:42")
    #expect(UsageStore.countdown(secondsRemaining: -1) == "Resetting…")
}

@MainActor
@Test func shutdownStopsTheUsageProvider() async {
    let provider = StubUsageProvider(results: [])
    let store = UsageStore(provider: provider)

    await store.shutdown()

    #expect(await provider.stopped)
}

@MainActor
@Test func automaticallyRefreshesUsageOnAFastFallbackInterval() async throws {
    let provider = CountingUsageProvider()
    let store = UsageStore(
        provider: provider,
        automaticRefreshInterval: 0.01,
        monitorsNetworkChanges: false
    )

    store.start()
    for _ in 0..<50 where await provider.refreshCount < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    store.stop()

    #expect(await provider.refreshCount >= 2)
}

@MainActor
@Test func refreshesImmediatelyAfterWakeNotification() async throws {
    let provider = CountingUsageProvider()
    let notificationCenter = NotificationCenter()
    let store = UsageStore(
        provider: provider,
        automaticRefreshInterval: 60,
        workspaceNotificationCenter: notificationCenter,
        monitorsNetworkChanges: false
    )

    store.start()
    for _ in 0..<50 where await provider.refreshCount < 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    for _ in 0..<50 where await provider.refreshCount < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    store.stop()

    #expect(await provider.refreshCount >= 2)
}

@MainActor
@Test func refreshesWhenNetworkConnectivityReturns() async {
    let provider = CountingUsageProvider()
    let store = UsageStore(provider: provider, monitorsNetworkChanges: false)

    await store.handleNetworkAvailabilityChange(isAvailable: true)
    await store.handleNetworkAvailabilityChange(isAvailable: false)
    await store.handleNetworkAvailabilityChange(isAvailable: true)

    #expect(await provider.refreshCount == 1)
}

private actor StubUsageProvider: CodexUsageProviding {
    private var results: [Result<AccountUsageResult, Error>]
    private(set) var stopped = false
    private(set) var refreshCount = 0

    init(results: [Result<AccountUsageResult, Error>]) {
        self.results = results
    }

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        guard !results.isEmpty else { throw StoreTestError.noResult }
        return try results.removeFirst().get()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {
        stopped = true
    }
}

private actor CountingUsageProvider: CodexUsageProviding {
    private(set) var refreshCount = 0

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        return .authenticated([Fixtures.codexSnapshot])
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { _ in }
    }

    func stop() async {}
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private enum StoreTestError: Error {
    case offline
    case noResult
}
