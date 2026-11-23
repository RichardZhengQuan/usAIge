import Foundation
import Testing
@testable import UsageHUD

private let cacheHistoryNow = Date(timeIntervalSince1970: 1_800_000_000)
private let cacheHistoryOrganization = "bc2ae38e-b50d-4dd8-84d2-459c2de2a02e"

private func historyPayload(session: Double = 6, weekly: Double = 26) -> JSONValue {
    let reset = ISO8601DateFormatter().string(from: cacheHistoryNow.addingTimeInterval(3_600))
    return JSONValue.parse(Data("""
    {"five_hour":{"utilization":\(session),"resets_at":"\(reset)"},
     "seven_day":{"utilization":\(weekly),"resets_at":"\(reset)"}}
    """.utf8))!
}

private func withCacheHistory<T>(
    organization: String = cacheHistoryOrganization,
    historyDate: Date = cacheHistoryNow,
    cache: ClaudeDesktopCachedUsage?,
    body: (ClaudeAppUsageHistory) throws -> T
) throws -> T {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-cache-history-\(UUID())")
    let directory = home.appendingPathComponent("Library/Application Support/Claude")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("""
    {"samples":[{"t":\(historyDate.timeIntervalSince1970 * 1000),"org":"\(organization)","u":{"fh":6,"sd":26}}]}
    """.utf8).write(to: directory.appendingPathComponent("plan-usage-history.json"))
    let source = ClaudeAppUsageHistory(homeDirectory: home, readCachedUsage: { id, _ in
        id == cacheHistoryOrganization ? cache : nil
    }, now: { cacheHistoryNow })
    return try body(source)
}

@Test(arguments: [60.0, 1_801.0, 10_800.0])
func claudeCacheNewerResponseUpdatesHistoryPercentagesAndObservation(historyAge: TimeInterval) throws {
    let cache = ClaudeDesktopCachedUsage(payload: historyPayload(session: 8, weekly: 27), recordedAt: cacheHistoryNow)
    try withCacheHistory(historyDate: cacheHistoryNow.addingTimeInterval(-historyAge), cache: cache) { source in
        let sample = try #require(source.latestSample())
        #expect(sample.recordedAt == cacheHistoryNow)
        #expect(sample.sessionPercent == 8)
        #expect(sample.weeklyPercent == 27)
        #expect(sample.cachedUsage == cache)
        #expect(ClaudeUsageProvider.snapshots(fromClaudeApp: sample, planType: nil).first?.resetAt != nil)
    }
}

@Test func claudeCacheOlderResponseRequiresMatchingHistoryPercentages() throws {
    let earlier = cacheHistoryNow.addingTimeInterval(-60)
    for session in [6.0, 5.0] {
        let cache = ClaudeDesktopCachedUsage(payload: historyPayload(session: session), recordedAt: earlier)
        try withCacheHistory(cache: cache) { source in
            let sample = try #require(source.latestSample())
            #expect(sample.sessionPercent == 6)
            #expect(sample.recordedAt == cacheHistoryNow)
            #expect((sample.cachedUsage != nil) == (session == 6))
            if session == 6 {
                #expect(ClaudeUsageProvider.snapshots(fromClaudeApp: sample, planType: nil).first?.updatedAt == earlier)
            }
        }
    }
}

@Test(arguments: [-1_801.0, 1.0])
func claudeCacheHistoryRejectsStaleAndFutureCache(age: Double) throws {
    let cache = ClaudeDesktopCachedUsage(payload: historyPayload(), recordedAt: cacheHistoryNow.addingTimeInterval(age))
    try withCacheHistory(cache: cache) { source in
        #expect(source.latestSample()?.cachedUsage == nil)
        #expect(source.latestSample()?.sessionPercent == 6)
    }
}

@Test func claudeCacheHistoryNeedsValidCurrentOrganizationEvidence() throws {
    let cache = ClaudeDesktopCachedUsage(payload: historyPayload(), recordedAt: cacheHistoryNow)
    try withCacheHistory(organization: "not-an-organization", cache: cache) { source in
        #expect(source.latestSample()?.organizationID == nil)
        #expect(source.latestSample()?.cachedUsage == nil)
    }
    try withCacheHistory(historyDate: cacheHistoryNow.addingTimeInterval(1), cache: cache) { source in
        #expect(source.latestSample()?.cachedUsage == nil)
    }
}

@Test func claudeCacheHistoryDoesNotReusePreviousOrganizationAfterEmptySwitch() throws {
    let other = "78e01022-088f-4f59-8f6a-969e1bd50a67"
    let samples = """
    {"samples":[
     {"t":1799999700000,"org":"\(cacheHistoryOrganization)","u":{"fh":6,"sd":26}},
     {"t":1799999800000,"org":"\(other)","u":{}}]}
    """
    #expect(ClaudeAppUsageHistory.latestSample(from: Data(samples.utf8)) == nil)
    let sameOrganization = samples.replacingOccurrences(of: other, with: cacheHistoryOrganization)
    #expect(ClaudeAppUsageHistory.latestSample(from: Data(sameOrganization.utf8))?.organizationID == cacheHistoryOrganization)
}

