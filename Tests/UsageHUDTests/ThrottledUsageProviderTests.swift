import Foundation
import Testing
@testable import UsageHUD

private func claudeSnapshot(remaining: Double) -> QuotaSnapshot {
    var snapshot = QuotaSnapshot(
        id: "claude",
        displayName: "All models",
        usedPercent: 100 - remaining,
        remainingPercent: remaining,
        resetAt: nil,
        windowDurationMinutes: 300,
        planType: nil,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    snapshot.toolID = .claude
    return snapshot
}

@Test func throttleReturnsCachedResultsUntilTheIntervalElapses() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(results: [
        .success(.authenticated([claudeSnapshot(remaining: 80)])),
        .success(.authenticated([claudeSnapshot(remaining: 70)])),
    ])
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 300,
        manualMinimumInterval: 60,
        now: { clock.now }
    )

    let first = try await provider.refresh()
    clock.now.addTimeInterval(120)
    let cached = try await provider.refresh()
    #expect(first == cached)
    #expect(await base.refreshCount == 1)

    clock.now.addTimeInterval(200)
    let refreshed = try await provider.refresh()
    #expect(refreshed.snapshots.first?.remainingPercent == 70)
    #expect(await base.refreshCount == 2)
}

@Test func manualRefreshUsesTheShorterFloor() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(result: .authenticated([claudeSnapshot(remaining: 80)]))
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 300,
        manualMinimumInterval: 60,
        now: { clock.now }
    )

    _ = try await provider.refresh()
    clock.now.addTimeInterval(30)
    _ = try await provider.refresh(manual: true)
    #expect(await base.refreshCount == 1)

    clock.now.addTimeInterval(40)
    _ = try await provider.refresh(manual: true)
    #expect(await base.refreshCount == 2)
    _ = try await provider.refresh(manual: false)
    #expect(await base.refreshCount == 2)
}

@Test func signedOutResultsAreRetriedSooner() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(results: [
        .success(.signedOut),
        .success(.authenticated([claudeSnapshot(remaining: 55)])),
    ])
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 300,
        signedOutRetryInterval: 30,
        now: { clock.now }
    )

    #expect(try await provider.refresh() == .signedOut)
    clock.now.addTimeInterval(31)
    #expect(try await provider.refresh().snapshots.count == 1)
    #expect(await base.refreshCount == 2)
}

@Test func rateLimitingBacksOffEvenForManualRefreshes() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(results: [
        .success(.authenticated([claudeSnapshot(remaining: 80)])),
        .failure(LocalToolUsageError.rateLimited),
        .success(.authenticated([claudeSnapshot(remaining: 60)])),
    ])
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 60,
        manualMinimumInterval: 10,
        rateLimitedInterval: 600,
        now: { clock.now }
    )

    _ = try await provider.refresh()
    clock.now.addTimeInterval(61)
    await #expect(throws: LocalToolUsageError.rateLimited) {
        try await provider.refresh()
    }
    clock.now.addTimeInterval(120)
    // Still inside the rate-limit window: the cached result is returned and
    // the provider is not contacted again, even for a manual refresh.
    let cached = try await provider.refresh(manual: true)
    #expect(cached.snapshots.first?.remainingPercent == 80)
    #expect(await base.refreshCount == 2)

    clock.now.addTimeInterval(500)
    let recovered = try await provider.refresh()
    #expect(recovered.snapshots.first?.remainingPercent == 60)
    #expect(await base.refreshCount == 3)
}

@Test func failuresWithoutACachedResultRethrowUntilRetryTime() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(results: [
        .failure(LocalToolUsageError.http(503)),
        .success(.authenticated([claudeSnapshot(remaining: 42)])),
    ])
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 60,
        manualMinimumInterval: 5,
        failureRetryInterval: 120,
        now: { clock.now }
    )

    await #expect(throws: LocalToolUsageError.http(503)) {
        try await provider.refresh()
    }
    clock.now.addTimeInterval(30)
    await #expect(throws: LocalToolUsageError.http(503)) {
        try await provider.refresh()
    }
    #expect(await base.refreshCount == 1)

    let manual = try await provider.refresh(manual: true)
    #expect(manual.snapshots.first?.remainingPercent == 42)
    #expect(await base.refreshCount == 2)

    await provider.stop()
    #expect(await base.stopCount == 1)
}

private actor SlowUsageProvider: CodexUsageProviding {
    private let delayNanoseconds: UInt64
    private let result: AccountUsageResult
    private(set) var refreshCount = 0

    init(delay: TimeInterval, result: AccountUsageResult) {
        delayNanoseconds = UInt64(delay * 1_000_000_000)
        self.result = result
    }

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

@Test func aBlockedRefreshDoesNotHoldUpCallersAndLandsLater() async throws {
    let base = SlowUsageProvider(delay: 0.5, result: .authenticated([claudeSnapshot(remaining: 64)]))
    let provider = ThrottledUsageProvider(base: base, minimumInterval: 300, waitLimit: 0.05)

    await #expect(throws: LocalToolUsageError.timedOut) {
        try await provider.refresh()
    }
    // A second caller joins the in-flight refresh instead of starting another.
    await #expect(throws: LocalToolUsageError.timedOut) {
        try await provider.refresh(manual: true)
    }
    #expect(await base.refreshCount == 1)

    try await Task.sleep(nanoseconds: 700_000_000)
    let landed = try await provider.refresh()
    #expect(landed.snapshots.first?.remainingPercent == 64)
    #expect(await base.refreshCount == 1)
}

@Test func keychainDenialBacksOffAutomaticallyButAllowsAManualRetry() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(results: [
        .failure(LocalToolUsageError.keychainAccessDenied),
        .success(.authenticated([claudeSnapshot(remaining: 90)])),
    ])
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 300,
        manualMinimumInterval: 60,
        accessDeniedRetryInterval: 3_600,
        now: { clock.now }
    )

    await #expect(throws: LocalToolUsageError.keychainAccessDenied) {
        try await provider.refresh()
    }
    clock.now.addTimeInterval(1_800)
    await #expect(throws: LocalToolUsageError.keychainAccessDenied) {
        try await provider.refresh()
    }
    #expect(await base.refreshCount == 1)

    let manual = try await provider.refresh(manual: true)
    #expect(manual.snapshots.first?.remainingPercent == 90)
    #expect(await base.refreshCount == 2)
}

@Test func aSignedOutResultAllowsAnImmediateManualRetry() async throws {
    let clock = TestClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    let base = ScriptedUsageProvider(results: [
        .success(.signedOut),
        .success(.authenticated([claudeSnapshot(remaining: 70)])),
    ])
    let provider = ThrottledUsageProvider(
        base: base,
        minimumInterval: 300,
        manualMinimumInterval: 60,
        now: { clock.now }
    )

    #expect(try await provider.refresh() == .signedOut)
    // Turning the tool on triggers a manual refresh right away.
    #expect(try await provider.refresh(manual: true).snapshots.count == 1)
    #expect(await base.refreshCount == 2)
}