@Test(arguments: ["", "invalid-organization"])
func claudeCacheHistoryCannotInferCurrentOrganizationFromAnEarlierRecord(organization: String) throws {
    let samples = """
    {"samples":[
     {"t":1799999700000,"org":"\(cacheHistoryOrganization)","u":{"fh":6,"sd":26}},
     {"t":1799999800000,"org":"\(organization)","u":{}}]}
    """
    let sample = try #require(ClaudeAppUsageHistory.latestSample(from: Data(samples.utf8)))
    #expect(sample.sessionPercent == 6)
    #expect(sample.organizationID == nil)
    #expect(sample.cachedUsage == nil)
}

@Test func claudeCacheHistoryKeepsModelScopedAuthoritativeLimits() throws {
    let payload = JSONValue.parse(Data("""
    {"limits":[{"kind":"session","percent":8,"resets_at":"2027-01-16T09:00:00Z"},
     {"kind":"weekly_all","percent":27,"resets_at":"2027-01-20T09:00:00Z"},
     {"kind":"weekly_model","group":"weekly","percent":10,"resets_at":"2027-01-20T09:00:00Z",
      "scope":{"model":{"id":"sonnet","display_name":"Sonnet"}}}]}
    """.utf8))!
    let cache = ClaudeDesktopCachedUsage(payload: payload, recordedAt: cacheHistoryNow)
    try withCacheHistory(historyDate: cacheHistoryNow.addingTimeInterval(-60), cache: cache) { source in
        let sample = try #require(source.latestSample())
        #expect(sample.sessionPercent == 8)
        #expect(sample.weeklyPercent == 27)
        #expect(ClaudeUsageProvider.snapshots(fromClaudeApp: sample, planType: nil).map(\.id) == ["claude", "claude_sonnet"])
    }
}

/// A response too old to show still lends the reset times of windows that
/// haven't reset since: usage only grows within a window.
@Test(arguments: [5.0, 6.0, 7.0])
func claudeEarlierResponseLendsResetsWhileItsWindowsRun(cachedSession: Double) throws {
    // History reads 6% of the 5-hour window and 26% of the week.
    let reset = cacheHistoryNow.addingTimeInterval(3_600)
    let payload = historyPayload(session: cachedSession, weekly: 20)
    let earlier = ClaudeDesktopCachedUsage(payload: payload, recordedAt: cacheHistoryNow.addingTimeInterval(-3 * 3_600))
    let sample = ClaudeAppUsageHistory.carryingResets(
        from: earlier,
        into: ClaudeAppUsageSample(recordedAt: cacheHistoryNow, sessionPercent: 6, weeklyPercent: 26),
        now: cacheHistoryNow
    )
    // 5% and 6% are at or below the history's 6%: the same window. 7% is
    // above it, so the window has reset since and its time is gone.
    #expect((sample.sessionResetAt != nil) == (cachedSession <= 6))
    #expect(sample.weeklyResetAt.map { abs($0.timeIntervalSince(reset)) < 1 } == true)
    #expect(sample.cachedUsage == nil)
    let snapshot = try #require(ClaudeUsageProvider.snapshots(fromClaudeApp: sample, planType: nil).first)
    #expect(snapshot.usedPercent == 6)
    #expect(snapshot.secondaryWindow?.usedPercent == 26)
    #expect(snapshot.secondaryWindow?.resetAt != nil)
}

@Test func claudeEarlierResponseNeverLendsAPassedReset() throws {
    let passed = ISO8601DateFormatter().string(from: cacheHistoryNow.addingTimeInterval(-60))
    let payload = JSONValue.parse(Data("""
    {"five_hour":{"utilization":3,"resets_at":"\(passed)"},"seven_day":{"utilization":20,"resets_at":"\(passed)"}}
    """.utf8))!
    let earlier = ClaudeDesktopCachedUsage(payload: payload, recordedAt: cacheHistoryNow.addingTimeInterval(-6 * 3_600))
    let sample = ClaudeAppUsageHistory.carryingResets(
        from: earlier,
        into: ClaudeAppUsageSample(recordedAt: cacheHistoryNow, sessionPercent: 6, weeklyPercent: 26),
        now: cacheHistoryNow
    )
    #expect(sample.sessionResetAt == nil)
    #expect(sample.weeklyResetAt == nil)
}

@Test func claudeStaleCacheStillLendsResetsToHistory() throws {
    let cache = ClaudeDesktopCachedUsage(payload: historyPayload(session: 6, weekly: 26),
                                         recordedAt: cacheHistoryNow.addingTimeInterval(-2 * 3_600))
    try withCacheHistory(cache: cache) { source in
        let sample = try #require(source.latestSample())
        #expect(sample.cachedUsage == nil)
        #expect(sample.sessionResetAt != nil)
        #expect(sample.weeklyResetAt != nil)
    }
}
